(* ::Package:: *)

(* ::Title:: *)
(* ClaudeRuntime_sessionrunner.wl *)

(* ::Subsection:: *)
(* 概要 *)

(* ════════════════════════════════════════════════════════════════════
   ClaudeRuntime_sessionrunner.wl

   ClaudeRuntime`Session` 名前空間 (ClaudeRuntime_session.wl の続き)。
   RuntimeSession episode の **external process backend** (§8.2
   ClaudeRuntimeExternalProcess / §22 新規 ClaudeRuntime_sessionrunner.wl)。

   Inc9 スコープ:
     - 双方向 durable spool (§11.1 を process 側へ拡張)
         inbox/<seq>-<id>.wxf  : Runtime event (runner → orchestrator)
         outbox/<command-id>.wxf: SessionCommand (orchestrator → runner)
       one-shot job (externalrunner.wl) と違い長寿命・双方向。
     - §8.1 backend 契約 ClaudeRuntimeExternalProcessBackendSpec[]
         StartEpisode / PollEvents / SendCommand / Inspect / Recover / Dispose
       (EpisodeId, Attempt, StartCommandId) 冪等 start。
     - PID identity (§18.3: 別 PID を誤 kill しない)。externalrunner.wl の
       $ClaudeExternalProcessProbe / $ClaudeExternalProcessKill seam を再利用。
     - orphan recovery (§15.2: reattach / lost)。
     - cancel → grace → pid-verified kill。
     - ref-only manifest/status (I4: secret/prompt/artifact 本文を出さない)。

   launcher seam ($ClaudeSessionRunnerLauncher):
     - 既定 = 実 wolframscript が ClaudeRunSessionFromSpool[spoolDir] を実行。
     - テスト = simulator (別プロセスを起こさず spool 実ファイルを駆動)。
     - backend option "Launcher" で per-backend に差し替え可能 (IncE)。

   IncE (worker seam) スコープ:
     - backend option "WorkerSpec" (InitFiles + Function 名) を manifest に
       保存し、子プロセスの ClaudeRunSessionFromSpool が simulator loop の
       代わりに worker 関数を実行する (任意の長時間作業を episode protocol
       で走らせる口)。worker は ctx (Emit/PollCommands/CancelRequestedQ 等)
       経由で spool と対話する。terminal event の fail-closed backstop 付き。
       設計: claude_orchestrator_specimpl_session_migration_v0_1.md §2。

   依存規則 (§22):
     ClaudeRuntime_sessionrunner -> ClaudeRuntime (public)
     ClaudeRuntime_session の Private helper (iRtEventHash / iRtCanonicalHash
       / iRtNewId / iRtAtomicExport / iRtWXFImport) を共有 Private として再利用。
     ClaudeRuntime -X-> ClaudeOrchestrator。
   ロード順: ClaudeRuntime.wl → ClaudeRuntime_session.wl →
            ClaudeRuntime_externalrunner.wl (probe/kill seam) →
            ClaudeRuntime_sessionrunner.wl

   バージョン: v0.1 (Inc9, 2026-07-11)
   ════════════════════════════════════════════════════════════════════ *)

(* パッケージ自身の絶対パスを捕捉 (real launcher の子 bootstrap が Get する) *)
ClaudeRuntime`Session`Private`$iSessionRunnerFile =
  If[StringQ[$InputFileName] && $InputFileName =!= "",
    $InputFileName, Missing[]];

BeginPackage["ClaudeRuntime`Session`", {"ClaudeRuntime`"}];

$ClaudeRuntimeSessionRunnerVersion::usage =
  "$ClaudeRuntimeSessionRunnerVersion は本モジュールのバージョン。";

$ClaudeSessionRunnerRoot::usage =
  "$ClaudeSessionRunnerRoot は external session runner の spool root。\n" <>
  "未設定時は $UserBaseDirectory/ClaudeRuntime/session-runners。";

$ClaudeSessionRunnerLauncher::usage =
  "$ClaudeSessionRunnerLauncher は runner プロセスの起動 seam。\n" <>
  "Function[<|\"SpoolDir\", \"StartSpec\", \"RunnerScript\"|>] ->\n" <>
  "<|\"Status\"->\"Launched\"|\"Failed\", \"PID\"->_, \"Executable\"->_|>。\n" <>
  "既定 = 実 wolframscript。テストは simulator を注入。";

ClaudeRuntimeExternalProcessBackendSpec::usage =
  "ClaudeRuntimeExternalProcessBackendSpec[opts] は §8.1 契約の external\n" <>
  "process backend を返す (ClaudeRuntimeExternalProcess)。双方向 spool +\n" <>
  "PID identity + orphan recovery。ClaudeRegisterRuntimeSessionBackend に\n" <>
  "渡して使う。オプション:\n" <>
  "  \"RunnerScript\" -> simulator の event 台本 (script 駆動時)\n" <>
  "  \"WorkerSpec\" -> None | <|\"InitFiles\"->{path..},\n" <>
  "    \"Function\"->\"Context`symbol\"|> (IncE: 子プロセスで実行する worker。\n" <>
  "    manifest 経由で子へ渡る。データのみ・Function 本体は保存しない)\n" <>
  "  \"Launcher\" -> Automatic | fn (per-backend launcher。Automatic =\n" <>
  "    $ClaudeSessionRunnerLauncher)。";

ClaudeRunSessionFromSpool::usage =
  "ClaudeRunSessionFromSpool[spoolDir] は runner (子プロセス) の\n" <>
  "entrypoint。start-spec と runner-script を読み、outbox の command を\n" <>
  "読みつつ inbox に event を書く loop を回す。manifest に WorkerSpec が\n" <>
  "あれば worker mode (IncE): InitFiles を Get し Function を ctx 付きで\n" <>
  "実行する。ctx keys: SpoolDir/Manifest/StartSpec/BackendInstanceId/\n" <>
  "Emit[type,payloadRefs]/PollCommands[]/AckCommand[cid]/\n" <>
  "CancelRequestedQ[]/WriteStatus[status,extra]/CanonicalHash/NewId。\n" <>
  "worker が terminal event (ArtifactProposed/Completed/Failed/Cancelled/\n" <>
  "EnvironmentLost) を emit せず終了した場合は fail-closed で Failed を\n" <>
  "emit する。WorkerSpec が無ければ MVP script 駆動 (deterministic)。";

ClaudeSessionRunnerSimulatorTick::usage =
  "ClaudeSessionRunnerSimulatorTick[spoolDir] は simulator runner を一歩\n" <>
  "進める (outbox command 処理 + scripted event emit)。テスト用。実\n" <>
  "プロセス経路では runner 自身が loop する。";

ClaudeSessionRunnerReset::usage =
  "ClaudeSessionRunnerReset[] は runner backend の in-kernel 状態を\n" <>
  "クリアする。テスト用 (spool file は残す = crash 模擬に使える)。";

ClaudeSessionRunnerRealLauncher::usage =
  "ClaudeSessionRunnerRealLauncher[spec] は実 wolframscript 子プロセスを\n" <>
  "StartProcess で起動する launcher (IncD)。run.wls bootstrap で本パッケージ\n" <>
  "群を Get し ClaudeRunSessionFromSpool[spoolDir] を実行。実 PID を\n" <>
  "pid.wxf に記録する。$ClaudeSessionRunnerLauncher に代入して使う。\n" <>
  "ライセンス席を消費する (子プロセス1つ)。オプション:\n" <>
  "  \"PackageDir\" -> Automatic (パッケージ .wl の所在。既定は本ファイル所在)\n" <>
  "  \"MaxRunSeconds\" -> 60 (子 runner の wall-clock 上限)。";

ClaudeSessionRunnerInspectSpool::usage =
  "ClaudeSessionRunnerInspectSpool[spoolDir] は spool の manifest/status/\n" <>
  "pid/inbox/outbox 一覧を返す (検査用)。";

Begin["`Private`"];

$ClaudeRuntimeSessionRunnerVersion = "v0.2 (Inc9+IncE, 2026-07-12)";

(* ── spool paths ── *)

iRunnerRoot[] :=
  If[StringQ[$ClaudeSessionRunnerRoot] && $ClaudeSessionRunnerRoot =!= "",
    $ClaudeSessionRunnerRoot,
    FileNameJoin[{$UserBaseDirectory, "ClaudeRuntime",
      "session-runners"}]];

iRunnerSpoolDir[startSpec_Association] :=
  FileNameJoin[{iRunnerRoot[],
    ToString[Lookup[startSpec, "SessionId", "ses-unknown"]],
    ToString[Lookup[startSpec, "EpisodeId", "epi-unknown"]],
    "attempts", ToString[Lookup[startSpec, "Attempt", 1]]}];

iRunnerEnsure[dir_] := (
  If[!DirectoryQ[dir],
    Quiet @ CreateDirectory[dir, CreateIntermediateDirectories -> True]];
  dir);

(* ── in-kernel handle registry (orchestrator 側の poller が使う) ── *)

If[!AssociationQ[$iRunnerHandles], $iRunnerHandles = <||>];
If[!AssociationQ[$iRunnerStarts], $iRunnerStarts = <||>];
If[!AssociationQ[$iRunnerSims], $iRunnerSims = <||>];

If[!AssociationQ[$iRunnerRealProcs], $iRunnerRealProcs = <||>];

ClaudeSessionRunnerReset[] := (
  $iRunnerHandles = <||>;
  $iRunnerStarts = <||>;
  $iRunnerSims = <||>;
  $iRunnerRealProcs = <||>;
  <|"Status" -> "Reset"|>);

(* ── ref-only manifest / status (I4) ── *)

iRunnerWriteManifest[spoolDir_, startSpec_, script_, workerSpec_:None] :=
  Module[{access = Lookup[startSpec, "Access", <||>], meta},
    meta = <|
      "SchemaVersion" -> 1,
      "SessionId" -> Lookup[startSpec, "SessionId", None],
      "EpisodeId" -> Lookup[startSpec, "EpisodeId", None],
      "Attempt" -> Lookup[startSpec, "Attempt", 1],
      "Backend" -> "ClaudeRuntimeExternalProcess",
      (* ref のみ。secret/prompt/artifact 本文は載せない *)
      "GoalRef" -> Lookup[Lookup[startSpec, "Task", <||>], "GoalRef",
        None],
      "AccessSpecHash" -> Lookup[access, "AccessSpecHash", ""],
      "PolicySnapshotHash" -> Lookup[access, "PolicySnapshotHash", ""],
      "CredentialRefs" ->
        Lookup[Lookup[startSpec, "Environment", <||>],
          "CredentialRefs", {}],
      "RunnerScriptRef" -> "spool://runner-script",
      (* IncE: worker 指定 (InitFiles paths + Function 名。データのみ) *)
      "WorkerSpec" -> workerSpec,
      "CreatedAt" -> DateString[TimeZoneConvert[Now, 0], "ISODateTime"]|>;
    Quiet @ Check[
      iRtAtomicExport[FileNameJoin[{spoolDir, "manifest.wxf"}], meta],
      $Failed];
    (* runner-script は別 file (テスト simulator 用の event 台本) *)
    Quiet @ Check[
      iRtAtomicExport[FileNameJoin[{spoolDir, "runner-script.wxf"}],
        script], $Failed];
    meta
  ];

iRunnerWriteStatus[spoolDir_, status_String, extra_Association:<||>] :=
  Quiet @ Check[
    iRtAtomicExport[FileNameJoin[{spoolDir, "status.wxf"}],
      Join[<|"Status" -> status,
        "At" -> DateString[TimeZoneConvert[Now, 0], "ISODateTime"]|>,
        extra]], $Failed];

iRunnerReadStatus[spoolDir_] :=
  Module[{r = iRtWXFImport[FileNameJoin[{spoolDir, "status.wxf"}]]},
    If[AssociationQ[r], r, <|"Status" -> "Unknown"|>]];

iRunnerWritePid[spoolDir_, pid_, exe_] :=
  Quiet @ Check[
    iRtAtomicExport[FileNameJoin[{spoolDir, "pid.wxf"}],
      <|"PID" -> pid, "Executable" -> exe,
        "StartedAt" -> AbsoluteTime[]|>], $Failed];

iRunnerReadPid[spoolDir_] :=
  iRtWXFImport[FileNameJoin[{spoolDir, "pid.wxf"}]];

(* ── event inbox (runner → orchestrator) ── *)

iRunnerInboxPath[spoolDir_, seq_] :=
  FileNameJoin[{spoolDir, "inbox",
    IntegerString[seq, 10, 6] <> ".wxf"}];

iRunnerEventCursorPath[spoolDir_] :=
  FileNameJoin[{spoolDir, "event-cursor.wxf"}];

iRunnerNextSeq[spoolDir_] :=
  Module[{c = iRtWXFImport[iRunnerEventCursorPath[spoolDir]]},
    If[IntegerQ[c], c, 0] + 1];

iRunnerBumpSeq[spoolDir_, seq_] :=
  Quiet @ Check[
    iRtAtomicExport[iRunnerEventCursorPath[spoolDir], seq], $Failed];

(* runner が inbox に event を書く。§7.9 hash は iRtEventHash (Runtime 側の
   自己完結実装、orchestrator の ClaudeSessionVerifyEventHash と一致) *)
iRunnerEmit[spoolDir_, startSpec_, type_, payloadRefs_, budgetSnap_,
            bki_] :=
  Module[{access = Lookup[startSpec, "Access", <||>], seq, ev},
    seq = iRunnerNextSeq[spoolDir];
    ev = <|
      "SchemaVersion" -> 1,
      "EventId" -> iRtNewId["evt"],
      "EventSeq" -> seq,
      "SessionId" -> Lookup[startSpec, "SessionId", "ses-unknown"],
      "EpisodeId" -> Lookup[startSpec, "EpisodeId", "epi-unknown"],
      "Attempt" -> Lookup[startSpec, "Attempt", 1],
      "BackendInstanceId" -> bki,
      "Source" -> "Runtime",
      "Type" -> type,
      "SupersedesThroughSeq" -> None,
      "PayloadRefs" -> payloadRefs,
      "LatestCheckpointRef" -> None,
      "BudgetSnapshot" -> budgetSnap,
      "AccessSpecHash" -> Lookup[access, "AccessSpecHash", ""],
      "PolicySnapshotHash" -> Lookup[access, "PolicySnapshotHash", ""],
      "PrivacyLabel" -> Lookup[access, "PrivacyLabel", 1.0],
      "CreatedAt" -> DateObject[]|>;
    ev = Append[ev, "EventHash" -> iRtEventHash[ev]];
    Quiet @ Check[
      iRtAtomicExport[iRunnerInboxPath[spoolDir, seq], ev], $Failed];
    iRunnerBumpSeq[spoolDir, seq];
    ev
  ];

iRunnerListInbox[spoolDir_, afterSeq_] :=
  Module[{files},
    files = Sort @ FileNames["*.wxf",
      FileNameJoin[{spoolDir, "inbox"}]];
    Select[
      Map[iRtWXFImport, files],
      AssociationQ[#] && IntegerQ[Lookup[#, "EventSeq", None]] &&
        Lookup[#, "EventSeq", 0] > afterSeq &]
  ];

(* ── command outbox (orchestrator → runner) ── *)

iRunnerOutboxPath[spoolDir_, cid_] :=
  FileNameJoin[{spoolDir, "outbox", cid <> ".wxf"}];

iRunnerListOutboxUnprocessed[spoolDir_] :=
  Module[{files, procDir, done},
    files = Sort @ FileNames["*.wxf",
      FileNameJoin[{spoolDir, "outbox"}]];
    procDir = FileNameJoin[{spoolDir, "outbox-processed"}];
    done = If[DirectoryQ[procDir],
      FileBaseName /@ FileNames["*.wxf", procDir], {}];
    Select[files, !MemberQ[done, FileBaseName[#]] &]
  ];

iRunnerMarkOutboxProcessed[spoolDir_, cid_] :=
  Quiet @ Check[
    iRtAtomicExport[
      FileNameJoin[{spoolDir, "outbox-processed", cid <> ".wxf"}],
      <|"CommandId" -> cid, "At" -> AbsoluteTime[]|>], $Failed];

(* ════════════════════════════════════════════════════════
   simulator runner (テスト用: 別プロセスを起こさず spool を駆動)

   RunnerScript = <|
     "Events" -> {template..},   (* start 後に順次 emit *)
     "AckCommands" -> True,       (* command 受理で CommandAccepted *)
     "TerminalOnCancel" -> True|>
   ════════════════════════════════════════════════════════ *)

iSimBudgetSnap[startSpec_, n_] :=
  Module[{g = Lookup[startSpec, "BudgetGrant", <||>]},
    <|"Turns" -> n, "Calls" -> n, "ToolCalls" -> 0,
      "InputTokens" -> 0, "OutputTokens" -> 0,
      "WallClockSeconds" -> 0., "IdleSeconds" -> 0.,
      "BytesWritten" -> 0, "NetworkRequests" -> 0,
      "ActualUSD" -> None, "ReservedUSD" -> None,
      "CostSource" -> "Unknown",
      "BudgetGrantId" -> Lookup[g, "BudgetGrantId", "grant-unknown"],
      "BudgetGrantVersion" -> Lookup[g, "Version", 1]|>];

iSessionRunnerSimLaunch[spec_Association] :=
  Module[{spoolDir, startSpec, script, bki, pid},
    spoolDir = Lookup[spec, "SpoolDir", None];
    startSpec = Lookup[spec, "StartSpec", <||>];
    script = Lookup[spec, "RunnerScript", <||>];
    bki = iRtNewId["extbki"];
    (* simulator は「生きているプロセス」を模す fake pid。probe seam を
       テストで mock して alive/image を返させる *)
    pid = RandomInteger[{10000, 99999}];
    iRunnerWritePid[spoolDir, pid, "wolframscript-sim"];
    iRunnerWriteStatus[spoolDir, "Running"];
    AssociateTo[$iRunnerSims, spoolDir -> <|
      "StartSpec" -> startSpec, "Script" -> script,
      "BackendInstanceId" -> bki,
      "EmitIndex" -> 0, "Terminal" -> False|>];
    <|"Status" -> "Launched", "PID" -> pid,
      "Executable" -> "wolframscript-sim",
      "BackendInstanceId" -> bki|>
  ];

ClaudeSessionRunnerSimulatorTick[spoolDir_String] :=
  Module[{sim = Lookup[$iRunnerSims, spoolDir, Missing["NoSim"]],
          startSpec, script, bki, emitted = 0, cmds},
    If[MissingQ[sim], Return[<|"Status" -> "NoSim"|>]];
    If[TrueQ[sim[["Terminal"]]], Return[<|"Status" -> "Terminal"|>]];
    startSpec = sim[["StartSpec"]];
    script = sim[["Script"]];
    bki = sim[["BackendInstanceId"]];

    (* 1. outbox の未処理 command を処理 *)
    cmds = iRunnerListOutboxUnprocessed[spoolDir];
    Scan[
      Function[f,
        Module[{cmd = iRtWXFImport[f], cid, type},
          If[AssociationQ[cmd],
            cid = Lookup[cmd, "CommandId", "?"];
            type = Lookup[cmd, "Type", None];
            If[TrueQ @ Lookup[script, "AckCommands", True],
              iRunnerEmit[spoolDir, startSpec, "CommandAccepted",
                <|"CommandId" -> cid|>,
                iSimBudgetSnap[startSpec, iRunnerNextSeq[spoolDir]],
                bki]];
            If[type === "Cancel" &&
               TrueQ @ Lookup[script, "TerminalOnCancel", True],
              iRunnerEmit[spoolDir, startSpec, "Cancelled",
                <|"CommandId" -> cid|>,
                iSimBudgetSnap[startSpec, iRunnerNextSeq[spoolDir]],
                bki];
              sim = Append[sim, "Terminal" -> True]];
            iRunnerMarkOutboxProcessed[spoolDir, cid];
            emitted++]]],
      cmds];

    (* 2. scripted event を一つ emit (EmitIndex 進行) *)
    If[!TrueQ[sim[["Terminal"]]],
      Module[{evs = Lookup[script, "Events", {}], idx},
        idx = sim[["EmitIndex"]];
        If[idx < Length[evs],
          Module[{tmpl = evs[[idx + 1]]},
            iRunnerEmit[spoolDir, startSpec,
              Lookup[tmpl, "Type", "Completed"],
              Lookup[tmpl, "PayloadRefs", <||>],
              Lookup[tmpl, "BudgetSnapshot",
                iSimBudgetSnap[startSpec, iRunnerNextSeq[spoolDir]]],
              bki];
            sim = Append[sim, "EmitIndex" -> idx + 1];
            If[MemberQ[{"Completed", "Failed", "EnvironmentLost"},
                 Lookup[tmpl, "Type", None]],
              sim = Append[sim, "Terminal" -> True]];
            emitted++]]]];

    AssociateTo[$iRunnerSims, spoolDir -> sim];
    If[TrueQ[sim[["Terminal"]]],
      iRunnerWriteStatus[spoolDir, "Completed"]];
    <|"Status" -> "Ticked", "Emitted" -> emitted,
      "Terminal" -> sim[["Terminal"]]|>
  ];

(* ════════════════════════════════════════════════════════
   IncE: worker mode (子プロセスで任意の長時間作業を episode protocol で
   実行する seam)。manifest の WorkerSpec = <|"InitFiles"->{path..},
   "Function"->"Context`symbol"|>。worker は ctx 経由で spool と対話する。
   ════════════════════════════════════════════════════════ *)

$iRunnerWorkerTerminalTypes =
  {"ArtifactProposed", "Completed", "Failed", "Cancelled",
   "EnvironmentLost"};

(* start-spec.wxf の full spec を優先し、無ければ manifest から最小限を再構成 *)
iRunnerWorkerStartSpec[spoolDir_, manifest_] :=
  Module[{full = iRtWXFImport[
      FileNameJoin[{spoolDir, "start-spec.wxf"}]]},
    If[AssociationQ[full] && KeyExistsQ[full, "SessionId"], full,
      <|"SessionId" -> Lookup[manifest, "SessionId", None],
        "EpisodeId" -> Lookup[manifest, "EpisodeId", None],
        "Attempt" -> Lookup[manifest, "Attempt", 1],
        "Access" -> <|
          "AccessSpecHash" -> Lookup[manifest, "AccessSpecHash", ""],
          "PolicySnapshotHash" ->
            Lookup[manifest, "PolicySnapshotHash", ""],
          "PrivacyLabel" -> 1.0|>|>]];

iRunnerLastInboxType[spoolDir_] :=
  Module[{files = Sort @ FileNames["*.wxf",
      FileNameJoin[{spoolDir, "inbox"}]], ev},
    If[files === {}, None,
      ev = iRtWXFImport[Last[files]];
      If[AssociationQ[ev], Lookup[ev, "Type", None], None]]];

(* worker へ渡す protocol API。Private helper を直接触らせない *)
iRunnerWorkerContext[spoolDir_, manifest_, startSpec_, bki_] :=
  <|
    "SpoolDir" -> spoolDir,
    "Manifest" -> manifest,
    "StartSpec" -> startSpec,
    "BackendInstanceId" -> bki,
    "Emit" -> Function[{type, payloadRefs},
      iRunnerEmit[spoolDir, startSpec, type, payloadRefs,
        iSimBudgetSnap[startSpec, iRunnerNextSeq[spoolDir]], bki]],
    "PollCommands" -> Function[{},
      Select[Map[iRtWXFImport,
        iRunnerListOutboxUnprocessed[spoolDir]], AssociationQ]],
    "AckCommand" -> Function[cid,
      (iRunnerEmit[spoolDir, startSpec, "CommandAccepted",
         <|"CommandId" -> cid|>,
         iSimBudgetSnap[startSpec, iRunnerNextSeq[spoolDir]], bki];
       iRunnerMarkOutboxProcessed[spoolDir, cid])],
    "CancelRequestedQ" -> Function[{},
      AnyTrue[
        Map[iRtWXFImport, iRunnerListOutboxUnprocessed[spoolDir]],
        Function[c, AssociationQ[c] &&
          Lookup[c, "Type", None] === "Cancel"]]],
    "WriteStatus" -> Function[{status, extra},
      iRunnerWriteStatus[spoolDir, status, extra]],
    "CanonicalHash" -> Function[expr, iRtCanonicalHash[expr]],
    "NewId" -> Function[kind, iRtNewId[kind]]
  |>;

iRunnerRunWorker[spoolDir_, manifest_, workerSpec_Association] :=
  Module[{startSpec, bki, initFiles, badInit, fnName, fn, callable,
          ctx, res, lastType, failStatus},
    startSpec = iRunnerWorkerStartSpec[spoolDir, manifest];
    bki = iRtNewId["extbki"];
    (* InitFiles を順に Get。最初の失敗で fail-closed *)
    initFiles = Lookup[workerSpec, "InitFiles", {}];
    badInit = SelectFirst[If[ListQ[initFiles], initFiles, {}],
      Function[f, !StringQ[f] || !FileExistsQ[f] ||
        (Quiet @ Check[Get[f]; True, $Failed]) =!= True],
      None];
    If[badInit =!= None,
      iRunnerEmit[spoolDir, startSpec, "Failed",
        <|"Reason" -> "WorkerInitFailed",
          "InitFile" -> ToString[badInit]|>,
        iSimBudgetSnap[startSpec, iRunnerNextSeq[spoolDir]], bki];
      iRunnerWriteStatus[spoolDir, "Failed",
        <|"Reason" -> "WorkerInitFailed"|>];
      Return[<|"Status" -> "Failed", "Reason" -> "WorkerInitFailed"|>]];
    fnName = Lookup[workerSpec, "Function", ""];
    fn = If[StringQ[fnName] && fnName =!= "",
      Quiet @ Check[Symbol[fnName], $Failed], $Failed];
    (* DownValues は HoldAll: ローカル変数を渡すと常に {} になるため
       With で実 symbol を注入する *)
    callable = MatchQ[fn, _Function] ||
      (MatchQ[fn, _Symbol] && With[{s = fn}, DownValues[s]] =!= {});
    If[!callable,
      iRunnerEmit[spoolDir, startSpec, "Failed",
        <|"Reason" -> "WorkerFunctionUnresolved",
          "Function" -> ToString[fnName]|>,
        iSimBudgetSnap[startSpec, iRunnerNextSeq[spoolDir]], bki];
      iRunnerWriteStatus[spoolDir, "Failed",
        <|"Reason" -> "WorkerFunctionUnresolved"|>];
      Return[<|"Status" -> "Failed",
        "Reason" -> "WorkerFunctionUnresolved"|>]];
    ctx = iRunnerWorkerContext[spoolDir, manifest, startSpec, bki];
    (* message は worker 内の通常運転で出うるので exception 扱いしない。
       abort / 未捕捉 Throw のみ WorkerException とする *)
    res = CheckAbort[
      Catch[fn[ctx], _,
        Function[{v, t}, $iRunnerWorkerAbortSentinel]],
      $iRunnerWorkerAbortSentinel];
    If[res === $iRunnerWorkerAbortSentinel,
      iRunnerEmit[spoolDir, startSpec, "Failed",
        <|"Reason" -> "WorkerException"|>,
        iSimBudgetSnap[startSpec, iRunnerNextSeq[spoolDir]], bki]];
    (* fail-closed backstop: terminal event 無しで終わった worker *)
    lastType = iRunnerLastInboxType[spoolDir];
    If[!MemberQ[$iRunnerWorkerTerminalTypes, lastType],
      iRunnerEmit[spoolDir, startSpec, "Failed",
        <|"Reason" -> "WorkerNoTerminalEvent"|>,
        iSimBudgetSnap[startSpec, iRunnerNextSeq[spoolDir]], bki]];
    failStatus = MemberQ[{"Failed", "EnvironmentLost"},
      iRunnerLastInboxType[spoolDir]];
    iRunnerWriteStatus[spoolDir,
      Which[
        iRunnerLastInboxType[spoolDir] === "Cancelled", "Cancelled",
        failStatus, "Failed",
        True, "Completed"]];
    <|"Status" -> "RunnerCompleted", "Mode" -> "Worker"|>
  ];

(* 実 runner entrypoint (子プロセス)。manifest に WorkerSpec があれば
   worker mode (IncE)。無ければ MVP script 駆動 (simulator tick を
   実プロセス内で回す)。outbox を wall-clock 制限で polling し、command 到着
   に反応する (双方向)。script の event を出し切り terminal になるか、
   MaxRunSeconds 超過で終了。 *)
Options[ClaudeRunSessionFromSpool] = {"MaxRunSeconds" -> 60,
  "PollIntervalSeconds" -> 0.3};

ClaudeRunSessionFromSpool[spoolDir_String, opts:OptionsPattern[]] :=
  Module[{manifest, script, startSpec, t0, maxSec, poll, workerSpec},
    manifest = iRtWXFImport[FileNameJoin[{spoolDir, "manifest.wxf"}]];
    script = iRtWXFImport[FileNameJoin[{spoolDir, "runner-script.wxf"}]];
    If[!AssociationQ[manifest] || !AssociationQ[script],
      iRunnerWriteStatus[spoolDir, "Failed",
        <|"Reason" -> "SpoolUnreadable"|>];
      Return[<|"Status" -> "Failed"|>]];
    (* IncE: worker mode *)
    workerSpec = Lookup[manifest, "WorkerSpec", None];
    If[AssociationQ[workerSpec] &&
       StringQ[Lookup[workerSpec, "Function", None]],
      Return[iRunnerRunWorker[spoolDir, manifest, workerSpec]]];
    startSpec = <|"SessionId" -> Lookup[manifest, "SessionId", None],
      "EpisodeId" -> Lookup[manifest, "EpisodeId", None],
      "Attempt" -> Lookup[manifest, "Attempt", 1],
      "Access" -> <|"AccessSpecHash" ->
          Lookup[manifest, "AccessSpecHash", ""],
        "PolicySnapshotHash" ->
          Lookup[manifest, "PolicySnapshotHash", ""],
        "PrivacyLabel" -> 1.0|>|>;
    AssociateTo[$iRunnerSims, spoolDir -> <|
      "StartSpec" -> startSpec, "Script" -> script,
      "BackendInstanceId" -> iRtNewId["extbki"],
      "EmitIndex" -> 0, "Terminal" -> False|>];
    maxSec = OptionValue["MaxRunSeconds"];
    t0 = AbsoluteTime[];
    poll = OptionValue["PollIntervalSeconds"];
    (* script の event を出し切り、その後は outbox を polling して command に
       反応する。terminal か MaxRunSeconds で終了。 *)
    While[
      !TrueQ[Lookup[$iRunnerSims, spoolDir, <||>][["Terminal"]]] &&
      AbsoluteTime[] - t0 < maxSec,
      ClaudeSessionRunnerSimulatorTick[spoolDir];
      If[!TrueQ[Lookup[$iRunnerSims, spoolDir, <||>][["Terminal"]]],
        Pause[poll]]];
    iRunnerWriteStatus[spoolDir,
      If[TrueQ[Lookup[$iRunnerSims, spoolDir, <||>][["Terminal"]]],
        "Completed", "RunnerTimeout"]];
    <|"Status" -> "RunnerCompleted"|>
  ];

(* ── real wolframscript launcher (IncD) ──
   run.wls bootstrap を書き、StartProcess で子 wolframscript を起動。
   子は本パッケージ群を Get し ClaudeRunSessionFromSpool[spoolDir] を実行。
   実 PID を pid.wxf に記録 (probe/kill は default の tasklist/taskkill)。 *)

Options[ClaudeSessionRunnerRealLauncher] = {
  "PackageDir" -> Automatic, "MaxRunSeconds" -> 60};

iSessionRunnerResolvePackageDir[dir_] :=
  Which[
    StringQ[dir] && DirectoryQ[dir], dir,
    StringQ[$iSessionRunnerFile],
      DirectoryName[$iSessionRunnerFile],
    True, Directory[]];

(* worker を起動する実行体。素のカーネル (init.m を読まない) を優先し、
   見つからなければ従来どおり wolframscript。 *)
If[! ValueQ[$ClaudeSessionRunnerPristineKernel],
  $ClaudeSessionRunnerPristineKernel = True];

iSessionRunnerKernelExe[] := iSessionRunnerKernelExe[] = Module[{cands, k},
  If[TrueQ[$ClaudeSessionRunnerPristineKernel],
    cands = {
      FileNameJoin[{$InstallationDirectory, "SystemFiles", "Kernel", "Binaries",
        $SystemID, "wolfram.exe"}],
      FileNameJoin[{$InstallationDirectory, "wolfram.exe"}],
      FileNameJoin[{$InstallationDirectory, "SystemFiles", "Kernel", "Binaries",
        $SystemID, "wolfram"}],
      FileNameJoin[{$InstallationDirectory, "wolfram"}]};
    k = SelectFirst[cands, StringQ[#] && FileExistsQ[#] &, None];
    If[StringQ[k], Return[k, Module]]];
  Quiet @ Check[
    First[Select[{
      "wolframscript",
      FileNameJoin[{$InstallationDirectory, "wolframscript"}],
      FileNameJoin[{$InstallationDirectory, "wolframscript.exe"}]},
      (# === "wolframscript" || FileExistsQ[#]) &],
      "wolframscript"], "wolframscript"]];

iSessionRunnerWriteBootstrap[spoolDir_, pkgDir_, maxSec_] :=
  Module[{runwls, code},
    runwls = FileNameJoin[{spoolDir, "run.wls"}];
    code = StringJoin[{
      "Block[{$CharacterEncoding = \"UTF-8\"},\n",
      "  Get[FileNameJoin[{", ToString[pkgDir, InputForm],
        ", \"ClaudeRuntime.wl\"}]];\n",
      "  Get[FileNameJoin[{", ToString[pkgDir, InputForm],
        ", \"ClaudeRuntime_session.wl\"}]];\n",
      "  Get[FileNameJoin[{", ToString[pkgDir, InputForm],
        ", \"ClaudeRuntime_externalrunner.wl\"}]];\n",
      "  Get[FileNameJoin[{", ToString[pkgDir, InputForm],
        ", \"ClaudeRuntime_sessionrunner.wl\"}]];\n",
      (* 解決済みの root を literal で渡す。以前は未設定時に
         ToString[$ClaudeSessionRunnerRoot, InputForm] がシンボル名を返し、
         子側で「未定義シンボルの自己代入」になっていた。 *)
      "  ClaudeRuntime`Session`$ClaudeSessionRunnerRoot = ",
        ToString[iRunnerRoot[], InputForm], ";\n",
      "  ClaudeRuntime`Session`ClaudeRunSessionFromSpool[",
        ToString[spoolDir, InputForm],
        ", \"MaxRunSeconds\" -> ", ToString[maxSec], "]\n",
      "]\n"}];
    Export[runwls, code, "Text"];
    runwls
  ];

ClaudeSessionRunnerRealLauncher[spec_Association,
    opts:OptionsPattern[]] :=
  Module[{spoolDir, pkgDir, maxSec, runwls, exe, proc, pid},
    spoolDir = Lookup[spec, "SpoolDir", None];
    If[!StringQ[spoolDir],
      Return[<|"Status" -> "Failed", "Reason" -> "NoSpoolDir"|>]];
    pkgDir = iSessionRunnerResolvePackageDir[OptionValue["PackageDir"]];
    maxSec = OptionValue["MaxRunSeconds"];
    runwls = iSessionRunnerWriteBootstrap[spoolDir, pkgDir, maxSec];
    (* 素のカーネル (init.m を読まない) を優先する。2026-08-20 実測:
       init.m -> localInit.wl -> NotebookExtensions.wl の
       Needs["RickHennigan`MCPServer`"] が ZeroMQLink を全カーネルへロードし、
       その libzeromqlink.dll が 0xC0000005 で落ちるため worker が起動直後に
       クラッシュしていた (ライセンス席とは無関係)。worker の run.wls は
       必要な .wl を自分で Get するので init.m は不要。
       ClaudeRuntime`Session`$ClaudeSessionRunnerPristineKernel = False で
       従来の wolframscript 起動に戻せる。 *)
    exe = Quiet @ Check[iSessionRunnerKernelExe[], "wolframscript"];
    proc = Quiet @ Check[
      StartProcess[
        If[StringQ[exe] && StringContainsQ[exe, "wolframscript"],
          {exe, "-file", runwls},
          {exe, "-noinit", "-script", runwls}]],
      $Failed];
    If[proc === $Failed || !MatchQ[proc, _ProcessObject],
      iRunnerWriteStatus[spoolDir, "Failed",
        <|"Reason" -> "StartProcessFailed"|>];
      Return[<|"Status" -> "Failed", "Reason" -> "StartProcessFailed"|>]];
    (* ProcessObject の PID (キーは "PID")。二引数形が未評価になる版が
       あるため Association 経由で取る *)
    pid = Quiet @ Check[
      Lookup[ProcessInformation[proc], "PID",
        Lookup[proc[[1]], "PID", None]], None];
    iRunnerWritePid[spoolDir, pid, "wolframscript"];
    iRunnerWriteStatus[spoolDir, "Running"];
    (* ProcessObject を in-kernel に保持 (snapshot には出さない I12) *)
    AssociateTo[$iRunnerRealProcs, spoolDir -> proc];
    <|"Status" -> "Launched", "PID" -> pid,
      "Executable" -> "wolframscript",
      "BackendInstanceId" -> iRtNewId["extbki"],
      "Process" -> proc|>
  ];

If[!AssociationQ[$iRunnerRealProcs], $iRunnerRealProcs = <||>];

(* ── launcher seam 既定 (simulator) ──
   実 wolframscript 起動は本番 wiring 側で $ClaudeSessionRunnerLauncher を
   差し替える。既定を simulator にしておくことで、席を消費せずに episode
   supervisor net と double でテストできる。 *)
If[!ValueQ[$ClaudeSessionRunnerLauncher],
  $ClaudeSessionRunnerLauncher =
    Function[spec, iSessionRunnerSimLaunch[spec]]];

(* ════════════════════════════════════════════════════════
   §8.1 backend contract (ClaudeRuntimeExternalProcess)
   ════════════════════════════════════════════════════════ *)

iRunnerBackendStart[opts_Association, startSpec_Association] :=
  Module[{epi, att, scmd, startKey, spoolDir, script, launched, h},
    epi = Lookup[startSpec, "EpisodeId", None];
    att = Lookup[startSpec, "Attempt", 1];
    scmd = Lookup[startSpec, "StartCommandId", "(no-start-command-id)"];
    If[!StringQ[epi],
      Return[<|"Status" -> "Failed", "Reason" -> "MissingEpisodeId"|>]];
    startKey = {epi, att, scmd};
    If[KeyExistsQ[$iRunnerStarts, startKey],
      Module[{h0 = $iRunnerStarts[startKey],
              st0 = Lookup[$iRunnerHandles,
                $iRunnerStarts[startKey], <||>]},
        Return[<|"Status" -> "AlreadyStarted",
          "SessionId" -> Lookup[st0, "SessionId", None],
          "EpisodeId" -> epi, "HandleRef" -> h0,
          "BackendInstanceId" ->
            Lookup[st0, "BackendInstanceId", None],
          "InitialEventCursor" -> <|"Attempt" -> att, "EventSeq" -> 0|>,
          "PIDRef" -> Lookup[st0, "PID", None]|>]]];

    spoolDir = iRunnerSpoolDir[startSpec];
    iRunnerEnsure[spoolDir];
    iRunnerEnsure[FileNameJoin[{spoolDir, "inbox"}]];
    iRunnerEnsure[FileNameJoin[{spoolDir, "outbox"}]];
    (* start-spec を ref-only で保存 (本文なし) + manifest *)
    Quiet @ Check[
      iRtAtomicExport[FileNameJoin[{spoolDir, "start-spec.wxf"}],
        (* raw goal/inputs は ref のみに縮退 *)
        KeyDrop[startSpec, {}]], $Failed];
    script = Lookup[opts, "RunnerScript",
      <|"Events" -> {<|"Type" -> "Completed"|>},
        "AckCommands" -> True, "TerminalOnCancel" -> True|>];
    iRunnerWriteManifest[spoolDir, startSpec, script,
      Lookup[opts, "WorkerSpec", None]];

    (* IncE: per-backend launcher。Automatic = global seam *)
    Module[{launcherFn = Lookup[opts, "Launcher", Automatic]},
      If[launcherFn === Automatic || launcherFn === None,
        launcherFn = $ClaudeSessionRunnerLauncher];
      launched = Quiet @ Check[
        launcherFn[<|
          "SpoolDir" -> spoolDir, "StartSpec" -> startSpec,
          "RunnerScript" -> script|>],
        <|"Status" -> "Failed", "Reason" -> "LauncherException"|>]];
    If[!AssociationQ[launched] ||
       Lookup[launched, "Status", None] =!= "Launched",
      iRunnerWriteStatus[spoolDir, "Failed",
        <|"Reason" -> "LaunchFailed"|>];
      Return[<|"Status" -> "Failed",
        "Reason" -> Lookup[launched, "Reason", "LaunchFailed"]|>]];

    h = "exth-" <> ToLowerCase[StringDelete[CreateUUID[], "-"]];
    AssociateTo[$iRunnerHandles, h -> <|
      "HandleRef" -> h, "SpoolDir" -> spoolDir,
      "SessionId" -> Lookup[startSpec, "SessionId", None],
      "EpisodeId" -> epi, "Attempt" -> att,
      "BackendInstanceId" ->
        Lookup[launched, "BackendInstanceId", iRtNewId["extbki"]],
      "PID" -> Lookup[launched, "PID", None],
      "Executable" -> Lookup[launched, "Executable", None],
      "Disposed" -> False|>];
    AssociateTo[$iRunnerStarts, startKey -> h];
    <|"Status" -> "Started",
      "SessionId" -> Lookup[startSpec, "SessionId", None],
      "EpisodeId" -> epi, "HandleRef" -> h,
      "BackendInstanceId" ->
        Lookup[launched, "BackendInstanceId", None],
      "InitialEventCursor" -> <|"Attempt" -> att, "EventSeq" -> 0|>,
      "PIDRef" -> Lookup[launched, "PID", None]|>
  ];

(* simulator の場合、poll 前に runner を一歩進める (実プロセスは自走) *)
iRunnerMaybeTick[spoolDir_] :=
  If[KeyExistsQ[$iRunnerSims, spoolDir],
    Quiet @ Check[ClaudeSessionRunnerSimulatorTick[spoolDir], Null]];

iRunnerBackendPoll[handleRef_, cursor_Association] :=
  Module[{st = Lookup[$iRunnerHandles, handleRef, Missing["NoHandle"]],
          spoolDir, evs, afterSeq, nextSeq},
    If[MissingQ[st],
      Return[<|"Status" -> "Lost", "Events" -> {},
        "NextCursor" -> cursor, "HeartbeatAt" -> None|>]];
    If[TrueQ[st[["Disposed"]]],
      Return[<|"Status" -> "Unavailable", "Events" -> {},
        "NextCursor" -> cursor, "HeartbeatAt" -> None|>]];
    spoolDir = st[["SpoolDir"]];
    iRunnerMaybeTick[spoolDir];
    afterSeq = Lookup[cursor, "EventSeq", 0];
    If[!IntegerQ[afterSeq], afterSeq = 0];
    evs = iRunnerListInbox[spoolDir, afterSeq];
    nextSeq = If[evs === {}, afterSeq,
      Max[Map[#[["EventSeq"]] &, evs]]];
    <|"Status" -> "OK", "Events" -> evs,
      "NextCursor" -> <|
        "Attempt" -> Lookup[cursor, "Attempt", st[["Attempt"]]],
        "EventSeq" -> nextSeq|>,
      "HeartbeatAt" -> DateObject[]|>
  ];

iRunnerBackendSend[handleRef_, cmd_Association] :=
  Module[{st = Lookup[$iRunnerHandles, handleRef, Missing["NoHandle"]],
          spoolDir, cid, path},
    If[MissingQ[st] || TrueQ[st[["Disposed"]]],
      Return[<|"Status" -> "Unavailable",
        "CommandId" -> Lookup[cmd, "CommandId", None],
        "Reason" -> "NoSuchHandle"|>]];
    cid = Lookup[cmd, "CommandId", None];
    If[!StringQ[cid],
      Return[<|"Status" -> "Rejected", "CommandId" -> cid,
        "Reason" -> "MissingCommandId"|>]];
    (* Attempt 不一致は拒否 (§7.8) *)
    If[Lookup[cmd, "Attempt", None] =!= st[["Attempt"]],
      Return[<|"Status" -> "Rejected", "CommandId" -> cid,
        "Reason" -> "StaleAttempt"|>]];
    spoolDir = st[["SpoolDir"]];
    path = iRunnerOutboxPath[spoolDir, cid];
    (* 冪等: 既に outbox にあれば AlreadyAccepted (transport retry) *)
    If[FileExistsQ[path],
      Return[<|"Status" -> "AlreadyAccepted", "CommandId" -> cid|>]];
    Quiet @ Check[iRtAtomicExport[path, cmd], $Failed];
    <|"Status" -> "Accepted", "CommandId" -> cid, "Reason" -> None|>
  ];

iRunnerBackendInspect[handleRef_] :=
  Module[{st = Lookup[$iRunnerHandles, handleRef, Missing["NoHandle"]]},
    If[MissingQ[st],
      Failure["NoSuchHandle", <|"HandleRef" -> handleRef|>],
      <|"HandleRef" -> handleRef, "SpoolDir" -> st[["SpoolDir"]],
        "SessionId" -> st[["SessionId"]],
        "EpisodeId" -> st[["EpisodeId"]],
        "Attempt" -> st[["Attempt"]],
        "PID" -> st[["PID"]],
        "Disposed" -> st[["Disposed"]],
        "Status" -> iRunnerReadStatus[st[["SpoolDir"]]][["Status"]]|>]
  ];

(* PID identity: externalrunner.wl の probe seam を再利用して pid.wxf の
   同一性を確認 (§18.3 誤 kill 防止)。 *)
iRunnerVerifyPid[spoolDir_] :=
  Module[{pidRec = iRunnerReadPid[spoolDir], probe, pid, info},
    If[!AssociationQ[pidRec],
      Return[<|"Verified" -> False, "Reason" -> "NoPidRecord"|>]];
    pid = Lookup[pidRec, "PID", None];
    If[!IntegerQ[pid] || pid <= 0,
      Return[<|"Verified" -> False, "Reason" -> "NoPid"|>]];
    probe = If[Names["ClaudeRuntime`$ClaudeExternalProcessProbe"] =!= {},
      Symbol["ClaudeRuntime`Private`iResolveProcessProbe"][],
      None];
    info = If[probe === None, None,
      Quiet @ Check[probe[pid], None]];
    Which[
      !AssociationQ[info],
        <|"Verified" -> False, "Reason" -> "NotAlive", "PID" -> pid|>,
      !TrueQ[Lookup[info, "Alive", False]],
        <|"Verified" -> False, "Reason" -> "NotAlive", "PID" -> pid|>,
      StringQ[Lookup[info, "Executable", None]] &&
        !StringContainsQ[ToLowerCase[Lookup[info, "Executable", ""]],
          "wolframscript"],
        <|"Verified" -> False, "Reason" -> "ImageMismatch",
          "PID" -> pid, "Executable" -> Lookup[info, "Executable", ""]|>,
      True,
        <|"Verified" -> True, "PID" -> pid|>]
  ];

(* Recover (§15.2): handle 消失後、spool から reattach 可否を判定 *)
iRunnerBackendRecover[episodeRecord_Association] :=
  Module[{h = Lookup[episodeRecord, "HandleRef", None], st, spoolDir,
          statusRec, verify},
    st = If[StringQ[h],
      Lookup[$iRunnerHandles, h, Missing["NoHandle"]],
      Missing["NoHandle"]];
    (* in-kernel handle が生きていれば即 reattach *)
    If[!MissingQ[st] && !TrueQ[st[["Disposed"]]],
      Return[<|"Status" -> "Reattached", "HandleRef" -> h,
        "ResumedCheckpointRef" -> None|>]];
    (* handle 消失 (main kernel abort 模擬): spool から再構築 *)
    spoolDir = Lookup[episodeRecord, "SessionSpoolRef",
      Lookup[episodeRecord, "SpoolDir", None]];
    If[!StringQ[spoolDir] || !DirectoryQ[spoolDir],
      Return[<|"Status" -> "LostUnrecoverable", "HandleRef" -> None,
        "ResumedCheckpointRef" -> None|>]];
    statusRec = iRunnerReadStatus[spoolDir];
    If[Lookup[statusRec, "Status", None] === "Completed",
      Return[<|"Status" -> "LostUnrecoverable", "HandleRef" -> None,
        "Reason" -> "AlreadyCompleted"|>]];
    verify = iRunnerVerifyPid[spoolDir];
    If[TrueQ[verify[["Verified"]]],
      (* alive + identity 一致 → in-kernel handle を再登録して reattach *)
      Module[{h2 = "exth-" <>
          ToLowerCase[StringDelete[CreateUUID[], "-"]],
          pidRec = iRunnerReadPid[spoolDir]},
        AssociateTo[$iRunnerHandles, h2 -> <|
          "HandleRef" -> h2, "SpoolDir" -> spoolDir,
          "SessionId" -> Lookup[episodeRecord, "SessionId", None],
          "EpisodeId" -> Lookup[episodeRecord, "EpisodeId", None],
          "Attempt" -> Lookup[episodeRecord, "Attempt", 1],
          "BackendInstanceId" -> iRtNewId["extbki"],
          "PID" -> Lookup[pidRec, "PID", None],
          "Executable" -> Lookup[pidRec, "Executable", None],
          "Disposed" -> False|>];
        <|"Status" -> "Reattached", "HandleRef" -> h2,
          "ResumedCheckpointRef" -> None|>],
      <|"Status" -> "LostUnrecoverable", "HandleRef" -> None,
        "Reason" -> verify[["Reason"]]|>]
  ];

(* Dispose (§18.3): cancel → grace → pid-verified kill。
   identity 不一致なら kill せず Quarantined。 *)
iRunnerBackendDispose[handleRef_, cleanupPolicy_] :=
  Module[{st = Lookup[$iRunnerHandles, handleRef, Missing["NoHandle"]],
          spoolDir, verify, killer, killed, prevStatus},
    Which[
      MissingQ[st], <|"Status" -> "AlreadyDisposed"|>,
      TrueQ[st[["Disposed"]]], <|"Status" -> "AlreadyDisposed"|>,
      True,
        spoolDir = st[["SpoolDir"]];
        (* "Disposed" 上書き前の status を捕捉 (正常終了判定に使う) *)
        prevStatus = Lookup[iRunnerReadStatus[spoolDir], "Status", None];
        verify = iRunnerVerifyPid[spoolDir];
        killed = False;
        If[TrueQ[verify[["Verified"]]],
          killer =
            If[Names["ClaudeRuntime`$ClaudeExternalProcessKill"] =!= {},
              Symbol["ClaudeRuntime`Private`iResolveProcessKill"][],
              None];
          If[killer =!= None,
            killed = TrueQ[Quiet @ Check[
              killer[verify[["PID"]]], False]]]];
        (* simulator は in-kernel。sim registry も掃除 *)
        If[KeyExistsQ[$iRunnerSims, spoolDir],
          $iRunnerSims = KeyDrop[$iRunnerSims, spoolDir]];
        AssociateTo[$iRunnerHandles, handleRef ->
          Append[st, "Disposed" -> True]];
        iRunnerWriteStatus[spoolDir, "Disposed"];
        Which[
          TrueQ[verify[["Verified"]]] && killed,
            <|"Status" -> "Disposed", "Killed" -> True|>,
          !TrueQ[verify[["Verified"]]] &&
            Lookup[verify, "Reason", None] === "NotAlive" &&
            MemberQ[{"Completed", "Failed", "Cancelled", "Disposed"},
              prevStatus],
            (* 子が terminal status を書いて正常 exit 済み → kill 不要の
               後始末 (Quarantined は生存疑いが残る identity 不明に限定) *)
            <|"Status" -> "Disposed", "Killed" -> False|>,
          !TrueQ[verify[["Verified"]]],
            (* identity 未確認 → kill せず Quarantined (§18.3) *)
            <|"Status" -> "Quarantined",
              "Reason" -> verify[["Reason"]]|>,
          True,
            <|"Status" -> "Disposed", "Killed" -> False|>]
    ]
  ];

ClaudeSessionRunnerInspectSpool[spoolDir_String] :=
  <|"SpoolDir" -> spoolDir,
    "Manifest" -> iRtWXFImport[FileNameJoin[{spoolDir, "manifest.wxf"}]],
    "Status" -> iRunnerReadStatus[spoolDir],
    "Pid" -> iRunnerReadPid[spoolDir],
    "InboxFiles" -> Map[FileNameTake,
      Sort @ FileNames["*.wxf", FileNameJoin[{spoolDir, "inbox"}]]],
    "OutboxFiles" -> Map[FileNameTake,
      Sort @ FileNames["*.wxf", FileNameJoin[{spoolDir, "outbox"}]]]|>;

Options[ClaudeRuntimeExternalProcessBackendSpec] = {
  "RunnerScript" -> Automatic,
  "WorkerSpec" -> None,
  "Launcher" -> Automatic};

ClaudeRuntimeExternalProcessBackendSpec[opts:OptionsPattern[]] :=
  Module[{bopts},
    bopts = <|"RunnerScript" -> Replace[OptionValue["RunnerScript"],
      Automatic -> <|"Events" -> {<|"Type" -> "Completed"|>},
        "AckCommands" -> True, "TerminalOnCancel" -> True|>],
      "WorkerSpec" -> OptionValue["WorkerSpec"],
      "Launcher" -> OptionValue["Launcher"]|>;
    <|
      "ProtocolVersion" -> 1,
      "Capabilities" -> {"ExternalProcess", "ToolLoop", "EventReplay",
        "Checkpoint", "Resume", "Interrupt"},
      "StartEpisode" ->
        Function[startSpec, iRunnerBackendStart[bopts, startSpec]],
      "PollEvents" ->
        Function[{h, cursor}, iRunnerBackendPoll[h, cursor]],
      "SendCommand" ->
        Function[{h, cmd}, iRunnerBackendSend[h, cmd]],
      "Inspect" -> Function[h, iRunnerBackendInspect[h]],
      "Recover" -> Function[rec, iRunnerBackendRecover[rec]],
      "Dispose" -> Function[{h, pol}, iRunnerBackendDispose[h, pol]]
    |>
  ];

End[];  (* `Private` *)

EndPackage[];

Print[Style[
  "ClaudeRuntime_sessionrunner.wl (Inc9+IncE) がロードされました。",
  Bold]];
Print["
  ClaudeRuntimeExternalProcessBackendSpec[opts]  → §8.1 external backend
    opts: RunnerScript / WorkerSpec (IncE worker) / Launcher (per-backend)
  ClaudeRunSessionFromSpool[spoolDir]            → runner entrypoint
    (manifest に WorkerSpec があれば worker mode)
  ClaudeSessionRunnerSimulatorTick[spoolDir]     → sim を一歩進める (テスト)
  ClaudeSessionRunnerInspectSpool / Reset
  seam: $ClaudeSessionRunnerLauncher (既定 simulator、本番は実 wolframscript)
"];
