(* ::Package:: *)

(* ClaudeRuntime_seatbroker.wl -- ライセンス席ブローカ (hardening 01 Inc1, 2026-07-07)

   仕様: SourceVault_info/design/system_hardening_operations_guideline/
         01_seatbroker_spec_v0.2.md

   目的:
     Wolfram ライセンス席 (controller 4 / subkernel 16, strixhalo128 実測) を
     単一のアロケータで管理し、席枯渇による wolframscript 起動不能・
     サービスカーネル silent 死・ParallelSubmit フリーズを構造的に防ぐ。

   設計要点 (v0.2):
     - Acquire は固定 lock (acquire.lock ディレクトリ, CreateDirectory の原子性)
       で直列化する。UUID token ファイルの作成は entry 書き込みとしては原子的
       だが token ごとにパスが異なり相互排他にならない (レビュー r1 P1-1)。
     - lock は TTL 30s で stale 破棄 (owner PID 死亡でも破棄)。
     - ledger entry は TTL 必須。TTL 失効 / owner kernel 死で reaper が回収し
       SeatLeaked を emit。**返却漏れが席を恒久占有しない**ことが不変条件。
     - 台帳は「実測 ($LicenseProcesses 等) にまだ現れていない spawn 中」の
       補正用。spawn 完了後は実測側に現れて二重計上になるため、capacity 計算
       では若い entry (SpawnGraceSeconds 以内) だけを差し引く。
     - 置き場所は $UserBaseDirectory 配下 (Dropbox 外)。席はマシンローカル資源。

   Load:
     Block[{$CharacterEncoding = "UTF-8"}, Get["ClaudeRuntime_seatbroker.wl"]]
     (claudecode.wl が先にロードされていれば SeatDenied/SeatLeaked 等を
      SIEM spool へ emit する。無ければ emit は no-op。)
*)

BeginPackage["ClaudeRuntime`"];

ClaudeSeatAcquire::usage =
  "ClaudeSeatAcquire[purpose, opts] はライセンス席を 1 つ確保し token association を返す。\n" <>
  "確保できない場合は Failure[\"NoSeat\"|\"SeatBrokerBusy\", <|\"Deferred\"->True,...|>] (呼び出し側が tick/RetryPolicy で再試行する)。\n" <>
  "opts: \"Pool\"->\"Controller\"|\"Subkernel\" (既定 Controller), \"Priority\"->_Integer (既定 40; >=90 は Reserve に食い込み可),\n" <>
  "\"TTLSeconds\"->_Integer (既定 600; 失効すると reaper が回収し SeatLeaked を記録), \"JobId\"->_String。\n" <>
  "Acquire に成功した呼び出し元は spawn 失敗時に必ず ClaudeSeatRelease を呼ぶこと (spec 01 §5.1)。";
ClaudeSeatRelease::usage =
  "ClaudeSeatRelease[token] は確保済みの席を返却する。既に reaper が回収済みの場合は Failure[\"UnknownToken\"] を返す (致命エラー扱いにしないこと)。";
ClaudeSeatWithSeat::usage =
  "ClaudeSeatWithSeat[purpose, fn, opts] は席を確保して fn[token] を実行し、終了時 (異常時含む) に必ず返却する同期スコープ用ラッパ。確保失敗時は fn を呼ばず Failure を返す。";
ClaudeSeatLedger::usage =
  "ClaudeSeatLedger[] は現在の席台帳と実測 free の診断 association を返す (<|\"Pools\"->..., \"Entries\"->Dataset|>)。";
ClaudeSeatReap::usage =
  "ClaudeSeatReap[] は TTL 失効 / owner kernel 死亡の ledger entry を回収する。回収時は SeatLeaked を SIEM に記録する。戻り値 <|\"Expired\"->n, \"OrphanOwner\"->m|>。";
$ClaudeSeatPools::usage =
  "$ClaudeSeatPools はプール定義 <|name -> <|\"CapacityFn\":>expr, \"Reserve\"->n|>|>。Controller の Reserve 1 は FE 対話用の予約席。";

Begin["`Private`"];

(* ── 定数 ── *)
If[! AssociationQ[$ClaudeSeatPools],
  $ClaudeSeatPools = <|
    "Controller" -> <|
      "CapacityFn" :> Max[0, Quiet @ Check[
        $MaxLicenseProcesses - $LicenseProcesses, 0]],
      "Reserve" -> 1|>,
    "Subkernel" -> <|
      "CapacityFn" :> Max[0, Quiet @ Check[
        $MaxLicenseSubprocesses - Length[Quiet @ Check[Kernels[], {}]], 0]],
      "Reserve" -> 0|>
  |>];
If[! ValueQ[$iSBLockTTLSeconds], $iSBLockTTLSeconds = 30];
If[! ValueQ[$iSBSpawnGraceSeconds], $iSBSpawnGraceSeconds = 60];
If[! ValueQ[$iSBDefaultTTLSeconds], $iSBDefaultTTLSeconds = 600];

(* ── パス ── *)
iSBRoot[] := FileNameJoin[{$UserBaseDirectory, "ApplicationData",
  "ClaudeRuntime", "seatbroker"}];
iSBLedgerDir[] := FileNameJoin[{iSBRoot[], "ledger"}];
iSBLockDir[] := FileNameJoin[{iSBRoot[], "acquire.lock"}];
iSBEnsureDirs[] := Quiet @ CreateDirectory[iSBLedgerDir[],
  CreateIntermediateDirectories -> True];

(* ── JSON I/O (temp-rename; 共通規約 2) ── *)
iSBJSONSafe[a_Association] :=
  Association @ KeyValueMap[ToString[#1] -> iSBJSONSafe[#2] &, a];
iSBJSONSafe[l_List] := iSBJSONSafe /@ l;
iSBJSONSafe[x_String] := x;
iSBJSONSafe[x_Integer] := x;
iSBJSONSafe[x_Real] := x;
iSBJSONSafe[x : (True | False | Null)] := x;
iSBJSONSafe[x_] := ToString[x, InputForm];

iSBWriteJSON[path_String, assoc_Association] := Module[{ba, tmp, strm, ok},
  ba = Quiet @ ExportByteArray[iSBJSONSafe[assoc], "RawJSON", "Compact" -> True];
  If[! ByteArrayQ[ba], Return[$Failed]];
  tmp = path <> ".tmp-" <> ToString[$ProcessID];
  strm = Quiet @ OpenWrite[tmp, BinaryFormat -> True];
  If[Head[strm] =!= OutputStream, Return[$Failed]];
  BinaryWrite[strm, ba]; Close[strm];
  ok = Quiet @ Check[RenameFile[tmp, path, OverwriteTarget -> True]; True, False];
  If[! TrueQ[ok], Quiet @ DeleteFile[tmp]; Return[$Failed]];
  path];

iSBReadJSON[path_String] := Module[{b},
  If[! FileExistsQ[path], Return[Missing["NoFile"]]];
  b = Quiet @ ReadByteArray[path];
  If[! ByteArrayQ[b], Return[Missing["Empty"]]];
  With[{r = Quiet @ ImportByteArray[b, "RawJSON"]},
    If[AssociationQ[r], r, Missing["Corrupt"]]]];

(* ── PID 生存 (servicemanager と同方式: tasklist) ── *)
iSBPidAlive[pid_Integer] := Module[{out},
  out = Quiet @ RunProcess[{"tasklist", "/FI", "PID eq " <> ToString[pid], "/NH"}];
  AssociationQ[out] && StringContainsQ[Lookup[out, "StandardOutput", ""],
    ToString[pid]]];
iSBPidAlive[_] := False;

(* ── SIEM emit 委譲 (claudecode.wl の spool shim へ。無ければ no-op) ── *)
iSBDiagEmit[class_String, payload_Association, severity_String: "warn"] :=
  Quiet @ Check[
    If[Length[DownValues[ClaudeCode`Private`iClaudeDiagEmit]] > 0,
      ClaudeCode`Private`iClaudeDiagEmit[class, payload, severity,
        "Producer" -> "ClaudeRuntime"]];
    Null,
    Null];

(* ── acquire lock (固定名ディレクトリ; CreateDirectory の原子性で相互排他) ── *)
iSBTryLockOnce[] := Module[{lock = iSBLockDir[], r},
  iSBEnsureDirs[];
  r = Quiet @ Check[CreateDirectory[lock], $Failed];
  If[r === $Failed, False,
    Quiet @ iSBWriteJSON[FileNameJoin[{lock, "owner.json"}],
      <|"PID" -> $ProcessID, "AcquiredAtAbs" -> AbsoluteTime[]|>];
    True]];

iSBBreakStaleLock[] := Module[{lock = iSBLockDir[], owner, at, pid, dirAge},
  If[! DirectoryQ[lock], Return[Null]];
  owner = iSBReadJSON[FileNameJoin[{lock, "owner.json"}]];
  If[AssociationQ[owner],
    at = Lookup[owner, "AcquiredAtAbs"]; pid = Lookup[owner, "PID"];
    If[(! NumericQ[at]) ||
       AbsoluteTime[] - at > $iSBLockTTLSeconds ||      (* TTL 超過 *)
       (IntegerQ[pid] && ! iSBPidAlive[pid]),           (* owner 死亡 *)
      Quiet @ DeleteDirectory[lock, DeleteContents -> True]],
    (* owner.json がまだ無い/読めない場合、それは「取得者が mkdir 直後で
       owner を書く前」の正常な窓かもしれない。ここで即破棄すると他者の
       新鮮な lock を壊し相互排他が破れる (競合テストで実証済みの穴)。
       lock ディレクトリ自体の年齢が 5s を超えたときだけ壊れとみなす
       (mkdir と owner 書きの間は ms オーダー; 5s 超は取得者の即死)。
       なお stale 破棄→再取得の間の TOCTOU 窓は残るが、これは 30s 超の
       異常からの回復パスに限定される (spec 01 §4.1 の許容範囲)。 *)
    dirAge = Quiet @ Check[
      AbsoluteTime[] - AbsoluteTime[FileDate[lock, "Modification"]], 0];
    If[NumericQ[dirAge] && dirAge > 5,
      Quiet @ DeleteDirectory[lock, DeleteContents -> True]]];
  Null];

iSBAcquireLock[] := Module[{got = False},
  Do[
    got = iSBTryLockOnce[];
    If[got, Break[]];
    iSBBreakStaleLock[];
    got = iSBTryLockOnce[];
    If[got, Break[]];
    Pause[RandomReal[{0.05, 0.15}]],
    {3}];
  got];

iSBReleaseLock[] := Module[{lock = iSBLockDir[], owner},
  owner = iSBReadJSON[FileNameJoin[{lock, "owner.json"}]];
  (* 自分の lock だけ消す (他者の lock を壊さない) *)
  If[AssociationQ[owner] && Lookup[owner, "PID"] === $ProcessID,
    Quiet @ DeleteDirectory[lock, DeleteContents -> True]];
  Null];

(* ── ledger ── *)
iSBLedgerEntries[] := Module[{files},
  iSBEnsureDirs[];
  files = Quiet @ Check[FileNames["seat-*.json", iSBLedgerDir[]], {}];
  Select[iSBReadJSON /@ files, AssociationQ]];

iSBEntryExpiredQ[e_Association] := Module[{at, ttl, opid},
  at = Lookup[e, "AcquiredAtAbs"]; ttl = Lookup[e, "TTLSeconds"];
  opid = Lookup[e, "OwnerKernelPid"];
  Which[
    ! NumericQ[at] || ! NumericQ[ttl], True,            (* 壊れ entry は失効扱い *)
    AbsoluteTime[] - at > ttl, True,
    IntegerQ[opid] && ! iSBPidAlive[opid], True,
    True, False]];

(* capacity から差し引くのは若い entry のみ (spawn がまだ実測に現れていない
   補正窓)。古い entry は実測 ($LicenseProcesses 等) 側に現れており、
   両方数えると二重計上で過剰 defer になる。 *)
iSBEntryCountsAgainstCapacityQ[e_Association] := Module[{at},
  at = Lookup[e, "AcquiredAtAbs"];
  NumericQ[at] && AbsoluteTime[] - at <= $iSBSpawnGraceSeconds &&
    ! iSBEntryExpiredQ[e]];

iSBReapLocked[] := Module[{entries, expired = 0, orphan = 0},
  (* 呼び出し側が lock 保持済み前提。失効 entry を削除 + SeatLeaked emit。 *)
  entries = iSBLedgerEntries[];
  Scan[Module[{e = #, opid},
      If[iSBEntryExpiredQ[e],
        opid = Lookup[e, "OwnerKernelPid"];
        If[IntegerQ[opid] && ! iSBPidAlive[opid], orphan++, expired++];
        Quiet @ DeleteFile[FileNameJoin[{iSBLedgerDir[],
          Lookup[e, "Token", "?"] <> ".json"}]];
        iSBDiagEmit["SeatLeaked",
          <|"Token" -> Lookup[e, "Token"], "Purpose" -> Lookup[e, "Purpose"],
            "Pool" -> Lookup[e, "Pool"],
            "TTLSeconds" -> Lookup[e, "TTLSeconds"],
            "Reason" -> If[IntegerQ[opid] && ! iSBPidAlive[opid],
              "OwnerDead", "TTLExpired"]|>, "error"]]] &,
    entries];
  <|"Expired" -> expired, "OrphanOwner" -> orphan|>];

iSBPoolFree[pool_String] := Module[{def, cap, reserve, active},
  def = Lookup[$ClaudeSeatPools, pool];
  If[! AssociationQ[def], Return[Missing["UnknownPool"]]];
  cap = Quiet @ Check[def["CapacityFn"], 0];
  reserve = Lookup[def, "Reserve", 0];
  active = Count[iSBLedgerEntries[],
    e_ /; Lookup[e, "Pool"] === pool && iSBEntryCountsAgainstCapacityQ[e]];
  <|"Capacity" -> cap, "Reserve" -> reserve, "ActiveYoung" -> active,
    "Free" -> cap - active - reserve,
    "FreeWithReserve" -> cap - active|>];

(* ── 公開 API ── *)
ClaudeSeatAcquire[purpose_String, opts___Rule] := Module[
  {o = <|opts|>, pool, priority, ttl, jobId, got, free, token, entry, path},
  pool = Lookup[o, "Pool", "Controller"];
  priority = Lookup[o, "Priority", 40];
  ttl = Lookup[o, "TTLSeconds", $iSBDefaultTTLSeconds];
  jobId = Lookup[o, "JobId", ""];
  If[! KeyExistsQ[$ClaudeSeatPools, pool],
    Return[Failure["UnknownPool", <|"Pool" -> pool|>]]];
  got = iSBAcquireLock[];
  If[! TrueQ[got],
    iSBDiagEmit["SeatBrokerBusy",
      <|"Purpose" -> purpose, "RetriedTimes" -> 3|>];
    Return[Failure["SeatBrokerBusy",
      <|"MessageTemplate" -> "seat broker lock busy", "Deferred" -> True|>]]];
  (* ── 臨界区間 (純ローカル I/O のみ; ネットワーク/LLM 禁止) ── *)
  Module[{result},
    result = Quiet @ Check[
      iSBReapLocked[];
      free = iSBPoolFree[pool];
      If[(priority >= 90 && free["FreeWithReserve"] > 0) ||
         free["Free"] > 0,
        token = "seat-" <> CreateUUID[];
        entry = <|"Token" -> token, "Pool" -> pool, "Purpose" -> purpose,
          "Priority" -> priority, "OwnerKernelPid" -> $ProcessID,
          "AcquiredAtAbs" -> AbsoluteTime[],
          "AcquiredAtUTC" -> DateString[TimeZoneConvert[Now, 0],
            "ISODateTime"] <> "Z",
          "TTLSeconds" -> ttl, "JobId" -> jobId|>;
        path = FileNameJoin[{iSBLedgerDir[], token <> ".json"}];
        If[iSBWriteJSON[path, entry] === $Failed,
          Failure["LedgerWriteFailed", <|"Path" -> path|>],
          entry],
        Failure["NoSeat",
          <|"MessageTemplate" -> "no license seat available",
            "Deferred" -> True, "Pool" -> pool,
            "FreeSeats" -> free["Free"], "Capacity" -> free["Capacity"]|>]],
      Failure["SeatBrokerError", <|"Purpose" -> purpose|>]];
    iSBReleaseLock[];
    If[MatchQ[result, Failure["NoSeat", ___]],
      iSBDiagEmit["SeatDenied",
        <|"Purpose" -> purpose, "Pool" -> pool,
          "FreeSeats" -> Lookup[free, "Free", Missing[]],
          "Priority" -> priority|>]];
    result]];

ClaudeSeatRelease[token_String] := Module[{path},
  path = FileNameJoin[{iSBLedgerDir[], token <> ".json"}];
  If[! FileExistsQ[path],
    Return[Failure["UnknownToken", <|"Token" -> token|>]]];
  Quiet @ DeleteFile[path];
  True];
ClaudeSeatRelease[entry_Association] :=
  ClaudeSeatRelease[Lookup[entry, "Token", ""]];

ClaudeSeatWithSeat[purpose_String, fn_, opts___Rule] := Module[{seat},
  seat = ClaudeSeatAcquire[purpose, opts];
  If[FailureQ[seat], Return[seat]];
  WithCleanup[
    fn[seat["Token"]],
    Quiet @ ClaudeSeatRelease[seat["Token"]]]];

ClaudeSeatLedger[] := Module[{entries},
  entries = iSBLedgerEntries[];
  <|"Pools" -> AssociationMap[iSBPoolFree, Keys[$ClaudeSeatPools]],
    "Entries" -> Dataset[entries]|>];

ClaudeSeatReap[] := Module[{got, r},
  got = iSBAcquireLock[];
  If[! TrueQ[got],
    Return[Failure["SeatBrokerBusy", <|"Deferred" -> True|>]]];
  r = Quiet @ Check[iSBReapLocked[], <|"Expired" -> 0, "OrphanOwner" -> 0|>];
  iSBReleaseLock[];
  r];

End[];
EndPackage[];
