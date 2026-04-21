(* ClaudeRuntime.wl -- Expression-Proposal Loop State Machine
   
   責務: turn loop / proposal loop / provider とのやり取り /
         validation・execution の進行管理 / continuation /
         usage・event の構造化 / session state の論理モデル

   不変条件:
   - Notebook, secret, access policy, label algebra を知らない
   - 知るのは abstract adapter interface だけ
   - 安全判定は adapter 経由で NBAccess が行う
   - 実行形式は claudecode の LLMGraph DAG で展開する
     (iLLMGraphNode / LLMGraphDAGCreate / 共有スケジューラ)
   
   Load: Block[{$CharacterEncoding = "UTF-8"}, Get["ClaudeRuntime.wl"]]
*)

BeginPackage["ClaudeRuntime`"];

(* ════════════════════════════════════════════════════════
   Public symbols
   ════════════════════════════════════════════════════════ *)

$ClaudeRuntimeVersion::usage =
  If[$Language === "Japanese",
    "$ClaudeRuntimeVersion はパッケージバージョン。",
    "$ClaudeRuntimeVersion is the package version."];

CreateClaudeRuntime::usage =
  If[$Language === "Japanese",
  "CreateClaudeRuntime[adapter, opts] は RuntimeState を生成し runtimeId を返す。\n",
  "CreateClaudeRuntime[adapter, opts] creates a RuntimeState and returns runtimeId.\n"] <>
  "adapter は <|\"BuildContext\" -> fn, \"QueryProvider\" -> fn,\n" <>
  "  \"ValidateProposal\" -> fn, \"ExecuteProposal\" -> fn,\n" <>
  "  \"RedactResult\" -> fn, \"ShouldContinue\" -> fn|> の形式。";

ClaudeRunTurn::usage =
  If[$Language === "Japanese",
  "ClaudeRunTurn[runtimeId, input] は expression-proposal loop を\n",
  "ClaudeRunTurn[runtimeId, input] launches an expression-proposal loop as\n"] <>
  "LLMGraph DAG として起動し、jobId を返す。";

ClaudeContinueTurn::usage =
  If[$Language === "Japanese",
  "ClaudeContinueTurn[runtimeId] は前回の turn の continuation を起動する。",
  "ClaudeContinueTurn[runtimeId] launches a continuation of the previous turn."];

ClaudeRuntimeState::usage =
  If[$Language === "Japanese",
  "ClaudeRuntimeState[runtimeId] は RuntimeState の軽量表示版を返す。\n" <>
  "FrontEnd のフォーマット負荷を軽減するため、NotebookObject や\n" <>
  "巨大な中間結果 (ConversationState, LastProviderResponse 等) を除外。\n" <>
  "完全な RuntimeState が必要な場合は ClaudeRuntimeStateFull を使う。",
  "ClaudeRuntimeState[runtimeId] returns a lightweight view of RuntimeState.\n" <>
  "NotebookObject and large intermediates are excluded to reduce FE format load.\n" <>
  "Use ClaudeRuntimeStateFull for the complete RuntimeState."];

ClaudeRuntimeStateFull::usage =
  If[$Language === "Japanese",
  "ClaudeRuntimeStateFull[runtimeId] は RuntimeState 全体 (Adapter 以外) を返す。\n" <>
  "Dynamic や直接評価での使用は避けること (FrontEnd がブロックする可能性)。",
  "ClaudeRuntimeStateFull[runtimeId] returns the complete RuntimeState (except Adapter).\n" <>
  "Avoid using in Dynamic or direct evaluation (may block FrontEnd)."];

ClaudeTurnTrace::usage =
  If[$Language === "Japanese",
  "ClaudeTurnTrace[runtimeId] は EventTrace 全体を返す。",
  "ClaudeTurnTrace[runtimeId] returns the full EventTrace."];

ClaudeApproveProposal::usage =
  If[$Language === "Japanese",
  "ClaudeApproveProposal[runtimeId] は AwaitingApproval 状態の proposal を承認する。",
  "ClaudeApproveProposal[runtimeId] approves a proposal in AwaitingApproval state."];

ClaudeDenyProposal::usage =
  If[$Language === "Japanese",
  "ClaudeDenyProposal[runtimeId] は AwaitingApproval 状態の proposal を拒否する。",
  "ClaudeDenyProposal[runtimeId] denies a proposal in AwaitingApproval state."];

ClaudeRuntimeCancel::usage =
  If[$Language === "Japanese",
  "ClaudeRuntimeCancel[runtimeId] は DAG ジョブをキャンセルする。",
  "ClaudeRuntimeCancel[runtimeId] cancels the DAG job."];

$ClaudeRuntimeRetryProfile::usage =
  If[$Language === "Japanese",
    "$ClaudeRuntimeRetryProfile は RetryPolicy の既定プロファイル。",
    "$ClaudeRuntimeRetryProfile is the default RetryPolicy profile."];

ClaudeRetryPolicy::usage =
  If[$Language === "Japanese",
    "ClaudeRetryPolicy[profile] は指定プロファイルの RetryPolicy を返す。\n" <>
    "profile: \"Eval\" | \"UpdatePackage\"",
    "ClaudeRetryPolicy[profile] returns the RetryPolicy for the given profile.\n" <>
    "profile: \"Eval\" | \"UpdatePackage\""];

ClaudeClassifyFailure::usage =
  If[$Language === "Japanese",
    "ClaudeClassifyFailure[failure] は failure class を返す。",
    "ClaudeClassifyFailure[failure] returns the failure classification."];

ClaudeGetConversationMessages::usage =
  If[$Language === "Japanese",
    "ClaudeGetConversationMessages[runtimeId] は全ターンの Messages を返す。\n" <>
    "各ターンは <|\"Turn\"->n, \"ProposedCode\"->..., \"ExecutionResult\"->..., " <>
    "\"TextResponse\"->...|> の形式。",
    "ClaudeGetConversationMessages[runtimeId] returns Messages from all turns.\n" <>
    "Each turn: <|\"Turn\"->n, \"ProposedCode\"->..., \"ExecutionResult\"->..., " <>
    "\"TextResponse\"->...|>"];

ClaudeRuntimeRetry::usage =
  If[$Language === "Japanese",
    "ClaudeRuntimeRetry[runtimeId] は直前ターンの Failed ノードを再実行する。\n" <>
    "Done ノードの結果は保持し、Failed/Pending ノードのみ新しい DAG で再起動する。\n" <>
    "アクティブ DAG が残っている場合は LLMGraphDAGRetry に委譲する。\n" <>
    "例: ClaudeRuntimeRetry[$ClaudeLastRuntimeId]",
    "ClaudeRuntimeRetry[runtimeId] retries failed nodes from the last turn.\n" <>
    "Results from Done nodes are preserved; only Failed/Pending nodes are re-run.\n" <>
    "If an active DAG job still exists, delegates to LLMGraphDAGRetry.\n" <>
    "Example: ClaudeRuntimeRetry[$ClaudeLastRuntimeId]"];

(* Phase 31 (ClaudeRunTurnDecomposed / ClaudeEvalDecomposed) は撤去済み。
   タスク分解・マルチエージェント機構は ClaudeOrchestrator.wl (別パッケージ) が担う。
   Phase 31 handoff: Phase31_next_session_handoff_v1.md 参照。 *)

Begin["`Private`"];

(* ── iL: $Language に基づく日英切替 ── *)
iL[ja_String, en_String] := If[$Language === "Japanese", ja, en];

(* ────────────────────────────────────────────────────────
   依存: claudecode.wl の LLMGraph インフラ
   以下のシンボルを ClaudeCode` コンテキストから使用する:
     ClaudeCode`iLLMGraphNode
     ClaudeCode`LLMGraphDAGCreate
     ClaudeCode`LLMGraphDAGCancel
   本番では claudecode.wl を先にロードすること。
   テスト時はスタブで代替可能。
   ──────────────────────────────────────────────────────── *)

(* ════════════════════════════════════════════════════════
   1. RetryPolicy
   ════════════════════════════════════════════════════════ *)

$defaultEvalLimits = <|
  "MaxTotalSteps"          -> 8,
  "MaxProposalIterations"  -> 4,
  "MaxTransportRetries"    -> 2,
  "MaxFormatRetries"       -> 2,
  "MaxValidationRepairs"   -> 3,
  "MaxExecutionRetries"    -> 1,
  "MaxToolIterations"      -> 6,
  "MaxReloadRepairs"       -> 0,
  "MaxTestRepairs"         -> 0,
  "MaxPatchApplyRetries"   -> 0,
  "MaxFullReplans"         -> 0
|>;

$defaultUpdateLimits = <|
  "MaxTotalSteps"          -> 20,
  "MaxProposalIterations"  -> 5,
  "MaxTransportRetries"    -> 3,
  "MaxFormatRetries"       -> 3,
  "MaxValidationRepairs"   -> 2,
  "MaxExecutionRetries"    -> 1,
  "MaxToolIterations"      -> 10,
  "MaxReloadRepairs"       -> 3,
  "MaxTestRepairs"         -> 3,
  "MaxPatchApplyRetries"   -> 2,
  "MaxFullReplans"         -> 1
|>;

ClaudeRetryPolicy["Eval"] := <|
  "Profile" -> "Eval",
  "Limits"  -> $defaultEvalLimits
|>;

ClaudeRetryPolicy["UpdatePackage"] := <|
  "Profile" -> "UpdatePackage",
  "Limits"  -> $defaultUpdateLimits
|>;

(* Planner プロファイル: ClaudeOrchestrator.wl 側で planner adapter を構築する際に
   流用できるよう最小限の軽量プロファイルを残す。Phase 31 の
   ClaudeRunTurnDecomposed は撤去済みだが、プロファイル定義自体は
   単に軽量な 1 shot 問い合わせ向けの便利セットなので保持する。 *)
$defaultPlannerLimits = <|
  "MaxTotalSteps"          -> 2,
  "MaxProposalIterations"  -> 1,
  "MaxTransportRetries"    -> 2,
  "MaxFormatRetries"       -> 2,
  "MaxValidationRepairs"   -> 0,
  "MaxExecutionRetries"    -> 0,
  "MaxToolIterations"      -> 0,
  "MaxReloadRepairs"       -> 0,
  "MaxTestRepairs"         -> 0,
  "MaxPatchApplyRetries"   -> 0,
  "MaxFullReplans"         -> 0
|>;

ClaudeRetryPolicy["Planner"] := <|
  "Profile" -> "Planner",
  "Limits"  -> $defaultPlannerLimits
|>;

If[!StringQ[$ClaudeRuntimeRetryProfile],
  $ClaudeRuntimeRetryProfile = "Eval"];

(* ════════════════════════════════════════════════════════
   2. Failure classification
   ════════════════════════════════════════════════════════ *)

$retryableClasses = {
  "TransportTransient", "ProviderRateLimit", "ProviderTimeout",
  "ModelFormatError", "ValidationRepairable",
  "PatchApplyConflict", "ReloadError", "TestFailure",
  "ExecutionTransient"
};

$fatalClasses = {
  "SecurityViolation", "ConfidentialLeakRisk",
  "ActsForInsufficient", "ForbiddenHead", "ExplicitDeny",
  "PolicyFlowViolation", "ReleasePolicyMissing"
};

ClaudeClassifyFailure[failure_Association] :=
  Module[{reasonClass},
    reasonClass = Lookup[failure, "ReasonClass",
      Lookup[failure, "class", "UnknownFailure"]];
    <|"Class" -> reasonClass,
      "Retryable" -> MemberQ[$retryableClasses, reasonClass],
      "Fatal" -> MemberQ[$fatalClasses, reasonClass]|>
  ];

ClaudeClassifyFailure[msg_String] :=
  Which[
    (* v2026-04-20 T07: stream-json \:5185\:306e rate-limit \:30a8\:30e9\:30fc\:306f Fatal \:306b\:6607\:683c\:3002
       \:5f93\:6765\:306f\:30b7\:30f3\:30d7\:30eb\:306a "rate" / "429" \:30de\:30c3\:30c1\:3067 Retryable \:6271\:3044\:3060\:3063\:305f\:304c\:3001
       stream-json \:5185\:306b api_error_status:429 \:3084 "hit your limit" \:304c\:3042\:308b\:5834\:5408\:306f
       \:30ea\:30c8\:30e9\:30a4\:3057\:3066\:3082\:5fa9\:65e7\:3057\:306a\:3044\:306e\:3067\:5373 Fatal \:306b\:3059\:308b\:3002 *)
    (StringContainsQ[msg, "\"api_error_status\":429"] ||
     StringContainsQ[msg, "\"error\":\"rate_limit\""] ||
     StringContainsQ[msg, "hit your limit"]),
      <|"Class" -> "RateLimitExceeded", "Retryable" -> False, "Fatal" -> True|>,
    StringContainsQ[msg, "timeout" | "Timeout" | "ETIMEDOUT"],
      <|"Class" -> "TransportTransient", "Retryable" -> True, "Fatal" -> False|>,
    StringContainsQ[msg, "rate" | "Rate" | "429"],
      <|"Class" -> "ProviderRateLimit", "Retryable" -> True, "Fatal" -> False|>,
    StringContainsQ[msg, "format" | "parse" | "JSON"],
      <|"Class" -> "ModelFormatError", "Retryable" -> True, "Fatal" -> False|>,
    StringContainsQ[msg, "forbidden" | "Forbidden" | "denied" | "Denied"],
      <|"Class" -> "ForbiddenHead", "Retryable" -> False, "Fatal" -> True|>,
    StringContainsQ[msg, "confidential" | "leak"],
      <|"Class" -> "ConfidentialLeakRisk", "Retryable" -> False, "Fatal" -> True|>,
    True,
      <|"Class" -> "UnknownFailure", "Retryable" -> False, "Fatal" -> False|>
  ];

(* ════════════════════════════════════════════════════════
   2b. Core context overwrite detection
   
   LLM が生成したコードがコアパッケージの関数を上書き
   しようとした場合に NeedsApproval に昇格させる。
   テスト中のスタブ上書きなど、意図しない状態汚染を防止。
   ════════════════════════════════════════════════════════ *)

$iProtectedContexts = {
  "NBAccess`", "ClaudeCode`",
  "ClaudeRuntime`", "ClaudeTestKit`"
};

(* コアコンテキストの関数上書きを検出する。
   検出パターン:
   1. Context`sym = ...         (OwnValues 代入)
   2. Context`sym := ...        (OwnValues 遅延代入)
   3. Context`sym[...] := ...   (DownValues 定義)
   4. DownValues[Context`sym] = ...
   5. Unprotect[Context`sym] / ClearAll / Remove
   注: Context`sym[args] の呼び出しは検出しない（代入と区別）。
   注: Context`Private`sym のようなネストコンテキストにも対応。 *)
iDetectsContextOverwrite[code_String] :=
  Module[{ctxAlt},
    ctxAlt = StringRiffle[
      StringReplace[#, "`" -> "\\`"] & /@ $iProtectedContexts, "|"];
    (* Pattern 1: 代入・定義 (呼び出しは除外) *)
    StringContainsQ[code,
      RegularExpression[
        "(?:" <> ctxAlt <>
        ")(?:[A-Za-z]+\\`)*[A-Za-z$][A-Za-z0-9$]*" <>
        "(?:\\s*=(?!=)|\\s*:=|\\[[^\\]]*\\]\\s*(?::=|=(?!=)))"]] ||
    (* Pattern 2: DownValues / UpValues 等の直接操作 *)
    StringContainsQ[code,
      RegularExpression[
        "(?:DownValues|UpValues|OwnValues|SubValues)" <>
        "\\s*\\[\\s*(?:" <> ctxAlt <> ")"]] ||
    (* Pattern 3: Unprotect / ClearAll / Remove *)
    StringContainsQ[code,
      RegularExpression[
        "(?:Unprotect|ClearAll|Remove)\\s*\\[\\s*(?:" <> ctxAlt <> ")"]]
  ];

iDetectsContextOverwrite[_] := False;

(* ════════════════════════════════════════════════════════
   3. RuntimeState 管理
   ════════════════════════════════════════════════════════ *)

If[!AssociationQ[$iClaudeRuntimes], $iClaudeRuntimes = <||>];

iMakeRuntimeId[] :=
  "rt-" <> ToString[UnixTime[]] <> "-" <> ToString[RandomInteger[99999]];

iMakeRuntimeState[adapter_Association, profile_String] := <|
  "RuntimeId"            -> None,
  "Profile"              -> profile,
  "Status"               -> "Initialized",
  "CurrentPhase"         -> None,
  "RetryPolicy"          -> ClaudeRetryPolicy[profile],
  "BudgetsUsed"          -> AssociationMap[0 &, Keys[$defaultEvalLimits]],
  "Adapter"              -> adapter,
  "TurnCount"            -> 0,
  "LastContextPacket"    -> None,
  "LastProviderResponse" -> None,
  "LastParseResult"      -> None,
  "LastProposal"         -> None,
  "LastValidationResult" -> None,
  "LastExecutionResult"  -> None,
  "LastFailure"          -> None,
  "FailureHistory"       -> {},
  "EventTrace"           -> {},
  "PendingApproval"      -> None,
  "CurrentJobId"         -> None,
  "ConversationState"    -> <||>,
  "ContinuationInput"    -> None,
  "TransactionState"     -> <||>,
  "CheckpointStack"      -> {},
  "Metadata"             -> <||>
|>;

iAppendEvent[runtimeId_String, event_Association] :=
  Module[{rt = $iClaudeRuntimes[runtimeId]},
    If[!AssociationQ[rt], Return[]];
    rt["EventTrace"] = Append[rt["EventTrace"],
      Append[event, "Timestamp" -> AbsoluteTime[]]];
    $iClaudeRuntimes[runtimeId] = rt;
  ];

iUpdateStatus[runtimeId_String, status_String] :=
  Module[{rt = $iClaudeRuntimes[runtimeId]},
    If[!AssociationQ[rt], Return[]];
    rt["Status"] = status;
    $iClaudeRuntimes[runtimeId] = rt;
    iAppendEvent[runtimeId, <|"Type" -> "StatusChange", "Status" -> status|>];
  ];

iUpdatePhase[runtimeId_String, phase_String] :=
  Module[{rt = $iClaudeRuntimes[runtimeId]},
    If[!AssociationQ[rt], Return[]];
    rt["CurrentPhase"] = phase;
    $iClaudeRuntimes[runtimeId] = rt;
  ];

iConsumeBudget[runtimeId_String, budgetKey_String] :=
  Module[{rt = $iClaudeRuntimes[runtimeId], used, limit,
          budgetsUsed, retryPolicy, limits},
    If[!AssociationQ[rt], Return[False]];
    (* v2026-04-20 T04 safety *)
    budgetsUsed = Lookup[rt, "BudgetsUsed", <||>];
    If[!AssociationQ[budgetsUsed], budgetsUsed = <||>];
    used = Lookup[budgetsUsed, budgetKey, 0];
    retryPolicy = Lookup[rt, "RetryPolicy", <||>];
    If[!AssociationQ[retryPolicy], retryPolicy = <||>];
    limits = Lookup[retryPolicy, "Limits", <||>];
    If[!AssociationQ[limits], limits = <||>];
    limit = Lookup[limits, budgetKey, 0];
    If[used >= limit, Return[False]];
    rt["BudgetsUsed"][budgetKey] = used + 1;
    $iClaudeRuntimes[runtimeId] = rt;
    True
  ];

iBudgetExhaustedQ[runtimeId_String, budgetKey_String] :=
  Module[{rt = $iClaudeRuntimes[runtimeId], used, limit,
          budgetsUsed, retryPolicy, limits},
    If[!AssociationQ[rt], Return[True]];
    (* v2026-04-20 T04 safety *)
    budgetsUsed = Lookup[rt, "BudgetsUsed", <||>];
    If[!AssociationQ[budgetsUsed], budgetsUsed = <||>];
    used = Lookup[budgetsUsed, budgetKey, 0];
    retryPolicy = Lookup[rt, "RetryPolicy", <||>];
    If[!AssociationQ[retryPolicy], retryPolicy = <||>];
    limits = Lookup[retryPolicy, "Limits", <||>];
    If[!AssociationQ[limits], limits = <||>];
    limit = Lookup[limits, budgetKey, 0];
    used >= limit
  ];

(* ════════════════════════════════════════════════════════
   4. Adapter interface 仕様
   ════════════════════════════════════════════════════════
   
   adapter は以下の関数を持つ Association:
   
   "BuildContext"[input, conversationState]
     → ClaudeContextPacket (Association)
     
   "QueryProvider"[contextPacket, conversationState]
     → <|"proc" -> ProcessObject, ...|>  (非同期)
     または <|"response" -> "...", ...|>  (同期/テスト用)
     SyncProvider -> True のとき同期モードで動作
     
   "ParseProposal"[rawResponse]
     → <|"HeldExpr" -> HoldComplete[...],
          "TextResponse" -> String,
          "HasProposal" -> True/False|>
     
   "ValidateProposal"[proposal, contextPacket]
     → <|"Decision" -> "Permit"|"Deny"|"NeedsApproval"|"RepairNeeded",
          "ReasonClass" -> String,
          "VisibleExplanation" -> String,
          "SanitizedExpr" -> HoldComplete[...]|>
     
   "ExecuteProposal"[proposal, validationResult]
     → <|"Success" -> True/False,
          "RawResult" -> ...,
          "Error" -> None|String|>
     
   "RedactResult"[executionResult, contextPacket]
     → <|"RedactedResult" -> ...,
          "Summary" -> String|>
     
   "ShouldContinue"[redactedResult, conversationState, turnCount]
     → True / False
     
   Optional:
   "SyncProvider" -> True/False  (デフォルト False)
   
   Tool Loop 用 (反復エージェントループ):
   "AvailableTools"[]
     → {<|"Name" -> String, "Description" -> String,
          "InputSchema" -> Association|>, ...}
     ツール定義のリスト。prompt に注入される。
     
   "ExecuteTools"[toolCalls, contextPacket]
     → {<|"ToolName" -> String, "ToolId" -> String,
          "Success" -> True/False,
          "Result" -> String, "Error" -> None|String|>, ...}
     ツール呼び出しを一括実行し結果を返す。
     未定義の場合 iExecuteToolsFallback が mathematica_eval のみ対応。
   
   Transaction 用 (UpdatePackage プロファイルで使用):
   "SnapshotPackage"[contextPacket]
     → <|"SnapshotId" -> String, "BackupPath" -> String,
          "PackagePath" -> String|>
     
   "ApplyToShadow"[proposal, snapshotInfo]
     → <|"Success" -> True/False, "ShadowPath" -> String,
          "Error" -> None|String|>
     
   "StaticCheck"[shadowResult]
     → <|"Success" -> True/False, "Errors" -> {}, "Warnings" -> {}|>
     
   "ReloadCheck"[shadowResult]
     → <|"Success" -> True/False, "Error" -> None|String|>
     
   "RunTests"[shadowResult, contextPacket]
     → <|"Success" -> True/False, "Passed" -> n, "Failed" -> n,
          "Failures" -> {...}, "Error" -> None|String|>
     
   "CommitTransaction"[shadowResult, snapshotInfo]
     → <|"Success" -> True/False, "Error" -> None|String|>
     
   "RollbackTransaction"[snapshotInfo]
     → <|"Success" -> True/False|>
   ════════════════════════════════════════════════════════ *)

iValidateAdapter[adapter_Association] :=
  Module[{required = {
    "BuildContext", "QueryProvider", "ParseProposal",
    "ValidateProposal", "ExecuteProposal", "RedactResult",
    "ShouldContinue"}},
    AllTrue[required, KeyExistsQ[adapter, #] &]
  ];

(* ════════════════════════════════════════════════════════
   5. CreateClaudeRuntime
   ════════════════════════════════════════════════════════ *)

Options[CreateClaudeRuntime] = {
  "Profile" -> Automatic,
  "Metadata" -> <||>
};

CreateClaudeRuntime[adapter_Association, opts:OptionsPattern[]] :=
  Module[{runtimeId, profile, state},
    If[!iValidateAdapter[adapter],
      Print[iL["ClaudeRuntime: adapter に必須キーが不足",
         "ClaudeRuntime: adapter missing required keys"]];
      Return[$Failed]];
    profile = OptionValue["Profile"];
    If[profile === Automatic, profile = $ClaudeRuntimeRetryProfile];
    runtimeId = iMakeRuntimeId[];
    state = iMakeRuntimeState[adapter, profile];
    state["RuntimeId"] = runtimeId;
    state["Metadata"]  = OptionValue["Metadata"];
    $iClaudeRuntimes[runtimeId] = state;
    iAppendEvent[runtimeId, <|"Type" -> "Created", "Profile" -> profile|>];
    runtimeId
  ];

(* ════════════════════════════════════════════════════════
   6. ClaudeRunTurn — DAG 構築と起動
   
   expression-proposal loop を LLMGraph DAG として展開する。
   
   DAG 構造:
     buildContext (sync)
       → queryProvider (claude-cli or sync)
         → parseProposal (sync)
           → validateProposal (sync)
             → dispatchDecision (sync, tolerateFailure)
               [Permit]       → execute → redact → continuation check
               [Deny]         → recordFailure
               [NeedsApproval]→ suspend
               [RepairNeeded] → schedule repair turn
   
   continuation の場合は onComplete から新 DAG を起動 (turnCount++)。
   ════════════════════════════════════════════════════════ *)

(* ── iMakeTurnNodes: ClaudeRunTurn / ClaudeRuntimeRetry 共用 ──
   ターン DAG のノード群を構築する。副作用なし。
   戻り値: <|"buildContext" -> node, "queryProvider" -> node, ...|> *)

iMakeTurnNodes[runtimeId_String, input_, adapter_Association] :=
  Module[{nodes = <||>,
          isSync = TrueQ[Lookup[adapter, "SyncProvider", False]]},
    With[{rid = runtimeId, inp = input, ad = adapter},
      
      nodes["buildContext"] = ClaudeCode`iLLMGraphNode[
        "buildContext", "sync", "rt-context", {},
        Function[{job},
          iSafeSync[iStepBuildContext[rid, inp, ad], "buildContext"]]];
      
      If[isSync,
        nodes["queryProvider"] = ClaudeCode`iLLMGraphNode[
          "queryProvider", "sync", "rt-provider",
          {"buildContext"},
          Function[{job},
            iSafeSync[iStepQueryProvider[rid, ad, job], "queryProvider"]]];
        nodes["parseProposal"] = ClaudeCode`iLLMGraphNode[
          "parseProposal", "sync", "rt-parse", {"queryProvider"},
          Function[{job},
            iSafeSync[iStepParseProposal[rid, ad, job], "parseProposal"]]],
        
        nodes["queryProvider"] = ClaudeCode`iLLMGraphNode[
          "queryProvider", "cli", "rt-provider",
          {"buildContext"},
          Function[{job},
            iStepQueryProviderAsync[rid, ad, job]]];
        
        nodes["collectProvider"] = ClaudeCode`iLLMGraphNode[
          "collectProvider", "sync", "rt-collect",
          {"queryProvider"},
          Function[{job},
            iSafeSync[
              iStepCollectProviderResult[rid, ad, job],
              "collectProvider"]]];
        
        nodes["parseProposal"] = ClaudeCode`iLLMGraphNode[
          "parseProposal", "sync", "rt-parse", {"collectProvider"},
          Function[{job},
            iSafeSync[iStepParseProposal[rid, ad, job], "parseProposal"]]]
      ];
      
      nodes["validateProposal"] = ClaudeCode`iLLMGraphNode[
        "validateProposal", "sync", "rt-validate", {"parseProposal"},
        Function[{job},
          iSafeSync[iStepValidateProposal[rid, ad, job],
            "validateProposal"]]];
      
      nodes["dispatchDecision"] = Append[
        ClaudeCode`iLLMGraphNode[
          "dispatchDecision", "sync", "rt-dispatch", {"validateProposal"},
          Function[{job},
            iSafeSync[iStepDispatchDecision[rid, ad, job],
              "dispatchDecision"]]],
        "tolerateFailure" -> True];
    ];
    nodes
  ];

Options[ClaudeRunTurn] = {"Notebook" -> Automatic};

ClaudeRunTurn[runtimeId_String, input_, opts:OptionsPattern[]] :=
  Module[{rt, adapter, nodes, jobId, nb, isSync},
    rt = $iClaudeRuntimes[runtimeId];
    If[!AssociationQ[rt],
      Return[Missing["RuntimeNotFound", runtimeId]]];
    If[!MemberQ[{"Initialized", "Done", "Failed"}, rt["Status"]],
      Return[Missing["RuntimeBusy", rt["Status"]]]];
    
    adapter = rt["Adapter"];
    nb = OptionValue["Notebook"];
    If[nb === Automatic,
      nb = Quiet @ Check[EvaluationNotebook[], $Failed]];
    
    rt["TurnCount"]         = rt["TurnCount"] + 1;
    rt["ContinuationInput"] = input;
    $iClaudeRuntimes[runtimeId] = rt;
    iUpdateStatus[runtimeId, "Running"];
    
    isSync = TrueQ[Lookup[adapter, "SyncProvider", False]];
    nodes = iMakeTurnNodes[runtimeId, input, adapter];
    
    jobId = ClaudeCode`LLMGraphDAGCreate[<|
      "nodes"          -> nodes,
      "taskDescriptor" -> <|
        "name"           -> "ClaudeRuntime Turn " <> ToString[rt["TurnCount"]],
        "categoryMap"    -> <|
          "rt-context"  -> "sync",
          "rt-provider" -> If[isSync, "sync", "cli"],
          "rt-collect"  -> "sync",
          "rt-parse"    -> "sync",
          "rt-validate" -> "sync",
          "rt-dispatch" -> "sync"|>,
        "maxConcurrency" -> <|"sync" -> 99, "cli" -> 1|>
      |>,
      "nb"         -> nb,
      "context"    -> <|"runtimeId" -> runtimeId,
                        "turnCount" -> rt["TurnCount"],
                        "detailLevel" -> "Internal"|>,
      "onComplete" -> Function[{completedJob},
        iOnTurnComplete[runtimeId, completedJob]]
    |>];
    
    Module[{current = $iClaudeRuntimes[runtimeId]},
      current["CurrentJobId"] = jobId;
      $iClaudeRuntimes[runtimeId] = current];
    iAppendEvent[runtimeId, <|
      "Type" -> "TurnStarted",
      "TurnCount" -> $iClaudeRuntimes[runtimeId]["TurnCount"],
      "JobId" -> jobId|>];
    jobId
  ];

(* ── iSafeSync: sync ハンドラーの DAG 互換ラッパー ──
   DAG インフラの sync ノードは $Failed / None を返すと "failed" にマークする。
   このラッパーは全例外をキャッチし、常に Association を返す。
   エラーは RuntimeState 側で追跡される
   (ステップ関数が iRecordFatalFailure / iUpdateStatus で記録)。
   DAG ノードとしては常に "done" になり、依存チェインが維持される。 *)
SetAttributes[iSafeSync, HoldFirst];
iSafeSync[expr_, stepName_String] :=
  Module[{result},
    result = Quiet @ Check[expr, $Failed];
    Which[
      AssociationQ[result], result,
      result === $Failed,
        <|"_step" -> stepName, "_error" -> "step returned $Failed"|>,
      result === None,
        <|"_step" -> stepName, "_error" -> "step returned None"|>,
      True,
        <|"_step" -> stepName, "_result" -> result|>
    ]
  ];

(* ════════════════════════════════════════════════════════
   7. DAG ノードの各ステップ実装
   ════════════════════════════════════════════════════════ *)

iStepBuildContext[runtimeId_String, input_, adapter_Association] :=
  Module[{rt, contextPacket, convState},
    iUpdatePhase[runtimeId, "BuildContext"];
    rt = $iClaudeRuntimes[runtimeId];
    convState = rt["ConversationState"];
    (* 初回ターン: OriginalTask を記録 *)
    If[!KeyExistsQ[convState, "OriginalTask"],
      convState["OriginalTask"] = input;
      convState["Messages"] = {};
      rt["ConversationState"] = convState;
      $iClaudeRuntimes[runtimeId] = rt];
    contextPacket = adapter["BuildContext"][input, convState];
    If[!AssociationQ[contextPacket],
      iAppendEvent[runtimeId, <|"Type" -> "Error",
        "Phase" -> "BuildContext", "Detail" -> "Invalid context packet"|>];
      Return[$Failed]];
    rt = $iClaudeRuntimes[runtimeId]; (* re-read *)
    rt["LastContextPacket"] = contextPacket;
    $iClaudeRuntimes[runtimeId] = rt;
    iAppendEvent[runtimeId, <|"Type" -> "ContextBuilt"|>];
    contextPacket
  ];

(* v2026-04-20 T08: \:30ec\:30b9\:30dd\:30f3\:30b9\:5185\:306e rate-limit \:30a8\:30e9\:30fc\:3092\:691c\:51fa\:3057\:3001
   \:691c\:51fa\:3057\:305f\:3089 FailureInfo \:3092\:69cb\:7bc9\:3057\:3066\:8a18\:9332\:3057\:3001True \:3092\:8fd4\:3059\:3002
   iStepQueryProvider \:306e Module \:5185\:306b\:30d9\:30bf\:66f8\:304d\:3057\:305f\:5834\:5408\:3001\:5185\:5074 Module \:3092\:62bc\:3057
   Return[$Failed, Module] \:304c\:5916\:5074\:306b\:8ca0\:3051\:305a\:306b\:6210\:529f\:6271\:3044\:3067 result \:3092\:8fd4\:3057\:3066
   \:3057\:307e\:3046\:30d0\:30b0\:306b\:5bfe\:5fdc\:3059\:308b\:3002\:547c\:3073\:51fa\:3057\:5074\:3067
   If[iCheckResponseRateLimit[...], Return[$Failed, Module]] \:3068\:3059\:308c\:3070\:3001
   Return \:306e Module \:30b9\:30b3\:30fc\:30d7\:306f\:4e0d\:30cd\:30b9\:30c8\:3001iStepQueryProvider \:306e
   Module \:3092\:6b63\:3057\:304f\:62b9\:3051\:308b\:3002 *)
iCheckResponseRateLimit[runtimeId_String, respText_String] :=
  Module[{isErr, rliInfo = None, failInfo,
          isRateLimit = False, resetsStr = ""},
    If[!StringQ[respText] || StringLength[respText] === 0,
      Return[False, Module]];
    isErr = Quiet @ Check[
      ClaudeCode`iIsAPIErrorResponse[respText], False];
    If[!TrueQ[isErr], Return[False, Module]];
    rliInfo = Quiet @ Check[
      ClaudeCode`iExtractRateLimitInfo[respText], None];
    isRateLimit = AssociationQ[rliInfo] &&
      (Lookup[rliInfo, "Source", ""] === "rate_limit_event" ||
       (IntegerQ[Lookup[rliInfo, "HttpStatus", None]] &&
        Lookup[rliInfo, "HttpStatus"] === 429));
    If[AssociationQ[rliInfo] &&
       Head[Lookup[rliInfo, "ResetsAt", None]] === DateObject,
      resetsStr = " (rate limit resets " <>
        DateString[rliInfo["ResetsAt"],
          {"Year", "-", "Month", "-", "Day", " ",
           "Hour24", ":", "Minute"}] <> ")"];
    failInfo = <|
      "ReasonClass" -> If[isRateLimit,
        "RateLimitExceeded", "ProviderAPIError"],
      "Error" -> StringTake[respText, UpTo[200]],
      "VisibleExplanation" ->
        "Claude CLI returned an error response" <> resetsStr|>;
    If[AssociationQ[rliInfo],
      AssociateTo[failInfo, "RateLimitInfo" -> rliInfo];
      AssociateTo[failInfo,
        "ResetsAt" -> Lookup[rliInfo, "ResetsAt", None]];
      AssociateTo[failInfo,
        "RateLimitType" -> Lookup[rliInfo, "RateLimitType", None]]];
    iAppendEvent[runtimeId, <|"Type" -> "ProviderRateLimited",
      "ReasonClass" -> failInfo["ReasonClass"],
      "ResetsAt" -> Lookup[failInfo, "ResetsAt", None]|>];
    iRecordFatalFailure[runtimeId, failInfo];
    True];
iCheckResponseRateLimit[_, _] := False;

iStepQueryProvider[runtimeId_String, adapter_Association,
    job_Association] :=
  Module[{contextPacket, rt, convState, result,
          attempt = 0, maxRetries, delay, fc, errMsg},
    iUpdatePhase[runtimeId, "QueryProvider"];
    (* Phase 16 fix: job["nodes"] ではなく RuntimeState から取得 *)
    rt = $iClaudeRuntimes[runtimeId];
    contextPacket = rt["LastContextPacket"];
    If[!AssociationQ[contextPacket], Return[$Failed]];
    convState = rt["ConversationState"];
    If[!iConsumeBudget[runtimeId, "MaxTotalSteps"],
      iAppendEvent[runtimeId, <|"Type" -> "BudgetExhausted",
        "Budget" -> "MaxTotalSteps"|>];
      iUpdateStatus[runtimeId, "Failed"];
      Return[$Failed]];
    (* v2026-04-20 T04 safety: rt["RetryPolicy"] \:307e\:305f\:306f ...["Limits"] \:304c
       None \:307e\:305f\:306f Association \:3067\:306a\:3044\:5834\:5408\:3001Lookup[None, ...] \:306b\:306a\:308b
       \:306e\:3067\:6bb5\:968e\:7684\:306b\:30ac\:30fc\:30c9\:3002 *)
    Module[{retryPolicy, limits},
      retryPolicy = Lookup[rt, "RetryPolicy", <||>];
      If[!AssociationQ[retryPolicy], retryPolicy = <||>];
      limits = Lookup[retryPolicy, "Limits", <||>];
      If[!AssociationQ[limits], limits = <||>];
      maxRetries = Lookup[limits, "MaxTransportRetries", 2];
    ];
    
    (* Transport retry loop with exponential backoff *)
    While[True,
      (* Quiet のみ使用: Check は iQueryViaAPI / LLMSynthesize 等の
         無害な Network メッセージもキャッチして $Failed にしてしまう。
         戻り値で成否を判定する。 *)
      result = Quiet[adapter["QueryProvider"][contextPacket, convState]];
      
      (* 成功判定: Association で "response" キーがあり、Error キーがない *)
      If[AssociationQ[result] &&
         KeyExistsQ[result, "response"] &&
         !StringQ[Lookup[result, "Error", None]],
        (* v2026-04-20 T08 fix: T06 \:306f\:5185\:5074 Module \:306b Return[$Failed, Module] \:3092\:7f6e\:3044\:3066
           \:3044\:305f\:305f\:3081\:5185\:5074 Module \:3060\:3051\:3092\:629c\:3051\:3001\:6210\:529f\:6271\:3044\:3067
           stream-json \:3092 result \:3068\:3057\:3066\:8fd4\:3057\:3066\:3044\:305f\:3002
           \:5225\:95a2\:6570 iCheckResponseRateLimit \:306b\:5207\:308a\:51fa\:3057\:3001
           True \:8fd4\:3057\:305f\:3089\:5916\:5074\:306e iStepQueryProvider \:306e Module \:3092\:629c\:3051\:308b\:3002 *)
        If[TrueQ[iCheckResponseRateLimit[runtimeId,
             Lookup[result, "response", ""]]],
          Return[$Failed, Module]];
        iAppendEvent[runtimeId, <|"Type" -> "ProviderQueried",
          "Attempt" -> attempt + 1|>];
        (* Phase 16 fix: レスポンスを RuntimeState に保存 *)
        Module[{cur = $iClaudeRuntimes[runtimeId]},
          cur["LastProviderResponse"] = result;
          $iClaudeRuntimes[runtimeId] = cur];
        Return[result, Module]];
      
      (* エラー分類 *)
      errMsg = If[AssociationQ[result],
        Lookup[result, "Error", "Provider call failed"],
        "Provider call failed: " <> ToString[Short[result, 2]]];
      fc = If[result === $Failed || !AssociationQ[result],
        (* $Failed / 非 Association は通信障害として retryable *)
        <|"Class" -> "TransportTransient", "Retryable" -> True, "Fatal" -> False|>,
        ClaudeClassifyFailure[errMsg]];
      
      (* Fatal エラーはリトライしない *)
      If[TrueQ[fc["Fatal"]],
        iAppendEvent[runtimeId, <|"Type" -> "ProviderFatalError",
          "Error" -> errMsg, "Class" -> fc["Class"]|>];
        (* v2026-04-20 T07: Fatal \:304c RateLimitExceeded \:306a\:3089
           iExtractRateLimitInfo \:3067 ResetsAt \:7b49\:3092\:62bd\:51fa\:3057\:3066 FailureInfo \:306b\:542b\:3081\:308b\:3002
           \:3053\:308c\:306b\:3088\:308a Orchestrator \:306f FailureInfo.ResetsAt \:3092\:898b\:3066
           \:5fa9\:65e7\:30bf\:30a4\:30df\:30f3\:30b0\:3092\:5224\:65ad\:3067\:304d\:308b\:3002 *)
        Module[{failInfo, rliInfo, resetsStr = ""},
          failInfo = <|"ReasonClass" -> fc["Class"],
                       "Error" -> StringTake[errMsg, UpTo[200]]|>;
          If[fc["Class"] === "RateLimitExceeded",
            rliInfo = Quiet @ Check[
              ClaudeCode`iExtractRateLimitInfo[errMsg], None];
            If[AssociationQ[rliInfo] &&
               Head[Lookup[rliInfo, "ResetsAt", None]] === DateObject,
              resetsStr = " (resets " <>
                DateString[rliInfo["ResetsAt"],
                  {"Year", "-", "Month", "-", "Day", " ",
                   "Hour24", ":", "Minute"}] <> ")"];
            AssociateTo[failInfo,
              "VisibleExplanation" ->
                "Claude CLI rate limit reached" <> resetsStr];
            If[AssociationQ[rliInfo],
              AssociateTo[failInfo, "RateLimitInfo" -> rliInfo];
              AssociateTo[failInfo,
                "ResetsAt" -> Lookup[rliInfo, "ResetsAt", None]];
              AssociateTo[failInfo,
                "RateLimitType" -> Lookup[rliInfo, "RateLimitType", None]]]];
          iRecordFatalFailure[runtimeId, failInfo]];
        Return[$Failed, Module]];
      
      (* リトライ可能かチェック *)
      If[!TrueQ[fc["Retryable"]] ||
         !iConsumeBudget[runtimeId, "MaxTransportRetries"],
        iAppendEvent[runtimeId, <|"Type" -> "TransportRetryExhausted",
          "Error" -> errMsg, "Attempts" -> attempt + 1|>];
        iUpdateStatus[runtimeId, "Failed"];
        Return[$Failed, Module]];
      
      (* Exponential backoff: SyncProvider 時はスキップ *)
      attempt++;
      If[!TrueQ[Lookup[adapter, "SyncProvider", False]],
        delay = Min[2^(attempt - 1), 30];
        Pause[delay],
        delay = 0];
      iAppendEvent[runtimeId, <|"Type" -> "TransportRetry",
        "Attempt" -> attempt, "Delay" -> delay,
        "Error" -> errMsg|>];
    ];
  ];

(* ── 非同期 QueryProvider: プロセス起動のみ ──
   adapter["QueryProviderAsync"] を呼び出し、
   <|"proc"->ProcessObject, "outFile"->..., ...|> を返す。
   DAG tick が ProcessStatus をポーリングし、完了後に
   collectProvider が結果を RuntimeState に保存する。 *)
iStepQueryProviderAsync[runtimeId_String, adapter_Association,
    job_Association] :=
  Module[{rt, contextPacket, convState, launchResult, errMsg = None},
    iUpdatePhase[runtimeId, "QueryProvider"];
    rt = $iClaudeRuntimes[runtimeId];
    contextPacket = rt["LastContextPacket"];
    If[!AssociationQ[contextPacket],
      Print[iL["  [RT-Async] エラー: LastContextPacket が Association ではありません",
         "  [RT-Async] ERROR: LastContextPacket is not Association"]];
      Return[$Failed]];
    convState = rt["ConversationState"];
    If[!iConsumeBudget[runtimeId, "MaxTotalSteps"],
      iAppendEvent[runtimeId, <|"Type" -> "BudgetExhausted",
        "Budget" -> "MaxTotalSteps"|>];
      iUpdateStatus[runtimeId, "Failed"];
      Return[$Failed]];
    
    (* Quiet を除去して実際のエラーメッセージを表示 *)
    launchResult = Check[
      adapter["QueryProviderAsync"][contextPacket, convState],
      (errMsg = "QueryProviderAsync raised a message";
       $Failed)];
    
    If[!AssociationQ[launchResult] || !KeyExistsQ[launchResult, "proc"],
      Print["  [RT-Async] Launch failed: launchResult = ",
        ToString[Short[launchResult, 3]]];
      If[StringQ[errMsg], Print["  [RT-Async] ", errMsg]];
      iAppendEvent[runtimeId, <|"Type" -> "AsyncLaunchFailed",
        "LaunchResult" -> ToString[Short[launchResult, 2]]|>];
      Return[$Failed]];
    
    iAppendEvent[runtimeId, <|"Type" -> "ProviderLaunched"|>];
    (* DAG が ProcessObject をポーリングするための runState を返す *)
    launchResult
  ];

(* ── collectProvider: async queryProvider の結果を RuntimeState に保存 ──
   DAG tick が Process 完了後に node["result"] にテキストを格納している。
   stream-json 形式の場合は iExtractResultFromStreamJsonText で
   実際のレスポンステキストを抽出する。
   parseProposal 以降は sync 時と同一のパスで動作する。 *)
iStepCollectProviderResult[runtimeId_String, adapter_Association,
    job_Association] :=
  Module[{queryNode, rawText, extractedText, rt},
    iUpdatePhase[runtimeId, "CollectProvider"];
    queryNode = Lookup[Lookup[job, "nodes", <||>],
      "queryProvider", <||>];
    rawText = Lookup[queryNode, "result", None];
    
    If[!StringQ[rawText] || rawText === "",
      (* Process が失敗した場合 *)
      Module[{errMsg = Lookup[queryNode, "error", "Provider process failed"]},
        iAppendEvent[runtimeId, <|"Type" -> "ProviderFailed",
          "Error" -> errMsg|>];
        iRecordFatalFailure[runtimeId,
          <|"ReasonClass" -> "TransportTransient", "Error" -> errMsg|>];
        Return[$Failed]]];
    
    (* stream-json 形式の検出と変換:
       rawText が JSON 行 ({"type":...) で始まる場合、
       iExtractResultFromStreamJsonText でレスポンステキストを抽出する。
       プレーンテキストの場合はそのまま使用。 *)
    extractedText = If[StringStartsQ[StringTrim[rawText], "{"],
      Module[{parsed = Quiet @ Check[
          ClaudeCode`Private`iExtractResultFromStreamJsonText[rawText],
          rawText]},
        If[StringQ[parsed] && parsed =!= "", parsed, rawText]],
      rawText];
    
    If[extractedText === "" || !StringQ[extractedText],
      Module[{errMsg = "Provider returned empty response after extraction"},
        iAppendEvent[runtimeId, <|"Type" -> "ProviderFailed",
          "Error" -> errMsg,
          "RawLength" -> If[StringQ[rawText], StringLength[rawText], 0]|>];
        iRecordFatalFailure[runtimeId,
          <|"ReasonClass" -> "TransportTransient", "Error" -> errMsg|>];
        Return[$Failed]]];
    
    rt = $iClaudeRuntimes[runtimeId];
    rt["LastProviderResponse"] = <|"response" -> extractedText|>;
    $iClaudeRuntimes[runtimeId] = rt;
    iAppendEvent[runtimeId, <|"Type" -> "ProviderQueried",
      "Async" -> True,
      "ResponseLength" -> StringLength[extractedText],
      "RawLength" -> StringLength[rawText],
      "StreamJson" -> StringStartsQ[StringTrim[rawText], "{"]|>];
    <|"response" -> extractedText|>
  ];

iStepParseProposal[runtimeId_String, adapter_Association,
    job_Association] :=
  Module[{rawResponse, proposal, parseResult},
    iUpdatePhase[runtimeId, "ParseProposal"];
    (* Phase 16 fix: job["nodes"] ではなく RuntimeState から取得 *)
    rawResponse = $iClaudeRuntimes[runtimeId]["LastProviderResponse"];
    If[rawResponse === None || rawResponse === $Failed, Return[$Failed]];
    If[AssociationQ[rawResponse],
      rawResponse = Lookup[rawResponse, "response", ToString[rawResponse]]];
    proposal = adapter["ParseProposal"][rawResponse];
    If[!AssociationQ[proposal],
      If[iConsumeBudget[runtimeId, "MaxFormatRetries"],
        iAppendEvent[runtimeId, <|"Type" -> "FormatRetry",
          "RawSnippet" -> StringTake[ToString[rawResponse], UpTo[100]]|>];
        iScheduleRepairTurn[runtimeId,
          "Your response could not be parsed. " <>
          "Please respond with a single ```mathematica code block " <>
          "containing the Mathematica expression to evaluate, " <>
          "or respond with text only (no code block) if no action is needed."];
        parseResult = <|"Decision" -> "RepairNeeded",
          "ReasonClass" -> "ModelFormatError",
          "VisibleExplanation" -> "Parse failed, repair scheduled"|>;
        (* RuntimeState に保存して返す *)
        Module[{rt = $iClaudeRuntimes[runtimeId]},
          rt["LastParseResult"] = parseResult;
          $iClaudeRuntimes[runtimeId] = rt];
        Return[parseResult]];
      iAppendEvent[runtimeId, <|"Type" -> "BudgetExhausted",
        "Budget" -> "MaxFormatRetries"|>];
      Return[$Failed]];
    Module[{rt = $iClaudeRuntimes[runtimeId]},
      rt["LastProposal"] = proposal;
      rt["LastParseResult"] = proposal;
      $iClaudeRuntimes[runtimeId] = rt];
    iAppendEvent[runtimeId, <|"Type" -> "ProposalParsed",
      "HasProposal" -> Lookup[proposal, "HasProposal", False],
      "CodeLength" -> StringLength[
        Lookup[proposal, "RawCode", ""]]|>];
    proposal
  ];

iStepValidateProposal[runtimeId_String, adapter_Association,
    job_Association] :=
  Module[{proposal, contextPacket, validationResult, rt,
          heldExpr, code, heads, denied, needsApproval},
    iUpdatePhase[runtimeId, "ValidateProposal"];
    rt = $iClaudeRuntimes[runtimeId];
    proposal = Lookup[rt, "LastParseResult",
      Lookup[rt, "LastProposal", None]];
    If[!AssociationQ[proposal], Return[$Failed]];
    If[KeyExistsQ[proposal, "Decision"] && !KeyExistsQ[proposal, "HasProposal"],
      Module[{cur = $iClaudeRuntimes[runtimeId]},
        cur["LastValidationResult"] = proposal;
        $iClaudeRuntimes[runtimeId] = cur];
      Return[proposal]];
    If[!TrueQ[Lookup[proposal, "HasProposal", False]],
      If[TrueQ[Lookup[proposal, "HasToolUse", False]],
        Module[{toolResult = <|"Decision" -> "ToolUse",
                  "ToolCalls" -> Lookup[proposal, "ToolCalls", {}],
                  "TextResponse" -> Lookup[proposal, "TextResponse", ""]|>,
                cur},
          cur = $iClaudeRuntimes[runtimeId];
          cur["LastValidationResult"] = toolResult;
          $iClaudeRuntimes[runtimeId] = cur;
          iAppendEvent[runtimeId, <|"Type" -> "ToolUseDetected",
            "ToolCount" -> Length[Lookup[proposal, "ToolCalls", {}]]|>];
          Return[toolResult]]];
      Module[{textResult = <|"Decision" -> "TextOnly",
                "TextResponse" -> Lookup[proposal, "TextResponse", ""]|>,
              cur},
        cur = $iClaudeRuntimes[runtimeId];
        cur["LastValidationResult"] = textResult;
        $iClaudeRuntimes[runtimeId] = cur;
        Return[textResult]]];
    
    (* ── Phase 26: head チェック + AutoEval 禁止チェック ──
       フロー:
       1. head チェック (NBAccess 直接 or adapter フォールバック)
          → Deny / NeedsApproval / Permit を判定
       2. AutoEval 禁止チェック (Permit の場合のみ)
          → Permit かつ AutoEval 禁止パターンなら NeedsApproval に昇格
       設計意図: Deny 式が NeedsApproval に退行するのを防止 *)
    rt = $iClaudeRuntimes[runtimeId];
    contextPacket = rt["LastContextPacket"];
    heldExpr = Lookup[proposal, "HeldExpr", None];
    code     = Lookup[proposal, "RawCode", ""];
    
    If[ListQ[Quiet[NBAccess`$NBDenyHeads]] ||
       ListQ[Quiet[NBAccess`$NBApprovalHeads]],
      (* ── NBAccess ロード済み: Runtime 側で直接 head チェック ── *)
      heads = Quiet @ Check[
        DeleteDuplicates @ Cases[heldExpr,
          s_Symbol[___] :> SymbolName[Unevaluated[s]],
          {1, Infinity}], {}];
      denied = If[ListQ[NBAccess`$NBDenyHeads],
        Select[heads, MemberQ[NBAccess`$NBDenyHeads, #] &], {}];
      needsApproval = If[ListQ[NBAccess`$NBApprovalHeads],
        Select[heads, MemberQ[NBAccess`$NBApprovalHeads, #] &], {}];
      
      validationResult = Which[
        Length[denied] > 0,
          <|"Decision" -> "Deny",
            "ReasonClass" -> "ForbiddenHead",
            "VisibleExplanation" ->
              "Forbidden heads: " <> StringRiffle[denied, ", "],
            "SanitizedExpr" -> heldExpr|>,
        Length[needsApproval] > 0,
          <|"Decision" -> "NeedsApproval",
            "ReasonClass" -> "AccessEscalationRequired",
            "VisibleExplanation" ->
              "Heads requiring approval: " <> StringRiffle[needsApproval, ", "],
            "SanitizedExpr" -> heldExpr|>,
        True,
          <|"Decision" -> "Permit",
            "ReasonClass" -> "None",
            "VisibleExplanation" -> "",
            "SanitizedExpr" -> heldExpr,
            "RouteAdvice" -> Quiet @ Check[
              NBAccess`NBRouteDecision[
                Lookup[contextPacket, "AccessSpec", <||>]], None]|>
      ],
      (* ── NBAccess 未ロード: adapter にフォールバック ──
         Quiet のみ使用 (Check は無害なメッセージもキャッチしてしまう)。
         結果が Association でない場合は後続の AssociationQ チェックで Deny になる。 *)
      validationResult = Quiet[
        adapter["ValidateProposal"][proposal, contextPacket]]
    ];
    
    (* AutoEvaluate 禁止操作チェック:
       Permit の場合のみ NeedsApproval に昇格。
       Deny / NeedsApproval はそのまま維持（安全レベルの退行防止）。 *)
    If[AssociationQ[validationResult] &&
       Lookup[validationResult, "Decision", ""] === "Permit" &&
       StringQ[code] &&
       TrueQ[Quiet @ Check[
         ClaudeCode`Private`iIsAutoEvalProhibited[code], False]],
      validationResult = <|"Decision" -> "NeedsApproval",
        "ReasonClass" -> "AccessEscalationRequired",
        "VisibleExplanation" -> iL["アクセス範囲を変更するコード。確認が必要です。",
          "Code modifies access scope. Review required."],
        "SanitizedExpr" -> heldExpr|>];
    
    (* コアコンテキスト上書き検出:
       NBAccess` / ClaudeCode` / ClaudeRuntime` / ClaudeTestKit` の
       関数を上書きするコードは停止してユーザーに判断を仰ぐ。
       テスト中のスタブ上書き等による意図しない状態汚染を防止。 *)
    If[AssociationQ[validationResult] &&
       Lookup[validationResult, "Decision", ""] === "Permit" &&
       StringQ[code] && iDetectsContextOverwrite[code],
      validationResult = <|"Decision" -> "NeedsApproval",
        "ReasonClass" -> "CoreContextOverwrite",
        "VisibleExplanation" ->
          iL["コアパッケージ (NBAccess/ClaudeCode/ClaudeRuntime/ClaudeTestKit) の" <>
            "関数を上書きするコードです。システム機能が破損する可能性があります。承認が必要です。",
          "Code overwrites core package functions " <>
            "(NBAccess/ClaudeCode/ClaudeRuntime/ClaudeTestKit). " <>
            "This may break system functionality. Approval required."],
        "SanitizedExpr" -> heldExpr|>];
    
    If[!AssociationQ[validationResult],
      validationResult = <|"Decision" -> "Deny",
        "ReasonClass" -> "ValidationError",
        "VisibleExplanation" -> "Validation returned: " <>
          ToString[Short[validationResult, 2]]|>];
    
    rt = $iClaudeRuntimes[runtimeId];
    rt["LastValidationResult"] = validationResult;
    $iClaudeRuntimes[runtimeId] = rt;
    iAppendEvent[runtimeId, <|"Type" -> "ValidationComplete",
      "Decision" -> Lookup[validationResult, "Decision", "?"],
      "Detail" -> Lookup[validationResult, "VisibleExplanation", ""],
      "RouteAdvice" -> Lookup[validationResult, "RouteAdvice", None]|>];
    validationResult
  ];

iStepDispatchDecision[runtimeId_String, adapter_Association,
    job_Association] :=
  Module[{validationResult, decision, proposal, contextPacket, rt},
    iUpdatePhase[runtimeId, "DispatchDecision"];
    (* Phase 16 fix: job["nodes"] ではなく RuntimeState から取得 *)
    validationResult = $iClaudeRuntimes[runtimeId]["LastValidationResult"];
    (* ParseProposal が TextOnly/RepairNeeded を返した場合は LastProposal にある *)
    If[!AssociationQ[validationResult],
      validationResult = $iClaudeRuntimes[runtimeId]["LastProposal"];
      (* LastProposal にも Decision がない場合は明示的エラーを設定 *)
      If[AssociationQ[validationResult] && !KeyExistsQ[validationResult, "Decision"],
        iAppendEvent[runtimeId, <|"Type" -> "ValidationMissing",
          "Detail" -> "LastValidationResult was not set; using LastProposal as fallback"|>];
        validationResult = <|"Decision" -> "Deny",
          "ReasonClass" -> "ValidationError",
          "VisibleExplanation" ->
            "Validation step did not produce a result. Proposal denied for safety.",
          "SanitizedExpr" -> Lookup[validationResult, "HeldExpr", None]|>];
      If[!AssociationQ[validationResult], Return[$Failed]]];
    decision = Lookup[validationResult, "Decision", "Deny"];
    rt = $iClaudeRuntimes[runtimeId];
    proposal     = rt["LastProposal"];
    contextPacket = rt["LastContextPacket"];
    
    Switch[decision,
      "TextOnly",
        Module[{textResp, msgs, prevCodeTurns},
          textResp = Lookup[proposal, "TextResponse",
            Lookup[validationResult, "TextResponse", ""]];
          rt = $iClaudeRuntimes[runtimeId];
          msgs = Lookup[rt["ConversationState"], "Messages", {}];
          
          (* Phase 16d: 初回ターンで TextOnly = LLM が式を提案せずテキストで回答。
             過去にコード実行ターンがない場合はフォーマット修復を要求し、
             Mathematica 式の提案を促す。
             過去にコード実行済みなら TextOnly = タスク完了シグナル。 *)
          prevCodeTurns = Select[msgs,
            (StringQ[Lookup[#, "ProposedCode", None]] ||
             ListQ[Lookup[#, "ToolCalls", None]]) &];
          
          If[Length[prevCodeTurns] === 0 &&
             iConsumeBudget[runtimeId, "MaxFormatRetries"],
            (* 初回で式なし → repair *)
            iAppendEvent[runtimeId, <|"Type" -> "TextOnlyRepair",
              "Reason" -> "First turn without code proposal"|>];
            iScheduleRepairTurn[runtimeId,
              "Your response MUST include one or more ```mathematica code blocks. " <>
              "Do NOT respond with text only.\n\n" <>
              "For computation tasks, write the expression:\n" <>
              "```mathematica\nSum[i, {i, 1, 100}]\n```\n\n" <>
              "For explanation/visualization tasks, write code that PRODUCES the output:\n" <>
              "```mathematica\nColumn[{Style[\"Title\", Bold, 16], " <>
              "Plot[Sin[x], {x, 0, 2 Pi}], \"Explanation text...\"}, Spacings -> 1]\n```\n\n" <>
              "The local Mathematica kernel evaluates your code blocks and displays the results."];
            <|"Outcome" -> "RepairScheduled"|>,
            
            (* 過去にコード実行済み or repair 予算切れ → 完了 *)
            rt["ConversationState"] = <|
              "Messages"    -> iCompactConversationHistory[
                Append[msgs, <|
                  "Turn"           -> rt["TurnCount"],
                  "TextResponse"   -> textResp,
                  "ExecutionResult" -> None,
                  "Timestamp"      -> AbsoluteTime[]|>],
                $MaxDetailedMessages, $MaxConversationMessages],
              "LastResult"   -> None,
              "OriginalTask" -> Lookup[rt["ConversationState"],
                "OriginalTask", ""]
            |>;
            $iClaudeRuntimes[runtimeId] = rt;
            iAppendEvent[runtimeId, <|"Type" -> "TextOnlyResponse"|>];
            iUpdateStatus[runtimeId, "Done"];
            <|"Outcome" -> "TextOnly",
              "TextResponse" -> textResp|>
          ]
        ],
      
      "Permit",
        If[rt["Profile"] === "UpdatePackage" &&
           KeyExistsQ[adapter, "SnapshotPackage"],
          iTransactionExecute[runtimeId, adapter, proposal,
            validationResult, contextPacket],
          iExecuteAndContinue[runtimeId, adapter, proposal,
            validationResult, contextPacket]],
      
      "ToolUse",
        iToolUseAndContinue[runtimeId, adapter, proposal,
          validationResult, contextPacket],
      
      "NeedsApproval",
        rt["PendingApproval"] = <|
          "Proposal"         -> proposal,
          "ValidationResult" -> validationResult,
          "ContextPacket"    -> contextPacket|>;
        $iClaudeRuntimes[runtimeId] = rt;
        iUpdateStatus[runtimeId, "AwaitingApproval"];
        iAppendEvent[runtimeId, <|"Type" -> "AwaitingApproval",
          "Reason" -> Lookup[validationResult, "VisibleExplanation", ""]|>];
        <|"Outcome" -> "AwaitingApproval"|>,
      
      "RepairNeeded",
        If[iConsumeBudget[runtimeId, "MaxValidationRepairs"],
          iAppendEvent[runtimeId, <|"Type" -> "ValidationRepairAttempt",
            "Reason" -> Lookup[validationResult, "ReasonClass", ""],
            "Detail" -> Lookup[validationResult, "VisibleExplanation", ""]|>];
          iScheduleRepairTurn[runtimeId,
            Lookup[validationResult, "VisibleExplanation", ""]];
          <|"Outcome" -> "RepairScheduled"|>,
          iRecordFatalFailure[runtimeId, validationResult];
          <|"Outcome" -> "Failed",
            "Reason" -> "ValidationRepairBudgetExhausted"|>],
      
      "Deny",
        (* Phase 25b: Deny は即時失敗ではなく承認待ちに遷移。
           ユーザーに詳細を見せて、それでも実行するか判断を仰ぐ。 *)
        rt["PendingApproval"] = <|
          "Proposal"         -> proposal,
          "ValidationResult" -> validationResult,
          "ContextPacket"    -> contextPacket,
          "DenyOverride"     -> True|>;
        $iClaudeRuntimes[runtimeId] = rt;
        iUpdateStatus[runtimeId, "AwaitingApproval"];
        iAppendEvent[runtimeId, <|"Type" -> "AwaitingApproval",
          "Reason" -> Lookup[validationResult, "VisibleExplanation", ""],
          "DenyOverride" -> True,
          "ReasonClass" -> Lookup[validationResult, "ReasonClass", "Deny"]|>];
        <|"Outcome" -> "AwaitingApproval"|>,
      
      _,
        iRecordFatalFailure[runtimeId, validationResult];
        <|"Outcome" -> "Failed", "Reason" -> "UnknownDecision"|>
    ]
  ];

(* ════════════════════════════════════════════════════════
   8. 実行 → redact → continuation
   ════════════════════════════════════════════════════════ *)

(* ── 8a. ToolUse ループ ──
   LLM がツール呼び出しを要求した場合の処理。
   ツールを実行 → 結果を ConversationState に蓄積 →
   continuation turn をスケジュール。
   
   フロー:
     ToolUse 検出 → adapter["ExecuteTools"] → 結果蓄積
       → MaxToolIterations budget 消費
       → ContinuationInput に ToolResults を含めて次ターンへ
       → 次ターンの BuildContext がツール結果を prompt に注入
       → LLM が最終応答 or さらにツール呼び出し
   
   budget は MaxToolIterations で管理。
   MaxProposalIterations は消費しない（ツールループは「同一提案の反復」ではない）。
   MaxTotalSteps は各ターンで消費される。
*)

iToolUseAndContinue[runtimeId_String, adapter_Association,
    proposal_Association, validationResult_Association,
    contextPacket_Association] :=
  Module[{toolCalls, toolResults, rt, msgs, turnMsg, textResp},
    iUpdatePhase[runtimeId, "ToolExecution"];
    
    (* budget チェック *)
    If[!iConsumeBudget[runtimeId, "MaxToolIterations"],
      iAppendEvent[runtimeId, <|"Type" -> "BudgetExhausted",
        "Budget" -> "MaxToolIterations"|>];
      (* budget 切れ: 現在のテキスト応答で Done にする *)
      iUpdateStatus[runtimeId, "Done"];
      iAppendEvent[runtimeId, <|"Type" -> "ToolLoopBudgetExhausted"|>];
      Return[<|"Outcome" -> "Done",
        "Reason" -> "ToolIterationBudgetExhausted",
        "TextResponse" -> Lookup[validationResult,
          "TextResponse", ""]|>]];
    
    toolCalls = Lookup[validationResult, "ToolCalls", {}];
    If[Length[toolCalls] === 0,
      (* ToolUse フラグがあるがツールコールが空 → テキスト応答として完了 *)
      iUpdateStatus[runtimeId, "Done"];
      Return[<|"Outcome" -> "Done",
        "TextResponse" -> Lookup[proposal, "TextResponse", ""]|>]];
    
    (* ── ツール実行 ── *)
    toolResults = If[KeyExistsQ[adapter, "ExecuteTools"],
      Quiet @ Check[
        adapter["ExecuteTools"][toolCalls, contextPacket],
        Map[<|"ToolName" -> Lookup[#, "Name", "?"],
              "ToolId" -> Lookup[#, "Id", ""],
              "Success" -> False,
              "Error" -> "ExecuteTools adapter failed"|> &,
          toolCalls]],
      (* ExecuteTools がない → 各ツールを個別に実行 *)
      iExecuteToolsFallback[runtimeId, adapter, toolCalls, contextPacket]
    ];
    
    iAppendEvent[runtimeId, <|"Type" -> "ToolsExecuted",
      "ToolCount" -> Length[toolCalls],
      "Results" -> Map[
        <|"Name" -> Lookup[#, "ToolName", "?"],
          "Success" -> TrueQ[Lookup[#, "Success", False]]|> &,
        toolResults]|>];
    
    (* ── ConversationState に蓄積 ── *)
    rt = $iClaudeRuntimes[runtimeId];
    msgs = Lookup[rt["ConversationState"], "Messages", {}];
    textResp = Lookup[proposal, "TextResponse",
      Lookup[validationResult, "TextResponse", ""]];
    
    turnMsg = <|
      "Turn"           -> rt["TurnCount"],
      "Type"           -> "ToolUse",
      "TextResponse"   -> textResp,
      "ToolCalls"      -> toolCalls,
      "ToolResults"    -> toolResults,
      "ProposedCode"   -> None,
      "ExecutionResult" -> None,
      "Timestamp"      -> AbsoluteTime[]
    |>;
    
    rt["ConversationState"] = <|
      "Messages"     -> iCompactConversationHistory[
        Append[msgs, turnMsg],
        $MaxDetailedMessages, $MaxConversationMessages],
      "LastResult"   -> <|"ToolResults" -> toolResults|>,
      "OriginalTask" -> Lookup[rt["ConversationState"],
        "OriginalTask", rt["ContinuationInput"]]
    |>;
    
    (* ── 次ターンをスケジュール ── *)
    rt["ContinuationInput"] = <|
      "Type"           -> "ToolResult",
      "OriginalTask"   -> Lookup[rt["ConversationState"],
                            "OriginalTask", ""],
      "ToolCalls"      -> toolCalls,
      "ToolResults"    -> toolResults,
      "TurnHistory"    -> Lookup[rt["ConversationState"],
                            "Messages", {}]
    |>;
    $iClaudeRuntimes[runtimeId] = rt;
    
    iAppendEvent[runtimeId, <|"Type" -> "ToolContinuationScheduled"|>];
    <|"Outcome" -> "ContinuationPending"|>
  ];

(* ── ツール個別実行フォールバック ──
   adapter に "ExecuteTools" がない場合、
   個別のツール名に基づいて adapter の関数を探す。
   主に mathematica_eval は既存の ExecuteProposal を流用。 *)
iExecuteToolsFallback[runtimeId_String, adapter_Association,
    toolCalls_List, contextPacket_Association] :=
  Map[
    Function[{call},
      Module[{name, input, tid, result},
        name  = Lookup[call, "Name", "unknown"];
        input = Lookup[call, "Input", <||>];
        tid   = Lookup[call, "Id", ""];
        
        result = Switch[name,
          "mathematica_eval",
            Module[{code, heldExpr, proposal, valResult, execResult, redacted},
              code = Lookup[input, "code", ""];
              heldExpr = Quiet @ Check[
                ToExpression[code, InputForm, HoldComplete], None];
              If[heldExpr === None,
                <|"Success" -> False, "Error" -> "Parse failed"|>,
                proposal = <|"HeldExpr" -> heldExpr, "RawCode" -> code,
                  "HasProposal" -> True|>;
                valResult = adapter["ValidateProposal"][
                  proposal, contextPacket];
                If[Lookup[valResult, "Decision", "Deny"] =!= "Permit",
                  <|"Success" -> False,
                    "Error" -> "Validation denied: " <>
                      Lookup[valResult, "VisibleExplanation",
                        Lookup[valResult, "ReasonClass", "Denied"]]|>,
                  execResult = adapter["ExecuteProposal"][
                    proposal, valResult];
                  redacted = adapter["RedactResult"][
                    execResult, contextPacket];
                  <|"Success" -> TrueQ[Lookup[execResult, "Success", False]],
                    "RawResult" -> Lookup[execResult, "RawResult", None],
                    "RedactedResult" -> Lookup[redacted,
                      "RedactedResult", ""],
                    "Summary" -> Lookup[redacted, "Summary", ""],
                    "Error" -> Lookup[execResult, "Error", None]|>]]],
          
          _,
            <|"Success" -> False,
              "Error" -> "Unknown tool: " <> name|>
        ];
        
        Join[result, <|"ToolName" -> name, "ToolId" -> tid|>]
      ]],
    toolCalls];

(* ── 8c. Expression-Proposal 実行 (従来フロー) ── *)

iExecuteAndContinue[runtimeId_String, adapter_Association,
    proposal_Association, validationResult_Association,
    contextPacket_Association] :=
  Module[{execResult, redacted, rt, shouldCont},
    iUpdatePhase[runtimeId, "Execute"];
    execResult = adapter["ExecuteProposal"][proposal, validationResult];
    rt = $iClaudeRuntimes[runtimeId];
    rt["LastExecutionResult"] = execResult;
    $iClaudeRuntimes[runtimeId] = rt;
    
    If[!TrueQ[Lookup[execResult, "Success", False]],
      iAppendEvent[runtimeId, <|"Type" -> "ExecutionFailed",
        "Error" -> Lookup[execResult, "Error", "?"]|>];
      Module[{fc = ClaudeClassifyFailure[
          Lookup[execResult, "Error", "unknown"]]},
        If[TrueQ[fc["Retryable"]] &&
           iConsumeBudget[runtimeId, "MaxExecutionRetries"],
          iScheduleRepairTurn[runtimeId,
            "Execution failed: " <> Lookup[execResult, "Error", ""]];
          Return[<|"Outcome" -> "ExecutionRetryScheduled"|>]]];
      iRecordFatalFailure[runtimeId, execResult];
      Return[<|"Outcome" -> "ExecutionFailed"|>]];
    
    iUpdatePhase[runtimeId, "Redact"];
    redacted = adapter["RedactResult"][execResult, contextPacket];
    iAppendEvent[runtimeId, <|"Type" -> "ResultRedacted"|>];
    
    iUpdatePhase[runtimeId, "ContinuationCheck"];
    rt = $iClaudeRuntimes[runtimeId];
    shouldCont = adapter["ShouldContinue"][
      redacted, rt["ConversationState"], rt["TurnCount"]];
    
    (* ── Messages 蓄積: 反復ループ用ターン履歴 ── *)
    Module[{msgs, proposalCode, proposalText, turnMsg},
      msgs = Lookup[rt["ConversationState"], "Messages", {}];
      proposalCode = If[AssociationQ[proposal],
        Lookup[proposal, "RawCode", None], None];
      proposalText = If[AssociationQ[proposal],
        Lookup[proposal, "TextResponse", None], None];
      turnMsg = <|
        "Turn"           -> rt["TurnCount"],
        "ProposedCode"   -> proposalCode,
        "TextResponse"   -> proposalText,
        "ExecutionResult" -> redacted,
        "Timestamp"      -> AbsoluteTime[]
      |>;
      rt["ConversationState"] = <|
        "Messages"   -> iCompactConversationHistory[
          Append[msgs, turnMsg],
          $MaxDetailedMessages, $MaxConversationMessages],
        "LastResult"  -> redacted,
        "OriginalTask" -> Lookup[rt["ConversationState"], "OriginalTask",
          rt["ContinuationInput"]]
      |>];
    $iClaudeRuntimes[runtimeId] = rt;
    
    If[TrueQ[shouldCont] &&
       !iBudgetExhaustedQ[runtimeId, "MaxProposalIterations"],
      iConsumeBudget[runtimeId, "MaxProposalIterations"];
      iAppendEvent[runtimeId, <|"Type" -> "ContinuationScheduled"|>];
      (* ContinuationInput: 構造化された継続メッセージ *)
      Module[{cur = $iClaudeRuntimes[runtimeId]},
        cur["ContinuationInput"] = <|
          "Type"            -> "Continuation",
          "OriginalTask"    -> Lookup[cur["ConversationState"],
                                "OriginalTask", ""],
          "PreviousResult"  -> redacted,
          "TurnHistory"     -> Lookup[cur["ConversationState"],
                                "Messages", {}]
        |>;
        $iClaudeRuntimes[runtimeId] = cur];
      <|"Outcome" -> "ContinuationPending"|>,
      
      iUpdateStatus[runtimeId, "Done"];
      iAppendEvent[runtimeId, <|"Type" -> "TurnComplete"|>];
      <|"Outcome" -> "Done", "Result" -> redacted|>
    ]
  ];

(* ════════════════════════════════════════════════════════
   8b. Transaction パイプライン (UpdatePackage 用)
   
   Snapshot → ShadowApply → StaticCheck → ReloadCheck
     → TestPhase → Commit
   失敗時: Rollback → RepairTurn or Fatal
   ════════════════════════════════════════════════════════ *)

iTransactionExecute[runtimeId_String, adapter_Association,
    proposal_Association, validationResult_Association,
    contextPacket_Association] :=
  Module[{snapshotInfo, shadowResult, staticResult, reloadResult,
          testResult, commitResult, rt, repairInfo, failCount,
          iSaveCP, iRecordPF, iFullReplan},
    
    (* ── ローカルヘルパー (関数解決の問題を回避) ── *)
    iSaveCP[phase_] := (
      Module[{cur = $iClaudeRuntimes[runtimeId]},
        cur["CheckpointStack"] = Append[
          Lookup[cur, "CheckpointStack", {}],
          <|"Phase" -> phase, "Timestamp" -> AbsoluteTime[]|>];
        $iClaudeRuntimes[runtimeId] = cur];
      iAppendEvent[runtimeId, <|"Type" -> "CheckpointSaved",
        "Phase" -> phase|>]);
    
    iRecordPF[phase_] := Module[{cur, counts},
      cur = $iClaudeRuntimes[runtimeId];
      If[!AssociationQ[cur], Return[0]];
      counts = Lookup[
        Lookup[cur, "TransactionState", <||>],
        "PhaseFailureCounts", <||>];
      counts[phase] = Lookup[counts, phase, 0] + 1;
      If[AssociationQ[cur["TransactionState"]],
        cur["TransactionState"]["PhaseFailureCounts"] = counts,
        cur["TransactionState"] = <|"PhaseFailureCounts" -> counts|>];
      $iClaudeRuntimes[runtimeId] = cur;
      counts[phase]];
    
    iFullReplan[adpt_, si_, fp_, ed_] := Module[{},
      If[!iConsumeBudget[runtimeId, "MaxFullReplans"], Return[False]];
      iAppendEvent[runtimeId, <|"Type" -> "FullReplanAttempt",
        "FailedPhase" -> fp|>];
      iRollbackAndRepair[runtimeId, adpt, si,
        <|"Hint" -> "Previous patch repeatedly failed at " <> fp <>
            ". Please generate a completely new approach.",
          "FailedPhase" -> fp,
          "ErrorDetails" -> ed,
          "RepairStrategy" -> "FullReplan",
          "FailureCount" -> Lookup[
            Lookup[
              Lookup[$iClaudeRuntimes[runtimeId],
                "TransactionState", <||>],
              "PhaseFailureCounts", <||>],
            fp, 0]|>];
      True];
    
    (* ── Step 1: Snapshot ── *)
    iUpdatePhase[runtimeId, "Snapshot"];
    snapshotInfo = Quiet @ Check[
      adapter["SnapshotPackage"][contextPacket], $Failed];
    If[!AssociationQ[snapshotInfo] || !TrueQ[Lookup[snapshotInfo, "Success", True]],
      iAppendEvent[runtimeId, <|"Type" -> "SnapshotFailed"|>];
      iRecordFatalFailure[runtimeId,
        <|"ReasonClass" -> "SnapshotFailed",
          "Error" -> "Could not snapshot package"|>];
      Return[<|"Outcome" -> "Failed", "Reason" -> "SnapshotFailed"|>]];
    
    rt = $iClaudeRuntimes[runtimeId];
    rt["TransactionState"] = <|
      "SnapshotInfo" -> snapshotInfo,
      "Phase" -> "Snapshot",
      "PhaseFailureCounts" -> Lookup[
        Lookup[rt, "TransactionState", <||>],
        "PhaseFailureCounts", <||>]|>;
    $iClaudeRuntimes[runtimeId] = rt;
    iAppendEvent[runtimeId, <|"Type" -> "SnapshotCreated",
      "SnapshotId" -> Lookup[snapshotInfo, "SnapshotId", "?"]|>];
    iSaveCP["Snapshot"];
    
    (* ── Step 2: ShadowApply ── *)
    iUpdatePhase[runtimeId, "ShadowApply"];
    shadowResult = Quiet @ Check[
      adapter["ApplyToShadow"][proposal, snapshotInfo], $Failed];
    If[!AssociationQ[shadowResult] || !TrueQ[shadowResult["Success"]],
      failCount = iRecordPF["ShadowApply"];
      repairInfo = <|
        "Hint" -> "Patch apply failed: " <>
          If[AssociationQ[shadowResult],
            Lookup[shadowResult, "Error", "unknown"], "unknown"],
        "FailedPhase" -> "ShadowApply",
        "ErrorDetails" -> If[AssociationQ[shadowResult],
          Lookup[shadowResult, "Error", None], None],
        "RepairStrategy" -> "Patch",
        "FailureCount" -> failCount|>;
      iAppendEvent[runtimeId, <|"Type" -> "ShadowApplyFailed",
        "Error" -> repairInfo["Hint"],
        "FailureCount" -> failCount|>];
      If[iConsumeBudget[runtimeId, "MaxPatchApplyRetries"],
        iRollbackAndRepair[runtimeId, adapter, snapshotInfo, repairInfo];
        Return[<|"Outcome" -> "RepairScheduled",
          "Phase" -> "ShadowApply"|>]];
      If[iFullReplan[adapter, snapshotInfo,
          "ShadowApply", repairInfo["ErrorDetails"]],
        Return[<|"Outcome" -> "RepairScheduled",
          "Phase" -> "ShadowApply", "Strategy" -> "FullReplan"|>]];
      iRollbackAndFail[runtimeId, adapter, snapshotInfo,
        <|"ReasonClass" -> "PatchApplyConflict",
          "Error" -> repairInfo["Hint"]|>];
      Return[<|"Outcome" -> "Failed", "Reason" -> "PatchApplyConflict"|>]];
    
    iUpdateTransactionPhase[runtimeId, "ShadowApply"];
    iAppendEvent[runtimeId, <|"Type" -> "ShadowApplied",
      "ShadowPath" -> Lookup[shadowResult, "ShadowPath", "?"]|>];
    iSaveCP["ShadowApply"];
    
    (* ── Step 3: StaticCheck ── *)
    iUpdatePhase[runtimeId, "StaticCheck"];
    staticResult = Quiet @ Check[
      adapter["StaticCheck"][shadowResult], $Failed];
    If[!AssociationQ[staticResult] || !TrueQ[staticResult["Success"]],
      failCount = iRecordPF["StaticCheck"];
      repairInfo = <|
        "Hint" -> "Static check failed: " <>
          If[AssociationQ[staticResult],
            ToString[Short[Lookup[staticResult, "Errors", {}], 3]],
            "unknown"],
        "FailedPhase" -> "StaticCheck",
        "ErrorDetails" -> If[AssociationQ[staticResult],
          Lookup[staticResult, "Errors", {}], {}],
        "RepairStrategy" -> "Patch",
        "FailureCount" -> failCount|>;
      iAppendEvent[runtimeId, <|"Type" -> "StaticCheckFailed",
        "Errors" -> If[AssociationQ[staticResult],
          Lookup[staticResult, "Errors", {}], {}],
        "FailureCount" -> failCount|>];
      If[iConsumeBudget[runtimeId, "MaxPatchApplyRetries"],
        iRollbackAndRepair[runtimeId, adapter, snapshotInfo, repairInfo];
        Return[<|"Outcome" -> "RepairScheduled",
          "Phase" -> "StaticCheck"|>]];
      If[iFullReplan[adapter, snapshotInfo,
          "StaticCheck", repairInfo["ErrorDetails"]],
        Return[<|"Outcome" -> "RepairScheduled",
          "Phase" -> "StaticCheck", "Strategy" -> "FullReplan"|>]];
      iRollbackAndFail[runtimeId, adapter, snapshotInfo,
        <|"ReasonClass" -> "StaticCheckFailed",
          "Error" -> repairInfo["Hint"]|>];
      Return[<|"Outcome" -> "Failed", "Reason" -> "StaticCheckFailed"|>]];
    
    iUpdateTransactionPhase[runtimeId, "StaticCheck"];
    iAppendEvent[runtimeId, <|"Type" -> "StaticCheckPassed"|>];
    iSaveCP["StaticCheck"];
    
    (* ── Step 4: ReloadCheck ── *)
    iUpdatePhase[runtimeId, "ReloadCheck"];
    reloadResult = Quiet @ Check[
      adapter["ReloadCheck"][shadowResult], $Failed];
    If[!AssociationQ[reloadResult] || !TrueQ[reloadResult["Success"]],
      failCount = iRecordPF["ReloadCheck"];
      repairInfo = <|
        "Hint" -> "Reload check failed: " <>
          If[AssociationQ[reloadResult],
            Lookup[reloadResult, "Error", "unknown"], "unknown"],
        "FailedPhase" -> "ReloadCheck",
        "ErrorDetails" -> If[AssociationQ[reloadResult],
          KeyDrop[reloadResult, {"Success"}], None],
        "RepairStrategy" -> "Patch",
        "FailureCount" -> failCount|>;
      iAppendEvent[runtimeId, <|"Type" -> "ReloadCheckFailed",
        "Error" -> repairInfo["Hint"],
        "FailureCount" -> failCount|>];
      If[iConsumeBudget[runtimeId, "MaxReloadRepairs"],
        iRollbackAndRepair[runtimeId, adapter, snapshotInfo, repairInfo];
        Return[<|"Outcome" -> "RepairScheduled",
          "Phase" -> "ReloadCheck"|>]];
      If[iFullReplan[adapter, snapshotInfo,
          "ReloadCheck", repairInfo["ErrorDetails"]],
        Return[<|"Outcome" -> "RepairScheduled",
          "Phase" -> "ReloadCheck", "Strategy" -> "FullReplan"|>]];
      iRollbackAndFail[runtimeId, adapter, snapshotInfo,
        <|"ReasonClass" -> "ReloadError",
          "Error" -> repairInfo["Hint"]|>];
      Return[<|"Outcome" -> "Failed", "Reason" -> "ReloadError"|>]];
    
    iUpdateTransactionPhase[runtimeId, "ReloadCheck"];
    iAppendEvent[runtimeId, <|"Type" -> "ReloadCheckPassed"|>];
    iSaveCP["ReloadCheck"];
    
    (* ── Step 5: TestPhase ── *)
    iUpdatePhase[runtimeId, "TestPhase"];
    testResult = Quiet @ Check[
      adapter["RunTests"][shadowResult, contextPacket], $Failed];
    If[!AssociationQ[testResult] || !TrueQ[testResult["Success"]],
      failCount = iRecordPF["TestPhase"];
      repairInfo = <|
        "Hint" -> "Tests failed: " <>
          If[AssociationQ[testResult],
            "Passed=" <> ToString[Lookup[testResult, "Passed", 0]] <>
            " Failed=" <> ToString[Lookup[testResult, "Failed", 0]],
            "unknown"],
        "FailedPhase" -> "TestPhase",
        "ErrorDetails" -> If[AssociationQ[testResult],
          KeyDrop[testResult, {"Success"}], None],
        "RepairStrategy" -> "Patch",
        "FailureCount" -> failCount|>;
      iAppendEvent[runtimeId, <|"Type" -> "TestsFailed",
        "Passed" -> If[AssociationQ[testResult],
          Lookup[testResult, "Passed", 0], 0],
        "Failed" -> If[AssociationQ[testResult],
          Lookup[testResult, "Failed", 0], 0],
        "FailureCount" -> failCount|>];
      If[iConsumeBudget[runtimeId, "MaxTestRepairs"],
        iRollbackAndRepair[runtimeId, adapter, snapshotInfo, repairInfo];
        Return[<|"Outcome" -> "RepairScheduled",
          "Phase" -> "TestPhase"|>]];
      If[iFullReplan[adapter, snapshotInfo,
          "TestPhase", repairInfo["ErrorDetails"]],
        Return[<|"Outcome" -> "RepairScheduled",
          "Phase" -> "TestPhase", "Strategy" -> "FullReplan"|>]];
      iRollbackAndFail[runtimeId, adapter, snapshotInfo,
        <|"ReasonClass" -> "TestFailure",
          "Error" -> repairInfo["Hint"]|>];
      Return[<|"Outcome" -> "Failed", "Reason" -> "TestFailure"|>]];
    
    iUpdateTransactionPhase[runtimeId, "TestPhase"];
    iAppendEvent[runtimeId, <|"Type" -> "TestsPassed",
      "Passed" -> Lookup[testResult, "Passed", 0]|>];
    iSaveCP["TestPhase"];
    
    (* ── Step 6: Commit ── *)
    iUpdatePhase[runtimeId, "Commit"];
    commitResult = Quiet @ Check[
      adapter["CommitTransaction"][shadowResult, snapshotInfo], $Failed];
    If[!AssociationQ[commitResult] || !TrueQ[commitResult["Success"]],
      iAppendEvent[runtimeId, <|"Type" -> "CommitFailed"|>];
      iRollbackAndFail[runtimeId, adapter, snapshotInfo,
        <|"ReasonClass" -> "CommitFailed",
          "Error" -> "Commit failed after all checks passed"|>];
      Return[<|"Outcome" -> "Failed", "Reason" -> "CommitFailed"|>]];
    
    iUpdateTransactionPhase[runtimeId, "Committed"];
    iAppendEvent[runtimeId, <|"Type" -> "TransactionCommitted"|>];
    
    (* ── 完了: redact + continuation check ── *)
    Module[{redacted, shouldCont},
      iUpdatePhase[runtimeId, "Redact"];
      redacted = adapter["RedactResult"][
        <|"Success" -> True,
          "RawResult" -> "Transaction committed successfully. " <>
            "Tests: " <> ToString[Lookup[testResult, "Passed", 0]] <>
            " passed"|>,
        contextPacket];
      iAppendEvent[runtimeId, <|"Type" -> "ResultRedacted"|>];
      
      iUpdatePhase[runtimeId, "ContinuationCheck"];
      rt = $iClaudeRuntimes[runtimeId];
      shouldCont = adapter["ShouldContinue"][
        redacted, rt["ConversationState"], rt["TurnCount"]];
      rt["ConversationState"] = Append[rt["ConversationState"],
        "LastResult" -> redacted];
      $iClaudeRuntimes[runtimeId] = rt;
      
      If[TrueQ[shouldCont] &&
         !iBudgetExhaustedQ[runtimeId, "MaxProposalIterations"],
        iConsumeBudget[runtimeId, "MaxProposalIterations"];
        iAppendEvent[runtimeId, <|"Type" -> "ContinuationScheduled"|>];
        Module[{cur = $iClaudeRuntimes[runtimeId]},
          cur["ContinuationInput"] = redacted;
          $iClaudeRuntimes[runtimeId] = cur];
        <|"Outcome" -> "ContinuationPending"|>,
        
        iUpdateStatus[runtimeId, "Done"];
        iAppendEvent[runtimeId, <|"Type" -> "TurnComplete"|>];
        <|"Outcome" -> "Done", "Result" -> redacted|>
      ]
    ]
  ];

(* ── Transaction ヘルパー ── *)

iUpdateTransactionPhase[runtimeId_String, phase_String] :=
  Module[{rt = $iClaudeRuntimes[runtimeId]},
    If[AssociationQ[rt],
      rt["TransactionState"]["Phase"] = phase;
      $iClaudeRuntimes[runtimeId] = rt]];

iRollbackAndRepair[runtimeId_String, adapter_Association,
    snapshotInfo_Association, repairInfo_] :=
  Module[{},
    iUpdatePhase[runtimeId, "Rollback"];
    Quiet @ adapter["RollbackTransaction"][snapshotInfo];
    iAppendEvent[runtimeId, <|"Type" -> "RolledBack"|>];
    If[AssociationQ[repairInfo],
      iScheduleRepairTurn[runtimeId, repairInfo],
      iScheduleRepairTurn[runtimeId, ToString[repairInfo]]]];

iRollbackAndFail[runtimeId_String, adapter_Association,
    snapshotInfo_Association, detail_Association] :=
  Module[{},
    iUpdatePhase[runtimeId, "Rollback"];
    Quiet @ adapter["RollbackTransaction"][snapshotInfo];
    iAppendEvent[runtimeId, <|"Type" -> "RolledBack"|>];
    iRecordFatalFailure[runtimeId, detail]];

(* ════════════════════════════════════════════════════════
   9. Turn 完了コールバック
   ════════════════════════════════════════════════════════ *)

iOnTurnComplete[runtimeId_String, completedJob_Association] :=
  Module[{rt, dispatchResult, outcome, callback, nodes, saved},
    rt = $iClaudeRuntimes[runtimeId];
    If[!AssociationQ[rt], Return[]];
    
    (* DAG ジョブは完了後に $iLLMGraphDAGJobs から削除されるため、
       ジョブ全体を RuntimeState に保存して事後照会・Plot を可能にする。
       handler (Function) と runState は保存不要なので除外。 *)
    nodes = Lookup[completedJob, "nodes", <||>];
    If[AssociationQ[nodes],
      saved = Association @ Map[
        KeyDrop[#, {"handler", "runState"}] &,
        nodes];
      rt["CompletedDAGJob"] = Append[
        KeyDrop[completedJob, {"nodes", "onComplete"}],
        "nodes" -> saved];
      rt["CompletedDAGNodes"] = saved;
      $iClaudeRuntimes[runtimeId] = rt];
    
    dispatchResult = Lookup[
      Lookup[completedJob["nodes"], "dispatchDecision", <||>],
      "result", None];
    outcome = If[AssociationQ[dispatchResult],
      Lookup[dispatchResult, "Outcome", "?"], "?"];
    
    (* Phase 31 (IsPlannerTurn / DecompositionStatus) 分岐は撤去。
       タスク分解は ClaudeOrchestrator.wl が担うため、このランタイム核は
       プレーンな 1 ターン実行に専念する。 *)
    
    If[outcome === "ContinuationPending" || outcome === "RepairScheduled",
      Module[{contInput = rt["ContinuationInput"],
              nb = Lookup[completedJob, "nb", $Failed]},
        iUpdateStatus[runtimeId, "Done"];
        ClaudeRunTurn[runtimeId, contInput, "Notebook" -> nb]];
      Return[]];
    
    (* ── Phase 16d: 非同期結果通知 ──
       ターン完了 (Done / Failed / AwaitingApproval) 時に
       Metadata["NotebookCallback"] があれば呼び出す。
       claudecode の iRuntimeDisplayResult が結果を notebook に書き込む。 *)
    callback = Lookup[Lookup[rt, "Metadata", <||>], "NotebookCallback", None];
    If[callback =!= None,
      Quiet[callback[runtimeId]]];
  ];

(* ════════════════════════════════════════════════════════
   10. Repair / failure recording / checkpoint
   ════════════════════════════════════════════════════════ *)

(* ── Structured repair turn: Association 形式で失敗コンテキストを伝達 ── *)
iScheduleRepairTurn[runtimeId_String, repairInfo_Association] :=
  Module[{rt = $iClaudeRuntimes[runtimeId]},
    rt["ContinuationInput"] = Join[
      <|"Type"     -> "RepairRequest",
        "Previous" -> rt["LastProposal"]|>,
      repairInfo];
    $iClaudeRuntimes[runtimeId] = rt;
  ];

(* 後方互換: 文字列ヒントのみの場合 *)
iScheduleRepairTurn[runtimeId_String, repairHint_String] :=
  iScheduleRepairTurn[runtimeId, <|"Hint" -> repairHint|>];

(* ── Checkpoint 管理 ── *)
iSaveCheckpoint[runtimeId_String, phase_String, data_Association] :=
  Module[{rt = $iClaudeRuntimes[runtimeId]},
    If[!AssociationQ[rt], Return[]];
    rt["CheckpointStack"] = Append[
      Lookup[rt, "CheckpointStack", {}],
      <|"Phase" -> phase, "Data" -> data,
        "Timestamp" -> AbsoluteTime[]|>];
    $iClaudeRuntimes[runtimeId] = rt;
    iAppendEvent[runtimeId, <|"Type" -> "CheckpointSaved",
      "Phase" -> phase|>];
  ];

iGetLatestCheckpoint[runtimeId_String] :=
  Module[{rt = $iClaudeRuntimes[runtimeId]},
    If[!AssociationQ[rt], Return[None]];
    Module[{stack = Lookup[rt, "CheckpointStack", {}]},
      If[Length[stack] > 0, Last[stack], None]]];

(* ── Per-phase failure tracking ── *)
iRecordPhaseFailure[runtimeId_String, phase_String] :=
  Module[{rt = $iClaudeRuntimes[runtimeId], counts},
    If[!AssociationQ[rt], Return[0]];
    counts = Lookup[rt["TransactionState"], "PhaseFailureCounts", <||>];
    counts[phase] = Lookup[counts, phase, 0] + 1;
    rt["TransactionState"]["PhaseFailureCounts"] = counts;
    $iClaudeRuntimes[runtimeId] = rt;
    counts[phase]
  ];

iGetPhaseFailureCount[runtimeId_String, phase_String] :=
  Module[{rt = $iClaudeRuntimes[runtimeId]},
    If[!AssociationQ[rt], Return[0]];
    Lookup[
      Lookup[rt["TransactionState"], "PhaseFailureCounts", <||>],
      phase, 0]
  ];

(* ── Full replan: 同一フェーズで repair が尽きた場合の最終手段 ── *)
iAttemptFullReplan[runtimeId_String, adapter_Association,
    snapshotInfo_Association, failedPhase_String,
    errorDetails_] :=
  Module[{},
    If[!iConsumeBudget[runtimeId, "MaxFullReplans"],
      Return[False]];
    iAppendEvent[runtimeId, <|"Type" -> "FullReplanAttempt",
      "FailedPhase" -> failedPhase|>];
    iRollbackAndRepair[runtimeId, adapter, snapshotInfo,
      <|"Hint" -> "Previous patch repeatedly failed at " <> failedPhase <>
          ". Please generate a completely new approach.",
        "FailedPhase" -> failedPhase,
        "ErrorDetails" -> errorDetails,
        "RepairStrategy" -> "FullReplan",
        "FailureCount" ->
          iGetPhaseFailureCount[runtimeId, failedPhase]|>];
    True
  ];

(* v2026-04-20 T11: Runtime \:304c Fatal \:306b\:306a\:3063\:305f\:6642\:306b\:3001\:305d\:306e Runtime \:306b\:5c5e\:3059\:308b
   \:3059\:3079\:3066\:306e LLMGraph DAG \:30b8\:30e7\:30d6\:3092\:5373\:6642\:306b\:30ad\:30e3\:30f3\:30bb\:30eb\:3059\:308b\:3002
   T10 \:3067 iLLMGraphDAGTick \:306b\:30ac\:30fc\:30c9\:3092\:5165\:308c\:305f\:304c\:3001
   ClaudeRuntime\`Private\`$iClaudeRuntimes \:3092 claudecode.wl \:304b\:3089\:53c2\:7167\:3059\:308b\:30d1\:30b9\:304c
   Private context \:306e\:305f\:3081\:52b9\:304b\:305a\:3001cascade failure \:304c\:6bce tick \:767a\:751f\:3057\:3066\:3044\:305f\:3002
   T11 \:3067\:306f ClaudeRuntime.wl \:5074 (\:540c\:30d1\:30c3\:30b1\:30fc\:30b8\:5185) \:304b\:3089 
   ClaudeCode\`$iLLMGraphDAGJobs \:3092\:76f4\:63a5\:64cd\:4f5c\:3059\:308b\:3002 *)
iAbortRuntimeDAGs[runtimeId_String] :=
  Module[{jobs, matchingIds, abortCount = 0},
    jobs = Quiet @ Check[ClaudeCode`$iLLMGraphDAGJobs, <||>];
    If[!AssociationQ[jobs], Return[0, Module]];
    matchingIds = Quiet @ Check[
      Select[Keys[jobs],
        Function[jid,
          Module[{j = Lookup[jobs, jid, <||>], ctx, rid},
            If[!AssociationQ[j], Return[False, Module]];
            ctx = Lookup[j, "context", <||>];
            If[!AssociationQ[ctx], Return[False, Module]];
            rid = Lookup[ctx, "runtimeId", None];
            StringQ[rid] && rid === runtimeId]]],
      {}];
    If[!ListQ[matchingIds], matchingIds = {}];
    Scan[Function[jid,
      Module[{job = Quiet @ jobs[jid], nodes, nkeys, nd, nodeAborted = False},
        If[!AssociationQ[job], Return[Null, Module]];
        nodes = Lookup[job, "nodes", <||>];
        If[!AssociationQ[nodes], Return[Null, Module]];
        nkeys = Keys[nodes];
        Do[
          nd = Lookup[nodes, k, <||>];
          If[AssociationQ[nd] &&
             MemberQ[{"pending", "running"}, Lookup[nd, "status", ""]],
            nd["status"] = "cancelled";
            nd["error"] = "Runtime Failed; node execution aborted (T11)";
            nd["result"] = None;
            nodes[k] = nd;
            nodeAborted = True],
          {k, nkeys}];
        If[nodeAborted,
          job["nodes"] = nodes;
          job["completedAt"] = AbsoluteTime[];
          Quiet[ClaudeCode`$iLLMGraphDAGJobs[jid] = job];
          abortCount++]]],
      matchingIds];
    abortCount];
iAbortRuntimeDAGs[_] := 0;

iRecordFatalFailure[runtimeId_String, detail_] :=
  Module[{rt = $iClaudeRuntimes[runtimeId]},
    rt["LastFailure"] = detail;
    rt["FailureHistory"] = Append[rt["FailureHistory"], detail];
    $iClaudeRuntimes[runtimeId] = rt;
    iUpdateStatus[runtimeId, "Failed"];
    iAppendEvent[runtimeId, <|"Type" -> "FatalFailure",
      "Detail" -> If[AssociationQ[detail],
        Lookup[detail, "ReasonClass",
          Lookup[detail, "Error", "?"]],
        ToString[Short[detail, 2]]]|>];
    (* v2026-04-20 T11: \:95a2\:9023 DAG \:30b8\:30e7\:30d6\:3092\:5373\:6642\:306b\:30ad\:30e3\:30f3\:30bb\:30eb\:3057\:3001
       tick \:304c cascade failure \:3092\:767a\:751f\:3055\:305b\:3089\:308c\:306a\:3044\:3088\:3046\:306b\:3059\:308b\:3002 *)
    Quiet @ Check[iAbortRuntimeDAGs[runtimeId], 0];
  ];

(* ════════════════════════════════════════════════════════
   11. ClaudeContinueTurn
   ════════════════════════════════════════════════════════ *)

ClaudeContinueTurn[runtimeId_String] :=
  Module[{rt = $iClaudeRuntimes[runtimeId], contInput},
    If[!AssociationQ[rt],
      Return[Missing["RuntimeNotFound", runtimeId]]];
    contInput = rt["ContinuationInput"];
    If[contInput === None, Return[Missing["NoContinuation"]]];
    ClaudeRunTurn[runtimeId, contInput]
  ];

(* ════════════════════════════════════════════════════════
   12. Approval
   ════════════════════════════════════════════════════════ *)

ClaudeApproveProposal[runtimeId_String] :=
  Module[{rt, pending, adapter, proposal, valResult, ctxPacket, result},
    rt = $iClaudeRuntimes[runtimeId];
    If[!AssociationQ[rt] || rt["Status"] =!= "AwaitingApproval",
      Return[Missing["NotAwaitingApproval"]]];
    pending   = rt["PendingApproval"];
    adapter   = rt["Adapter"];
    proposal  = pending["Proposal"];
    valResult = pending["ValidationResult"];
    ctxPacket = pending["ContextPacket"];
    rt["PendingApproval"] = None;
    $iClaudeRuntimes[runtimeId] = rt;
    iUpdateStatus[runtimeId, "Running"];
    iAppendEvent[runtimeId, <|"Type" -> "ApprovalGranted"|>];
    result = iExecuteAndContinue[runtimeId, adapter, proposal, valResult, ctxPacket];
    (* DAG 外で呼ばれるため onComplete が発火しない → 手動で continuation 起動 *)
    If[AssociationQ[result] &&
       Lookup[result, "Outcome", ""] === "ContinuationPending",
      Module[{contInput = $iClaudeRuntimes[runtimeId]["ContinuationInput"]},
        iUpdateStatus[runtimeId, "Done"];
        ClaudeRunTurn[runtimeId, contInput, "Notebook" -> $Failed]]];
    result
  ];

ClaudeDenyProposal[runtimeId_String] :=
  Module[{rt},
    rt = $iClaudeRuntimes[runtimeId];
    If[!AssociationQ[rt] || rt["Status"] =!= "AwaitingApproval",
      Return[Missing["NotAwaitingApproval"]]];
    rt["PendingApproval"] = None;
    $iClaudeRuntimes[runtimeId] = rt;
    iRecordFatalFailure[runtimeId, <|"ReasonClass" -> "UserDenied"|>];
    "Denied"
  ];

(* ════════════════════════════════════════════════════════
   13. 状態照会
   ════════════════════════════════════════════════════════ *)

ClaudeRuntimeState[runtimeId_String] :=
  Module[{rt = $iClaudeRuntimes[runtimeId]},
    If[!AssociationQ[rt], Return[Missing["RuntimeNotFound", runtimeId]]];
    (* FrontEnd シリアライズ負荷軽減のため、NotebookObject, Function,
       Adapter 等を含む重いキーを除外。これらが必要な場合は
       ClaudeRuntimeStateFull[rid] または $iClaudeRuntimes[rid] を直接参照。 *)
    KeyDrop[rt, {
      "Adapter",
      "Metadata",                   (* NotebookCallback=Function を含む *)
      "CompletedDAGJob",            (* 巨大 *)
      "CompletedDAGNodes",          (* 巨大 *)
      "OriginalRetryPolicy",        (* 別途 RetryPolicy キーにある *)
      "LastContextPacket",          (* 巨大 *)
      "LastProviderResponse",       (* 巨大 *)
      "LastParseResult",            (* 巨大 *)
      "ConversationState"           (* メッセージ履歴で巨大 *)
      (* LastExecutionResult は保持 (最終結果の参照に使う) *)
    }]
  ];

(* 完全な RuntimeState が必要な場合の専用 API。Dynamic や直接評価での
   使用は避けること (FrontEnd がブロックする可能性)。 *)
ClaudeRuntimeStateFull[runtimeId_String] :=
  Module[{rt = $iClaudeRuntimes[runtimeId]},
    If[!AssociationQ[rt], Return[Missing["RuntimeNotFound", runtimeId]]];
    KeyDrop[rt, {"Adapter"}]
  ];

ClaudeTurnTrace[runtimeId_String] :=
  Module[{rt = $iClaudeRuntimes[runtimeId]},
    If[!AssociationQ[rt], Return[Missing["RuntimeNotFound", runtimeId]]];
    rt["EventTrace"]
  ];

ClaudeRuntimeCancel[runtimeId_String] :=
  Module[{rt = $iClaudeRuntimes[runtimeId], jobId},
    If[!AssociationQ[rt], Return[$Failed]];
    jobId = rt["CurrentJobId"];
    If[StringQ[jobId], ClaudeCode`LLMGraphDAGCancel[jobId]];
    iUpdateStatus[runtimeId, "Failed"];
    iAppendEvent[runtimeId, <|"Type" -> "Cancelled"|>];
    runtimeId
  ];

(* ════════════════════════════════════════════════════════
   ClaudeRuntimeRetry — 直前ターンの Failed ノードを再実行
   
   処理フロー:
     Case 1: アクティブ DAG ジョブが $iLLMGraphDAGJobs に残っていれば
             → LLMGraphDAGStop → LLMGraphDAGRetry に委譲
     Case 2: ターン完了済み (CompletedDAGNodes あり) なら
             → iMakeTurnNodes でハンドラーを再構築
             → Done ノードの結果を移植
             → 新 DAG ジョブとして再登録・起動
   
   TurnCount は増やさない (同一ターンのリトライ)。
   ════════════════════════════════════════════════════════ *)

ClaudeRuntimeRetry[runtimeId_String] :=
  Module[{rt, adapter, completedNodes, failedIds, input,
          nb, newNodes, jobId, turnCount, isSync},
    rt = $iClaudeRuntimes[runtimeId];
    If[!AssociationQ[rt],
      Print[Style[iL[
        "\[WarningSign] RuntimeId \:304c\:898b\:3064\:304b\:308a\:307e\:305b\:3093: " <> runtimeId,
        "\[WarningSign] RuntimeId not found: " <> runtimeId], Red]];
      Return[Missing["RuntimeNotFound", runtimeId]]];
    
    (* ── Case 1: \:30a2\:30af\:30c6\:30a3\:30d6 DAG \:30b8\:30e7\:30d6\:304c\:6b8b\:3063\:3066\:3044\:308b\:5834\:5408 ── *)
    Module[{activeJobId = Lookup[rt, "CurrentJobId", None],
            activeJob},
      If[StringQ[activeJobId],
        activeJob = Quiet @
          ClaudeCode`Private`$iLLMGraphDAGJobs[activeJobId];
        If[AssociationQ[activeJob],
          Module[{statuses = Lookup[#, "status", "?"] & /@
                    Values[activeJob["nodes"]],
                  hasRunning, hasFailed},
            hasRunning = MemberQ[statuses, "running"];
            hasFailed  = MemberQ[statuses, "failed"];
            If[hasRunning,
              ClaudeCode`LLMGraphDAGStop[activeJobId]];
            If[hasFailed || hasRunning,
              iUpdateStatus[runtimeId, "Running"];
              iAppendEvent[runtimeId,
                <|"Type" -> "RetryStarted",
                  "Source" -> "ActiveDAG",
                  "JobId" -> activeJobId|>];
              Print[Style[iL[
                "\[FilledSquare] \:30a2\:30af\:30c6\:30a3\:30d6 DAG \:306e\:30ea\:30c8\:30e9\:30a4: " <> activeJobId,
                "\[FilledSquare] Retrying active DAG: " <> activeJobId],
                Bold]];
              ClaudeCode`LLMGraphDAGRetry[activeJobId];
              Return[activeJobId],
              Print[iL[
                "  \:30ea\:30c8\:30e9\:30a4\:5bfe\:8c61\:306e\:30ce\:30fc\:30c9\:304c\:3042\:308a\:307e\:305b\:3093\:3002",
                "  No nodes to retry."]];
              Return[Missing["NoFailedNodes", activeJobId]]]]]]];
    
    (* ── Case 2: \:30bf\:30fc\:30f3\:5b8c\:4e86\:6e08\:307f → DAG \:3092\:518d\:69cb\:7bc9\:3057\:3066\:30ea\:30c8\:30e9\:30a4 ── *)
    (* DAGJob プロファイルは独自ノード構造のため Case 2 では再構築不可。
       dag_job.wl による復元 (Case 1 経由) が必要。 *)
    If[Lookup[rt, "Profile", ""] === "DAGJob",
      Print[Style[iL[
        "\[WarningSign] DAGJob \:306e DAG \:30b8\:30e7\:30d6\:304c\:30e1\:30e2\:30ea\:306b\:3042\:308a\:307e\:305b\:3093\:3002\n" <>
        "  ClaudeRuntimeRestore[snapDir, \"Resume\"] \:3067\:5fa9\:5143\:3057\:3066\:304f\:3060\:3055\:3044\:3002",
        "\[WarningSign] DAGJob's DAG job not found in memory.\n" <>
        "  Use ClaudeRuntimeRestore[snapDir, \"Resume\"] to restore first."],
        Orange]];
      Return[Missing["DAGJobNotInMemory", runtimeId]]];
    If[!MemberQ[{"Done", "Failed"}, Lookup[rt, "Status", "?"]],
      Print[Style[iL[
        "\[WarningSign] Status \:304c Done/Failed \:3067\:306f\:3042\:308a\:307e\:305b\:3093: " <>
          Lookup[rt, "Status", "?"],
        "\[WarningSign] Status is not Done/Failed: " <>
          Lookup[rt, "Status", "?"]], Red]];
      Return[Missing["RuntimeBusy", rt["Status"]]]];
    
    completedNodes = Lookup[rt, "CompletedDAGNodes", <||>];
    If[!AssociationQ[completedNodes] || Length[completedNodes] === 0,
      Print[Style[iL[
        "\[WarningSign] \:5b8c\:4e86\:6e08\:307f\:30bf\:30fc\:30f3\:304c\:3042\:308a\:307e\:305b\:3093\:3002",
        "\[WarningSign] No completed turn found."], Red]];
      Return[Missing["NoCompletedTurn"]]];
    
    failedIds = Select[Keys[completedNodes],
      MemberQ[{"failed", "pending"},
        Lookup[completedNodes[#], "status", ""]] &];
    If[Length[failedIds] === 0,
      Print[iL[
        "  \:5168\:30ce\:30fc\:30c9\:304c\:6210\:529f\:6e08\:307f\:3067\:3059\:3002\:30ea\:30c8\:30e9\:30a4\:4e0d\:8981\:3002",
        "  All nodes succeeded. No retry needed."]];
      Return[Missing["NoFailedNodes"]]];
    
    adapter   = rt["Adapter"];
    input     = Lookup[rt, "ContinuationInput", ""];
    isSync    = TrueQ[Lookup[adapter, "SyncProvider", False]];
    turnCount = Lookup[rt, "TurnCount", 1];
    nb = Quiet @ Check[EvaluationNotebook[], $Failed];
    
    (* \:30cf\:30f3\:30c9\:30e9\:30fc\:4ed8\:304d\:306e\:65b0\:30ce\:30fc\:30c9\:3092\:69cb\:7bc9 *)
    newNodes = iMakeTurnNodes[runtimeId, input, adapter];
    
    (* Done \:30ce\:30fc\:30c9\:306e\:7d50\:679c\:3092\:79fb\:690d *)
    Do[
      If[KeyExistsQ[completedNodes, nid] &&
         Lookup[completedNodes[nid], "status", ""] === "done",
        Module[{n = newNodes[nid]},
          n["status"] = "done";
          n["result"] = completedNodes[nid]["result"];
          newNodes[nid] = n]],
      {nid, Keys[newNodes]}];
    
    iUpdateStatus[runtimeId, "Running"];
    
    (* \:65b0 DAG \:30b8\:30e7\:30d6\:3068\:3057\:3066\:8d77\:52d5 *)
    jobId = ClaudeCode`LLMGraphDAGCreate[<|
      "nodes"          -> newNodes,
      "taskDescriptor" -> <|
        "name"           -> iL[
          "ClaudeRuntime Turn " <> ToString[turnCount] <> " (\:30ea\:30c8\:30e9\:30a4)",
          "ClaudeRuntime Turn " <> ToString[turnCount] <> " (retry)"],
        "categoryMap"    -> <|
          "rt-context"  -> "sync",
          "rt-provider" -> If[isSync, "sync", "cli"],
          "rt-collect"  -> "sync",
          "rt-parse"    -> "sync",
          "rt-validate" -> "sync",
          "rt-dispatch" -> "sync"|>,
        "maxConcurrency" -> <|"sync" -> 99, "cli" -> 1|>
      |>,
      "nb"         -> nb,
      "context"    -> <|"runtimeId" -> runtimeId,
                        "turnCount" -> turnCount,
                        "isRetry"   -> True,
                        "detailLevel" -> "Internal"|>,
      "onComplete" -> Function[{completedJob},
        iOnTurnComplete[runtimeId, completedJob]]
    |>];
    
    Module[{cur = $iClaudeRuntimes[runtimeId]},
      cur["CurrentJobId"] = jobId;
      $iClaudeRuntimes[runtimeId] = cur];
    
    iAppendEvent[runtimeId,
      <|"Type" -> "RetryStarted",
        "Source" -> "RebuildDAG",
        "JobId" -> jobId,
        "FailedNodes" -> failedIds,
        "PreservedDone" -> Complement[Keys[completedNodes], failedIds]|>];
    
    Print[Style[iL[
      "\[FilledSquare] ClaudeRuntime \:30ea\:30c8\:30e9\:30a4\:8d77\:52d5",
      "\[FilledSquare] ClaudeRuntime retry started"], Bold]];
    Print["  JobId: ", jobId];
    Print["  ", iL["\:30ea\:30c8\:30e9\:30a4\:5bfe\:8c61: ", "Retrying: "],
      StringRiffle[failedIds, ", "],
      " (", ToString[Length[failedIds]],
      iL[" \:30ce\:30fc\:30c9)", " nodes)"]];
    Module[{doneIds = Complement[Keys[newNodes], failedIds]},
      If[Length[doneIds] > 0,
        Print["  ", iL["\:4fdd\:6301\:6e08\:307f: ", "Preserved: "],
          StringRiffle[doneIds, ", "]]]];
    
    jobId
  ];


(* ════════════════════════════════════════════════════════
   Phase 16: ConversationState メモリ管理
   
   Messages リストの無制限な成長を防止。
   古いターンを圧縮し、トークン消費を抑制しつつ文脈を保持する。
   ════════════════════════════════════════════════════════ *)

(* ── 設定 ── *)
If[!IntegerQ[$MaxConversationMessages],
  $MaxConversationMessages = 20];

If[!IntegerQ[$MaxDetailedMessages],
  $MaxDetailedMessages = 5];

(* ── 会話履歴圧縮 ──
   maxTotal 件を超えた場合、古いターンを圧縮する。
   直近 maxDetailed 件は詳細のまま保持。
   それ以前は <|"Turn"->n, "Summary"->"...", "Compacted"->True|> に変換。
   既に Compacted のものはそのまま。
*)
iCompactConversationHistory[messages_List, maxDetailed_Integer,
    maxTotal_Integer] :=
  Module[{n = Length[messages], cutoff, older, recent, compacted},
    If[n <= maxTotal, Return[messages]];
    
    (* 保持する詳細ターン数 *)
    cutoff = Max[1, n - maxDetailed + 1];
    older  = messages[[1 ;; cutoff - 1]];
    recent = messages[[cutoff ;; ]];
    
    (* 古いターンを圧縮 *)
    compacted = Map[
      Function[{msg},
        If[TrueQ[Lookup[msg, "Compacted", False]],
          msg, (* 既に圧縮済み *)
          <|"Turn"      -> Lookup[msg, "Turn", "?"],
            "Summary"   -> iMakeTurnSummary[msg],
            "Compacted" -> True,
            "Timestamp" -> Lookup[msg, "Timestamp", 0]|>
        ]],
      older];
    
    (* maxTotal を超える分は最古を削除 *)
    If[Length[compacted] + Length[recent] > maxTotal,
      compacted = compacted[[-Max[1, maxTotal - Length[recent]] ;; ]]];
    
    Join[compacted, recent]
  ];

(* ── ターン要約生成 ── *)
iMakeTurnSummary[msg_Association] :=
  Module[{code, result, text, parts = {}, toolCalls, toolResults},
    code        = Lookup[msg, "ProposedCode", None];
    result      = Lookup[msg, "ExecutionResult", None];
    text        = Lookup[msg, "TextResponse", None];
    toolCalls   = Lookup[msg, "ToolCalls", None];
    toolResults = Lookup[msg, "ToolResults", None];
    
    If[ListQ[toolCalls] && Length[toolCalls] > 0,
      AppendTo[parts, "Tools: " <> StringRiffle[
        Map[Lookup[#, "Name", "?"] &, toolCalls], ", "]]];
    If[ListQ[toolResults] && Length[toolResults] > 0,
      AppendTo[parts, "ToolResults: " <> ToString[Length[toolResults]] <>
        " results"]];
    If[StringQ[code],
      AppendTo[parts, "Code: " <> StringTake[code, UpTo[80]]]];
    If[AssociationQ[result],
      AppendTo[parts, "Result: " <> StringTake[
        Lookup[result, "Summary",
          Lookup[result, "RedactedResult", ""]], UpTo[100]]]];
    If[StringQ[text] && Length[parts] === 0,
      AppendTo[parts, "Text: " <> StringTake[text, UpTo[100]]]];
    
    If[Length[parts] === 0, iL["(空ターン)", "(empty turn)"],
      StringRiffle[parts, " | "]]
  ];

(* ── RuntimeState から全 Messages を取得 ── *)
ClaudeGetConversationMessages[runtimeId_String] :=
  Module[{rt = $iClaudeRuntimes[runtimeId]},
    If[!AssociationQ[rt], Return[{}]];
    Lookup[rt["ConversationState"], "Messages", {}]
  ];

$ClaudeRuntimeVersion = "2026-04-20T12-budget-lookup-none-guard";

End[];
EndPackage[];

(* ── $UseClaudeRuntime ──
   ClaudeRuntime.wl がロードされたら $UseClaudeRuntime = True に設定。
   ClaudeRuntime をロードする目的は runtime パスを使うことなので、
   常に True にする。 *)
ClaudeCode`$UseClaudeRuntime = True;

Print[Style[If[$Language === "Japanese",
  "ClaudeRuntime パッケージがロードされました。(v" <>
    ClaudeRuntime`$ClaudeRuntimeVersion <> ")",
  "ClaudeRuntime package loaded. (v" <>
    ClaudeRuntime`$ClaudeRuntimeVersion <> ")"], Bold]];
Print["  $UseClaudeRuntime = " <> ToString[ClaudeCode`$UseClaudeRuntime]];
Print[If[$Language === "Japanese", "
  CreateClaudeRuntime[adapter]         \[Rule] runtimeId 生成
  ClaudeRunTurn[runtimeId, input]      \[Rule] DAG jobId 起動
  ClaudeContinueTurn[runtimeId]        \[Rule] 継続ターン
  ClaudeRuntimeState[runtimeId]        \[Rule] 状態照会 (軽量版)
  ClaudeRuntimeStateFull[runtimeId]    \[Rule] 状態照会 (完全、重い)
  ClaudeTurnTrace[runtimeId]           \[Rule] イベントトレース
  ClaudeApproveProposal[runtimeId]     \[Rule] 承認
  ClaudeDenyProposal[runtimeId]        \[Rule] 拒否
  ClaudeRuntimeCancel[runtimeId]       \[Rule] キャンセル
  ClaudeRuntimeRetry[runtimeId]        \[Rule] Failed ノード再実行
  ClaudeRetryPolicy[profile]           \[Rule] RetryPolicy 取得
  ClaudeClassifyFailure[failure]       \[Rule] failure 分類
  (\:30bf\:30b9\:30af\:5206\:89e3\:30fb\:30de\:30eb\:30c1\:30a8\:30fc\:30b8\:30a7\:30f3\:30c8\:5b9f\:884c\:306f ClaudeOrchestrator.wl \:3092\:5c0e\:5165\:3059\:308b\:3053\:3068)
", "
  CreateClaudeRuntime[adapter]         \[Rule] Create runtimeId
  ClaudeRunTurn[runtimeId, input]      \[Rule] Launch DAG jobId
  ClaudeContinueTurn[runtimeId]        \[Rule] Continue turn
  ClaudeRuntimeState[runtimeId]        \[Rule] Query state (lightweight)
  ClaudeRuntimeStateFull[runtimeId]    \[Rule] Query state (complete, heavy)
  ClaudeTurnTrace[runtimeId]           \[Rule] Event trace
  ClaudeApproveProposal[runtimeId]     \[Rule] Approve
  ClaudeDenyProposal[runtimeId]        \[Rule] Deny
  ClaudeRuntimeCancel[runtimeId]       \[Rule] Cancel
  ClaudeRuntimeRetry[runtimeId]        \[Rule] Retry failed nodes
  ClaudeRetryPolicy[profile]           \[Rule] Get RetryPolicy
  ClaudeClassifyFailure[failure]       \[Rule] Classify failure
  (for task decomposition / multi-agent orchestration, load ClaudeOrchestrator.wl)
"]];
