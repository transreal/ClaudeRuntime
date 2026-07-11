(* ::Package:: *)

(* ClaudeRuntime_processsupervisor.wl -- 2 相 spawn manifest + 孤児回収 (hardening 03 Inc1, 2026-07-07)

   仕様: SourceVault_info/design/system_hardening_operations_guideline/
         03_process_supervisor_spec_v0.2.md

   目的:
     「poll tick が死ぬと spawn 済みプロセスが漏れる」構造 (mail jobs /
     $iExternalProcs) を閉じる。外部プロセス spawn を manifest 記録付き
     ヘルパ経由にし、期限切れ・親不在プロセスを決定論的に回収する。

   設計要点 (v0.2):
     - 2 相 manifest: Phase A (PendingSpawn を spawn 前に永続化) →
       Phase B (StartProcess + PID/StartTime で Running 確定) →
       Phase C (finalize 失敗時: kill + seat release + emit)。
       どのタイミングで親が死んでも「manifest なしの孤児」は生じない。
     - **PID 再利用ガード**: 回収時は PID 生存だけでなく ProcessStartTimeUTC
       の一致を要求。不一致 = 別プロセスが PID を再利用 → kill しない
       (本仕様の最重要正しさ要件)。
     - cleanup 順序は固定: ①SeatToken release → ②archive。release 失敗は
       manifest を CleanupFailed で残置し次回 reap が再試行 (席リークの
       追跡可能性を優先)。SeatBroker TTL 失効が最終防衛線。
     - 置き場所は $UserBaseDirectory 配下 (Dropbox 外)。PID はマシンローカル。

   状態機械:
     PendingSpawn -> Running -> Completed | Reaped | Vanished
     どの状態からも cleanup 失敗 -> CleanupFailed (再試行対象)

   Load:
     Block[{$CharacterEncoding = "UTF-8"}, Get["ClaudeRuntime_processsupervisor.wl"]]
*)

BeginPackage["ClaudeRuntime`"];

ClaudeSupervisedStartProcess::usage =
  "ClaudeSupervisedStartProcess[cmd, purpose, opts] は StartProcess を 2 相 manifest 記録付きで実行する。\n" <>
  "戻り値 <|\"Process\"->proc, \"JobId\"->..., \"Manifest\"->path|> | Failure[\"SpawnFailed\"|\"SpawnManifestFinalizeFailed\", ...]。\n" <>
  "opts: \"DeadlineSeconds\" (既定 1800; 超過で reap が kill), \"DoneMarker\"->path (存在=正常完了),\n" <>
  "\"SeatToken\" (cleanup 時に ClaudeSeatRelease), \"JobId\", \"Persistent\"->True (登録のみ・回収対象外)。";
ClaudeSupervisedComplete::usage =
  "ClaudeSupervisedComplete[jobId] は正常完了を通知する: State->Completed とし cleanup (seat release + archive 移動) を行う。DoneMarker 検出時の reap と同一の cleanup 経路を通る。";
ClaudeProcessReap::usage =
  "ClaudeProcessReap[] は manifest 全走査で孤児を回収する: DoneMarker 完了 / プロセス消滅 / deadline 超過 kill / owner kernel 死亡 / PendingSpawn 期限切れ / CleanupFailed 再試行。戻り値は分類別カウント。カーネル起動時 + 低頻度 tick + 手動で呼ぶ。";
ClaudeProcessInventory::usage =
  "ClaudeProcessInventory[] は生存 manifest の一覧 (実プロセス照合付き) を Dataset で返す。診断用。";
ClaudeProcessManifestCounts::usage =
  "ClaudeProcessManifestCounts[] は manifest の State 別件数を返す (OS 照会なしの高速集計)。\"Active\" は非 Persistent の件数。SystemDoctor probe / reap tick の自己解除判定に使う。";

Begin["`Private`"];

(* ── 定数 (テストから差し替え可) ── *)
If[! ValueQ[$iPSDefaultDeadlineSeconds], $iPSDefaultDeadlineSeconds = 1800];
If[! ValueQ[$iPSPendingGraceSeconds], $iPSPendingGraceSeconds = 300];
If[! ValueQ[$iPSOwnerGraceSeconds], $iPSOwnerGraceSeconds = 600];
If[! ValueQ[$iPSArchiveKeepDays], $iPSArchiveKeepDays = 7];
(* テスト用故障注入: <|"FinalizeFail"->True|> で Phase B の manifest 書きを失敗させる等 *)
If[! AssociationQ[$iPSTestInject], $iPSTestInject = <||>];

(* ── パス ── *)
iPSRoot[] := FileNameJoin[{$UserBaseDirectory, "ApplicationData",
  "ClaudeRuntime", "processes"}];
iPSArchiveDir[] := FileNameJoin[{iPSRoot[], "archive",
  DateString[TimeZoneConvert[Now, 0], {"Year", "Month", "Day"}]}];
iPSManifestPath[jobId_String] := FileNameJoin[{iPSRoot[], jobId <> ".json"}];
iPSEnsureDirs[] := Quiet @ CreateDirectory[iPSRoot[],
  CreateIntermediateDirectories -> True];

(* ── JSON I/O (temp-rename; 共通規約 2) ── *)
iPSJSONSafe[a_Association] :=
  Association @ KeyValueMap[ToString[#1] -> iPSJSONSafe[#2] &, a];
iPSJSONSafe[l_List] := iPSJSONSafe /@ l;
iPSJSONSafe[x_String] := x;
iPSJSONSafe[x_Integer] := x;
iPSJSONSafe[x_Real] := x;
iPSJSONSafe[x : (True | False | Null)] := x;
iPSJSONSafe[x_] := ToString[x, InputForm];

iPSWriteJSON[path_String, assoc_Association] := Module[{ba, tmp, strm, ok},
  If[TrueQ[$iPSTestInject["FinalizeFail"]] &&
     Lookup[assoc, "State", ""] === "Running",
    Return[$Failed]];   (* 故障注入: Phase B finalize 失敗 *)
  ba = Quiet @ ExportByteArray[iPSJSONSafe[assoc], "RawJSON", "Compact" -> True];
  If[! ByteArrayQ[ba], Return[$Failed]];
  tmp = path <> ".tmp-" <> ToString[$ProcessID];
  strm = Quiet @ OpenWrite[tmp, BinaryFormat -> True];
  If[Head[strm] =!= OutputStream, Return[$Failed]];
  BinaryWrite[strm, ba]; Close[strm];
  ok = Quiet @ Check[RenameFile[tmp, path, OverwriteTarget -> True]; True, False];
  If[! TrueQ[ok], Quiet @ DeleteFile[tmp]; Return[$Failed]];
  path];

iPSReadJSON[path_String] := Module[{b},
  If[! FileExistsQ[path], Return[Missing["NoFile"]]];
  b = Quiet @ ReadByteArray[path];
  If[! ByteArrayQ[b], Return[Missing["Empty"]]];
  With[{r = Quiet @ ImportByteArray[b, "RawJSON"]},
    If[AssociationQ[r], r, Missing["Corrupt"]]]];

(* ── SIEM emit 委譲 (externalrunner と同一実装; どちらが先にロードされても同じ) ── *)
iCRDiagEmit[class_String, payload_Association, severity_String: "warn"] :=
  Quiet @ Check[
    If[Length[DownValues[ClaudeCode`Private`iClaudeDiagEmit]] > 0,
      ClaudeCode`Private`iClaudeDiagEmit[class, payload, severity,
        "Producer" -> "ClaudeRuntime"]];
    Null,
    Null];

(* ── プロセス照会 (PID + StartTime) ── *)
(* PowerShell 1 呼びで alive + UTC StartTime を取る。プロセス不在なら "NONE"。 *)
iPSProcessStartTimeUTC[pid_Integer] := Module[{out, s},
  out = Quiet @ RunProcess[{"powershell", "-NoProfile", "-NonInteractive",
    "-Command",
    "try { (Get-Process -Id " <> ToString[pid] <>
    " -ErrorAction Stop).StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch { 'NONE' }"}];
  s = If[AssociationQ[out], StringTrim @ Lookup[out, "StandardOutput", ""], ""];
  If[StringMatchQ[s, RegularExpression["\\d{4}-\\d{2}-\\d{2}T.*Z"]], s, Missing["NoProcess"]]];
iPSProcessStartTimeUTC[_] := Missing["NoPid"];

iPSPidAlive[pid_Integer] := StringQ[iPSProcessStartTimeUTC[pid]];
iPSPidAlive[_] := False;

(* manifest の Pid が「同一プロセス」を指しているか (PID 再利用ガード)。
   StartTime の文字列一致を要求。秒未満のずれは同一クエリ方法なので出ない。 *)
iPSSameProcessQ[m_Association] := Module[{pid, st0, st1},
  pid = Lookup[m, "Pid"]; st0 = Lookup[m, "ProcessStartTimeUTC"];
  If[! IntegerQ[pid] || ! StringQ[st0], Return[False]];
  st1 = iPSProcessStartTimeUTC[pid];
  StringQ[st1] && st1 === st0];

iPSKillTree[pid_Integer] := Quiet @ RunProcess[{"taskkill", "/PID",
  ToString[pid], "/T", "/F"}];

(* ── seat release (SeatBroker 弱結合) ── *)
iPSSeatRelease[m_Association] := Module[{tok = Lookup[m, "SeatToken", None]},
  If[TrueQ[$iPSTestInject["SeatReleaseFail"]], Return[$Failed]];  (* 故障注入 *)
  If[! StringQ[tok] || tok === "", Return[True]];
  If[Length[DownValues[ClaudeSeatRelease]] === 0, Return[True]];
  (* UnknownToken = 既に TTL reaper が回収済み → 成功扱い (spec 03 §7) *)
  Quiet @ ClaudeSeatRelease[tok];
  True];

(* ── cleanup (順序固定: ①seat release → ②archive) ── *)
iPSCleanup[m_Association, finalState_String, reason_String] := Module[
  {jobId, path, rel, arch, dst},
  jobId = Lookup[m, "JobId", "?"];
  path = iPSManifestPath[jobId];
  rel = iPSSeatRelease[m];
  If[rel === $Failed,
    iPSWriteJSON[path, Join[m, <|"State" -> "CleanupFailed",
      "CleanupFailure" -> <|"Step" -> "SeatRelease",
        "AtUTC" -> iPSUTCNow[]|>|>]];
    iCRDiagEmit["ProcessCleanupFailed",
      <|"JobId" -> jobId, "Step" -> "SeatRelease"|>, "error"];
    Return[<|"State" -> "CleanupFailed", "Step" -> "SeatRelease"|>]];
  Quiet @ CreateDirectory[iPSArchiveDir[],
    CreateIntermediateDirectories -> True];
  dst = FileNameJoin[{iPSArchiveDir[], jobId <> ".json"}];
  arch = Quiet @ Check[
    iPSWriteJSON[dst, Join[m, <|"State" -> finalState,
      "CleanupReason" -> reason, "CleanedAtUTC" -> iPSUTCNow[]|>]];
    Quiet @ DeleteFile[path];
    True, False];
  If[! TrueQ[arch],
    iPSWriteJSON[path, Join[m, <|"State" -> "CleanupFailed",
      "CleanupFailure" -> <|"Step" -> "Archive", "AtUTC" -> iPSUTCNow[]|>|>]];
    iCRDiagEmit["ProcessCleanupFailed",
      <|"JobId" -> jobId, "Step" -> "Archive"|>, "error"];
    Return[<|"State" -> "CleanupFailed", "Step" -> "Archive"|>]];
  <|"State" -> finalState|>];

iPSUTCNow[] := DateString[TimeZoneConvert[Now, 0], "ISODateTime"] <> "Z";

(* ── 公開: 2 相 spawn ── *)
Options[ClaudeSupervisedStartProcess] = {
  "DeadlineSeconds" -> Automatic, "DoneMarker" -> None, "SeatToken" -> None,
  "JobId" -> Automatic, "Persistent" -> False,
  "ProcessOptions" -> {}};   (* StartProcess へ渡す追加オプション
                                (ProcessDirectory / ProcessEnvironment 等) *)
ClaudeSupervisedStartProcess[cmd_List, purpose_String, OptionsPattern[]] :=
  Module[{jobId, deadline, m, path, proc, pid, st, fin, killAttempted = False,
          killOk = False},
    iPSEnsureDirs[];
    jobId = OptionValue["JobId"] /. Automatic :>
      (ToLowerCase[StringReplace[purpose, Except[LetterCharacter | DigitCharacter] -> ""]] <>
       "-" <> ToString[UnixTime[]] <> "-" <>
       IntegerString[RandomInteger[{16^^10000, 16^^FFFFF}], 16]);
    deadline = OptionValue["DeadlineSeconds"] /.
      Automatic -> $iPSDefaultDeadlineSeconds;
    path = iPSManifestPath[jobId];
    (* Phase A: PendingSpawn を先に永続化 *)
    m = <|"JobId" -> jobId, "State" -> "PendingSpawn",
      "Cmd" -> cmd, "Exe" -> First[cmd, "?"], "Purpose" -> purpose,
      "OwnerKernelPid" -> $ProcessID,
      "CreatedAtAbs" -> AbsoluteTime[], "CreatedAtUTC" -> iPSUTCNow[],
      "DeadlineSeconds" -> deadline,
      "SeatToken" -> (OptionValue["SeatToken"] /. None -> Null),
      "DoneMarker" -> (OptionValue["DoneMarker"] /. None -> Null),
      "Persistent" -> TrueQ[OptionValue["Persistent"]]|>;
    If[iPSWriteJSON[path, m] === $Failed,
      Return[Failure["SpawnFailed",
        <|"MessageTemplate" -> "manifest write failed (Phase A)",
          "JobId" -> jobId|>]]];
    (* Phase B: spawn + finalize *)
    proc = Quiet @ Check[
      StartProcess[cmd, Sequence @@ OptionValue["ProcessOptions"]], $Failed];
    If[proc === $Failed || ! MatchQ[proc, _ProcessObject],
      iPSCleanup[m, "Vanished", "SpawnFailed"];
      iCRDiagEmit["SpawnFailed",
        <|"Purpose" -> purpose, "Exe" -> ToString[First[cmd, "?"]],
          "JobId" -> jobId|>, "error"];
      Return[Failure["SpawnFailed",
        <|"MessageTemplate" -> "StartProcess failed", "JobId" -> jobId|>]]];
    (* PID/StartTime は ProcessObject 自身のデータから取る
       (ProcessInformation は本環境では ExitCode しか持たない。実測 2026-07-07)。
       ProcessObject の StartTime は子が即終了しても取得できるのが利点。 *)
    pid = Quiet @ Check[Lookup[First[proc], "PID", None], None];
    st = Quiet @ Check[
      With[{d = Lookup[First[proc], "StartTime", None]},
        If[Head[d] === DateObject,
          DateString[TimeZoneConvert[d, 0], "ISODateTime"] <> "Z",
          Missing["NoStartTime"]]],
      Missing["NoStartTime"]];
    (* fallback: OS 照会 (reap 時の比較と同一経路)。両者は同じ OS 生成時刻
       由来なので秒精度で一致する。 *)
    If[! StringQ[st] && IntegerQ[pid], st = iPSProcessStartTimeUTC[pid]];
    m = Join[m, <|"State" -> "Running", "Pid" -> If[IntegerQ[pid], pid, Null],
      "ProcessStartTimeUTC" -> If[StringQ[st], st, Null],
      "SpawnedAtAbs" -> AbsoluteTime[], "SpawnedAtUTC" -> iPSUTCNow[],
      "DeadlineAbs" -> AbsoluteTime[] + deadline|>];
    fin = If[IntegerQ[pid] && StringQ[st], iPSWriteJSON[path, m], $Failed];
    If[fin === $Failed,
      (* Phase C: finalize 失敗 → その場で kill + release を試みる *)
      killAttempted = True;
      killOk = TrueQ[Quiet @ Check[KillProcess[proc]; True, False]];
      If[! killOk && IntegerQ[pid],
        killOk = AssociationQ[iPSKillTree[pid]]];
      iPSSeatRelease[m];
      iCRDiagEmit["SpawnManifestFinalizeFailed",
        <|"JobId" -> jobId, "Purpose" -> purpose,
          "KillAttempted" -> killAttempted, "KillSucceeded" -> killOk|>,
        "error"];
      If[killOk,
        Quiet @ DeleteFile[path],   (* 始末済み: PendingSpawn 残骸も消す *)
        iPSWriteJSON[path, Join[m, <|"State" -> "CleanupFailed",
          "CleanupFailure" -> <|"Step" -> "Kill", "AtUTC" -> iPSUTCNow[]|>|>]]];
      Return[Failure["SpawnManifestFinalizeFailed",
        <|"JobId" -> jobId, "KillSucceeded" -> killOk|>]]];
    <|"Process" -> proc, "JobId" -> jobId, "Manifest" -> path|>];

(* ── 公開: 正常完了通知 ── *)
ClaudeSupervisedComplete[jobId_String] := Module[{m},
  m = iPSReadJSON[iPSManifestPath[jobId]];
  If[! AssociationQ[m],
    Return[Failure["UnknownJob", <|"JobId" -> jobId|>]]];
  With[{r = iPSCleanup[m, "Completed", "Complete"]},
    If[r["State"] === "Completed", True,
      Failure["CleanupFailed", r]]]];

(* ── 公開: 回収 ── *)
ClaudeProcessReap[] := Module[
  {files, counts, now = AbsoluteTime[]},
  iPSEnsureDirs[];
  counts = <|"Reaped" -> {}, "Expired" -> 0, "OrphanOwner" -> 0,
    "PendingExpired" -> 0, "Completed" -> 0, "Vanished" -> 0,
    "CleanupRetried" -> 0, "Skipped" -> 0|>;
  files = Quiet @ Check[FileNames["*.json", iPSRoot[]], {}];
  Scan[Module[{m = iPSReadJSON[#], state, doneM, owner},
      If[! AssociationQ[m], Quiet @ DeleteFile[#]; Return[Null, Module]];
      state = Lookup[m, "State", "?"];
      doneM = Lookup[m, "DoneMarker", Null];
      owner = Lookup[m, "OwnerKernelPid"];
      Which[
        TrueQ[Lookup[m, "Persistent", False]],
          counts["Skipped"]++,
        state === "CleanupFailed",
          counts["CleanupRetried"]++;
          (* Step=Kill で残置された場合はプロセスが生きている可能性がある
             ので、同一性が確認できる限り kill を再試行してから cleanup *)
          If[Lookup[Lookup[m, "CleanupFailure", <||>], "Step"] === "Kill" &&
             iPSSameProcessQ[m],
            iPSKillTree[Lookup[m, "Pid"]]];
          iPSCleanup[m, "Reaped", "CleanupRetry"],
        (* 1. DoneMarker 完了 (Complete と同一 cleanup 経路) *)
        state === "Running" && StringQ[doneM] && FileExistsQ[doneM],
          counts["Completed"]++;
          iPSCleanup[m, "Completed", "DoneMarker"],
        (* 2. プロセス不在 or StartTime 不一致 = 異常終了/PID 再利用 *)
        state === "Running" && ! iPSSameProcessQ[m],
          counts["Vanished"]++;
          iCRDiagEmit["ProcessVanished",
            <|"JobId" -> Lookup[m, "JobId"], "Purpose" -> Lookup[m, "Purpose"],
              "Reason" -> "GoneOrPidReused", "State" -> state|>, "error"];
          iPSCleanup[m, "Vanished", "GoneOrPidReused"],
        (* 2'. PendingSpawn 期限切れ *)
        state === "PendingSpawn" &&
          now - Lookup[m, "CreatedAtAbs", now] > $iPSPendingGraceSeconds,
          counts["PendingExpired"]++;
          iCRDiagEmit["ProcessVanished",
            <|"JobId" -> Lookup[m, "JobId"], "Purpose" -> Lookup[m, "Purpose"],
              "Reason" -> "PendingExpired", "State" -> state|>];
          iPSCleanup[m, "Vanished", "PendingExpired"],
        (* 4. deadline 超過 → kill (同一プロセス確認済みの場合のみ) *)
        state === "Running" &&
          now > Lookup[m, "DeadlineAbs", Infinity],
          counts["Expired"]++;
          AppendTo[counts["Reaped"], Lookup[m, "JobId"]];
          iPSKillTree[Lookup[m, "Pid"]];
          iCRDiagEmit["OrphanReaped",
            <|"JobId" -> Lookup[m, "JobId"], "Purpose" -> Lookup[m, "Purpose"],
              "Reason" -> "DeadlineExceeded", "State" -> state|>];
          iPSCleanup[m, "Reaped", "DeadlineExceeded"],
        (* 5. owner kernel 死亡 + 猶予超過 *)
        state === "Running" && IntegerQ[owner] && ! iPSPidAlive[owner] &&
          now - Lookup[m, "SpawnedAtAbs", now] > $iPSOwnerGraceSeconds,
          counts["OrphanOwner"]++;
          AppendTo[counts["Reaped"], Lookup[m, "JobId"]];
          iPSKillTree[Lookup[m, "Pid"]];
          iCRDiagEmit["OrphanReaped",
            <|"JobId" -> Lookup[m, "JobId"], "Purpose" -> Lookup[m, "Purpose"],
              "Reason" -> "OwnerDead", "State" -> state|>];
          iPSCleanup[m, "Reaped", "OwnerDead"],
        True,
          counts["Skipped"]++]] &,
    files];
  iPSPruneArchive[];
  iPSRegisterDoctorProbe[];   (* 遅延ロードされた diagnostics への冪等登録 *)
  counts];

(* archive の保持期間超過分を削除 *)
iPSPruneArchive[] := Module[{root = FileNameJoin[{iPSRoot[], "archive"}], dirs},
  If[! DirectoryQ[root], Return[Null]];
  dirs = Quiet @ Check[Select[FileNames["*", root], DirectoryQ], {}];
  Scan[If[Quiet @ Check[
        AbsoluteTime[] - AbsoluteTime[FileDate[#, "Modification"]] >
          $iPSArchiveKeepDays*86400, False],
      Quiet @ DeleteDirectory[#, DeleteContents -> True]] &, dirs];
  Null];

(* ── 公開: State 別集計 (高速・OS 照会なし) ── *)
ClaudeProcessManifestCounts[] := Module[{files, states},
  iPSEnsureDirs[];
  files = Quiet @ Check[FileNames["*.json", iPSRoot[]], {}];
  states = Map[Module[{m = iPSReadJSON[#]},
      If[! AssociationQ[m], Nothing,
        <|"State" -> Lookup[m, "State", "?"],
          "Persistent" -> TrueQ[Lookup[m, "Persistent", False]]|>]] &, files];
  If[states === {}, Return[<|"Active" -> 0|>, Module]];
  Append[
    Counts[Lookup[states, "State"]],
    "Active" -> Count[states, s_ /; ! TrueQ[s["Persistent"]]]]];

(* ── SystemDoctor probe (hardening 03 Inc4; rule 11: producer 所有・弱結合) ──
   SourceVault_diagnostics がロード済みのときだけ登録する。登録は
   ロード時 + ClaudeProcessReap のたびに冪等に試みる (後から diagnostics が
   ロードされたカーネルでも tick 経由で自然に登録される)。
   probe は SystemDoctor から同期に呼ばれるため OS 照会をしない。 *)
If[! ValueQ[$iPSDoctorProbeRegistered], $iPSDoctorProbeRegistered = False];
iPSRegisterDoctorProbe[] :=
  Quiet @ Check[
    If[! TrueQ[$iPSDoctorProbeRegistered] &&
       Names["SourceVault`SourceVaultDiagnosticsRegisterProbe"] =!= {} &&
       (* 2026-07-09 fix: DownValues[Symbol[..]] は HoldAll で機能しない *)
       With[{sym = Symbol["SourceVault`SourceVaultDiagnosticsRegisterProbe"]},
         Length[DownValues[sym]]] > 0,
      Symbol["SourceVault`SourceVaultDiagnosticsRegisterProbe"][
        "SupervisedProcesses",
        Function[Module[{c = ClaudeProcessManifestCounts[]},
          (* normalizer が全体を Detail に包むので、内側は Counts に留めて
             ComponentHealth...Detail.Counts の一段構造にする (result5 知見) *)
          <|"Health" -> If[Lookup[c, "CleanupFailed", 0] > 0,
              "Degraded", "OK"],
            "Counts" -> c|>]]];
      $iPSDoctorProbeRegistered = True];
    Null, Null];
iPSRegisterDoctorProbe[];

(* ── 公開: 診断一覧 ── *)
ClaudeProcessInventory[] := Module[{files, rows},
  iPSEnsureDirs[];
  files = Quiet @ Check[FileNames["*.json", iPSRoot[]], {}];
  rows = Map[Module[{m = iPSReadJSON[#]},
      If[! AssociationQ[m], Nothing,
        Join[KeyTake[m, {"JobId", "State", "Purpose", "Pid",
            "OwnerKernelPid", "CreatedAtUTC", "Persistent"}],
          <|"ProcessAlive" -> If[Lookup[m, "State"] === "Running",
              iPSSameProcessQ[m], Missing["NA"]]|>]]] &, files];
  Dataset[rows]];

End[];
EndPackage[];
