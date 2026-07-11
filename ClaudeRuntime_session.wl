(* ::Package:: *)

(* ::Title:: *)
(* ClaudeRuntime_session.wl *)

(* ::Subsection:: *)
(* 概要 *)

(* ════════════════════════════════════════════════════════════════════
   ClaudeRuntime_session.wl

   ClaudeRuntime`Session` 名前空間。
   RuntimeSession episode 層 (仕様: ClaudeOrchestrator_info/design/
   claude_orchestrator_runtime_session_episode_petri_spec_v0_1.md) の
   Runtime 側 facade (§12) と in-kernel backend (§8.2
   ClaudeRuntimeInKernel)。

   本ファイルの現行スコープは Inc4a:
     - adapter factory registry (§12.1 ClaudeRegisterRuntimeAdapterFactory)
     - control event journal (§12.5: 発行前 durable 保存、
       EventSeq は attempt 内単調増加)
     - session facade (§12.1: Open/StartEpisode/Poll/Command/Stop/Info)
     - §8.1 backend protocol 実装 ClaudeRuntimeSessionBackendSpec[]
       ((EpisodeId, Attempt, StartCommandId) 冪等 start /
        ExpectedAfterEventSeq precondition / Cancel の stale 免除)
     - adapter factory の 2 モード:
         "Compute"       : 1-turn 純計算 episode (headless 検証可。
                           runtime-orchestrator-boundary: turn 内で閉じる
                           純関数実行は Runtime の領分)
         "ClaudeRuntime" : CreateClaudeRuntime + ClaudeRunTurn を包み、
                           既存 AwaitingApproval (proposal 粒度) を
                           ApprovalRequired event に変換 (§12.2)。
                           実 turn は ClaudeCode` 環境 (NB) で検証する。

   Inc4b (未実装、ClaudeRuntime.wl 本体の改修):
     - tool 単位 pre-execution approval gate (ToolCallId scoped)
     - BudgetInterrupt suspend / versioned grant / resume
     - Prepared/Committed/Failed の tool effect journal
     - routine/boundary checkpoint export (Inc6)

   依存規則 (§22):
     ClaudeRuntime_session -> ClaudeRuntime (public API のみ)
     ClaudeRuntime_session -X-> ClaudeOrchestrator
       (event hash は §7.9 の canonical 算法を自己完結に実装する。
        orchestrator 側 ClaudeSessionEventHash と一致することは
        cross-implementation テストで保証)

   バージョン: v0.1 (Inc4a, 2026-07-11)
   ════════════════════════════════════════════════════════════════════ *)

BeginPackage["ClaudeRuntime`Session`", {"ClaudeRuntime`"}];

$ClaudeRuntimeSessionVersion::usage =
  "$ClaudeRuntimeSessionVersion は本モジュールのバージョン文字列。";

$ClaudeRuntimeSessionJournalRoot::usage =
  "$ClaudeRuntimeSessionJournalRoot は control event journal の durable\n" <>
  "保存先 root (§12.5)。未設定時は $UserBaseDirectory/ClaudeRuntime/\n" <>
  "session-journal。";

ClaudeRegisterRuntimeAdapterFactory::usage =
  "ClaudeRegisterRuntimeAdapterFactory[name, fn] は adapter factory を\n" <>
  "登録する (§12.1)。fn[startSpec] は\n" <>
  "  <|\"Mode\"->\"Compute\", \"Compute\"->fn2|>  (fn2[startSpec] が結果) か\n" <>
  "  <|\"Mode\"->\"ClaudeRuntime\", \"Adapter\"-><|BuildContext,..|>,\n" <>
  "    \"InitialInput\"->_|>\n" <>
  "を返す。checkpoint からの resume 時も同名 factory で再構築する (§7.5)。";

ClaudeRuntimeAdapterFactories::usage =
  "ClaudeRuntimeAdapterFactories[] は登録済み adapter factory 名を返す。";

ClaudeRuntimeOpenSession::usage =
  "ClaudeRuntimeOpenSession[startSpec] は session 状態を作り sessionId を\n" <>
  "返す (§12.1)。まだ episode は開始しない。";

ClaudeRuntimeStartEpisode::usage =
  "ClaudeRuntimeStartEpisode[sessionId] は adapter factory を解決して\n" <>
  "episode を開始する。Compute モードは同期実行して terminal event まで\n" <>
  "journal に積む。ClaudeRuntime モードは CreateClaudeRuntime +\n" <>
  "ClaudeRunTurn を起動し、以後の event は poll 時に harvest する。";

ClaudeRuntimeSessionPoll::usage =
  "ClaudeRuntimeSessionPoll[sessionId, cursor] は cursor\n" <>
  "(<|Attempt, EventSeq|>) 以降の control event を返す (§12.1)。\n" <>
  "ClaudeRuntime モードでは runtime 状態を harvest してから返す。";

ClaudeRuntimeSessionCommand::usage =
  "ClaudeRuntimeSessionCommand[sessionId, command] は SessionCommand を\n" <>
  "冪等に受理する (§7.8: CommandId dedup / Attempt 不一致は\n" <>
  "Rejected(StaleAttempt) / ExpectedAfterEventSeq 不一致は\n" <>
  "Rejected(StaleContext)、Cancel のみ stale context 免除)。";

ClaudeRuntimeStopSession::usage =
  "ClaudeRuntimeStopSession[sessionId, reason] は runtime を cancel し\n" <>
  "Cancelled event を journal に積んで session を閉じる。";

ClaudeRuntimeSessionInfo::usage =
  "ClaudeRuntimeSessionInfo[sessionId] は session の状態 summary を返す。";

ClaudeRuntimeSessionResult::usage =
  "ClaudeRuntimeSessionResult[sessionId] は Compute/ClaudeRuntime episode の\n" <>
  "最終結果 (redacted) を返す。event の PayloadRefs は ref のみを運ぶ\n" <>
  "(I4) ため、本文はこの accessor で取得する。";

ClaudeRuntimeSessionBackendSpec::usage =
  "ClaudeRuntimeSessionBackendSpec[] は §8.1 契約の in-kernel backend\n" <>
  "Association を返す (ClaudeRuntimeInKernel)。ClaudeOrchestrator 側の\n" <>
  "ClaudeRegisterRuntimeSessionBackend に渡して使う (wiring は\n" <>
  "claudecode.wl / テスト側が行い、本ファイルは Orchestrator に依存しない)。";

ClaudeRuntimeSessionReset::usage =
  "ClaudeRuntimeSessionReset[] は facade の内部状態 (全 session / start\n" <>
  "冪等 index) をクリアする。durable journal/checkpoint file は残る\n" <>
  "(kernel crash の模擬にも使える)。テスト用。";

(* ── Inc6: tool effect journal + checkpoint/resume ── *)

ClaudeRuntimeSessionToolJournal::usage =
  "ClaudeRuntimeSessionToolJournal[sessionId] は tool effect journal\n" <>
  "(§15.3: Prepared/Committed) を返す。gate Permit 時に Prepared、実行\n" <>
  "結果で Committed へ durable に更新される。実行が失敗/不確定の tool は\n" <>
  "Prepared のまま残り、自動 resume を塞ぐ (I9)。";

ClaudeRuntimeSessionCheckpoint::usage =
  "ClaudeRuntimeSessionCheckpoint[sessionId, opts] は\n" <>
  "RuntimeCheckpointManifest (§7.5) を durable に保存する。\n" <>
  "\"Kind\"->\"Boundary\" (既定) は CheckpointCreated control event を\n" <>
  "emit、\"Routine\" は event を出さない (granularity 条件 §9.6)。\n" <>
  "戻り値に CheckpointRef (file path) と Manifest。";

ClaudeRuntimeSessionResumeDecision::usage =
  "ClaudeRuntimeSessionResumeDecision[checkpointRef] は §15.2/§15.3 の\n" <>
  "resume 可否を返す: Prepared のままの (non-idempotent かもしれない)\n" <>
  "tool effect があれば NeedsRestartApproval、無ければ ResumeAllowed。";

ClaudeRuntimeResumeSession::usage =
  "ClaudeRuntimeResumeSession[checkpointRef, startSpec, opts] は checkpoint\n" <>
  "から Attempt+1 で新 session を作る (§12.2 resume / §15)。\n" <>
  "manifest の ContentHash / policy hash / Attempt 連番を検証し、budget\n" <>
  "counter は manifest から引き継いで後退させない。journal に Prepared が\n" <>
  "残る場合は \"ApproveRestart\"->True が無い限り NeedsRestartApproval を\n" <>
  "返して session を作らない (I9)。";

(* ── IncE: Inc10 前提 session reuse 安全ガード (§14.5/§16.4/§26.3) ── *)

ClaudeSessionReuseEligibleQ::usage =
  "ClaudeSessionReuseEligibleQ[sessionId, newStartSpec] は open session を\n" <>
  "新 episode に再利用してよいか判定する (Inc10 前提の安全ガード)。\n" <>
  "全条件 AND で eligible: ReusePolicy==SameWorkflowSameTrust / 同 WorkflowId\n" <>
  " / 同 PolicySnapshotHash / 新 backend の InferenceTrustDomain が session\n" <>
  "累積 PrivacyLabel を受容 (§16.4 taint 単調) / Prepared な非冪等 effect\n" <>
  "が残っていない (I9)。戻り値 <|Eligible, Reasons, CarryForward|>。\n" <>
  "reuse 本体 (ReusePolicy=SameWorkflowSameTrust の実施) は v0.1 非目標で\n" <>
  "本関数は判定のみ。";

ClaudeSessionRaiseAccumulatedPrivacy::usage =
  "ClaudeSessionRaiseAccumulatedPrivacy[sessionId, label] は session の\n" <>
  "累積 PrivacyLabel を単調に引き上げる (§16.4)。読んだ input/artifact/\n" <>
  "tool result の最大値へ。下げられない。現在値を返す。";

ClaudeRuntimeReuseSessionForEpisode::usage =
  "ClaudeRuntimeReuseSessionForEpisode[sessionId, newStartSpec] は Inc10\n" <>
  "本体 = session reuse の *機構*。終端 (Completed) の生きた session を、\n" <>
  "同一 workflow / 同一 trust domain の次 episode 用に再オープンする。\n" <>
  "ClaudeSessionReuseEligibleQ の gate を通り、eligible なら per-episode\n" <>
  "状態 (RuntimeId/Journal/NextSeq/Result 等) を reset しつつ、累積の\n" <>
  "BudgetUsed.ToolCalls と AccumulatedPrivacyLabel は reset せず carry\n" <>
  "forward する (Inc10 受け入れ)。物理 session id は維持し、Status を\n" <>
  "\"Open\" に戻して次の StartEpisode を可能にする。\n" <>
  "『いつ reuse するか』の判断は Petri net の ReusePolicy (Orchestrator)\n" <>
  "の領分で、本関数は worker runtime 側の機構のみを提供する。\n" <>
  "戻り値 <|Status(Reused|Ineligible|NotReusableYet|NoSession|Disposed),\n" <>
  "  SessionId, EpisodeId, CarriedToolCalls, AccumulatedPrivacyLabel,\n" <>
  "  EpisodeCount, Reasons|>。";

Begin["`Private`"];

$ClaudeRuntimeSessionVersion = "v0.1 (Inc4a, 2026-07-11)";

(* ════════════════════════════════════════════════════════
   canonical hash (§7.9 の自己完結実装)

   ClaudeOrchestrator_session.wl の ClaudeSessionCanonicalHash と
   同一算法 (全階層 KeySort / DateObject→epoch ms / WXF / Base64 /
   SHA256)。依存方向 (Runtime -X-> Orchestrator) を守るための複製で、
   一致は cross-implementation テストで保証する。
   ════════════════════════════════════════════════════════ *)

iRtCanon[a_Association] := KeySort[Map[iRtCanon, a]];
iRtCanon[l_List]        := Map[iRtCanon, l];
iRtCanon[d_DateObject]  :=
  <|"__CanonicalDateMs" -> Round[1000 * AbsoluteTime[d]]|>;
iRtCanon[x_]            := x;

iRtCanonicalHash[expr_] :=
  IntegerString[
    Hash[BaseEncode[BinarySerialize[iRtCanon[expr]], "Base64"], "SHA256"],
    16, 64];

$iRtTransportKeys = {
  "Delivered", "DeliveredAt", "DeliveryStatus", "FetchedAt",
  "TransportMeta"};

iRtEventHash[ev_Association] :=
  iRtCanonicalHash[KeyDrop[ev, Join[{"EventHash"}, $iRtTransportKeys]]];

iRtNewId[pfx_String] :=
  pfx <> "-" <> ToLowerCase[StringDelete[CreateUUID[], "-"]];

(* ════════════════════════════════════════════════════════
   registry / journal
   ════════════════════════════════════════════════════════ *)

If[!AssociationQ[$iRtSessions], $iRtSessions = <||>];
If[!AssociationQ[$iRtSessionStarts], $iRtSessionStarts = <||>];
If[!AssociationQ[$iRtAdapterFactories], $iRtAdapterFactories = <||>];
If[!AssociationQ[$iRtRuntimeToSession], $iRtRuntimeToSession = <||>];

ClaudeRuntimeSessionReset[] := (
  $iRtSessions         = <||>;
  $iRtSessionStarts    = <||>;
  $iRtRuntimeToSession = <||>;
  <|"Status" -> "Reset"|>);

ClaudeRegisterRuntimeAdapterFactory[name_String, fn_] := (
  AssociateTo[$iRtAdapterFactories, name -> fn];
  <|"Status" -> "Registered", "Factory" -> name|>);

ClaudeRuntimeAdapterFactories[] := Keys[$iRtAdapterFactories];

iRtJournalRoot[] :=
  If[StringQ[$ClaudeRuntimeSessionJournalRoot] &&
     $ClaudeRuntimeSessionJournalRoot =!= "",
    $ClaudeRuntimeSessionJournalRoot,
    FileNameJoin[{$UserBaseDirectory, "ClaudeRuntime",
      "session-journal"}]];

(* §12.5: 発行前に durable journal へ保存 (best effort、失敗しても
   in-memory journal は正)。 *)
iRtJournalPersist[sid_String, ev_Association] :=
  Quiet @ Check[
    Module[{dir, path, tmp},
      dir = FileNameJoin[{iRtJournalRoot[], sid}];
      If[!DirectoryQ[dir],
        CreateDirectory[dir, CreateIntermediateDirectories -> True]];
      path = FileNameJoin[{dir,
        "evt-" <> IntegerString[Lookup[ev, "EventSeq", 0], 10, 6] <>
        ".wxf"}];
      tmp = path <> ".tmp-" <> ToString[$ProcessID];
      Export[tmp, ev, "WXF"];
      If[FileExistsQ[path], Quiet @ DeleteFile[path]];
      RenameFile[tmp, path];
      path],
    $Failed];

(* control event を組み立てて journal に積む。EventSeq は attempt 内で
   単調増加 (§12.5)。 *)
iRtEmit[sid_String, type_String, payloadRefs_Association,
        budgetSnapshot_Association, extra_Association:<||>] :=
  Module[{st = Lookup[$iRtSessions, sid, Missing["NoSession"]], ss,
          access, seq, ev},
    If[MissingQ[st], Return[$Failed]];
    ss = st[["StartSpec"]];
    access = Lookup[ss, "Access", <||>];
    seq = st[["NextSeq"]];
    ev = <|
      "SchemaVersion" -> 1,
      "EventId" -> iRtNewId["evt"],
      "EventSeq" -> seq,
      "SessionId" -> Lookup[ss, "SessionId", sid],
      "EpisodeId" -> Lookup[ss, "EpisodeId", "epi-unknown"],
      "Attempt" -> Lookup[ss, "Attempt", 1],
      "BackendInstanceId" -> st[["BackendInstanceId"]],
      "Source" -> "Runtime",
      "Type" -> type,
      "SupersedesThroughSeq" -> None,
      "PayloadRefs" -> payloadRefs,
      "LatestCheckpointRef" -> None,
      "BudgetSnapshot" -> budgetSnapshot,
      "AccessSpecHash" -> Lookup[access, "AccessSpecHash", ""],
      "PolicySnapshotHash" -> Lookup[access, "PolicySnapshotHash", ""],
      "PrivacyLabel" -> Lookup[access, "PrivacyLabel", 1.0],
      "CreatedAt" -> DateObject[]|>;
    If[extra =!= <||>, ev = Append[ev, Normal[extra]]];
    ev = Append[ev, "EventHash" -> iRtEventHash[ev]];
    iRtJournalPersist[sid, ev];
    AssociateTo[st, {"Journal" -> Append[st[["Journal"]], ev],
      "NextSeq" -> seq + 1}];
    AssociateTo[$iRtSessions, sid -> st];
    ev
  ];

iRtDefaultSnapshot[ss_Association, turns_Integer] :=
  Module[{g = Lookup[ss, "BudgetGrant", <||>]},
    <|"Turns" -> turns, "Calls" -> turns, "ToolCalls" -> 0,
      "InputTokens" -> 0, "OutputTokens" -> 0,
      "WallClockSeconds" -> 0., "IdleSeconds" -> 0.,
      "BytesWritten" -> 0, "NetworkRequests" -> 0,
      "ActualUSD" -> None, "ReservedUSD" -> None,
      "CostSource" -> "Unknown",
      "BudgetGrantId" -> Lookup[g, "BudgetGrantId", "grant-unknown"],
      "BudgetGrantVersion" -> Lookup[g, "Version", 1]|>];

(* ════════════════════════════════════════════════════════
   facade (§12.1)
   ════════════════════════════════════════════════════════ *)

ClaudeRuntimeOpenSession[startSpec_Association] :=
  Module[{sid},
    sid = Lookup[startSpec, "SessionId", iRtNewId["ses"]];
    If[KeyExistsQ[$iRtSessions, sid],
      Return[<|"Status" -> "AlreadyOpen", "SessionId" -> sid|>]];
    AssociateTo[$iRtSessions, sid -> <|
      "SessionId" -> sid,
      "StartSpec" -> startSpec,
      "BackendInstanceId" -> iRtNewId["rtbki"],
      "Mode" -> None,
      "RuntimeId" -> None,
      "Journal" -> {},
      "NextSeq" -> 1,
      "AcceptedCommands" -> <||>,
      "Result" -> None,
      "Emitted" -> <||>,       (* harvest 済み境界の記録 *)
      (* Inc5: episode budget (grant は versioned、使用量は保守的計上) *)
      "BudgetGrant" -> Lookup[startSpec, "BudgetGrant", <||>],
      "BudgetUsed" -> <|"ToolCalls" -> 0|>,
      "Reservations" -> {},
      (* IncE (§16.4): 累積 privacy label。読んだ input/artifact/tool result
         の最大へ単調に上がり、下がらない。reuse の trust gate に使う *)
      "AccumulatedPrivacyLabel" ->
        N @ Lookup[Lookup[startSpec, "Access", <||>], "PrivacyLabel", 0.],
      (* IncG (Inc10): この物理 session で走らせた episode 数 (原初=0) *)
      "EpisodeCount" -> 0,
      "Status" -> "Open",
      "Disposed" -> False|>];
    <|"Status" -> "Opened", "SessionId" -> sid|>
  ];

ClaudeRuntimeStartEpisode[sid_String] :=
  Module[{st = Lookup[$iRtSessions, sid, Missing["NoSession"]], ss,
          factoryName, factory, plan, mode},
    If[MissingQ[st], Return[<|"Status" -> "Failed",
      "Reason" -> "NoSuchSession"|>]];
    If[st[["Status"]] =!= "Open",
      Return[<|"Status" -> "AlreadyStarted", "SessionId" -> sid|>]];
    ss = st[["StartSpec"]];
    factoryName = Lookup[Lookup[ss, "Worker", <||>],
      "AdapterFactory", None];
    factory = Lookup[$iRtAdapterFactories, factoryName,
      Missing["NoFactory"]];
    If[MissingQ[factory],
      Return[<|"Status" -> "Failed",
        "Reason" -> "UnknownAdapterFactory: " <>
          ToString[factoryName]|>]];
    plan = Quiet @ Check[factory[ss],
      <|"Mode" -> "Invalid", "Reason" -> "AdapterFactoryException"|>];
    If[!AssociationQ[plan],
      plan = <|"Mode" -> "Invalid", "Reason" -> "InvalidFactoryResult"|>];
    mode = Lookup[plan, "Mode", "Invalid"];
    AssociateTo[st, {"Mode" -> mode, "Status" -> "Running"}];
    AssociateTo[$iRtSessions, sid -> st];
    Switch[mode,
      "Compute",
        iRtRunComputeEpisode[sid, plan],
      "ClaudeRuntime",
        iRtLaunchRuntimeEpisode[sid, plan],
      _,
        AssociateTo[$iRtSessions, sid ->
          Append[Lookup[$iRtSessions, sid], "Status" -> "Failed"]];
        Return[<|"Status" -> "Failed",
          "Reason" -> Lookup[plan, "Reason", "InvalidAdapterMode"]|>]
    ];
    <|"Status" -> "Started", "SessionId" -> sid,
      "Mode" -> mode|>
  ];

(* Compute モード: turn 内で閉じる純計算 (boundary skill 準拠で Runtime の
   領分)。同期実行し、Completed / Failed を journal に積む。 *)
iRtRunComputeEpisode[sid_String, plan_Association] :=
  Module[{st = $iRtSessions[sid], ss, fn, result},
    ss = st[["StartSpec"]];
    fn = Lookup[plan, "Compute", None];
    result = Quiet @ Check[
      If[Head[fn] === Function ||
         (Head[fn] === Symbol && Length[DownValues[fn]] > 0),
        fn[ss],
        $Failed],
      $Failed];
    st = $iRtSessions[sid];
    If[result === $Failed,
      AssociateTo[st, "Status" -> "Failed"];
      AssociateTo[$iRtSessions, sid -> st];
      iRtEmit[sid, "Failed",
        <|"Reason" -> "ComputeFailed"|>, iRtDefaultSnapshot[ss, 1]],
      AssociateTo[st, {"Result" -> result, "Status" -> "Completed"}];
      AssociateTo[$iRtSessions, sid -> st];
      iRtEmit[sid, "Completed",
        <|"ResultRef" -> "rtses://" <> sid <> "/result"|>,
        iRtDefaultSnapshot[ss, 1]]
    ]
  ];

(* ClaudeRuntime モード: 既存 Runtime turn/tool loop を包む (§12.2/§12.3)。
   最初の turn だけを起動し、以後の continuation は Runtime 内部
   (LLMGraph onComplete / AsyncToolExec tick) が駆動する。境界は poll 時の
   harvest で control event 化する。ClaudeCode` が必要 (NB 環境で検証)。 *)
iRtLaunchRuntimeEpisode[sid_String, plan_Association] :=
  Module[{st = $iRtSessions[sid], ss, adapter, initialInput, rid, job},
    ss = st[["StartSpec"]];
    adapter = Lookup[plan, "Adapter", None];
    initialInput = Lookup[plan, "InitialInput",
      Lookup[Lookup[ss, "Task", <||>], "GoalRef", ""]];
    If[!AssociationQ[adapter],
      AssociateTo[st, "Status" -> "Failed"];
      AssociateTo[$iRtSessions, sid -> st];
      iRtEmit[sid, "Failed", <|"Reason" -> "MissingAdapter"|>,
        iRtDefaultSnapshot[ss, 0]];
      Return[$Failed]];
    rid = CreateClaudeRuntime[adapter,
      "Metadata" -> <|"SessionId" -> sid,
        "EpisodeId" -> Lookup[ss, "EpisodeId", None]|>];
    If[!StringQ[rid],
      AssociateTo[st, "Status" -> "Failed"];
      AssociateTo[$iRtSessions, sid -> st];
      iRtEmit[sid, "Failed", <|"Reason" -> "CreateRuntimeFailed"|>,
        iRtDefaultSnapshot[ss, 0]];
      Return[$Failed]];
    AssociateTo[st, "RuntimeId" -> rid];
    AssociateTo[$iRtSessions, sid -> st];
    (* Inc4b: tool gate 用の逆引きと privacy taint 初期化 (§16.4) *)
    AssociateTo[$iRtRuntimeToSession, rid -> sid];
    Quiet @ Check[
      ClaudeRuntimeRaisePrivacyLabel[rid,
        Lookup[Lookup[ss, "Access", <||>], "PrivacyLabel", 1.0]],
      Null];
    job = Quiet @ Check[ClaudeRunTurn[rid, initialInput], $Failed];
    If[job === $Failed,
      iRtEmit[sid, "Failed", <|"Reason" -> "RunTurnFailed"|>,
        iRtDefaultSnapshot[ss, 0]]];
    job
  ];

(* poll 時 harvest: Runtime の状態遷移を一度だけ control event 化する。
   proposal 粒度の AwaitingApproval → ApprovalRequired (§12.2。
   tool 単位 gate は Inc4b)。 *)
iRtHarvest[sid_String] :=
  Module[{st = Lookup[$iRtSessions, sid, Missing["NoSession"]], ss,
          rid, rtState, status, emitted, turns},
    If[MissingQ[st], Return[Null]];
    If[st[["Mode"]] =!= "ClaudeRuntime", Return[Null]];
    rid = st[["RuntimeId"]];
    If[!StringQ[rid], Return[Null]];
    rtState = Quiet @ Check[ClaudeRuntimeState[rid], $Failed];
    If[!AssociationQ[rtState], Return[Null]];
    ss = st[["StartSpec"]];
    status = Lookup[rtState, "Status", None];
    turns = Lookup[rtState, "TurnCount", 0];
    emitted = st[["Emitted"]];
    Which[
      (* Inc5: budget 枯渇 suspend → BudgetInterrupt event (§14.3) *)
      status === "BudgetSuspended" &&
        !TrueQ[Lookup[emitted, "BudgetInterrupt", False]],
        Module[{pend, snap},
          pend = Lookup[
            Quiet @ Check[ClaudeRuntimeStateFull[rid], <||>],
            "PendingBudgetResume", <||>];
          If[!AssociationQ[pend], pend = <||>];
          AssociateTo[st, "Emitted" ->
            Append[emitted, "BudgetInterrupt" -> True]];
          AssociateTo[$iRtSessions, sid -> st];
          snap = Append[iRtDefaultSnapshot[ss, Max[turns, 1]],
            {"ToolCalls" ->
               Lookup[Lookup[st, "BudgetUsed", <||>], "ToolCalls", 0],
             "BudgetGrantVersion" ->
               Lookup[Lookup[st, "BudgetGrant", <||>], "Version", 1]}];
          iRtEmit[sid, "BudgetInterrupt",
            <|"LimitKind" -> Lookup[pend, "LimitKind", "Unknown"],
              "PendingActionSummaryRef" ->
                "rtses://" <> sid <> "/pending-budget",
              "MinimumAdditionalGrant" ->
                Lookup[pend, "MinimumAdditionalGrant", None],
              "DegradeOptions" -> {"FinalizePartial"},
              "LatestCheckpointRef" -> None|>,
            snap]],
      (* Inc4b: tool 単位 pre-execution gate の suspend (§12.4)。
         proposal 粒度の AwaitingApproval とは event payload で区別する *)
      status === "ToolAwaitingApproval" &&
        !TrueQ[Lookup[emitted, "ToolApprovalRequired", False]],
        Module[{pend, ids},
          pend = Lookup[
            Quiet @ Check[ClaudeRuntimeStateFull[rid], <||>],
            "PendingToolApproval", <||>];
          If[!AssociationQ[pend], pend = <||>];
          ids = Map[Lookup[#, "ToolCallId", "?"] &,
            Lookup[pend, "ToolCalls", {}]];
          AssociateTo[st, "Emitted" ->
            Append[emitted, "ToolApprovalRequired" -> True]];
          AssociateTo[$iRtSessions, sid -> st];
          iRtEmit[sid, "ApprovalRequired",
            <|"ToolCallId" -> First[ids, "tool-unknown"],
              "ToolCallIds" -> ids,
              "ActionSummaryRef" -> "rtses://" <> sid <> "/pending-tools",
              "RequestedEffectClasses" -> {"ToolExecution"},
              "RequestedResourceRefs" ->
                Lookup[pend, "Forbidden", {}],
              "ApprovalEligibility" -> "AskUserAllowed"|>,
            iRtDefaultSnapshot[ss, Max[turns, 1]]]],
      status === "AwaitingApproval" &&
        !TrueQ[Lookup[emitted, "ApprovalRequired", False]],
        AssociateTo[st, "Emitted" ->
          Append[emitted, "ApprovalRequired" -> True]];
        AssociateTo[$iRtSessions, sid -> st];
        iRtEmit[sid, "ApprovalRequired",
          <|"ToolCallId" -> "proposal-" <> rid,
            "ActionSummaryRef" -> "rtses://" <> sid <> "/proposal",
            "RequestedEffectClasses" -> {"ProposalExecution"},
            "ApprovalEligibility" -> "AskUserAllowed"|>,
          iRtDefaultSnapshot[ss, Max[turns, 1]]],
      status === "Running" &&
        TrueQ[Lookup[emitted, "ApprovalRequired", False]] &&
        !TrueQ[Lookup[emitted, "ApprovalResumed", False]],
        (* 承認後に再開した場合は emitted flag をリセットし次回に備える *)
        AssociateTo[st, "Emitted" ->
          Append[emitted, {"ApprovalRequired" -> False,
            "ApprovalResumed" -> False}]];
        AssociateTo[$iRtSessions, sid -> st],
      MemberQ[{"Done", "Completed", "Succeeded"}, status] &&
        !TrueQ[Lookup[emitted, "Terminal", False]],
        AssociateTo[st, {"Emitted" ->
            Append[emitted, "Terminal" -> True],
          "Status" -> "Completed",
          "Result" -> Lookup[rtState, "LastRedactedResult", None]}];
        AssociateTo[$iRtSessions, sid -> st];
        iRtEmit[sid, "Completed",
          <|"ResultRef" -> "rtses://" <> sid <> "/result"|>,
          iRtDefaultSnapshot[ss, Max[turns, 1]]],
      MemberQ[{"Failed", "Fatal"}, status] &&
        !TrueQ[Lookup[emitted, "Terminal", False]],
        AssociateTo[st, {"Emitted" ->
            Append[emitted, "Terminal" -> True],
          "Status" -> "Failed"}];
        AssociateTo[$iRtSessions, sid -> st];
        iRtEmit[sid, "Failed",
          <|"Reason" -> ToString[Lookup[rtState, "LastFailure", status]]|>,
          iRtDefaultSnapshot[ss, Max[turns, 1]]],
      True, Null
    ]
  ];

ClaudeRuntimeSessionPoll[sid_String, cursor_Association] :=
  Module[{st, att, seq, evs},
    st = Lookup[$iRtSessions, sid, Missing["NoSession"]];
    If[MissingQ[st],
      Return[<|"Status" -> "Lost", "Events" -> {},
               "NextCursor" -> cursor, "HeartbeatAt" -> None|>]];
    If[TrueQ[st[["Disposed"]]],
      Return[<|"Status" -> "Unavailable", "Events" -> {},
               "NextCursor" -> cursor, "HeartbeatAt" -> None|>]];
    iRtHarvest[sid];
    st = $iRtSessions[sid];
    att = Lookup[cursor, "Attempt", None];
    seq = Lookup[cursor, "EventSeq", None];
    If[att =!= Lookup[st[["StartSpec"]], "Attempt", 1] ||
       !IntegerQ[seq] || seq < 0,
      Return[<|"Status" -> "OK", "Events" -> {},
        "NextCursor" -> <|
          "Attempt" -> Lookup[st[["StartSpec"]], "Attempt", 1],
          "EventSeq" -> st[["NextSeq"]] - 1|>,
        "HeartbeatAt" -> DateObject[]|>]];
    evs = Select[st[["Journal"]], #[["EventSeq"]] > seq &];
    <|"Status" -> "OK", "Events" -> evs,
      "NextCursor" -> <|"Attempt" -> att,
        "EventSeq" -> If[evs === {}, seq,
          Max[Map[#[["EventSeq"]] &, evs]]]|>,
      "HeartbeatAt" -> DateObject[]|>
  ];

ClaudeRuntimeSessionCommand[sid_String, cmd_Association] :=
  Module[{st, cid, lastEmitted, cmdType},
    st = Lookup[$iRtSessions, sid, Missing["NoSession"]];
    If[MissingQ[st] || TrueQ[st[["Disposed"]]],
      Return[<|"Status" -> "Unavailable",
        "CommandId" -> Lookup[cmd, "CommandId", None],
        "Reason" -> "NoSuchSession"|>]];
    cid = Lookup[cmd, "CommandId", None];
    If[!StringQ[cid],
      Return[<|"Status" -> "Rejected", "CommandId" -> cid,
        "Reason" -> "InvalidCommand: missing CommandId"|>]];
    If[KeyExistsQ[st[["AcceptedCommands"]], cid],
      Return[<|"Status" -> "AlreadyAccepted", "CommandId" -> cid,
        "Reason" -> "DuplicateCommandId"|>]];
    If[Lookup[cmd, "Attempt", None] =!=
         Lookup[st[["StartSpec"]], "Attempt", 1],
      Return[<|"Status" -> "Rejected", "CommandId" -> cid,
        "Reason" -> "StaleAttempt"|>]];
    cmdType = Lookup[cmd, "Type", None];
    lastEmitted = st[["NextSeq"]] - 1;
    If[cmdType =!= "Cancel" &&
       Lookup[cmd, "ExpectedAfterEventSeq", -1] =!= lastEmitted,
      Return[<|"Status" -> "Rejected", "CommandId" -> cid,
        "Reason" -> "StaleContext"|>]];

    (* Inc5 (§14.3): GrantBudget は version が現行より大きい場合のみ受理。
       追加 grant は差分ではなく新しい累積上限を送る *)
    If[cmdType === "GrantBudget",
      Module[{g = Lookup[cmd, "BudgetGrant", None], curV},
        curV = Lookup[Lookup[st, "BudgetGrant", <||>], "Version", 0];
        If[!AssociationQ[g] ||
           !IntegerQ[Lookup[g, "Version", None]] ||
           Lookup[g, "Version", 0] <= curV,
          Return[<|"Status" -> "Rejected", "CommandId" -> cid,
            "Reason" -> "StaleBudgetGrantVersion"|>]]]];

    AssociateTo[st, "AcceptedCommands" ->
      Append[st[["AcceptedCommands"]],
        cid -> <|"Type" -> cmdType, "AcceptedAt" -> DateObject[]|>]];
    AssociateTo[$iRtSessions, sid -> st];

    (* command 種別ごとの effect *)
    Switch[cmdType,
      "GrantScopedApproval",
        If[StringQ[st[["RuntimeId"]]],
          Module[{rtStatus, tcid, pend, ids, usedScoped = False},
            rtStatus = Lookup[
              Quiet @ Check[ClaudeRuntimeState[st[["RuntimeId"]]], <||>],
              "Status", None];
            If[rtStatus === "ToolAwaitingApproval",
              (* Inc7: NBAccess permit があれば ToolCallId 単位で解禁
                 (§13.2)。無ければ Inc4b の full approve (K7 互換) *)
              tcid = Lookup[Lookup[cmd, "PayloadRefs", <||>],
                "ToolCallId", None];
              If[StringQ[tcid] &&
                 Names["NBAccess`NBGrantToolCallPermit"] =!= {},
                (* 保留 tool の ToolCallId 群に permit を発行 *)
                pend = Lookup[
                  Quiet @ Check[
                    ClaudeRuntimeStateFull[st[["RuntimeId"]]], <||>],
                  "PendingToolApproval", <||>];
                ids = Map[Lookup[#, "ToolCallId", "?"] &,
                  Lookup[pend, "ToolCalls", {}]];
                Scan[
                  Quiet @ Check[
                    Symbol["NBAccess`NBGrantToolCallPermit"][#], Null] &,
                  ids];
                Quiet @ Check[ClaudeResumeToolCalls[
                  st[["RuntimeId"]], "ApproveScoped"], Null];
                usedScoped = True];
              If[!usedScoped,
                Quiet @ Check[ClaudeResumeToolCalls[
                  st[["RuntimeId"]], "Approve"], Null]],
              Quiet @ Check[ClaudeApproveProposal[st[["RuntimeId"]]],
                Null]]];
          Module[{st2 = $iRtSessions[sid]},
            AssociateTo[st2, "Emitted" ->
              Append[st2[["Emitted"]],
                {"ApprovalResumed" -> True,
                 "ToolApprovalRequired" -> False}]];
            AssociateTo[$iRtSessions, sid -> st2]]],
      "GrantBudget",
        (* 新しい累積上限へ差替え、同一 episode を再開 (§14.3/§14.5)。
           別 session を暗黙起動しない *)
        Module[{st4 = $iRtSessions[sid], rtStatus},
          AssociateTo[st4, {
            "BudgetGrant" -> Lookup[cmd, "BudgetGrant", <||>],
            "Emitted" -> Append[Lookup[st4, "Emitted", <||>],
              "BudgetInterrupt" -> False]}];
          AssociateTo[$iRtSessions, sid -> st4];
          If[StringQ[st[["RuntimeId"]]],
            rtStatus = Lookup[
              Quiet @ Check[ClaudeRuntimeState[st[["RuntimeId"]]], <||>],
              "Status", None];
            If[rtStatus === "BudgetSuspended",
              Quiet @ Check[
                ClaudeResumeBudget[st[["RuntimeId"]]], Null]]]],
      "Cancel",
        If[StringQ[st[["RuntimeId"]]],
          Quiet @ Check[ClaudeRuntimeCancel[st[["RuntimeId"]]], Null]],
      _, Null
    ];

    iRtEmit[sid, "CommandAccepted",
      <|"CommandId" -> cid|>,
      iRtDefaultSnapshot[st[["StartSpec"]], 1]];

    If[cmdType === "Cancel",
      Module[{st3 = $iRtSessions[sid]},
        AssociateTo[st3, "Status" -> "Cancelled"];
        AssociateTo[$iRtSessions, sid -> st3]];
      iRtEmit[sid, "Cancelled",
        <|"CommandId" -> cid|>,
        iRtDefaultSnapshot[st[["StartSpec"]], 1]]];

    <|"Status" -> "Accepted", "CommandId" -> cid, "Reason" -> None|>
  ];

ClaudeRuntimeStopSession[sid_String, reason_String:"Stopped"] :=
  Module[{st = Lookup[$iRtSessions, sid, Missing["NoSession"]]},
    If[MissingQ[st], Return[<|"Status" -> "NoSuchSession"|>]];
    If[StringQ[st[["RuntimeId"]]],
      Quiet @ Check[ClaudeRuntimeCancel[st[["RuntimeId"]]], Null]];
    If[!TrueQ[Lookup[st[["Emitted"]], "Terminal", False]],
      Module[{st2 = $iRtSessions[sid]},
        AssociateTo[st2, {"Emitted" ->
            Append[st2[["Emitted"]], "Terminal" -> True],
          "Status" -> "Cancelled"}];
        AssociateTo[$iRtSessions, sid -> st2]];
      iRtEmit[sid, "Cancelled", <|"Reason" -> reason|>,
        iRtDefaultSnapshot[st[["StartSpec"]], 1]]];
    <|"Status" -> "Stopped", "SessionId" -> sid|>
  ];

ClaudeRuntimeSessionInfo[sid_String] :=
  Module[{st = Lookup[$iRtSessions, sid, Missing["NoSession"]]},
    If[MissingQ[st],
      Failure["NoSuchSession", <|"SessionId" -> sid|>],
      <|"SessionId" -> sid,
        "Mode" -> st[["Mode"]],
        "Status" -> st[["Status"]],
        "RuntimeId" -> st[["RuntimeId"]],
        "EventCount" -> Length[st[["Journal"]]],
        "LastEmittedSeq" -> st[["NextSeq"]] - 1,
        "AcceptedCommandIds" -> Keys[st[["AcceptedCommands"]]],
        (* IncG/IncI: reuse 観測用 *)
        "EpisodeCount" -> Lookup[st, "EpisodeCount", 0],
        "AccumulatedPrivacyLabel" ->
          Lookup[st, "AccumulatedPrivacyLabel", 0.],
        "BudgetUsedToolCalls" ->
          Lookup[Lookup[st, "BudgetUsed", <||>], "ToolCalls", 0],
        "Disposed" -> st[["Disposed"]]|>]
  ];

ClaudeRuntimeSessionResult[sid_String] :=
  Lookup[Lookup[$iRtSessions, sid, <||>], "Result", None];

(* ════════════════════════════════════════════════════════
   §8.1 backend protocol (ClaudeRuntimeInKernel)
   ════════════════════════════════════════════════════════ *)

iRtBackendStart[startSpec_Association] :=
  Module[{epi, att, scmd, startKey, sid, opened, started},
    epi  = Lookup[startSpec, "EpisodeId", None];
    att  = Lookup[startSpec, "Attempt", 1];
    scmd = Lookup[startSpec, "StartCommandId", "(no-start-command-id)"];
    If[!StringQ[epi],
      Return[<|"Status" -> "Failed", "Reason" -> "MissingEpisodeId"|>]];
    startKey = {epi, att, scmd};
    If[KeyExistsQ[$iRtSessionStarts, startKey],
      Module[{sid0 = $iRtSessionStarts[startKey], st0},
        st0 = Lookup[$iRtSessions, sid0, <||>];
        Return[<|"Status" -> "AlreadyStarted",
          "SessionId" -> sid0, "EpisodeId" -> epi,
          "HandleRef" -> sid0,
          "BackendInstanceId" -> Lookup[st0, "BackendInstanceId", None],
          "InitialEventCursor" ->
            <|"Attempt" -> att, "EventSeq" -> 0|>,
          "PIDRef" -> None|>]]];
    opened = ClaudeRuntimeOpenSession[startSpec];
    sid = opened[["SessionId"]];
    started = ClaudeRuntimeStartEpisode[sid];
    If[Lookup[started, "Status", None] === "Failed",
      Return[<|"Status" -> "Failed",
        "Reason" -> Lookup[started, "Reason", "StartFailed"]|>]];
    AssociateTo[$iRtSessionStarts, startKey -> sid];
    <|"Status" -> "Started",
      "SessionId" -> sid, "EpisodeId" -> epi,
      "HandleRef" -> sid,
      "BackendInstanceId" ->
        Lookup[Lookup[$iRtSessions, sid, <||>],
          "BackendInstanceId", None],
      "InitialEventCursor" -> <|"Attempt" -> att, "EventSeq" -> 0|>,
      "PIDRef" -> None|>
  ];

(* IncI: reuse を backend §8.1 契約経由で提供 (facade 機構への薄い橋)。
   priorHandleRef の物理 session を newStartSpec の次 episode 用に再利用し、
   StartEpisode まで行う。ineligible/不可なら Status を返し caller が fresh
   へ fallback する。 *)
iRtBackendReuse[priorHandleRef_, newStartSpec_Association] :=
  Module[{sid, reuse, epi, att, scmd, startKey, started, st},
    If[!StringQ[priorHandleRef],
      Return[<|"Status" -> "NoPriorHandle"|>]];
    sid = priorHandleRef;
    reuse = ClaudeRuntimeReuseSessionForEpisode[sid, newStartSpec];
    If[Lookup[reuse, "Status", None] =!= "Reused",
      Return[<|"Status" -> Lookup[reuse, "Status", "ReuseFailed"],
        "Reasons" -> Lookup[reuse, "Reasons", {}],
        "HandleRef" -> sid|>]];
    epi  = Lookup[newStartSpec, "EpisodeId", None];
    att  = Lookup[newStartSpec, "Attempt", 1];
    scmd = Lookup[newStartSpec, "StartCommandId", "(no-start-command-id)"];
    startKey = {epi, att, scmd};
    started = ClaudeRuntimeStartEpisode[sid];
    If[Lookup[started, "Status", None] === "Failed",
      Return[<|"Status" -> "Failed",
        "Reason" -> Lookup[started, "Reason", "StartFailed"],
        "HandleRef" -> sid|>]];
    AssociateTo[$iRtSessionStarts, startKey -> sid];
    st = Lookup[$iRtSessions, sid, <||>];
    <|"Status" -> "Started",
      "Reused" -> True,
      "SessionId" -> sid, "EpisodeId" -> epi,
      "HandleRef" -> sid,
      "EpisodeCount" -> Lookup[reuse, "EpisodeCount", None],
      "CarriedToolCalls" -> Lookup[reuse, "CarriedToolCalls", None],
      "AccumulatedPrivacyLabel" ->
        Lookup[reuse, "AccumulatedPrivacyLabel", None],
      "BackendInstanceId" -> Lookup[st, "BackendInstanceId", None],
      "InitialEventCursor" -> <|"Attempt" -> att, "EventSeq" -> 0|>,
      "PIDRef" -> None|>
  ];

iRtBackendRecover[rec_Association] :=
  Module[{h = Lookup[rec, "HandleRef", None], st},
    st = If[StringQ[h],
      Lookup[$iRtSessions, h, Missing["NoSession"]],
      Missing["NoSession"]];
    If[!MissingQ[st] && !TrueQ[st[["Disposed"]]],
      <|"Status" -> "Reattached", "HandleRef" -> h,
        "ResumedCheckpointRef" -> None|>,
      <|"Status" -> "LostUnrecoverable", "HandleRef" -> None,
        "ResumedCheckpointRef" -> None|>]
  ];

iRtBackendDispose[h_, cleanupPolicy_] :=
  Module[{st = Lookup[$iRtSessions, h, Missing["NoSession"]]},
    Which[
      MissingQ[st], <|"Status" -> "AlreadyDisposed"|>,
      TrueQ[st[["Disposed"]]], <|"Status" -> "AlreadyDisposed"|>,
      True,
        If[StringQ[st[["RuntimeId"]]],
          Quiet @ Check[ClaudeRuntimeCancel[st[["RuntimeId"]]], Null]];
        AssociateTo[st, "Disposed" -> True];
        AssociateTo[$iRtSessions, h -> st];
        <|"Status" -> "Disposed"|>]
  ];

(* ════════════════════════════════════════════════════════
   Inc4b: session tool gate (§12.4 の判定側)

   MVP の許可判定は startSpec Access["AllowedCapabilities"]
   (tool 名の明示 allowlist、空 = 全 tool 要承認の fail-closed)。
   NBAccess canonical EffectClass への接続は Inc7。
   非 session runtime (逆引きに無い) は Permit 素通し。
   ════════════════════════════════════════════════════════ *)

(* NBAccess の ToolCallId permit を消費できれば True (Inc7)。
   NBAccess 未ロードなら常に False (permit 機構なし = allowlist のみ) *)
iRtConsumeToolPermitIfAny[toolCallId_] :=
  StringQ[toolCallId] &&
  Names["NBAccess`NBConsumeToolCallPermit"] =!= {} &&
  TrueQ[Quiet @ Check[
    Symbol["NBAccess`NBConsumeToolCallPermit"][toolCallId], False]];

iRtSesToolGate[rid_, calls_List, ctx_] :=
  Module[{sid = Lookup[$iRtRuntimeToSession, rid, None], st, allowed,
          forbidden, grant, hard, maxTool, usedTC, n, maxCost, ucp},
    If[!StringQ[sid], Return[<|"Decision" -> "Permit"|>]];
    st = Lookup[$iRtSessions, sid, <||>];
    allowed = Lookup[
      Lookup[Lookup[st, "StartSpec", <||>], "Access", <||>],
      "AllowedCapabilities", {}];
    If[!ListQ[allowed], allowed = {}];
    (* Inc7: ToolCallId scoped permit を持つ call は allowlist 外でも
       通す (permit は one-shot、ここで消費する §13.2)。NBAccess 未ロード
       環境では permit 機構なし = allowlist のみ *)
    forbidden = Select[calls,
      Function[c,
        !MemberQ[allowed, Lookup[c, "Name", ""]] &&
        !iRtConsumeToolPermitIfAny[Lookup[c, "ToolCallId", None]]]];
    If[forbidden =!= {},
      Return[<|"Decision" -> "Suspend",
        "Reason" -> "CapabilityNotAllowed",
        "Forbidden" -> Map[Lookup[#, "Name", "?"] &, forbidden]|>]];

    (* ── Inc5 (§14.2): budget guard。次の billable action の直前に
       即時停止できることが Runtime local guard の要件 ── *)
    grant = Lookup[st, "BudgetGrant", <||>];
    hard  = Lookup[grant, "HardLimits", <||>];
    n     = Length[calls];

    (* unknown cost は 0 扱いしない (§25.3)。cash 上限があり
       UnknownCostPolicy = Reject なら、cost 見積の無い tool batch は
       fail-open せず suspend する *)
    maxCost = Lookup[hard, "MaxCostUSD", None];
    ucp = Lookup[grant, "UnknownCostPolicy", "Reject"];
    If[NumericQ[maxCost] && ucp === "Reject" &&
       !AllTrue[calls, NumericQ[Lookup[#, "CostEstimateUSD", None]] &],
      Return[<|"Decision" -> "SuspendBudget",
        "LimitKind" -> "UnknownCost",
        "MinimumAdditionalGrant" -> None|>]];

    (* MaxToolCalls: Used + NewReservation <= GrantedLimit (§14.2) *)
    maxTool = Lookup[hard, "MaxToolCalls", Infinity];
    usedTC = Lookup[Lookup[st, "BudgetUsed", <||>], "ToolCalls", 0];
    If[IntegerQ[maxTool] && usedTC + n > maxTool,
      Return[<|"Decision" -> "SuspendBudget",
        "LimitKind" -> "ToolCalls",
        "MinimumAdditionalGrant" -> usedTC + n|>]];

    (* 予約 = 即時計上 (保守的。実行失敗でも戻さない)。
       ReservationId 単位の記録が §15.4 reconcile の素地 *)
    AssociateTo[st, {
      "BudgetUsed" -> Append[Lookup[st, "BudgetUsed", <||>],
        "ToolCalls" -> usedTC + n],
      "Reservations" -> Append[Lookup[st, "Reservations", {}],
        <|"ReservationId" -> iRtNewId["resv"],
          "ToolCalls" -> n, "At" -> AbsoluteTime[]|>]}];
    AssociateTo[$iRtSessions, sid -> st];
    (* Inc6 (§15.3 手順 4): 実行前に Prepared を durable journal へ *)
    Quiet @ Check[iRtToolJournalPrepare[sid, calls], $Failed];
    <|"Decision" -> "Permit"|>
  ];

(* ════════════════════════════════════════════════════════
   Inc6: tool effect journal (§15.3) + checkpoint/resume (§7.5/§15)
   ════════════════════════════════════════════════════════ *)

iRtWXFImport[path_] :=
  If[StringQ[path] && FileExistsQ[path],
    Quiet @ Check[Import[path, "WXF"], $Failed],
    $Failed];

iRtAtomicExport[path_String, expr_] :=
  Module[{tmp},
    If[!DirectoryQ[DirectoryName[path]],
      Quiet @ CreateDirectory[DirectoryName[path],
        CreateIntermediateDirectories -> True]];
    tmp = path <> ".tmp-" <> ToString[$ProcessID];
    Export[tmp, expr, "WXF"];
    If[FileExistsQ[path], Quiet @ DeleteFile[path]];
    RenameFile[tmp, path];
    path
  ];

iRtToolJournalPath[sid_String] :=
  FileNameJoin[{iRtJournalRoot[], sid, "tool-journal.wxf"}];

iRtToolJournalPrepare[sid_String, calls_List] :=
  Module[{j = iRtWXFImport[iRtToolJournalPath[sid]]},
    If[!ListQ[j], j = {}];
    j = Join[j, Map[
      <|"ToolCallId" -> Lookup[#, "ToolCallId", "?"],
        "Name" -> Lookup[#, "Name", "?"],
        "Id" -> Lookup[#, "Id", ""],
        "Phase" -> "Prepared",
        "PreparedAt" -> AbsoluteTime[],
        "CommittedAt" -> None,
        "ResultRef" -> None,
        "LastError" -> None|> &, calls]];
    iRtAtomicExport[iRtToolJournalPath[sid], j]
  ];

(* 結果 hook (engine seam から)。成功 → Committed (ResultRef は ref のみ
   I4)、失敗/不確定 → Prepared のまま LastError を記録し、自動 resume を
   塞ぐ (I9: effect 実行有無が不明な non-idempotent tool の保守側)。 *)
iRtToolJournalOnResults[rid_, calls_List, results_List] :=
  Module[{sid = Lookup[$iRtRuntimeToSession, rid, None], j, k},
    If[!StringQ[sid], Return[Null]];
    j = iRtWXFImport[iRtToolJournalPath[sid]];
    If[!ListQ[j] || j === {}, Return[Null]];
    Scan[
      Function[res,
        Module[{tid = Lookup[res, "ToolId", ""]},
          k = None;
          Do[
            If[Lookup[j[[i]], "Phase", ""] === "Prepared" &&
               Lookup[j[[i]], "Id", ""] === tid,
              k = i; Break[]],
            {i, Length[j], 1, -1}];
          If[IntegerQ[k],
            If[TrueQ[Lookup[res, "Success", False]],
              j[[k]] = Append[j[[k]], {
                "Phase" -> "Committed",
                "CommittedAt" -> AbsoluteTime[],
                "ResultRef" -> "rtses://" <> sid <> "/tool/" <>
                  ToString[Lookup[j[[k]], "ToolCallId", "?"]]}],
              j[[k]] = Append[j[[k]],
                "LastError" ->
                  ToString[Lookup[res, "Error", "ToolFailed"]]]]]]],
      results];
    Quiet @ Check[iRtAtomicExport[iRtToolJournalPath[sid], j], $Failed]
  ];

ClaudeRuntimeSessionToolJournal[sid_String] :=
  Module[{j = iRtWXFImport[iRtToolJournalPath[sid]]},
    If[ListQ[j], j, {}]];

(* ── checkpoint (§7.5/§15.1) ── *)

Options[ClaudeRuntimeSessionCheckpoint] = {"Kind" -> "Boundary"};

ClaudeRuntimeSessionCheckpoint[sid_String, opts:OptionsPattern[]] :=
  Module[{st, ss, worker, grant, turns, used, snap, ckDir, n, m0, m,
          path, kind},
    st = Lookup[$iRtSessions, sid, Missing["NoSession"]];
    If[MissingQ[st],
      Return[Failure["NoSuchSession", <|"SessionId" -> sid|>]]];
    kind = OptionValue["Kind"];
    ss = st[["StartSpec"]];
    worker = Lookup[ss, "Worker", <||>];
    grant = Lookup[st, "BudgetGrant", <||>];
    turns = If[StringQ[st[["RuntimeId"]]],
      Lookup[Quiet @ Check[ClaudeRuntimeState[st[["RuntimeId"]]], <||>],
        "TurnCount", 0], 0];
    used = Lookup[Lookup[st, "BudgetUsed", <||>], "ToolCalls", 0];
    snap = <|"Turns" -> turns, "Calls" -> turns, "ToolCalls" -> used,
      "InputTokens" -> 0, "OutputTokens" -> 0,
      "WallClockSeconds" -> 0., "IdleSeconds" -> 0.,
      "BytesWritten" -> 0, "NetworkRequests" -> 0,
      "ActualUSD" -> None, "ReservedUSD" -> None,
      "CostSource" -> "Unknown",
      "BudgetGrantId" -> Lookup[grant, "BudgetGrantId", "grant-unknown"],
      "BudgetGrantVersion" -> Lookup[grant, "Version", 1]|>;
    ckDir = FileNameJoin[{iRtJournalRoot[], sid, "checkpoints"}];
    n = Length[FileNames["ckpt-*.wxf", ckDir]] + 1;
    m0 = <|
      "SchemaVersion" -> 1,
      "SessionId" -> Lookup[ss, "SessionId", sid],
      "EpisodeId" -> Lookup[ss, "EpisodeId", "epi-unknown"],
      "Attempt" -> Lookup[ss, "Attempt", 1],
      "CheckpointId" -> "ckpt-" <> IntegerString[n, 10, 4],
      "CreatedAt" -> DateObject[],
      "RuntimeProfile" -> Lookup[worker, "RuntimeProfile", "unknown"],
      "AdapterFactory" -> Lookup[worker, "AdapterFactory", "unknown"],
      "ConversationStateRef" -> None,
      "ConversationSummaryRef" -> None,
      "ToolJournalRef" -> iRtToolJournalPath[sid],
      "EnvironmentSnapshotRef" -> None,
      "ArtifactStagingManifestRef" -> None,
      "BudgetSnapshot" -> snap,
      "LastEventSeq" -> st[["NextSeq"]] - 1,
      "PendingCommandIds" -> {},
      "AccessSpecHash" ->
        Lookup[Lookup[ss, "Access", <||>], "AccessSpecHash", ""],
      "PolicySnapshotHash" ->
        Lookup[Lookup[ss, "Access", <||>], "PolicySnapshotHash", ""],
      "BudgetGrantId" -> Lookup[grant, "BudgetGrantId", "grant-unknown"],
      "BudgetGrantVersion" -> Lookup[grant, "Version", 1],
      "PrivacyLabel" ->
        Lookup[Lookup[ss, "Access", <||>], "PrivacyLabel", 1.0]|>;
    m = Append[m0, "ContentHash" -> iRtCanonicalHash[m0]];
    path = FileNameJoin[{ckDir,
      Lookup[m, "CheckpointId", "ckpt"] <> ".wxf"}];
    iRtAtomicExport[path, m];
    (* Routine は control event を出さない (granularity §9.6)。
       Boundary だけ CheckpointCreated を emit する (§7.5) *)
    If[kind === "Boundary",
      iRtEmit[sid, "CheckpointCreated",
        <|"CheckpointRef" -> path, "Kind" -> kind|>,
        snap,
        <|"LatestCheckpointRef" -> path|>]];
    <|"Status" -> If[kind === "Boundary",
        "CheckpointCreated", "RoutineCheckpointed"],
      "CheckpointRef" -> path,
      "Manifest" -> m|>
  ];

(* ── resume decision / resume (§15.2/§15.3) ── *)

ClaudeRuntimeSessionResumeDecision[checkpointRef_String] :=
  Module[{m = iRtWXFImport[checkpointRef], j, prepared},
    If[!AssociationQ[m],
      Return[<|"Decision" -> "Invalid",
        "Reason" -> "UnreadableManifest"|>]];
    If[iRtCanonicalHash[KeyDrop[m, "ContentHash"]] =!=
         Lookup[m, "ContentHash", ""],
      Return[<|"Decision" -> "Invalid",
        "Reason" -> "ContentHashMismatch"|>]];
    j = iRtWXFImport[Lookup[m, "ToolJournalRef", ""]];
    If[!ListQ[j], j = {}];
    prepared = Select[j, Lookup[#, "Phase", ""] === "Prepared" &];
    If[prepared === {},
      <|"Decision" -> "ResumeAllowed",
        "CheckpointRef" -> checkpointRef|>,
      <|"Decision" -> "NeedsRestartApproval",
        "PreparedToolCallIds" ->
          Map[Lookup[#, "ToolCallId", "?"] &, prepared]|>]
  ];

Options[ClaudeRuntimeResumeSession] = {"ApproveRestart" -> False};

ClaudeRuntimeResumeSession[checkpointRef_String,
    startSpec_Association, opts:OptionsPattern[]] :=
  Module[{m, dec, ssAccess, opened, sid2, st2, carried},
    m = iRtWXFImport[checkpointRef];
    If[!AssociationQ[m],
      Return[Failure["UnreadableManifest",
        <|"Ref" -> checkpointRef|>]]];
    If[iRtCanonicalHash[KeyDrop[m, "ContentHash"]] =!=
         Lookup[m, "ContentHash", ""],
      Return[Failure["ContentHashMismatch", <||>]]];
    If[Lookup[startSpec, "Attempt", 0] =!= Lookup[m, "Attempt", 0] + 1,
      Return[Failure["AttemptMismatch",
        <|"Expected" -> Lookup[m, "Attempt", 0] + 1,
          "Got" -> Lookup[startSpec, "Attempt", 0]|>]]];
    ssAccess = Lookup[startSpec, "Access", <||>];
    If[Lookup[ssAccess, "AccessSpecHash", ""] =!=
         Lookup[m, "AccessSpecHash", ""] ||
       Lookup[ssAccess, "PolicySnapshotHash", ""] =!=
         Lookup[m, "PolicySnapshotHash", ""],
      Return[Failure["PolicyHashMismatch", <||>]]];
    dec = ClaudeRuntimeSessionResumeDecision[checkpointRef];
    If[Lookup[dec, "Decision", ""] === "NeedsRestartApproval" &&
       !TrueQ[OptionValue["ApproveRestart"]],
      Return[dec]];
    opened = ClaudeRuntimeOpenSession[startSpec];
    sid2 = opened[["SessionId"]];
    (* budget counter は後退させない (§15.1/Inc6 受け入れ) *)
    carried = Lookup[Lookup[m, "BudgetSnapshot", <||>], "ToolCalls", 0];
    st2 = $iRtSessions[sid2];
    AssociateTo[st2, {
      "BudgetUsed" -> Append[Lookup[st2, "BudgetUsed", <||>],
        "ToolCalls" -> Max[carried,
          Lookup[Lookup[st2, "BudgetUsed", <||>], "ToolCalls", 0]]],
      "ResumedFrom" -> checkpointRef,
      "InheritedToolJournalRef" -> Lookup[m, "ToolJournalRef", None]}];
    AssociateTo[$iRtSessions, sid2 -> st2];
    <|"Status" -> "Resumed", "SessionId" -> sid2,
      "CarriedToolCalls" -> carried,
      "Attempt" -> Lookup[startSpec, "Attempt", 0]|>
  ];

(* ── IncE: Inc10 前提 session reuse 安全ガード (§14.5/§16.4/§26.3) ── *)

ClaudeSessionRaiseAccumulatedPrivacy[sid_String, label_?NumericQ] :=
  Module[{st = Lookup[$iRtSessions, sid, Missing["NoSession"]], cur, nxt},
    If[MissingQ[st], Return[Missing["NoSession"]]];
    cur = N @ Lookup[st, "AccumulatedPrivacyLabel", 0.];
    nxt = Max[cur, N[label]];   (* 単調: 下げない *)
    AssociateTo[st, "AccumulatedPrivacyLabel" -> nxt];
    AssociateTo[$iRtSessions, sid -> st];
    nxt
  ];

ClaudeSessionReuseEligibleQ[sid_String, newStartSpec_Association] :=
  Module[{st = Lookup[$iRtSessions, sid, Missing["NoSession"]],
          ss, oldAcc, newAcc, reasons = {}, prepared, accLabel, newLabel,
          usedToolCalls, eligible},
    If[MissingQ[st],
      Return[<|"Eligible" -> False, "Reasons" -> {"NoSession"},
        "CarryForward" -> <||>|>]];
    If[TrueQ[Lookup[st, "Disposed", False]] ||
       MemberQ[{"Failed"}, Lookup[st, "Status", ""]],
      Return[<|"Eligible" -> False,
        "Reasons" -> {"SessionNotAlive:" <> ToString[Lookup[st, "Status", ""]]},
        "CarryForward" -> <||>|>]];
    ss = Lookup[st, "StartSpec", <||>];
    oldAcc = Lookup[ss, "Access", <||>];
    newAcc = Lookup[newStartSpec, "Access", <||>];
    accLabel = N @ Lookup[st, "AccumulatedPrivacyLabel", 0.];
    newLabel = N @ Lookup[newAcc, "PrivacyLabel", 0.];
    usedToolCalls = Lookup[Lookup[st, "BudgetUsed", <||>], "ToolCalls", 0];

    (* (1) ReusePolicy が明示的に SameWorkflowSameTrust か *)
    If[Lookup[ss, "ReusePolicy", "Never"] =!= "SameWorkflowSameTrust",
      AppendTo[reasons, "ReusePolicyNotReusable"]];
    (* (2) 同一 workflow か *)
    If[Lookup[ss, "WorkflowId", "?a"] =!= Lookup[newStartSpec, "WorkflowId", "?b"],
      AppendTo[reasons, "DifferentWorkflow"]];
    (* (3) 同一 trust domain か: access spec / policy snapshot の両 hash 一致
       (§16.4 異なる trust domain 間では reuse しない) *)
    If[Lookup[oldAcc, "AccessSpecHash", "?a"] =!=
         Lookup[newAcc, "AccessSpecHash", "?b"],
      AppendTo[reasons, "DifferentAccessSpec"]];
    If[Lookup[oldAcc, "PolicySnapshotHash", "?a"] =!=
         Lookup[newAcc, "PolicySnapshotHash", "?b"],
      AppendTo[reasons, "DifferentPolicySnapshot"]];
    (* (4) 非冪等かもしれない Prepared effect が残っていない (I9) *)
    prepared = Select[
      Quiet @ Check[ClaudeRuntimeSessionToolJournal[sid], {}],
      Lookup[#, "Phase", ""] === "Prepared" &];
    If[prepared =!= {},
      AppendTo[reasons, "PendingPreparedEffect"]];

    eligible = (reasons === {});
    <|"Eligible" -> eligible,
      "Reasons" -> reasons,
      (* carry forward は eligible でなくても「もし再利用したら何が持ち越されるか」
         を示す。budget counter も privacy label も reset せず単調に持ち越す *)
      "CarryForward" -> <|
        (* privacy label は max。新 episode は累積 taint を継承 (下げない) *)
        "AccumulatedPrivacyLabel" -> Max[accLabel, newLabel],
        (* budget 使用量は据え置き (0 に戻さない) *)
        "BudgetUsedToolCalls" -> usedToolCalls,
        "SessionId" -> sid,
        "FromWorkflowId" -> Lookup[ss, "WorkflowId", None]|>|>
  ];

(* Inc10 本体: reuse の機構 (判断は Petri ReusePolicy=Orchestrator の領分) *)
ClaudeRuntimeReuseSessionForEpisode[sid_String,
    newStartSpec_Association] :=
  Module[{st = Lookup[$iRtSessions, sid, Missing["NoSession"]],
          elig, cf, newSpec, newEpi, newAtt, epc},
    If[MissingQ[st],
      Return[<|"Status" -> "NoSession", "SessionId" -> sid|>]];
    If[TrueQ[Lookup[st, "Disposed", False]],
      Return[<|"Status" -> "Disposed", "SessionId" -> sid|>]];
    (* 現 episode が終端 (Completed) か、まだ走っていない (Open) 場合のみ
       再利用可。Running/CommandPending 等の実行中は不可 *)
    If[!MemberQ[{"Completed", "Open"}, Lookup[st, "Status", ""]],
      Return[<|"Status" -> "NotReusableYet",
        "SessionId" -> sid,
        "SessionStatus" -> Lookup[st, "Status", ""]|>]];
    (* eligibility gate (ReusePolicy/workflow/trust domain/Prepared) *)
    elig = ClaudeSessionReuseEligibleQ[sid, newStartSpec];
    If[!TrueQ[Lookup[elig, "Eligible", False]],
      Return[<|"Status" -> "Ineligible", "SessionId" -> sid,
        "Reasons" -> Lookup[elig, "Reasons", {}]|>]];
    cf = Lookup[elig, "CarryForward", <||>];
    newEpi = Lookup[newStartSpec, "EpisodeId", iRtNewId["epi"]];
    newAtt = Lookup[newStartSpec, "Attempt", 1];
    epc = Lookup[st, "EpisodeCount", 0] + 1;
    (* 物理 session id は維持したまま次 episode の spec を載せる *)
    newSpec = Append[newStartSpec, "SessionId" -> sid];
    AssociateTo[st, {
      "StartSpec" -> newSpec,
      "BackendInstanceId" -> iRtNewId["rtbki"],   (* 新 episode instance *)
      (* per-episode 状態は reset *)
      "Mode" -> None, "RuntimeId" -> None,
      "Journal" -> {}, "NextSeq" -> 1,
      "AcceptedCommands" -> <||>, "Result" -> None, "Emitted" -> <||>,
      "Reservations" -> {},
      "BudgetGrant" -> Lookup[newStartSpec, "BudgetGrant",
        Lookup[st, "BudgetGrant", <||>]],
      (* ── carry-forward (Inc10 受け入れ: 累積は reset しない) ── *)
      "BudgetUsed" -> <|"ToolCalls" ->
        Lookup[cf, "BudgetUsedToolCalls", 0]|>,
      "AccumulatedPrivacyLabel" ->
        Lookup[cf, "AccumulatedPrivacyLabel",
          Lookup[st, "AccumulatedPrivacyLabel", 0.]],
      "EpisodeCount" -> epc,
      "Status" -> "Open", "Disposed" -> False}];
    AssociateTo[$iRtSessions, sid -> st];
    <|"Status" -> "Reused", "SessionId" -> sid,
      "EpisodeId" -> newEpi, "Attempt" -> newAtt,
      "CarriedToolCalls" -> Lookup[cf, "BudgetUsedToolCalls", 0],
      "AccumulatedPrivacyLabel" ->
        Lookup[cf, "AccumulatedPrivacyLabel", 0.],
      "EpisodeCount" -> epc|>
  ];

(* seam 注入 (§12.4/§15.3)。ClaudeRuntime` は本 module に依存しない *)
ClaudeRuntime`$ClaudeRuntimeToolGate =
  Function[{rid, calls, ctx}, iRtSesToolGate[rid, calls, ctx]];
ClaudeRuntime`$ClaudeRuntimeToolResultHook =
  Function[{rid, calls, results},
    iRtToolJournalOnResults[rid, calls, results]];

ClaudeRuntimeSessionBackendSpec[] := <|
  "ProtocolVersion" -> 1,
  "Capabilities" -> {"ToolLoop", "EventReplay", "Interrupt",
    "SessionReuse"},
  "StartEpisode" -> Function[startSpec, iRtBackendStart[startSpec]],
  (* IncI: reuse (SameWorkflowSameTrust) を契約経由で提供 (§14.5/§16.4) *)
  "ReuseEpisode" ->
    Function[{priorHandle, newStartSpec},
      iRtBackendReuse[priorHandle, newStartSpec]],
  "PollEvents" ->
    Function[{h, cursor}, ClaudeRuntimeSessionPoll[h, cursor]],
  "SendCommand" ->
    Function[{h, cmd}, ClaudeRuntimeSessionCommand[h, cmd]],
  "Inspect" -> Function[h, ClaudeRuntimeSessionInfo[h]],
  "Recover" -> Function[rec, iRtBackendRecover[rec]],
  "Dispose" -> Function[{h, pol}, iRtBackendDispose[h, pol]]
|>;

End[];  (* `Private` *)

EndPackage[];

Print[Style["ClaudeRuntime_session.wl (Inc4a) がロードされました。", Bold]];
Print["
  ClaudeRegisterRuntimeAdapterFactory[name, fn] → adapter factory 登録
  ClaudeRuntimeOpenSession / StartEpisode / SessionPoll / SessionCommand
  ClaudeRuntimeStopSession / SessionInfo / SessionResult
  ClaudeRuntimeSessionBackendSpec[]  → §8.1 in-kernel backend (要 wiring)
  ClaudeRuntimeSessionReset[]
"];
