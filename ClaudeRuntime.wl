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

   Phase 30 (2026-05-13): タイムアウト延長承認フロー。
   - iDispatchDecision の "Permit" 分岐で proposal[ExpectedSeconds] が
     adapter[DefaultTimeoutSeconds] を超える場合、AwaitingApproval に遷移。
   - PendingApproval に Kind="TimeoutExtension" / ExpectedSeconds /
     DefaultTimeoutSeconds の追加フィールド。
   - ClaudeApproveProposalWithTimeout[rid, timeout] を新規追加。
     timeout に Infinity / 正整数を渡すと adapter[DefaultTimeoutSeconds] を
     一時的に上書きして実行を再開する。
   - 設計原則 (Imai 先生指針):
     原則初期設定のタイムアウトを順守、延長すれば計算できる場合のみ
     問い合わせダイアログを出す。

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

ClaudeApproveProposalWithTimeout::usage =
  If[$Language === "Japanese",
  "ClaudeApproveProposalWithTimeout[runtimeId, timeout] は AwaitingApproval 状態の proposal を、\nadapter の DefaultTimeoutSeconds を一時的に timeout 秒 (Infinity 可) に上書きして承認する。\nPhase 30 (2026-05-13) で追加。タイムアウト延長承認フローで使用。",
  "ClaudeApproveProposalWithTimeout[runtimeId, timeout] approves a proposal with the adapter's\nDefaultTimeoutSeconds temporarily overridden to the given timeout (Infinity allowed).\nAdded in Phase 30 (2026-05-13) for timeout extension approval flow."];

ClaudeDenyProposal::usage =
  If[$Language === "Japanese",
  "ClaudeDenyProposal[runtimeId] は AwaitingApproval 状態の proposal を拒否する。",
  "ClaudeDenyProposal[runtimeId] denies a proposal in AwaitingApproval state."];

ClaudeMarkApprovalConsumed::usage =
  If[$Language === "Japanese",
  "ClaudeMarkApprovalConsumed[runtimeId, reason] は承認 UI 側が desktop action を既に実行した場合に承認待ち状態を消費し Done にする (実行ロジックは呼ばない)。",
  "ClaudeMarkApprovalConsumed[runtimeId, reason] consumes the approval state and marks Done when the UI already executed the desktop action."];

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

(* ════════════════════════════════════════════════════════
   ClaudeRuntimeExecuteTransition: ClaudeOrchestrator`Workflow` 連携
   (Stage B Day 4c で新設)

   位置付け: WorkflowNet の Transition (Executor->"ClaudeRuntime") 1 つ分の
   実行 adapter。既存 CreateClaudeRuntime / ClaudeRunTurn とは別系統で、
   multi-turn loop / continuation / approval / retry を一切持たない。
   それらの責務は Orchestrator (= WorkflowNet の transition 連鎖) が担う。

   runtime-orchestrator-boundary skill 準拠:
     - ClaudeRuntime に入れていいもの: 1 turn 内の純関数的計算
       (BuildContext / QueryProvider / ValidateProposal /
        ExecuteProposal / RedactResult)
     - ClaudeRuntime に入れてはいけないもの: multi-turn 状態 / approval /
       retry / snapshot / commit ordering

   adapter の形式 (CreateClaudeRuntime と同じ; ShouldContinue は不要):
     <|"BuildContext"     -> fn[contextPacket] -> ctx,
       "QueryProvider"     -> fn[ctx, contextPacket] -> proposal,
       "ValidateProposal"  -> fn[proposal, contextPacket] -> validateResult,
       "ExecuteProposal"   -> fn[proposal, contextPacket] -> execResult,
       "RedactResult"      -> fn[execResult, contextPacket] -> redactedResult|>

   contextPacket の主なキー (Workflow 側 iBuildContextPacket が組み立てる):
     "TransitionName", "Binding", "InputTokens", "Role",
     "DirectiveBundle", "DirectivePrompt", "AllowedCapabilities",
     "OutputSchema"

   戻り値:
     <|"Status" -> "Success",
       "Output" -> redactedResult,
       "Proposal" -> proposal,
       "Validation" -> validateResult,
       "ExecResult" -> execResult|>
   または失敗時:
     <|"Status" -> "Failed", "Reason" -> "...", "Diagnostics" -> ...|>
   ════════════════════════════════════════════════════════ *)

ClaudeRuntimeExecuteTransition::usage =
  If[$Language === "Japanese",
    "ClaudeRuntimeExecuteTransition[adapter, contextPacket] は\n" <>
    "WorkflowNet の Transition 1 つを 1 turn 内で実行する adapter API。\n" <>
    "BuildContext -> QueryProvider -> ValidateProposal -> ExecuteProposal\n" <>
    "-> RedactResult を順に呼ぶ純関数的な実行。multi-turn / retry /\n" <>
    "approval は ClaudeOrchestrator`Workflow` が担当し、ここでは扱わない。\n" <>
    "戻り値: <|\"Status\" -> \"Success\"|\"Failed\", \"Output\" -> ...,\n" <>
    "         \"Proposal\", \"Validation\", \"ExecResult\"|>",
    "ClaudeRuntimeExecuteTransition[adapter, contextPacket] executes one\n" <>
    "WorkflowNet Transition within a single turn. It runs BuildContext\n" <>
    "-> QueryProvider -> ValidateProposal -> ExecuteProposal ->\n" <>
    "RedactResult as a pure pipeline. Multi-turn / retry / approval are\n" <>
    "outside scope (handled by ClaudeOrchestrator`Workflow`).\n" <>
    "Returns: <|Status -> Success|Failed, Output, Proposal, Validation,\n" <>
    "          ExecResult|>"];

(* Phase 31 (ClaudeRunTurnDecomposed / ClaudeEvalDecomposed) は撤去済み。
   タスク分解・マルチエージェント機構は ClaudeOrchestrator.wl (別パッケージ) が担う。
   Phase 31 handoff: Phase31_next_session_handoff_v1.md 参照。 *)

(* \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550
   Phase 32 (2026-05-13): \:30b3\:30fc\:30c9\:5b9f\:884c\:306e\:975e\:540c\:671f\:5316 (ParallelSubmit + \:5171\:6709 polling)

   ExecuteProposal handler \:304c\:6b21\:306e\:5f62\:5f0f\:306e Association \:3092\:8fd4\:3057\:305f\:5834\:5408\:3001
   ClaudeRuntime \:306f\:5b9f\:884c\:5f8c\:306e\:6bb5\:968e (RedactResult, ShouldContinue, Continuation)
   \:3092 ClaudeRegisterPollingTick \:7d4c\:7531\:306e tick \:306b\:7e4b\:3052\:308b:

     <|"Async"      -> True,
       "Future"     -> EvaluationObject[...],   (* ParallelSubmit \:306e\:623b\:308a\:5024 *)
       "HeldExpr"   -> heldExpr,
       "Timeout"    -> seconds | Infinity,
       "StartTime"  -> AbsoluteTime[]|>

   \:540c\:671f\:5f62\:5f0f (\:5f93\:6765\:901a\:308a) \:306f\:305d\:306e\:307e\:307e\:30b5\:30dd\:30fc\:30c8\:3055\:308c\:308b\:3002

   ClaudeApproveProposal[WithTimeout] \:304b\:3089\:306e\:8d77\:52d5\:6642\:3082\:3001
   "AsyncExecutionScheduled" \:3092\:691c\:51fa\:3057\:305f\:3089 polling tick \:306b\:5f8c\:51e6\:7406\:3092\:59d4\:306d\:308b\:3002 *)

ClaudeRuntimeAsyncExecutionStatus::usage =
  If[$Language === "Japanese",
    "ClaudeRuntimeAsyncExecutionStatus[runtimeId] \:306f\:8a72\:5f53 runtime \:3067\n" <>
    "\:975e\:540c\:671f\:5b9f\:884c\:4e2d\:306e\:30bf\:30b9\:30af\:306e\:72b6\:614b\:3092\:8fd4\:3059:\n" <>
    "  <|\"Running\" -> True | False,\n" <>
    "    \"Elapsed\" -> seconds,\n" <>
    "    \"Timeout\" -> seconds | Infinity,\n" <>
    "    \"StartTime\" -> AbsoluteTime,\n" <>
    "    \"PollKey\" -> string|>\n" <>
    "\:8a72\:5f53 runtime \:306b async \:5b9f\:884c\:304c\:306a\:3044\:5834\:5408\:306f\n" <>
    "<|\"Running\" -> False|> \:3092\:8fd4\:3059\:3002",
    "ClaudeRuntimeAsyncExecutionStatus[runtimeId] returns the async execution\n" <>
    "status of the runtime, or <|\"Running\" -> False|> if none."];

ClaudeRuntimeCancelAsyncExecution::usage =
  If[$Language === "Japanese",
    "ClaudeRuntimeCancelAsyncExecution[runtimeId] \:306f\:5b9f\:884c\:4e2d\:306e\n" <>
    "\:975e\:540c\:671f\:30b3\:30fc\:30c9\:3092\:4e2d\:65ad\:3057\:3001AbortKernels[] \:3067\:5f37\:5236\:505c\:6b62\:3059\:308b\:3002\n" <>
    "\:4e2d\:65ad\:5f8c\:306f LaunchKernels[] \:3067\:4e26\:5217\:30ab\:30fc\:30cd\:30eb\:3092\:518d\:8d77\:52d5\:3059\:308b\:3002",
    "ClaudeRuntimeCancelAsyncExecution[runtimeId] cancels the async execution\n" <>
    "by AbortKernels[] and relaunches via LaunchKernels[]."];

(* Phase 32k (2026-05-14): \:975e\:540c\:671f\:5b9f\:884c\:7d4c\:8def\:306e\:8a3a\:65ad\:30c4\:30fc\:30eb *)
ClaudeRuntimeAsyncDiagnose::usage =
  If[$Language === "Japanese",
    "ClaudeRuntimeAsyncDiagnose[] \:306f ClaudeRuntime \:306e\:975e\:540c\:671f\:5b9f\:884c\:7d4c\:8def\:306e\n" <>
    "\:73fe\:5728\:72b6\:614b\:3092\:8fd4\:3059\:3002\n" <>
    "  <|\"ParallelKernels\" -> _Integer,\n" <>
    "    \"ParallelKernelsReady\" -> True | False,\n" <>
    "    \"AsyncExecutionEnabled\" -> True | False,\n" <>
    "    \"AsyncExecutionForced\" -> True | False,\n" <>
    "    \"HighPriorityMode\" -> True | False,\n" <>
    "    \"RuntimeCount\" -> _Integer,\n" <>
    "    \"Runtimes\" -> {<|...|>, ...}|>\n" <>
    "\:5404 Runtime \:306e Status / Phase / TurnCount / AsyncActive /\n" <>
    "AsyncFutureState / AsyncElapsed \:3092\:542b\:3080\:3002",
    "ClaudeRuntimeAsyncDiagnose[] returns the current state of the async\n" <>
    "execution path: ParallelKernels count, ready flag, runtime list."];

ClaudeRuntimeAsyncActiveQ::usage =
  "ClaudeRuntimeAsyncActiveQ[] は、いずれかの runtime で非同期実行 (AsyncExecution) " <>
  "または非同期 tool 実行 (AsyncToolExec の Running 非空) が走行中なら True を返す。" <>
  "NBAccess の PendingFinalActionQueue は、これが True の間 FrontEnd ブロック action を " <>
  "実行せず Pending のまま待つ ($NBFinalActionAsyncActiveFunction 経由、spec 案3-lite 5A.1)。";

(* Phase 32k Step 3 Phase C (2026-05-14): AsyncToolExec \:516c\:958b\:95a2\:6570 *)
ClaudeRuntimeCancelAsyncToolExec::usage =
  If[$Language === "Japanese",
    "ClaudeRuntimeCancelAsyncToolExec[runtimeId] \:306f\:8d70\:884c\:4e2d\:306e\n" <>
    "AsyncToolExec (\:975e\:540c\:671f tool \:5b9f\:884c) \:3092\:30ad\:30e3\:30f3\:30bb\:30eb\:3059\:308b\:3002\n" <>
    "Running \:306e\:5168 entry \:306b\:5bfe\:3057\:3066 adapter[\"CancelToolAsync\"] \:3092\:547c\:3073\:3001\n" <>
    "Queue \:306e call \:3082 Cancelled \:306b\:5378\:3057\:3066\:3001polling tick \:3092\:89e3\:9664\:3059\:308b\:3002\n" <>
    "\:8fd4\:308a\:5024: <|\"Success\" -> _, \"CancelledCount\" -> _Integer,\n" <>
    "         \"PollKey\" -> _String|>",
    "ClaudeRuntimeCancelAsyncToolExec[runtimeId] cancels the running\n" <>
    "AsyncToolExec by invoking adapter['CancelToolAsync'] on all entries\n" <>
    "and unregistering the polling tick."];

ClaudeRuntimeToolExecDiagnose::usage =
  If[$Language === "Japanese",
    "ClaudeRuntimeToolExecDiagnose[runtimeId] \:306f\:73fe\:5728\:306e\n" <>
    "AsyncToolExec state \:3092\:8fd4\:3059\:8a3a\:65ad\:95a2\:6570\:3002\n" <>
    "  <|\"Active\" -> _, \"Finalized\" -> _,\n" <>
    "    \"PollKey\" -> _String,\n" <>
    "    \"QueueSize\" -> _Integer, \"RunningSize\" -> _Integer,\n" <>
    "    \"CollectedSize\" -> _Integer, \"ToolCount\" -> _Integer,\n" <>
    "    \"MaxConcurrent\" -> _Integer, \"Elapsed\" -> _Real,\n" <>
    "    \"RunningIndices\" -> _List, \"QueueIndices\" -> _List,\n" <>
    "    \"CollectedIndices\" -> _List|>",
    "ClaudeRuntimeToolExecDiagnose[runtimeId] returns the current\n" <>
    "AsyncToolExec state for diagnostics."];

(* Phase 32k Step 3 Phase D (2026-05-14): AsyncToolExec \:65e2\:5b9a\:30d5\:30e9\:30b0 *)
$ClaudeRuntimeToolAsyncDefault::usage =
  If[$Language === "Japanese",
    "$ClaudeRuntimeToolAsyncDefault \:306f AsyncToolExec \:306e\:65e2\:5b9a\:6709\:52b9\:30d5\:30e9\:30b0\:3002\n" <>
    "True \:306b\:3059\:308b\:3068 web_search \:7b49\:3092\:5225 OS \:30d7\:30ed\:30bb\:30b9\:3067\:5b9f\:884c\:3057\:3001\n" <>
    "\:30e1\:30a4\:30f3\:30ab\:30fc\:30cd\:30eb\:3092\:30d6\:30ed\:30c3\:30af\:3057\:306a\:3044\:3002\n" <>
    "\:521d\:671f\:5024\:306f False (legacy sync \:7d4c\:8def\:7dad\:6301)\:3002\n" <>
    "Runtime \:3054\:3068\:306b Metadata[\"ToolAsync\"] \:3067\:4e0a\:66f8\:304d\:53ef\:80fd\:3002\n" <>
    "Adapter \:3054\:3068\:306b adapter[\"ToolAsync\"] \:3067\:3082\:4e0a\:66f8\:304d\:53ef\:80fd\:3002",
    "$ClaudeRuntimeToolAsyncDefault is the default flag for AsyncToolExec.\n" <>
    "When True, web_search etc. are run in separate OS processes\n" <>
    "instead of blocking the main kernel. Default is False."];

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

(* Phase 32k Step 3 Phase D (2026-05-14): AsyncToolExec \:65e2\:5b9a\:30d5\:30e9\:30b0\:521d\:671f\:5316
   2026-05-15: \:7d4c\:8def\:7d71\:4e00\:306b\:4f34\:3044\:30c7\:30d5\:30a9\:30eb\:30c8\:3092 True \:306b\:3002
   ClaudeRuntime \:3092\:30ed\:30fc\:30c9\:3057\:305f\:30e6\:30fc\:30b6\:30fc\:306f\:5e38\:306b AsyncToolExec \:7d4c\:8def\:3092\:901a\:308b\:3053\:3068\:3092\:60f3\:5b9a\:3002 *)
If[!BooleanQ[$ClaudeRuntimeToolAsyncDefault],
  $ClaudeRuntimeToolAsyncDefault = True];

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
    (* Phase 30 (2026-05-13): "Execution timed out after Ns" を独立分類。
       AwaitingApproval に戻して再度ユーザに判断を仰ぐ。 *)
    StringContainsQ[msg, "timed out" | "TimedOut" | "Execution timeout"],
      <|"Class" -> "ExecutionTimeout", "Retryable" -> True, "Fatal" -> False|>,
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
  Module[{rt = $iClaudeRuntimes[runtimeId], used, limit},
    If[!AssociationQ[rt], Return[False]];
    used  = Lookup[rt["BudgetsUsed"], budgetKey, 0];
    limit = Lookup[rt["RetryPolicy"]["Limits"], budgetKey, 0];
    If[used >= limit, Return[False]];
    rt["BudgetsUsed"][budgetKey] = used + 1;
    $iClaudeRuntimes[runtimeId] = rt;
    True
  ];

iBudgetExhaustedQ[runtimeId_String, budgetKey_String] :=
  Module[{rt = $iClaudeRuntimes[runtimeId], used, limit},
    If[!AssociationQ[rt], Return[True]];
    used  = Lookup[rt["BudgetsUsed"], budgetKey, 0];
    limit = Lookup[rt["RetryPolicy"]["Limits"], budgetKey, 0];
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
     
   Optional:
   "PreValidate"[proposal, contextPacket]
     → None (通常の ValidateProposal に進む)
     または <|"Decision" -> "RepairNeeded"|"Deny"|...,
              "ReasonClass" -> String,
              "VisibleExplanation" -> String,
              "SanitizedExpr" -> HoldComplete[...]|>
     adapter 固有の早期 validation を行う optional hook。
     HasProposal=True が確定した後、head チェックの前に呼ばれる。
     None または非 Association を返した場合は通常 flow を継続。
     用途: 空コード / メタ関数呼び出しなどの adapter 固有検出。
     PreValidate を使うと Trace に PreValidationApplied イベントが
     残り、後続の head チェックは skip される。
   
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

(* \:2500\:2500 iSafeSync: sync \:30cf\:30f3\:30c9\:30e9\:30fc\:306e DAG \:4e92\:63db\:30e9\:30c3\:30d1\:30fc \:2500\:2500
   DAG \:30a4\:30f3\:30d5\:30e9\:306e sync \:30ce\:30fc\:30c9\:306f $Failed / None \:3092\:8fd4\:3059\:3068 "failed" \:306b\:30de\:30fc\:30af\:3059\:308b\:3002
   \:3053\:306e\:30e9\:30c3\:30d1\:30fc\:306f\:5168\:4f8b\:5916\:3092\:30ad\:30e3\:30c3\:30c1\:3057\:3001\:5e38\:306b Association \:3092\:8fd4\:3059\:3002
   \:30a8\:30e9\:30fc\:306f RuntimeState \:5074\:3067\:8ffd\:8de1\:3055\:308c\:308b
   (\:30b9\:30c6\:30c3\:30d7\:95a2\:6570\:304c iRecordFatalFailure / iUpdateStatus \:3067\:8a18\:9332)\:3002
   DAG \:30ce\:30fc\:30c9\:3068\:3057\:3066\:306f\:5e38\:306b "done" \:306b\:306a\:308a\:3001\:4f9d\:5b58\:30c1\:30a7\:30a4\:30f3\:304c\:7dad\:6301\:3055\:308c\:308b\:3002
   
   2026-05-07 fix v3:
   v1: Quiet @ Check \:5168\:5ec3\:6b62 \:2192 silent failure (\:4f8b\:5916\:4fdd\:8b77\:559c\:5931)
   v2: Quiet @ Catch[..., _, ($Failed) &] \:2192 \:904e\:5270\:6355\:6349\:3001
       TimeConstrained \:7b49\:306e Mathematica \:5185\:90e8 Throw \:307e\:3067\:62fe\:3063\:3066
       $Failed \:5316\:3057 ExecutionFailed (result10.nb \:3067\:78ba\:8a8d)\:3002
   v3: Quiet \:306e\:307f\:6b8b\:3059\:3002Check \:306f\:7f60 #16 \:306e\:539f\:56e0\:306a\:306e\:3067\:9664\:53bb\:3001
       Catch \:306f\:5185\:90e8 Throw \:5e72\:6e09\:306e\:539f\:56e0\:306a\:306e\:3067\:9664\:53bb\:3002
       Quiet \:306f\:30e1\:30c3\:30bb\:30fc\:30b8\:8868\:793a\:3092\:6291\:5236\:3059\:308b\:306e\:307f\:3067 expr \:306e\:8a55\:4fa1\:6319\:52d5\:306b
       \:5e72\:6e09\:3057\:306a\:3044\:305f\:3081\:3001\:3053\:308c\:304c\:6700\:3082\:5b89\:5168\:3002 *)
SetAttributes[iSafeSync, HoldFirst];
iSafeSync[expr_, stepName_String] :=
  Module[{result},
    result = Quiet[expr];
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
    maxRetries = Lookup[rt["RetryPolicy"]["Limits"],
      "MaxTransportRetries", 2];
    
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
        iRecordFatalFailure[runtimeId,
          <|"ReasonClass" -> fc["Class"], "Error" -> errMsg|>];
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
    
    (* ── Phase F: PreValidate hook (optional adapter callback) ──
       adapter が "PreValidate" キーを持つ場合、head チェックの前に呼び出す。
       PreValidate の戻り値が Association で "Decision" キーを持つなら、
       それを validationResult として採用し、後続の head チェックを
       skip する。None を返した場合は通常の flow を継続する。
       
       用途:
       - 空コード / trivial コードを Decision="RepairNeeded",
         ReasonClass="EmptyOrTrivialCode" として扱い、明示的な
         repair turn を schedule する (Trace に EmptyOrTrivialCode
         として記録される)。
       - メタ関数呼び出し (ClaudeUpdatePackage[...]) の早期検出。
       
       設計意図:
       - 従来 ParseProposal で HasProposal=False に書き換えていた
         (Phase B-fix7) よりも、Trace の表現力が高くなる。
       - "コードがあるが空" と "コードが本当にない" を semantically
         区別できる。 *)
    rt = $iClaudeRuntimes[runtimeId];
    contextPacket = rt["LastContextPacket"];
    
    If[KeyExistsQ[adapter, "PreValidate"],
      With[{preResult = Quiet @ Check[
          adapter["PreValidate"][proposal, contextPacket], None]},
        If[AssociationQ[preResult] && KeyExistsQ[preResult, "Decision"],
          iAppendEvent[runtimeId, <|"Type" -> "PreValidationApplied",
            "Decision"    -> Lookup[preResult, "Decision", "?"],
            "ReasonClass" -> Lookup[preResult, "ReasonClass", ""]|>];
          Module[{cur = $iClaudeRuntimes[runtimeId]},
            cur["LastValidationResult"] = preResult;
            $iClaudeRuntimes[runtimeId] = cur];
          Return[preResult]]
      ]];
    
    (* ── Phase 26 (+Phase C-lite 整合修正 2026-06-05): head チェック +
         AutoEval 禁止チェック ──
       フロー:
       1. head チェック (adapter["ValidateProposal"] へ委譲。NBAccess ロード時は
          NBValidateHeldExpr 経由の完全判定 = 実行ゲートと一致。adapter に
          ValidateProposal が無い場合のみ Runtime 側ブラックリストにフォールバック)
          → Deny / NeedsApproval / Permit を判定
       2. AutoEval 禁止チェック (Permit の場合のみ)
          → Permit かつ AutoEval 禁止パターンなら NeedsApproval に昇格
       設計意図: Deny 式が NeedsApproval に退行するのを防止 *)
    heldExpr = Lookup[proposal, "HeldExpr", None];
    code     = Lookup[proposal, "RawCode", ""];
    
    (* Phase C-lite 整合修正 (2026-06-05): 検証ゲートを実行ゲート
       (NBExecuteHeldExpr 内の NBValidateHeldExpr 再検証) と完全一致させる。
       adapter["ValidateProposal"] は NBAccess ロード時に NBValidateHeldExpr へ
       委譲済み (claudecode.wl)。旧来この分岐は NBAccess ロード時に Runtime 側の
       簡易ブラックリスト ($NBDenyHeads/$NBApprovalHeads のみ) を使っており、
       unknown head を Permit に素通し → 実行段階で初めて NeedsApproval 拒否
       (承認 UI なし、致命的失敗) になる食い違いを生んでいた。adapter を最優先で
       使い、inline blacklist は ValidateProposal を持たない adapter のときだけ
       フォールバックとして使う。 *)
    If[KeyExistsQ[adapter, "ValidateProposal"],
      (* ── adapter 委譲: NBAccess ロード時は NBValidateHeldExpr 経由の完全判定。
         Quiet のみ使用 (Check は無害なメッセージもキャッチしてしまう)。
         結果が Association でない場合は後続の AssociationQ チェックで Deny になる。 *)
      validationResult = Quiet[
        adapter["ValidateProposal"][proposal, contextPacket]],
      (* ── adapter に ValidateProposal が無い場合のみ: Runtime 側で直接
         head チェック ($NBDenyHeads/$NBApprovalHeads ブラックリスト) ── *)
      heads = Quiet @ Check[
        DeleteDuplicates @ Cases[heldExpr,
          s_Symbol[___] :> SymbolName[Unevaluated[s]],
          {1, Infinity}], {}];
      denied = If[ListQ[Quiet[NBAccess`$NBDenyHeads]],
        Select[heads, MemberQ[NBAccess`$NBDenyHeads, #] &], {}];
      needsApproval = If[ListQ[Quiet[NBAccess`$NBApprovalHeads]],
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
      ]
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
        (* Phase 30 (2026-05-13): proposal[ExpectedSeconds] > adapter[DefaultTimeoutSeconds] なら
           AwaitingApproval に遷移。ユーザの判断を仰ぐ。 *)
        Module[{expSec, defTimeout, kind},
          expSec = Lookup[proposal, "ExpectedSeconds", None];
          defTimeout = If[AssociationQ[adapter],
            Lookup[adapter, "DefaultTimeoutSeconds", 30], 30];
          kind = If[(IntegerQ[expSec] || (NumericQ[expSec] && expSec > 0)) &&
                    IntegerQ[defTimeout] && expSec > defTimeout,
            "TimeoutExtension", None];
          If[kind === "TimeoutExtension",
            (* AwaitingApproval に遷移 *)
            rt["PendingApproval"] = <|
              "Proposal"             -> proposal,
              "ValidationResult"     -> <|
                "Decision"           -> "NeedsApproval",
                "ReasonClass"        -> "TimeoutExtension",
                "VisibleExplanation" ->
                  "LLM proposes " <> ToString[expSec] <> "s execution " <>
                  "(default: " <> ToString[defTimeout] <> "s)"|>,
              "ContextPacket"        -> contextPacket,
              "Kind"                 -> "TimeoutExtension",
              "ExpectedSeconds"      -> expSec,
              "DefaultTimeoutSeconds" -> defTimeout|>;
            $iClaudeRuntimes[runtimeId] = rt;
            iUpdateStatus[runtimeId, "AwaitingApproval"];
            iAppendEvent[runtimeId, <|"Type" -> "AwaitingApproval",
              "Kind" -> "TimeoutExtension",
              "ExpectedSeconds" -> expSec,
              "DefaultTimeoutSeconds" -> defTimeout|>];
            <|"Outcome" -> "AwaitingApproval"|>,
            (* 通常の Permit 経路 *)
            If[rt["Profile"] === "UpdatePackage" &&
               KeyExistsQ[adapter, "SnapshotPackage"],
              iTransactionExecute[runtimeId, adapter, proposal,
                validationResult, contextPacket],
              iExecuteAndContinue[runtimeId, adapter, proposal,
                validationResult, contextPacket]]
          ]
        ],
      
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
        (* Phase C-lite (2026-06-03, spec 5A.9): Deny は承認 UI (実行/中止ボタン)
           を出してはならない。Deny は承認しても実行されない (NBExecuteHeldExpr が
           UserApproved でも昇格しないことを保証) ため、ボタンを出すと「押しても
           実行されない」混乱を招く。よって AwaitingApproval に遷移させず、即座に
           失敗として記録し、bridge 側で拒否理由だけ表示する。
           旧 Phase 25b の DenyOverride (Deny でも override 実行) は廃止。 *)
        iRecordFatalFailure[runtimeId,
          <|"ReasonClass" -> Lookup[validationResult, "ReasonClass", "Deny"],
            "Decision" -> "Deny",
            "VisibleExplanation" ->
              Lookup[validationResult, "VisibleExplanation", ""],
            "Error" -> "Execution refused: Deny",
            "DeniedProposal" -> proposal|>];
        <|"Outcome" -> "Failed",
          "Reason" -> "Denied",
          "ReasonClass" -> Lookup[validationResult, "ReasonClass", "Deny"]|>,
      
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
  Module[{rt, useAsync, asyncNames, toolCalls, classified, syncIndexed,
          asyncIndexed, syncCallsRaw, syncResultsRaw, syncResultsByIdx,
          syncIndices},

    rt = $iClaudeRuntimes[runtimeId];
    If[!AssociationQ[rt],
      Return[<|"Outcome" -> "Failed", "Reason" -> "RuntimeMissing"|>]];

    (* ToolAsync \:89e3\:6c7a: runtime metadata > adapter > global default *)
    useAsync = iResolveToolAsync[rt, adapter];

    (* legacy \:7d4c\:8def: useAsync = False\:3001\:307e\:305f\:306f adapter \:306b async API \:304c\:306a\:3044 *)
    asyncNames = Lookup[adapter, "AsyncToolNames", {}];
    If[!TrueQ[useAsync] ||
       !ListQ[asyncNames] || Length[asyncNames] === 0 ||
       !KeyExistsQ[adapter, "SubmitToolAsync"] ||
       !KeyExistsQ[adapter, "CollectToolAsync"],
      Return[iToolUseAndContinueSyncLegacy[runtimeId, adapter, proposal,
        validationResult, contextPacket]]];

    (* \[HorizontalLine] hybrid \:7d4c\:8def \[HorizontalLine] *)
    iUpdatePhase[runtimeId, "ToolExecution"];

    (* budget \:30c1\:30a7\:30c3\:30af *)
    If[!iConsumeBudget[runtimeId, "MaxToolIterations"],
      iAppendEvent[runtimeId, <|"Type" -> "BudgetExhausted",
        "Budget" -> "MaxToolIterations"|>];
      iUpdateStatus[runtimeId, "Done"];
      iAppendEvent[runtimeId, <|"Type" -> "ToolLoopBudgetExhausted"|>];
      Return[<|"Outcome" -> "Done",
        "Reason" -> "ToolIterationBudgetExhausted",
        "TextResponse" -> Lookup[validationResult, "TextResponse", ""]|>]];

    toolCalls = Lookup[validationResult, "ToolCalls", {}];
    If[Length[toolCalls] === 0,
      iUpdateStatus[runtimeId, "Done"];
      Return[<|"Outcome" -> "Done",
        "TextResponse" -> Lookup[proposal, "TextResponse", ""]|>]];

    (* sync/async \:632f\:308a\:5206\:3051 *)
    classified    = iClassifyToolCalls[toolCalls, adapter];
    syncIndexed   = Lookup[classified, "SyncCalls", {}];
    asyncIndexed  = Lookup[classified, "AsyncCalls", {}];

    iAppendEvent[runtimeId, <|
      "Type"       -> "ToolClassified",
      "TotalCalls" -> Length[toolCalls],
      "SyncCount"  -> Length[syncIndexed],
      "AsyncCount" -> Length[asyncIndexed]|>];

    (* sync \:90e8\:5206\:3092 adapter[ExecuteTools] \:3067\:5148\:884c\:5b9f\:884c (\:30ec\:30d3\:30e5\:30fc \:00a73.3 \:6e96\:62e0\:3092\:4fdd\:3064) *)
    syncResultsByIdx = <||>;
    If[Length[syncIndexed] > 0,
      syncCallsRaw = Map[Lookup[#, "Call", <||>] &, syncIndexed];
      syncIndices  = Map[Lookup[#, "Index", 0] &, syncIndexed];
      syncResultsRaw = If[KeyExistsQ[adapter, "ExecuteTools"],
        Quiet @ Check[
          adapter["ExecuteTools"][syncCallsRaw, contextPacket],
          Map[<|"ToolName" -> Lookup[#, "Name", "?"],
                "ToolId"   -> Lookup[#, "Id", ""],
                "Success"  -> False,
                "Error"    -> "ExecuteTools adapter failed"|> &,
            syncCallsRaw]],
        iExecuteToolsFallback[runtimeId, adapter, syncCallsRaw,
          contextPacket]];
      If[Length[syncResultsRaw] === Length[syncIndices],
        syncResultsByIdx = AssociationThread[
          syncIndices -> syncResultsRaw],
        (* \:9577\:3055\:4e0d\:4e00\:81f4\:6642\:306f\:5168\:90e8 error \:306b\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af *)
        syncResultsByIdx = AssociationThread[
          syncIndices -> Map[
            <|"ToolName" -> Lookup[#, "Name", "?"],
              "ToolId"   -> Lookup[#, "Id", ""],
              "Success"  -> False,
              "Error"    -> "Sync exec returned wrong length"|> &,
            syncCallsRaw]]]];

    (* async \:304c\:306a\:3051\:308c\:3070 sync \:7d50\:679c\:3060\:3051\:3067 continuation (legacy \:3068\:540c\:3058) *)
    If[Length[asyncIndexed] === 0,
      Module[{toolResults},
        toolResults = iToolExecMergeResults[
          toolCalls, syncResultsByIdx, <||>];
        Return[iToolUseAccumulateAndContinue[runtimeId, adapter, proposal,
          validationResult, contextPacket, toolCalls, toolResults]]]];

    (* async \:3042\:308a: schedule \:3057\:3066 AsyncToolExecScheduled \:3092\:8fd4\:3059 *)
    iScheduleAsyncToolExecPoll[runtimeId, adapter, proposal,
      validationResult, contextPacket,
      syncResultsByIdx, asyncIndexed, toolCalls]
  ];

(* ToolAsync \:89e3\:6c7a:
   runtime metadata[\"ToolAsync\"] > adapter[\"ToolAsync\"] > $ClaudeRuntimeToolAsyncDefault *)
iResolveToolAsync[rt_Association, adapter_Association] :=
  Module[{meta, runtimeOpt, adapterOpt},
    meta = Lookup[rt, "Metadata", <||>];
    If[!AssociationQ[meta], meta = <||>];
    runtimeOpt = Lookup[meta, "ToolAsync", Automatic];

    Which[
      runtimeOpt === True, True,
      runtimeOpt === False, False,
      True,
        adapterOpt = Lookup[adapter, "ToolAsync", Automatic];
        Which[
          adapterOpt === True, True,
          adapterOpt === False, False,
          True, TrueQ[$ClaudeRuntimeToolAsyncDefault]]
    ]
  ];

iResolveToolAsync[___] := False;

(* legacy sync \:7d4c\:8def: Phase D \:524d\:306e\:65e7\:5b9f\:88c5\:3092\:305d\:306e\:307e\:307e\:4fdd\:5b58
   2026-05-15: \:5916\:90e8 adapter (Workflow / Package transaction) \:5411\:3051\:306e\:5b89\:5168\:88c5\:7f6e\:3068\:3057\:3066\:6b8b\:5b58\:3002
   \:5b9f\:969b\:306e\:547c\:3070\:308c\:65b9\:3092\:8a08\:6e2c\:3059\:308b\:305f\:3081\:306b\:30c8\:30ec\:30fc\:30b9\:30ed\:30b0\:3092\:5148\:982d\:306b\:5d4c\:3081\:8fbc\:307f\:3002 *)
iToolUseAndContinueSyncLegacy[runtimeId_String, adapter_Association,
    proposal_Association, validationResult_Association,
    contextPacket_Association] :=
  Module[{toolCalls, toolResults, rt, msgs, turnMsg, textResp},
    (* \:65e7\:7d4c\:8def\:30c8\:30ec\:30fc\:30b9 (claudecode \:5074\:306e\:30ed\:30ac\:30fc\:3092\:518d\:5229\:7528) *)
    Quiet @ Check[ClaudeCode`Private`iLogLegacyPath["iToolUseAndContinueSyncLegacy"], Null];

    iUpdatePhase[runtimeId, "ToolExecution"];

    (* budget \:30c1\:30a7\:30c3\:30af *)
    If[!iConsumeBudget[runtimeId, "MaxToolIterations"],
      iAppendEvent[runtimeId, <|"Type" -> "BudgetExhausted",
        "Budget" -> "MaxToolIterations"|>];
      iUpdateStatus[runtimeId, "Done"];
      iAppendEvent[runtimeId, <|"Type" -> "ToolLoopBudgetExhausted"|>];
      Return[<|"Outcome" -> "Done",
        "Reason" -> "ToolIterationBudgetExhausted",
        "TextResponse" -> Lookup[validationResult,
          "TextResponse", ""]|>]];

    toolCalls = Lookup[validationResult, "ToolCalls", {}];
    If[Length[toolCalls] === 0,
      iUpdateStatus[runtimeId, "Done"];
      Return[<|"Outcome" -> "Done",
        "TextResponse" -> Lookup[proposal, "TextResponse", ""]|>]];

    (* \:30c4\:30fc\:30eb\:5b9f\:884c *)
    toolResults = If[KeyExistsQ[adapter, "ExecuteTools"],
      Quiet @ Check[
        adapter["ExecuteTools"][toolCalls, contextPacket],
        Map[<|"ToolName" -> Lookup[#, "Name", "?"],
              "ToolId" -> Lookup[#, "Id", ""],
              "Success" -> False,
              "Error" -> "ExecuteTools adapter failed"|> &,
          toolCalls]],
      iExecuteToolsFallback[runtimeId, adapter, toolCalls, contextPacket]
    ];

    iToolUseAccumulateAndContinue[runtimeId, adapter, proposal,
      validationResult, contextPacket, toolCalls, toolResults]
  ];

(* \:5171\:901a\:672b\:5c3e\:51e6\:7406: ToolsExecuted \:30a4\:30d9\:30f3\:30c8 + ConversationState \:8398\:7a4d
   + ContinuationInput \:69cb\:7bc9 + ContinuationPending \:3092\:8fd4\:3059\:3002

   legacy / hybrid (sync only) / hybrid (async finalize) \:306e\:4e09\:8005\:304b\:3089\:5171\:901a\:3067\:547c\:3070\:308c\:308b\:3002 *)
iToolUseAccumulateAndContinue[runtimeId_String, adapter_Association,
    proposal_Association, validationResult_Association,
    contextPacket_Association, toolCalls_List, toolResults_List] :=
  Module[{rt, msgs, turnMsg, textResp},
    iAppendEvent[runtimeId, <|"Type" -> "ToolsExecuted",
      "ToolCount" -> Length[toolCalls],
      "Results" -> Map[
        <|"Name" -> Lookup[#, "ToolName", "?"],
          "Success" -> TrueQ[Lookup[#, "Success", False]]|> &,
        toolResults]|>];

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

iToolUseAccumulateAndContinue[___] :=
  <|"Outcome" -> "Failed", "Reason" -> "InvalidArgs"|>;

(* \[HorizontalLine] \:30c4\:30fc\:30eb\:500b\:5225\:5b9f\:884c\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af \[HorizontalLine]
   adapter \:306b \"ExecuteTools\" \:304c\:306a\:3044\:5834\:5408\:3001
   \:500b\:5225\:306e\:30c4\:30fc\:30eb\:540d\:306b\:57fa\:3065\:3044\:3066 adapter \:306e\:95a2\:6570\:3092\:63a2\:3059\:3002
   \:4e3b\:306b mathematica_eval \:306f\:65e2\:5b58\:306e ExecuteProposal \:3092\:6d41\:7528\:3002 *)
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

(* Phase 32 (2026-05-13): \:30b3\:30fc\:30c9\:5b9f\:884c\:306e\:975e\:540c\:671f\:5316\:5bfe\:5fdc\:3002
   adapter["ExecuteProposal"] \:304c <|"Async" -> True, "Future" -> ...|> \:3092
   \:8fd4\:3057\:305f\:5834\:5408\:3001iScheduleAsyncExecutionPoll \:7d4c\:7531\:3067 polling tick \:306b
   \:5f8c\:7d9a\:51e6\:7406 (Redact / ShouldContinue / Continuation) \:3092\:59d4\:306d\:308b\:3002
   \:5f93\:6765\:306e\:540c\:671f\:7d50\:679c (Association \:304c\:78ba\:5b9a\:5024\:3092\:6301\:3064) \:306f\:305d\:306e\:307e\:307e
   iExecuteAndContinueSyncFinalize \:3067\:540c\:671f\:51e6\:7406\:3055\:308c\:308b\:3002 *)
iExecuteAndContinue[runtimeId_String, adapter_Association,
    proposal_Association, validationResult_Association,
    contextPacket_Association] :=
  Module[{execResult, isAsync},
    iUpdatePhase[runtimeId, "Execute"];
    execResult = adapter["ExecuteProposal"][proposal, validationResult];
    
    (* Async \:5224\:5b9a: <|"Async" -> True, "Future" -> _, ...|> \:5f62\:5f0f *)
    isAsync = AssociationQ[execResult] &&
              TrueQ[Lookup[execResult, "Async", False]] &&
              KeyExistsQ[execResult, "Future"];
    
    If[isAsync,
      iScheduleAsyncExecutionPoll[runtimeId, adapter,
        proposal, validationResult, contextPacket, execResult],
      iExecuteAndContinueSyncFinalize[runtimeId, adapter,
        proposal, validationResult, contextPacket, execResult]
    ]
  ];

(* \:5f93\:6765\:306e\:540c\:671f\:5b9f\:884c\:30d1\:30b9\:3002execResult \:304c\:78ba\:5b9a\:6e08\:307f\:306e\:3068\:304d\:306b\:547c\:3076\:3002
   async \:7d4c\:8def\:306e finalize \:304b\:3089\:3082\:518d\:5229\:7528\:3055\:308c\:308b\:3002 *)
iExecuteAndContinueSyncFinalize[runtimeId_String, adapter_Association,
    proposal_Association, validationResult_Association,
    contextPacket_Association, execResult_] :=
  Module[{redacted, rt, shouldCont},
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
    
    (* \[LongDash]\[LongDash] Messages \:84c4\:7a4d: \:53cd\:5fa9\:30eb\:30fc\:30d7\:7528\:30bf\:30fc\:30f3\:5c65\:6b74 \[LongDash]\[LongDash] *)
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
      (* ContinuationInput: \:69cb\:9020\:5316\:3055\:308c\:305f\:7d99\:7d9a\:30e1\:30c3\:30bb\:30fc\:30b8 *)
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

    (* Phase 32k Step 3 Phase D (2026-05-14): \:30ec\:30d3\:30e5\:30fc \:00a73.1 \:5fc5\:9808\:9805\:76ee\:3002
       AsyncExecutionScheduled / AsyncToolExecScheduled \:306f\:307e\:3060 turn \:5b8c\:4e86\:3057\:3066
       \:3044\:306a\:3044\:305f\:3081\:3001callback \:3092\:547c\:3070\:305a\:65e9\:671f return \:3059\:308b\:3002
       \:5b8c\:4e86\:3057\:305f\:3089 iAsyncExecutionFinalize / iAsyncToolExecFinalize \:304c
       ClaudeRunTurn \:3092\:518d\:8d77\:52d5\:3059\:308b\:3002 *)
    If[outcome === "AsyncExecutionScheduled" ||
       outcome === "AsyncToolExecScheduled",
      iAppendEvent[runtimeId, <|
        "Type"    -> "TurnAwaitingAsync",
        "Outcome" -> outcome|>];
      Return[]];

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

(* \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550
   9b. Phase 32: \:30b3\:30fc\:30c9\:5b9f\:884c\:306e\:975e\:540c\:671f\:5316 (ParallelSubmit + polling)
   \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550

   adapter["ExecuteProposal"] \:304c <|"Async" -> True, "Future" -> EvaluationObject[...],
   "HeldExpr" -> _, "Timeout" -> _, "StartTime" -> _, ...|> \:3092\:8fd4\:3057\:305f\:5834\:5408\:3001
   \:5171\:6709 polling tick \:7d4c\:7531\:3067\:5b8c\:4e86\:3092\:30dd\:30fc\:30ea\:30f3\:30b0\:3057\:3001\:5b8c\:4e86\:6642\:306b
   iAsyncExecutionFinalize \:3067\:5f8c\:7d9a\:51e6\:7406 (Redact / ShouldContinue / Continuation)
   \:3092\:884c\:3046\:3002

   runtime-orchestrator-boundary \:6e96\:62e0:
     - Runtime DAG-IP \:306e\:7df4\:5ea6\:3067\:9589\:3058\:308b\:7d14\:95a2\:6570\:7684\:5e76\:5217\:5316
     - Workflow state / approval / retry policy \:306f\:6271\:308f\:306a\:3044
     - \:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:66f8\:8fbc\:307f\:306f Notebook callback (meta) \:7d4c\:7531\:306e\:307f *)

(* \:5171\:6709 polling tick \:306e key \:751f\:6210 *)
iAsyncExecutionPollKey[runtimeId_String] :=
  "ClaudeRuntimeAsyncExec_" <> runtimeId;

(* \:5b8c\:4e86\:5224\:5b9a\:30d8\:30eb\:30d1: \:30d6\:30ed\:30c3\:30af\:3057\:306a\:3044\:72b6\:614b\:30dd\:30fc\:30ea\:30f3\:30b0\:3002
   Phase 32d (2026-05-13): WaitNext \:7d4c\:7531\:3092\:7834\:68c4\:3057\:3001EvaluationObject["State"]
   \:30d7\:30ed\:30d1\:30c6\:30a3\:3092\:898b\:308b\:65b9\:5f0f\:306b\:5909\:66f4\:3002
   
   \:54f2\:5b66:
   - WaitNext[{future}, t] \:306f future \:304c\:672a\:5b8c\:4e86\:306e\:3068\:304d t \:79d2\:30d6\:30ed\:30c3\:30af\:3059\:308b\:3002
     ScheduledTask \:4e2d\:3067\:547c\:3076\:3068\:3001\:30e1\:30a4\:30f3\:30ab\:30fc\:30cd\:30eb\:304c\:305d\:306e\:9593\:30d7\:30ea\:30a8\:30f3\:30d7\:30c6\:30a3\:30d6\:306b
     \:30d6\:30ed\:30c3\:30af\:3055\:308c\:3001ClaudeStatus[] \:306a\:3069\:4ed6\:306e\:8efd\:3044\:64cd\:4f5c\:3082\:305d\:306e\:9593\:5f85\:305f\:3055\:308c\:308b\:3002
   - EvaluationObject["State"] \:306f Master \:5074\:306e Association \:30eb\:30c3\:30af\:30a2\:30c3\:30d7\:306e\:307f\:3067\:3001
     subkernel \:3068\:306e\:901a\:4fe1\:306f\:767a\:751f\:3057\:306a\:3044\:3002\:3088\:3063\:3066\:30d6\:30ed\:30c3\:30af\:3057\:306a\:3044\:3002
   - "received" \:307e\:305f\:306f "finished" \:72b6\:614b\:306e EvaluationObject \:306b\:5bfe\:3057\:3066\:306e\:307f
     WaitAll \:3092\:547c\:3076 (\:3053\:308c\:306f\:5373\:6642\:306b\:8fd4\:308b)\:3002
   
   maxWait \:5f15\:6570\:306f\:4e0b\:4f4d\:4e92\:63db\:6027\:306e\:305f\:3081\:6b8b\:3059\:304c\:3001\:672c\:95a2\:6570\:3067\:306f\:4e00\:5207\:4f7f\:308f\:306a\:3044\:3002
   
   \:8fd4\:308a\:5024:
     <|"Completed" -> True | False, "Result" -> value | None|> *)
iPollFutureComplete[future_, maxWait_:0.01] :=
  Module[{state, result},
    state = Quiet @ Check[future["State"], "unknown"];
    Which[
      (* \:5b8c\:4e86\:6e08\:307f: WaitAll \:3067\:5373\:6642\:56de\:53ce *)
      state === "received" || state === "finished",
        result = Quiet @ Check[WaitAll[future], $Failed];
        <|"Completed" -> True, "Result" -> result|>,
      
      (* \:5b9f\:884c\:4e2d / \:672a\:8d77\:52d5 / \:4e0d\:660e: \:30d6\:30ed\:30c3\:30af\:305b\:305a\:6b21\:56de tick \:3078 *)
      True,
        <|"Completed" -> False, "Result" -> None|>
    ]
  ];

iPollFutureComplete[___] := <|"Completed" -> False, "Result" -> None|>;

(* \:975e\:540c\:671f\:5b9f\:884c\:3092\:5171\:6709 polling \:306b\:767b\:9332\:3057\:3001AsyncExecution \:60c5\:5831\:3092
   RuntimeState \:306b\:683c\:7d0d\:3059\:308b\:3002\:5f8c\:7d9a\:51e6\:7406\:306f iAsyncExecutionTickFn \:7d4c\:7531\:3067\:8d77\:52d5\:3055\:308c\:308b\:3002 *)
iScheduleAsyncExecutionPoll[runtimeId_String, adapter_Association,
    proposal_Association, validationResult_Association,
    contextPacket_Association, asyncToken_Association] :=
  Module[{rt, pollKey, future, timeout, startTime, heldExpr,
          registerFn, registerResult},
    rt = $iClaudeRuntimes[runtimeId];
    If[!AssociationQ[rt],
      Return[<|"Outcome" -> "Failed",
        "Reason" -> "RuntimeMissing"|>]];
    
    future    = Lookup[asyncToken, "Future", None];
    heldExpr  = Lookup[asyncToken, "HeldExpr", None];
    timeout   = Lookup[asyncToken, "Timeout", 30];
    startTime = Lookup[asyncToken, "StartTime", AbsoluteTime[]];
    pollKey   = iAsyncExecutionPollKey[runtimeId];
    
    iUpdatePhase[runtimeId, "ExecutingAsync"];
    iAppendEvent[runtimeId, <|
      "Type"      -> "AsyncExecutionStarted",
      "Timeout"   -> timeout,
      "StartTime" -> startTime,
      "PollKey"   -> pollKey|>];
    
    rt["AsyncExecution"] = <|
      "Future"           -> future,
      "HeldExpr"         -> heldExpr,
      "Timeout"          -> timeout,
      "StartTime"        -> startTime,
      "PollKey"          -> pollKey,
      "Adapter"          -> adapter,
      "Proposal"         -> proposal,
      "ValidationResult" -> validationResult,
      "ContextPacket"    -> contextPacket|>;
    $iClaudeRuntimes[runtimeId] = rt;
    
    (* claudecode.wl \:306e\:5171\:6709 polling \:30bf\:30b9\:30af\:306b\:767b\:9332\:3002
       Phase 32f (2026-05-13): Suppressible -> True \:3092\:660e\:793a\:3002
       UI \:64cd\:4f5c (documentation) \:4e2d\:306f $ClaudePriorityModeUntil \:304c\:8a2d\:5b9a\:3055\:308c\:3001
       Suppressible -> True \:306e tick \:306f\:4e00\:6642\:7684\:306b\:30b9\:30ad\:30c3\:30d7\:3055\:308c\:308b\:3002
       claudecode \:81ea\:8eab\:306e ClaudeQuery \:9032\:884c\:30b8\:30e7\:30d6\:306f Suppressible -> False
       (\:30c7\:30d5\:30a9\:30eb\:30c8) \:306a\:306e\:3067\:3001UI \:30e2\:30fc\:30c9\:4e2d\:3082\:5f71\:97ff\:3092\:53d7\:3051\:305a\:9032\:884c\:3059\:308b\:3002 *)
    registerFn = ClaudeCode`ClaudeRegisterPollingTick;
    registerResult = Quiet @ Check[
      registerFn[pollKey,
        Function[Null, iAsyncExecutionTickFn[runtimeId]],
        "Phase"        -> "ExecutingAsync",
        "Caller"       -> "ClaudeRuntime",
        "Priority"     -> 10,
        "Suppressible" -> True],
      $Failed];
    
    If[registerResult === $Failed,
      (* \:767b\:9332\:5931\:6557\:6642\:306f\:540c\:671f\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af *)
      iAppendEvent[runtimeId, <|
        "Type"  -> "AsyncExecutionRegisterFailed",
        "Error" -> "ClaudeRegisterPollingTick unavailable"|>];
      Module[{result, fallbackExec},
        (* Future \:3092\:540c\:671f\:7684\:306b\:5f85\:3064 (\:30d6\:30ed\:30c3\:30ad\:30f3\:30b0\:3060\:304c\:6700\:5f8c\:306e\:899a\:609f\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af) *)
        result = Quiet @ Check[
          If[NumericQ[timeout] && timeout =!= Infinity,
            TimeConstrained[WaitNext[{future}][[1]], timeout, $TimedOut],
            WaitNext[{future}][[1]]],
          $Failed];
        fallbackExec = If[result === $TimedOut,
          <|"Success" -> False, "RawResult" -> None,
            "HeldExpr" -> heldExpr,
            "Error" -> "Async execution timed out (fallback sync wait)"|>,
          If[result === $Failed,
            <|"Success" -> False, "RawResult" -> None,
              "HeldExpr" -> heldExpr,
              "Error" -> "Async future retrieval failed"|>,
            <|"Success" -> True, "RawResult" -> result,
              "HeldExpr" -> heldExpr, "Error" -> None|>]];
        (* AsyncExecution \:30af\:30ea\:30a2 *)
        rt = $iClaudeRuntimes[runtimeId];
        If[AssociationQ[rt],
          rt["AsyncExecution"] = None;
          $iClaudeRuntimes[runtimeId] = rt];
        Return[iExecuteAndContinueSyncFinalize[runtimeId, adapter,
          proposal, validationResult, contextPacket, fallbackExec]]]];
    
    <|"Outcome" -> "AsyncExecutionScheduled",
      "PollKey" -> pollKey,
      "Timeout" -> timeout|>
  ];

(* polling tick \:6bce\:306b\:547c\:3070\:308c\:308b\:5b8c\:4e86\:30c1\:30a7\:30c3\:30af\:3002
   - \:30bf\:30a4\:30e0\:30a2\:30a6\:30c8\:306b\:9054\:3057\:305f\:3089\:5f37\:5236\:5b8c\:4e86 (AbortKernels + LaunchKernels)
   - WaitNext[{future}, 0.01] \:3067\:5373\:6642\:5b8c\:4e86\:5224\:5b9a
   - \:5b8c\:4e86\:6642\:306f iAsyncExecutionFinalize \:3092\:547c\:3076 *)
iAsyncExecutionTickFn[runtimeId_String] :=
  Module[{rt, async, future, elapsed, timeout, pollResult, execResult},
    rt = Quiet @ Check[$iClaudeRuntimes[runtimeId], None];
    If[!AssociationQ[rt],
      (* runtime \:81ea\:4f53\:304c\:6d88\:5931\:3057\:3066\:3044\:308b\:5834\:5408: tick \:767b\:9332\:3092\:524a\:9664 *)
      Quiet @ ClaudeCode`ClaudeUnregisterPollingTick[
        iAsyncExecutionPollKey[runtimeId]];
      Return[]];
    
    async = Lookup[rt, "AsyncExecution", None];
    If[!AssociationQ[async] || Length[async] === 0,
      Quiet @ ClaudeCode`ClaudeUnregisterPollingTick[
        iAsyncExecutionPollKey[runtimeId]];
      Return[]];
    
    future   = Lookup[async, "Future", None];
    timeout  = Lookup[async, "Timeout", 30];
    elapsed  = AbsoluteTime[] - Lookup[async, "StartTime", AbsoluteTime[]];
    
    (* \:30bf\:30a4\:30e0\:30a2\:30a6\:30c8\:5224\:5b9a *)
    If[NumericQ[timeout] && timeout =!= Infinity && elapsed > timeout,
      iAppendEvent[runtimeId, <|
        "Type"    -> "AsyncExecutionTimedOut",
        "Elapsed" -> elapsed,
        "Timeout" -> timeout|>];
      (* \:5f37\:5236\:7d42\:4e86: AbortKernels \:5f8c\:518d\:8d77\:52d5 *)
      Quiet @ Check[
        AbortKernels[]; LaunchKernels[];,
        Null];
      execResult = <|
        "Success"   -> False,
        "RawResult" -> None,
        "HeldExpr"  -> Lookup[async, "HeldExpr", None],
        "Error"     -> "Async execution timed out after " <>
                       ToString[timeout] <> "s"|>;
      iAsyncExecutionFinalize[runtimeId, execResult];
      Return[]];
    
    (* \:5b8c\:4e86\:5224\:5b9a: WaitNext \:30bf\:30a4\:30e0\:30a2\:30a6\:30c8 0.01 \:79d2 *)
    pollResult = iPollFutureComplete[future, 0.01];
    
    If[TrueQ[Lookup[pollResult, "Completed", False]],
      Module[{result = Lookup[pollResult, "Result", $Failed]},
        execResult = Which[
          result === $TimedOut,
            <|"Success" -> False, "RawResult" -> None,
              "HeldExpr" -> Lookup[async, "HeldExpr", None],
              "Error"    -> "Kernel-side TimeConstrained timed out"|>,
          result === $Failed,
            <|"Success" -> False, "RawResult" -> None,
              "HeldExpr" -> Lookup[async, "HeldExpr", None],
              "Error"    -> "WaitNext returned $Failed"|>,
          True,
            <|"Success" -> True, "RawResult" -> result,
              "HeldExpr" -> Lookup[async, "HeldExpr", None],
              "Error"    -> None|>];
        iAsyncExecutionFinalize[runtimeId, execResult]]]
  ];

(* \:5b8c\:4e86\:6642\:306b\:547c\:3070\:308c\:308b\:6700\:7d42\:51e6\:7406:
   1) polling \:30bf\:30b9\:30af\:3092\:89e3\:9664
   2) AsyncExecution \:60c5\:5831\:3092\:30af\:30ea\:30a2
   3) iExecuteAndContinueSyncFinalize \:3092\:547c\:3076 (Redact \:4ee5\:964d)
   4) ContinuationPending \:306e\:5834\:5408\:306f ClaudeRunTurn \:3092\:518d\:5e30\:7684\:306b\:8d77\:52d5
   5) Notebook callback (meta) \:3067\:7d50\:679c\:8868\:793a *)
iAsyncExecutionFinalize[runtimeId_String, execResult_] :=
  Module[{rt, async, pollKey, adapter, proposal, validationResult,
          ctxPacket, syncResult, contInput, meta, callback},
    rt = $iClaudeRuntimes[runtimeId];
    If[!AssociationQ[rt], Return[<|"Outcome" -> "Failed",
      "Reason" -> "RuntimeMissing"|>]];
    
    async = Lookup[rt, "AsyncExecution", <||>];
    If[!AssociationQ[async] || Length[async] === 0,
      Return[<|"Outcome" -> "Failed",
        "Reason" -> "AsyncExecutionMissing"|>]];
    
    pollKey          = Lookup[async, "PollKey", None];
    adapter          = Lookup[async, "Adapter", <||>];
    proposal         = Lookup[async, "Proposal", <||>];
    validationResult = Lookup[async, "ValidationResult", <||>];
    ctxPacket        = Lookup[async, "ContextPacket", <||>];
    
    (* polling \:30bf\:30b9\:30af\:3092\:89e3\:9664 *)
    If[StringQ[pollKey],
      Quiet @ ClaudeCode`ClaudeUnregisterPollingTick[pollKey]];
    
    (* AsyncExecution \:60c5\:5831\:3092\:30af\:30ea\:30a2 *)
    rt = $iClaudeRuntimes[runtimeId];
    If[AssociationQ[rt],
      rt["AsyncExecution"] = None;
      rt["LastExecutionResult"] = execResult;
      $iClaudeRuntimes[runtimeId] = rt];
    
    iAppendEvent[runtimeId, <|
      "Type"    -> "AsyncExecutionCompleted",
      "Success" -> TrueQ[Lookup[execResult, "Success", False]]|>];
    
    (* \:540c\:671f\:51e6\:7406\:306e\:7d9a\:304d (Redact \:4ee5\:964d) *)
    syncResult = iExecuteAndContinueSyncFinalize[runtimeId, adapter,
      proposal, validationResult, ctxPacket, execResult];
    
    (* ContinuationPending \:306a\:3089\:7d99\:7d9a\:30bf\:30fc\:30f3\:3092\:8d77\:52d5\:3002
       Notebook \:5f15\:6570\:306f $Failed \:3067\:5b89\:5168\:5024\:3068\:3057\:3066\:6e21\:3057\:3001
       ClaudeRunTurn \:5074\:306f Metadata \:7d4c\:7531\:3067 nb \:3092\:518d\:8a3c\:5b9a\:3059\:308b\:3002 *)
    If[AssociationQ[syncResult] &&
       Lookup[syncResult, "Outcome", ""] === "ContinuationPending",
      contInput = Lookup[$iClaudeRuntimes[runtimeId],
        "ContinuationInput", None];
      iUpdateStatus[runtimeId, "Done"];
      If[contInput =!= None,
        Quiet @ Check[
          ClaudeRunTurn[runtimeId, contInput, "Notebook" -> $Failed],
          Null]]];
    
    (* Notebook callback: \:5b8c\:4e86\:6642\:306e\:7d50\:679c\:8868\:793a
       2026-05-15: \:5143\:306f Outcome === "Done" \:306e\:307f\:3060\:3063\:305f\:304c\:3001
       AsyncExecutionTimedOut \:7d4c\:7531\:3067 ExecutionFailed \:306b\:306a\:3063\:305f\:5834\:5408\:306b\:3082
       \:30e6\:30fc\:30b6\:30fc\:306b\:30a8\:30e9\:30fc\:3092\:8868\:793a\:3059\:308b\:5fc5\:8981\:304c\:3042\:308b\:305f\:3081\:3001
       \"Done\" | \"Failed\" | \"AwaitingApproval\" \:3092\:8a31\:5bb9\:3059\:308b\:3002
       ContinuationPending \:3060\:3051\:306f\:6b21\:306e turn \:304c\:8d70\:308b\:306e\:3067\:9664\:5916\:3002 *)
    Module[{rt2 = $iClaudeRuntimes[runtimeId], finalOutcome},
      If[AssociationQ[rt2],
        meta = Lookup[rt2, "Metadata", <||>];
        callback = Lookup[meta, "NotebookCallback", None];
        finalOutcome = If[AssociationQ[syncResult],
          Lookup[syncResult, "Outcome", ""], ""];
        If[callback =!= None &&
           MemberQ[{"Done", "Failed", "AwaitingApproval"}, finalOutcome],
          Quiet @ Check[callback[runtimeId], Null]]]];
    
    syncResult
  ];

(* \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550
   9c. Phase 32k Step 3 Phase C (2026-05-14):
        Tool \:5b9f\:884c\:306e\:975e\:540c\:671f\:5316 (AsyncToolExec state machine)
   \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550

   adapter \:304c "AsyncToolNames"/"SubmitToolAsync"/"CollectToolAsync"/"CancelToolAsync"/
   "MaxConcurrentTools" \:3092\:6301\:3064\:5834\:5408\:306b\:3001toolCalls \:306e\:3046\:3061 AsyncToolNames \:306b\:5217\:6319\:3055\:308c\:305f
   tool \:3092\:5225 OS \:30d7\:30ed\:30bb\:30b9\:5316\:3057\:3001\:5171\:6709 polling tick \:7d4c\:7531\:3067\:5b8c\:4e86\:3092\:30dd\:30fc\:30ea\:30f3\:30b0\:3059\:308b\:3002

   Phase C \:306e\:7bc4\:56f2: AsyncToolExec state machine \:306e\:4f5c\:308a\:8fbc\:307f\:306e\:307f\:3002
   iToolUseAndContinue \:306b\:306f\:3055\:305f\:63a5\:7d9a\:3057\:306a\:3044 (Phase D \:3067\:63a5\:7d9a)\:3002
   \:672c\:7bc4\:56f2\:306f\:76f4\:63a5\:547c\:3073\:51fa\:3057\:3067\:5358\:4f53\:30c6\:30b9\:30c8\:3059\:308b\:3053\:3068\:3092\:60f3\:5b9a\:3059\:308b\:3002

   AsyncToolExec state \:30b9\:30ad\:30fc\:30de\:30fc(\:30ec\:30d3\:30e5\:30fc \:00a74.2):
     rt["AsyncToolExec"] = <|
       "PollKey"             -> _String,
       "ToolCalls"           -> _List,        (* \:5143 toolCalls \:5168\:4f53 *)
       "SyncResultsByIndex"  -> <||>,         (* sync \:3067\:5148\:306b\:5b9f\:884c\:3057\:305f\:5206 *)
       "Queue"               -> _List,        (* {<|"Index"\[Rule]i,"Call"\[Rule]call|>, ...} *)
       "Running"             -> _List,        (* entry list (Index \:30d5\:30a3\:30fc\:30eb\:30c9\:4ed8\:4e0e\:6e08) *)
       "CollectedByIndex"    -> <||>,         (* Index \[Rule] toolResult *)
       "MaxConcurrent"       -> 4,
       "Adapter"             -> _,
       "Proposal"             -> _,
       "ValidationResult"    -> _,
       "ContextPacket"       -> _,
       "StartTime"           -> _Real,
       "Finalized"           -> False|>

   \:30ec\:30d3\:30e5\:30fc\:53cd\:6620:
     \:00a73.2: \:7d50\:679c\:306e\:5143\:9806\:5e8f\:5fa9\:5143 (Index \:4fdd\:6301)
     \:00a73.3: adapter API \:7d4c\:7531\:3067 claudecode private \:306b\:4f9d\:5b58\:3057\:306a\:3044
     \:00a73.6: polling \:767b\:9332\:5931\:6557\:6642\:306f\:540c\:671f wait \:3057\:306a\:3044 (Process kill + error)
     \:00a74.1/\:00a74.2: MaxConcurrent + Queue/Running/CollectedByIndex
     \:00a79: pollKey \:306b runtimeId + turn + UUID \:3092\:542b\:3081\:308b *)

(* \[HorizontalLine] PollKey \[HorizontalLine] *)
iAsyncToolExecPollKey[runtimeId_String, turnCount_:0] :=
  "ClaudeRuntimeToolExec_" <> runtimeId <> "_" <>
    ToString[turnCount] <> "_" <> CreateUUID[];

(* \[HorizontalLine] toolCalls \:3092 sync/async \:306b\:632f\:308a\:5206\:3051\:308b \[HorizontalLine]
   \:8fd4\:308a\:5024: <|"SyncCalls"\[Rule]{<|Index,Call|>...}, "AsyncCalls"\[Rule]{<|Index,Call|>...}|>
   adapter \:306b "AsyncToolNames" \:304c\:306a\:3044/\:7a7a\:306e\:5834\:5408\:306f\:5168\:90e8 sync \:306b\:306a\:308b\:3002 *)
iClassifyToolCalls[toolCalls_List, adapter_Association] :=
  Module[{asyncNames, sync = {}, async = {}},
    asyncNames = Lookup[adapter, "AsyncToolNames", {}];
    If[!ListQ[asyncNames] || Length[asyncNames] === 0,
      Return[<|"SyncCalls"  -> MapIndexed[
                  <|"Index" -> #2[[1]], "Call" -> #1|> &, toolCalls],
               "AsyncCalls" -> {}|>]];

    Do[
      Module[{call = toolCalls[[i]], name},
        name = Lookup[call, "Name", ""];
        If[MemberQ[asyncNames, name],
          AppendTo[async, <|"Index" -> i, "Call" -> call|>],
          AppendTo[sync,  <|"Index" -> i, "Call" -> call|>]]],
      {i, Length[toolCalls]}];

    <|"SyncCalls" -> sync, "AsyncCalls" -> async|>
  ];

iClassifyToolCalls[___] := <|"SyncCalls" -> {}, "AsyncCalls" -> {}|>;

(* \[HorizontalLine] 1 \:500b\:306e async call \:3092\:8d77\:52d5\:3057\:3066 Running entry \:3092\:8fd4\:3059 \[HorizontalLine]
   \:5931\:6557\:3057\:305f\:5834\:5408\:3082 entry \:3092\:8fd4\:3059 (Status=\"Failed\" \:4ed8\:304d)\:3002Index \:30d5\:30a3\:30fc\:30eb\:30c9\:3092\:4ed8\:4e0e\:3059\:308b\:3002 *)
iAsyncToolExecSubmitOne[adapter_Association, indexedCall_Association,
    contextPacket_Association] :=
  Module[{submitFn, entry},
    submitFn = Lookup[adapter, "SubmitToolAsync", None];
    If[Head[submitFn] =!= Function,
      Return[<|"Index" -> Lookup[indexedCall, "Index", 0],
               "ToolCall" -> Lookup[indexedCall, "Call", <||>],
               "ToolName" -> Lookup[
                 Lookup[indexedCall, "Call", <||>], "Name", ""],
               "ToolId" -> Lookup[
                 Lookup[indexedCall, "Call", <||>], "Id", ""],
               "Status" -> "Failed",
               "Error" -> "Adapter SubmitToolAsync missing"|>]];

    entry = Quiet @ Check[
      submitFn[Lookup[indexedCall, "Call", <||>], contextPacket],
      $Failed];

    If[!AssociationQ[entry],
      Return[<|"Index" -> Lookup[indexedCall, "Index", 0],
               "ToolCall" -> Lookup[indexedCall, "Call", <||>],
               "ToolName" -> Lookup[
                 Lookup[indexedCall, "Call", <||>], "Name", ""],
               "ToolId" -> Lookup[
                 Lookup[indexedCall, "Call", <||>], "Id", ""],
               "Status" -> "Failed",
               "Error" -> "SubmitToolAsync returned non-association"|>]];

    Append[entry, "Index" -> Lookup[indexedCall, "Index", 0]]
  ];

(* \[HorizontalLine] Failed entry \:3092 toolResult Association \:306b\:5909\:63db \[HorizontalLine] *)
iAsyncToolExecEntryToFailedResult[entry_Association] :=
  <|"ToolName" -> Lookup[entry, "ToolName", ""],
    "ToolId"   -> Lookup[entry, "ToolId", ""],
    "Success"  -> False,
    "Error"    -> Lookup[entry, "Error", "Unknown async tool error"]|>;

(* \[HorizontalLine] AsyncToolExec \:306e schedule (\:4e3b\:8981\:30a8\:30f3\:30c8\:30ea\:30dd\:30a4\:30f3\:30c8) \[HorizontalLine]

   asyncCallsWithIndex: {<|"Index"\[Rule]i,"Call"\[Rule]call|>, ...}
   syncResultsByIndex:  <|i\[Rule]toolResult, ...|>  (sync \:3092\:5148\:306b\:5b9f\:884c\:3057\:305f\:5834\:5408)

   asyncCalls \:304c\:7a7a\:306a\:3089\:5373\:6642 finalize (\:540c\:671f\:8fd4\:308a)\:3002 *)
iScheduleAsyncToolExecPoll[runtimeId_String, adapter_Association,
    proposal_Association, validationResult_Association,
    contextPacket_Association,
    syncResultsByIndex_Association,
    asyncCallsWithIndex_List, toolCalls_List] :=
  Module[{rt, pollKey, maxConcurrent, queue, running, available,
          toStart, registerFn, registerResult, turnCount,
          submittedFailed, submittedRunning, splitRes,
          failedEntries = {}, finalEntries},
    rt = $iClaudeRuntimes[runtimeId];
    If[!AssociationQ[rt],
      Return[<|"Outcome" -> "Failed", "Reason" -> "RuntimeMissing"|>]];

    turnCount = Lookup[rt, "TurnCount", 0];
    pollKey   = iAsyncToolExecPollKey[runtimeId, turnCount];

    maxConcurrent = Lookup[adapter, "MaxConcurrentTools", 4];
    If[!IntegerQ[maxConcurrent] || maxConcurrent <= 0,
      maxConcurrent = 4];

    (* \:521d\:671f Queue: \:5168 asyncCalls *)
    queue = asyncCallsWithIndex;

    (* MaxConcurrent \:307e\:3067\:3092\:5373\:6642\:8d77\:52d5 *)
    available = Min[maxConcurrent, Length[queue]];
    toStart = Take[queue, available];
    queue = Drop[queue, available];

    running = Map[
      iAsyncToolExecSubmitOne[adapter, #, contextPacket] &, toStart];

    (* Status="Failed" \:306e entry \:306f\:5373\:6642\:306b CollectedByIndex \:306b\:5165\:308c\:308b\:3002
       Running \:306b\:306f\:751f\:304d\:3066\:3044\:308b Process \:3092\:6301\:3064 entry \:3060\:3051\:6b8b\:3059\:3002 *)
    splitRes = GroupBy[running,
      (Lookup[#, "Status", ""] === "Failed") &];
    failedEntries    = Lookup[splitRes, True, {}];
    submittedRunning = Lookup[splitRes, False, {}];

    (* CollectedByIndex \:521d\:671f\:5024 *)
    Module[{collected = <||>},
      Scan[
        Function[{entry},
          collected[Lookup[entry, "Index", 0]] =
            iAsyncToolExecEntryToFailedResult[entry]],
        failedEntries];

      (* State \:3092 RuntimeState \:306b\:4fdd\:5b58 *)
      rt["AsyncToolExec"] = <|
        "PollKey"             -> pollKey,
        "ToolCalls"           -> toolCalls,
        "SyncResultsByIndex"  -> syncResultsByIndex,
        "Queue"               -> queue,
        "Running"             -> submittedRunning,
        "CollectedByIndex"    -> collected,
        "MaxConcurrent"       -> maxConcurrent,
        "Adapter"             -> adapter,
        "Proposal"            -> proposal,
        "ValidationResult"    -> validationResult,
        "ContextPacket"       -> contextPacket,
        "StartTime"           -> AbsoluteTime[],
        "Finalized"           -> False|>;
      $iClaudeRuntimes[runtimeId] = rt;
    ];

    iUpdatePhase[runtimeId, "ExecutingAsyncTools"];
    iAppendEvent[runtimeId, <|
      "Type"            -> "AsyncToolExecStarted",
      "PollKey"         -> pollKey,
      "TotalAsync"      -> Length[asyncCallsWithIndex],
      "InitialRunning"  -> Length[submittedRunning],
      "InitialFailed"   -> Length[failedEntries],
      "QueueRemaining"  -> Length[queue],
      "MaxConcurrent"   -> maxConcurrent|>];

    (* \:3082\:3057 Queue/Running \:3068\:3082\:306b\:7a7a\:306a\:3089\:5373\:6642 finalize \:3002
       \:ff08\:4f8b: asyncCalls \:304c\:7a7a / \:5168\:4e8b\:696d submit \:5931\:6557\:ff09*)
    If[Length[queue] === 0 && Length[submittedRunning] === 0,
      Return[iAsyncToolExecFinalize[runtimeId]]];

    (* polling tick \:3092\:767b\:9332\:3002\:30ec\:30d3\:30e5\:30fc \:00a73.6:
       \:767b\:9332\:5931\:6557\:6642\:306f\:540c\:671f wait \:306b\:623b\:3089\:305a\:3001Running \:3092 cancel \:3057\:3066 error \:306b\:3059\:308b\:3002 *)
    registerFn = ClaudeCode`ClaudeRegisterPollingTick;
    registerResult = Quiet @ Check[
      registerFn[pollKey,
        Function[Null, iAsyncToolExecTickFn[runtimeId]],
        "Phase"        -> "ExecutingAsyncTools",
        "Caller"       -> "ClaudeRuntime",
        "Priority"     -> 10,
        "Suppressible" -> True],
      $Failed];

    If[registerResult === $Failed,
      iAppendEvent[runtimeId, <|
        "Type"  -> "AsyncToolExecRegisterFailed",
        "Error" -> "ClaudeRegisterPollingTick unavailable"|>];
      (* Running \:306e\:5168 entry \:3092 cancel + error \:5316 *)
      Module[{cancelFn = Lookup[adapter, "CancelToolAsync", None],
              rt2, collected2},
        rt2 = $iClaudeRuntimes[runtimeId];
        collected2 = Lookup[rt2["AsyncToolExec"],
          "CollectedByIndex", <||>];
        Scan[
          Function[{entry},
            Module[{idx = Lookup[entry, "Index", 0], r},
              r = If[Head[cancelFn] === Function,
                Quiet @ Check[cancelFn[entry], $Failed],
                $Failed];
              collected2[idx] = If[AssociationQ[r], r,
                <|"ToolName" -> Lookup[entry, "ToolName", ""],
                  "ToolId"   -> Lookup[entry, "ToolId", ""],
                  "Success"  -> False,
                  "Error"    -> "Polling register failed; cancelled"|>]]],
          submittedRunning];
        rt2["AsyncToolExec"]["CollectedByIndex"] = collected2;
        rt2["AsyncToolExec"]["Running"]          = {};
        rt2["AsyncToolExec"]["Queue"]            = {};
        $iClaudeRuntimes[runtimeId] = rt2];
      Return[iAsyncToolExecFinalize[runtimeId]]];

    (* Phase 32k Step 3 Phase D2 (2026-05-14):
       $claudeProgress[pollKey] \:306b ClaudeStatus[] / WindowStatusArea \:7528\:306e
       \:8ffd\:52a0\:60c5\:5831\:3092\:30bb\:30c3\:30c8\:3057\:3001UI \:30b9\:30c6\:30fc\:30bf\:30b9\:8868\:793a\:304c\:5076\:6240\:6027\:3092\:6301\:3064\:3088\:3046\:306b\:3059\:308b\:3002
       ClaudeRegisterPollingTick \:81ea\:4f53\:306f tickFn/phase/caller \:7b49\:3057\:304b\:691c\:7d22\:3057\:306a\:3044\:305f\:3081\:3001
       \:8ffd\:52a0\:30d5\:30a3\:30fc\:30eb\:30c9 (startTime / status / nb / toolUses) \:3092\:660e\:793a\:7684\:306b\:5165\:308c\:308b\:3002 *)
    Module[{nbForStatus, initialDisp, initialStatusJP},
      nbForStatus = Lookup[
        Lookup[rt, "Metadata", <||>], "Notebook", $Failed];
      If[Head[nbForStatus] =!= NotebookObject, nbForStatus = $Failed];

      initialStatusJP = If[$Language === "Japanese",
        "Web\:691c\:7d22\:4e26\:5217\:5b9f\:884c\:4e2d",
        "Async web search"];
      initialDisp = If[$Language === "Japanese",
        "ClaudeRuntime: Web\:691c\:7d22\:4e26\:5217\:5b9f\:884c\:4e2d... 0s | " <>
          ToString[Length[submittedRunning]] <> "/" <>
          ToString[Length[asyncCallsWithIndex]],
        "ClaudeRuntime: Async tools... 0s | " <>
          ToString[Length[submittedRunning]] <> "/" <>
          ToString[Length[asyncCallsWithIndex]]];

      If[AssociationQ[ClaudeCode`Private`$claudeProgress] &&
         KeyExistsQ[ClaudeCode`Private`$claudeProgress, pollKey],
        ClaudeCode`Private`$claudeProgress[pollKey, "startTime"]    = AbsoluteTime[];
        ClaudeCode`Private`$claudeProgress[pollKey, "status"]       = initialStatusJP;
        ClaudeCode`Private`$claudeProgress[pollKey, "disp"]         = initialDisp;
        ClaudeCode`Private`$claudeProgress[pollKey, "nb"]           = nbForStatus;
        ClaudeCode`Private`$claudeProgress[pollKey, "toolUses"]     = Length[asyncCallsWithIndex];
        ClaudeCode`Private`$claudeProgress[pollKey, "textFragments"] = 0;
        ClaudeCode`Private`$claudeProgress[pollKey, "thinkingFragments"] = 0;
        ClaudeCode`Private`$claudeProgress[pollKey, "lineCount"]    = 0;
        ClaudeCode`Private`$claudeProgress[pollKey, "lastText"]     = "";
        ClaudeCode`Private`$claudeProgress[pollKey, "caller"]       = "ClaudeRuntime:Async-Tools"];

      If[Head[nbForStatus] === NotebookObject,
        Quiet[CurrentValue[nbForStatus, WindowStatusArea] = initialDisp]];
    ];

    <|"Outcome"        -> "AsyncToolExecScheduled",
      "PollKey"        -> pollKey,
      "InitialRunning" -> Length[submittedRunning],
      "QueueRemaining" -> Length[queue]|>
  ];

iScheduleAsyncToolExecPoll[___] :=
  <|"Outcome" -> "Failed", "Reason" -> "InvalidArgs"|>;

(* \[HorizontalLine] polling tick \:672c\:4f53 \[HorizontalLine]
   1) Running \:306e\:5404 entry \:3092\:898b\:3066\:5b8c\:4e86 / timeout \:3092\:691c\:51fa
   2) \:5b8c\:4e86 entry: CollectToolAsync \:3067\:7d50\:679c\:56de\:53ce \[Rule] CollectedByIndex
   3) timeout entry: CancelToolAsync \:3067 kill + cleanup \[Rule] error result
   4) Queue \:304b\:3089 MaxConcurrent \:307e\:3067\:8ffd\:52a0\:8d77\:52d5
   5) Queue=={} \:304b\:3064 Running=={} \:306a\:3089 finalize *)
iAsyncToolExecTickFn[runtimeId_String] :=
  Module[{rt, async, running, queue, maxC, adapter, ctxPacket,
          collected, completedIdxs = {}, timeoutIdxs = {},
          collectFn, cancelFn, available, toStart, newlyStarted,
          newRunning, newQueue, splitRes, failedEntries},
    rt = Quiet @ Check[$iClaudeRuntimes[runtimeId], None];
    If[!AssociationQ[rt],
      Quiet @ ClaudeCode`ClaudeUnregisterPollingTick[
        "ClaudeRuntimeToolExec_" <> runtimeId];  (* fallback *)
      Return[]];

    async = Lookup[rt, "AsyncToolExec", None];
    If[!AssociationQ[async] || Length[async] === 0,
      Quiet @ ClaudeCode`ClaudeUnregisterPollingTick[
        "ClaudeRuntimeToolExec_" <> runtimeId];
      Return[]];

    If[TrueQ[Lookup[async, "Finalized", False]],
      Quiet @ ClaudeCode`ClaudeUnregisterPollingTick[
        Lookup[async, "PollKey", ""]];
      Return[]];

    running    = Lookup[async, "Running", {}];
    queue      = Lookup[async, "Queue", {}];
    maxC       = Lookup[async, "MaxConcurrent", 4];
    adapter    = Lookup[async, "Adapter", <||>];
    ctxPacket  = Lookup[async, "ContextPacket", <||>];
    collected  = Lookup[async, "CollectedByIndex", <||>];
    collectFn  = Lookup[adapter, "CollectToolAsync", None];
    cancelFn   = Lookup[adapter, "CancelToolAsync", None];

    (* (1)(2)(3) Running \:3092\:8d70\:67fb *)
    newRunning = {};
    Scan[
      Function[{entry},
        Module[{proc, status, elapsed, tmo, idx, r},
          proc    = Lookup[entry, "Process", None];
          idx     = Lookup[entry, "Index", 0];
          tmo     = Lookup[entry, "Timeout", 300];
          elapsed = AbsoluteTime[] -
            Lookup[entry, "StartTime", AbsoluteTime[]];

          status = If[Head[proc] === ProcessObject,
            Quiet @ Check[ProcessStatus[proc], "Unknown"],
            "Invalid"];

          Which[
            (* timeout *)
            NumericQ[tmo] && elapsed > tmo &&
              status === "Running",
              AppendTo[timeoutIdxs, idx];
              r = If[Head[cancelFn] === Function,
                Quiet @ Check[cancelFn[entry], $Failed],
                $Failed];
              collected[idx] = If[AssociationQ[r],
                Append[r, "Error" -> "Async tool timed out after " <>
                  ToString[tmo] <> "s"],
                <|"ToolName" -> Lookup[entry, "ToolName", ""],
                  "ToolId"   -> Lookup[entry, "ToolId", ""],
                  "Success"  -> False,
                  "Error"    -> "Async tool timed out (cancel failed)"|>],

            (* \:5b8c\:4e86 (ProcessStatus =!= "Running")
               Phase 32k Step 3 Phase B \:3067\:691c\:51fa: Mathematica 14 \:3067\:306f
               "Finished" \:3092\:8fd4\:3059\:3002"Stopped" / "Aborted" / "Unknown" \:3082
               \:5b8c\:4e86\:6271\:3044\:306b\:3057\:3066\:53ce\:96c6\:3059\:308b\:3002 *)
            status =!= "Running" && status =!= "Invalid",
              AppendTo[completedIdxs, idx];
              r = If[Head[collectFn] === Function,
                Quiet @ Check[collectFn[entry], $Failed],
                $Failed];
              collected[idx] = If[AssociationQ[r], r,
                <|"ToolName" -> Lookup[entry, "ToolName", ""],
                  "ToolId"   -> Lookup[entry, "ToolId", ""],
                  "Success"  -> False,
                  "Error"    -> "CollectToolAsync failed"|>],

            (* Invalid \:30d7\:30ed\:30bb\:30b9 *)
            status === "Invalid",
              AppendTo[completedIdxs, idx];
              collected[idx] = <|
                "ToolName" -> Lookup[entry, "ToolName", ""],
                "ToolId"   -> Lookup[entry, "ToolId", ""],
                "Success"  -> False,
                "Error"    -> "Process object invalid"|>,

            (* \:307e\:3060\:5b9f\:884c\:4e2d *)
            True,
              AppendTo[newRunning, entry]]
        ]],
      running];

    (* (4) Queue \:304b\:3089 MaxConcurrent \:307e\:3067\:8ffd\:52a0\:8d77\:52d5 *)
    available = maxC - Length[newRunning];
    newQueue = queue;
    If[available > 0 && Length[queue] > 0,
      toStart = Take[queue, Min[available, Length[queue]]];
      newQueue = Drop[queue, Min[available, Length[queue]]];
      newlyStarted = Map[
        iAsyncToolExecSubmitOne[adapter, #, ctxPacket] &, toStart];

      (* Status="Failed" \:3092\:5206\:96e2\:3057\:3066 collected \:3078 *)
      splitRes = GroupBy[newlyStarted,
        (Lookup[#, "Status", ""] === "Failed") &];
      failedEntries = Lookup[splitRes, True, {}];
      newlyStarted  = Lookup[splitRes, False, {}];

      Scan[
        Function[{entry},
          collected[Lookup[entry, "Index", 0]] =
            iAsyncToolExecEntryToFailedResult[entry]],
        failedEntries];

      newRunning = Join[newRunning, newlyStarted]];

    (* state \:66f4\:65b0 *)
    rt = $iClaudeRuntimes[runtimeId];
    If[AssociationQ[rt] && AssociationQ[Lookup[rt, "AsyncToolExec", None]],
      rt["AsyncToolExec"]["Running"]          = newRunning;
      rt["AsyncToolExec"]["Queue"]            = newQueue;
      rt["AsyncToolExec"]["CollectedByIndex"] = collected;
      $iClaudeRuntimes[runtimeId] = rt];

    If[Length[completedIdxs] > 0 || Length[timeoutIdxs] > 0,
      iAppendEvent[runtimeId, <|
        "Type"           -> "AsyncToolExecTick",
        "CompletedIdxs"  -> completedIdxs,
        "TimeoutIdxs"    -> timeoutIdxs,
        "Running"        -> Length[newRunning],
        "Queue"          -> Length[newQueue]|>]];

    (* Phase 32k Step 3 Phase D2 (2026-05-14):
       \:30bf\:30a4\:30c8\:30eb\:30d0\:30fc\:306e WindowStatusArea \:3068 ClaudeStatus[] \:7528 $claudeProgress \:3092\:6bce tick \:66f4\:65b0\:3002
       \:7d4c\:904e\:6642\:9593\:30fbRunning/Done \:6570\:30fb\:5b8c\:4e86\:8a08\:6570\:3092\:8868\:793a\:3057\:3001
       \:300c0 sec \:306e\:307e\:307e\:6b62\:307e\:3063\:305f\:3088\:3046\:306b\:898b\:3048\:308b\:300d\:554f\:984c\:3092\:89e3\:6d88\:3059\:308b\:3002 *)
    Module[{asyncRefresh, pollKey, startT, elapsed, runC, doneC, totalC,
            nbForStatus, dispText, statusText},
      asyncRefresh = Lookup[rt, "AsyncToolExec", <||>];
      pollKey      = Lookup[asyncRefresh, "PollKey", ""];
      startT       = Lookup[asyncRefresh, "StartTime", AbsoluteTime[]];
      elapsed      = Round[AbsoluteTime[] - startT, 1];
      runC         = Length[newRunning];
      doneC        = Length[collected];
      totalC       = Length[Lookup[asyncRefresh, "ToolCalls", {}]];
      nbForStatus  = Lookup[
        Lookup[rt, "Metadata", <||>], "Notebook", $Failed];
      If[Head[nbForStatus] =!= NotebookObject, nbForStatus = $Failed];

      statusText = Which[
        runC === 0 && doneC === totalC,
          If[$Language === "Japanese", "\:5b8c\:4e86", "Done"],
        runC > 0,
          If[$Language === "Japanese",
            "Web\:691c\:7d22\:4e26\:5217\:5b9f\:884c\:4e2d (" <> ToString[doneC] <>
              "/" <> ToString[totalC] <> ")",
            "Async web search (" <> ToString[doneC] <>
              "/" <> ToString[totalC] <> ")"],
        True,
          If[$Language === "Japanese", "\:5f85\:6a5f\:4e2d", "Pending"]];

      dispText = If[$Language === "Japanese",
        "ClaudeRuntime: Web\:691c\:7d22\:4e26\:5217\:5b9f\:884c\:4e2d... " <>
          ToString[elapsed] <> "s | Run:" <> ToString[runC] <>
          " Done:" <> ToString[doneC] <> "/" <> ToString[totalC],
        "ClaudeRuntime: Async tools... " <>
          ToString[elapsed] <> "s | Run:" <> ToString[runC] <>
          " Done:" <> ToString[doneC] <> "/" <> ToString[totalC]];

      (* $claudeProgress \:66f4\:65b0 (ClaudeStatus[] \:8868\:793a\:7528) *)
      If[StringQ[pollKey] && pollKey =!= "" &&
         AssociationQ[ClaudeCode`Private`$claudeProgress] &&
         KeyExistsQ[ClaudeCode`Private`$claudeProgress, pollKey],
        ClaudeCode`Private`$claudeProgress[pollKey, "disp"]     = dispText;
        ClaudeCode`Private`$claudeProgress[pollKey, "status"]   = statusText;
        ClaudeCode`Private`$claudeProgress[pollKey, "toolUses"] = totalC];

      (* WindowStatusArea \:66f4\:65b0 (\:30bf\:30a4\:30c8\:30eb\:30d0\:30fc\:8868\:793a\:7528) *)
      If[Head[nbForStatus] === NotebookObject,
        Quiet[CurrentValue[nbForStatus, WindowStatusArea] = dispText]];
    ];

    (* (5) \:5b8c\:4e86\:5224\:5b9a *)
    If[Length[newQueue] === 0 && Length[newRunning] === 0,
      iAsyncToolExecFinalize[runtimeId]]
  ];

iAsyncToolExecTickFn[___] := Null;

(* \[HorizontalLine] toolCalls \:9806\:306b toolResults \:3092\:5fa9\:5143 (\:30ec\:30d3\:30e5\:30fc \:00a73.2 \:5fc5\:9808) \[HorizontalLine] *)
iToolExecMergeResults[toolCalls_List, syncResultsByIndex_Association,
    asyncResultsByIndex_Association] :=
  Table[
    Which[
      KeyExistsQ[asyncResultsByIndex, i],
        asyncResultsByIndex[i],
      KeyExistsQ[syncResultsByIndex, i],
        syncResultsByIndex[i],
      True,
        Module[{call = toolCalls[[i]]},
          <|"ToolName" -> Lookup[call, "Name", "?"],
            "ToolId"   -> Lookup[call, "Id", ""],
            "Success"  -> False,
            "Error"    -> "Missing tool result (index " <>
                          ToString[i] <> ")"|>]],
    {i, Length[toolCalls]}];

iToolExecMergeResults[___] := {};

(* \[HorizontalLine] AsyncToolExec finalize (\:5b8c\:4e86\:6642\:306e\:96c6\:7d04 \:00b7 continuation \:8d77\:52d5) \[HorizontalLine]

   \:4e3b\:8981\:51e6\:7406:
     1) polling tick \:3092\:89e3\:9664
     2) CollectedByIndex \:3068 SyncResultsByIndex \:3092\:30de\:30fc\:30b8\:3057\:3066\:5143 toolCalls \:9806\:306b\:5fa9\:5143
     3) AsyncToolExec \:3092\:30af\:30ea\:30a2 (Finalized\[Rule]True)
     4) ConversationState \:306b\:30c4\:30fc\:30eb\:7d50\:679c\:3092\:8a18\:9332
     5) ContinuationInput \:3092\:4f5c\:3063\:3066 ClaudeRunTurn \:3092\:518d\:8d77\:52d5

   Phase C \:6642\:70b9: iToolUseAndContinue \:306b\:63a5\:7d9a\:3055\:308c\:3066\:3044\:306a\:3044\:305f\:3081\:3001\:672c\:95a2\:6570\:306f
   \:96c6\:7d04\:3057\:305f toolResults \:3092 Association \:3068\:3057\:3066\:8fd4\:3059\:306e\:307f\:3002Phase D \:3067 ConversationState
   \:53cd\:6620 \:30fb continuation \:8d77\:52d5\:3092 iToolUseAndContinue \:4e26\:307f\:306b\:5b9f\:88c5\:3059\:308b\:3002 *)
iAsyncToolExecFinalize[runtimeId_String] :=
  Module[{rt, async, pollKey, toolCalls, syncByIdx, asyncByIdx,
          toolResults, summary},
    rt = $iClaudeRuntimes[runtimeId];
    If[!AssociationQ[rt],
      Return[<|"Outcome" -> "Failed",
               "Reason"  -> "RuntimeMissing"|>]];

    async = Lookup[rt, "AsyncToolExec", None];
    If[!AssociationQ[async] || Length[async] === 0,
      Return[<|"Outcome" -> "Failed",
               "Reason"  -> "AsyncToolExecMissing"|>]];

    pollKey    = Lookup[async, "PollKey", ""];
    toolCalls  = Lookup[async, "ToolCalls", {}];
    syncByIdx  = Lookup[async, "SyncResultsByIndex", <||>];
    asyncByIdx = Lookup[async, "CollectedByIndex", <||>];

    (* (1) polling tick \:89e3\:9664 *)
    If[StringQ[pollKey] && pollKey =!= "",
      Quiet @ ClaudeCode`ClaudeUnregisterPollingTick[pollKey]];

    (* (2) \:9806\:5e8f\:5fa9\:5143 *)
    toolResults = iToolExecMergeResults[toolCalls, syncByIdx, asyncByIdx];

    summary = <|
      "Outcome"       -> "AsyncToolExecCompleted",
      "PollKey"       -> pollKey,
      "ToolCount"     -> Length[toolCalls],
      "AsyncCount"    -> Length[asyncByIdx],
      "SyncCount"     -> Length[syncByIdx],
      "ToolResults"   -> toolResults,
      "Elapsed"       -> AbsoluteTime[] -
                         Lookup[async, "StartTime", AbsoluteTime[]]|>;

    (* (3) AsyncToolExec \:30af\:30ea\:30a2 + Finalized\[Rule]True \:30de\:30fc\:30af *)
    rt = $iClaudeRuntimes[runtimeId];
    If[AssociationQ[rt],
      rt["LastAsyncToolExecResult"] = summary;
      rt["AsyncToolExec"] = <|"Finalized" -> True,
        "LastSummary" -> summary|>;
      $iClaudeRuntimes[runtimeId] = rt];

    iAppendEvent[runtimeId, <|
      "Type"        -> "AsyncToolExecCompleted",
      "ToolCount"   -> Length[toolCalls],
      "Elapsed"     -> Lookup[summary, "Elapsed", 0]|>];

    (* (4) ConversationState \:53cd\:6620 + ContinuationInput \:69cb\:7bc9 \:2014\:2014 Phase D (2026-05-14) \:2014\:2014
       iToolUseAccumulateAndContinue \:3067 sync \:7d4c\:8def\:3068\:540c\:3058\:5f62\:5f0f\:306b\:8398\:7a4d\:3059\:308b\:3002
       \:3053\:308c\:3092\:547c\:3076\:3068 ContinuationInput \:304c rt \:306b\:4fdd\:5b58\:3055\:308c\:3001\:30a4\:30d9\:30f3\:30c8\:3082\:8a18\:9332\:3055\:308c\:308b\:3002 *)
    Module[{adapter, proposal, validationResult, ctxPacket, accumResult},
      adapter          = Lookup[async, "Adapter", <||>];
      proposal         = Lookup[async, "Proposal", <||>];
      validationResult = Lookup[async, "ValidationResult", <||>];
      ctxPacket        = Lookup[async, "ContextPacket", <||>];
      accumResult = Quiet @ Check[
        iToolUseAccumulateAndContinue[runtimeId, adapter, proposal,
          validationResult, ctxPacket, toolCalls, toolResults],
        <|"Outcome" -> "Failed",
          "Reason"  -> "AccumulateAndContinueFailed"|>];

      (* (5) ContinuationPending \:306a\:3089 ClaudeRunTurn \:3092\:660e\:793a\:7684\:306b\:518d\:8d77\:52d5\:3002
         \:65e2\:5b58 iAsyncExecutionFinalize \:3068\:540c\:3058\:30d1\:30bf\:30fc\:30f3\:3002
         Notebook \:5f15\:6570\:306f $Failed \:3067\:5b89\:5168\:5024\:3068\:3057\:3066\:6e21\:3057\:3001
         ClaudeRunTurn \:5074\:306f Metadata \:7d4c\:7531\:3067 nb \:3092\:518d\:8a3c\:5b9a\:3059\:308b\:3002 *)
      If[AssociationQ[accumResult] &&
         Lookup[accumResult, "Outcome", ""] === "ContinuationPending",
        Module[{contInput, rt2},
          rt2 = $iClaudeRuntimes[runtimeId];
          contInput = If[AssociationQ[rt2],
            Lookup[rt2, "ContinuationInput", None], None];
          iUpdateStatus[runtimeId, "Done"];
          If[contInput =!= None,
            Quiet @ Check[
              ClaudeRunTurn[runtimeId, contInput, "Notebook" -> $Failed],
              Null]]];
      ];
    ];

    summary
  ];

iAsyncToolExecFinalize[___] :=
  <|"Outcome" -> "Failed", "Reason" -> "InvalidArgs"|>;

(* \[HorizontalLine] Public: AsyncToolExec \:3092\:30ad\:30e3\:30f3\:30bb\:30eb \[HorizontalLine]

   Queue \:306f\:6368\:3066\:3001Running \:306e\:5168 entry \:3092 CancelToolAsync \:3067 kill\:3002
   polling tick \:3092\:89e3\:9664\:3057\:3001runtime status \:3092 "Cancelled" \:306b\:3059\:308b\:3002 *)
ClaudeRuntimeCancelAsyncToolExec[runtimeId_String] :=
  Module[{rt, async, adapter, cancelFn, running, queue, collected,
          pollKey, cancelledIdxs = {}},
    rt = Quiet @ Check[$iClaudeRuntimes[runtimeId], None];
    If[!AssociationQ[rt],
      Return[<|"Success" -> False, "Error" -> "Runtime not found"|>]];

    async = Lookup[rt, "AsyncToolExec", None];
    If[!AssociationQ[async] || Length[async] === 0 ||
       TrueQ[Lookup[async, "Finalized", False]],
      Return[<|"Success" -> False,
               "Error"   -> "No active AsyncToolExec"|>]];

    pollKey   = Lookup[async, "PollKey", ""];
    adapter   = Lookup[async, "Adapter", <||>];
    cancelFn  = Lookup[adapter, "CancelToolAsync", None];
    running   = Lookup[async, "Running", {}];
    queue     = Lookup[async, "Queue", {}];
    collected = Lookup[async, "CollectedByIndex", <||>];

    (* Running \:3092 cancel *)
    Scan[
      Function[{entry},
        Module[{idx = Lookup[entry, "Index", 0], r},
          r = If[Head[cancelFn] === Function,
            Quiet @ Check[cancelFn[entry], $Failed],
            $Failed];
          collected[idx] = If[AssociationQ[r], r,
            <|"ToolName" -> Lookup[entry, "ToolName", ""],
              "ToolId"   -> Lookup[entry, "ToolId", ""],
              "Success"  -> False,
              "Error"    -> "Cancelled (CancelToolAsync failed)"|>];
          AppendTo[cancelledIdxs, idx]]],
      running];

    (* Queue \:306e call \:306f Cancelled \:306b *)
    Scan[
      Function[{indexedCall},
        Module[{idx = Lookup[indexedCall, "Index", 0],
                call = Lookup[indexedCall, "Call", <||>]},
          collected[idx] = <|
            "ToolName" -> Lookup[call, "Name", ""],
            "ToolId"   -> Lookup[call, "Id", ""],
            "Success"  -> False,
            "Error"    -> "Cancelled (not yet started)"|>;
          AppendTo[cancelledIdxs, idx]]],
      queue];

    (* polling tick \:89e3\:9664 *)
    If[StringQ[pollKey] && pollKey =!= "",
      Quiet @ ClaudeCode`ClaudeUnregisterPollingTick[pollKey]];

    (* state \:66f4\:65b0 *)
    rt = $iClaudeRuntimes[runtimeId];
    If[AssociationQ[rt],
      rt["AsyncToolExec"]["Running"]          = {};
      rt["AsyncToolExec"]["Queue"]            = {};
      rt["AsyncToolExec"]["CollectedByIndex"] = collected;
      rt["AsyncToolExec"]["Finalized"]        = True;
      rt["Status"]                            = "Cancelled";
      $iClaudeRuntimes[runtimeId] = rt];

    iAppendEvent[runtimeId, <|
      "Type"           -> "AsyncToolExecCancelled",
      "CancelledIdxs"  -> cancelledIdxs|>];

    <|"Success"        -> True,
      "CancelledCount" -> Length[cancelledIdxs],
      "PollKey"        -> pollKey|>
  ];

ClaudeRuntimeCancelAsyncToolExec[___] :=
  <|"Success" -> False, "Error" -> "Invalid args"|>;

(* \[HorizontalLine] Public: AsyncToolExec \:306e\:8a3a\:65ad \[HorizontalLine] *)
ClaudeRuntimeToolExecDiagnose[runtimeId_String] :=
  Module[{rt, async},
    rt = Quiet @ Check[$iClaudeRuntimes[runtimeId], None];
    If[!AssociationQ[rt],
      Return[<|"Active" -> False, "Reason" -> "RuntimeMissing"|>]];

    async = Lookup[rt, "AsyncToolExec", None];
    If[!AssociationQ[async] || Length[async] === 0,
      Return[<|"Active" -> False|>]];

    <|"Active"             -> !TrueQ[Lookup[async, "Finalized", False]],
      "Finalized"          -> TrueQ[Lookup[async, "Finalized", False]],
      "PollKey"            -> Lookup[async, "PollKey", ""],
      "QueueSize"          -> Length[Lookup[async, "Queue", {}]],
      "RunningSize"        -> Length[Lookup[async, "Running", {}]],
      "CollectedSize"      -> Length[Lookup[async, "CollectedByIndex", <||>]],
      "ToolCount"          -> Length[Lookup[async, "ToolCalls", {}]],
      "MaxConcurrent"      -> Lookup[async, "MaxConcurrent", 4],
      "Elapsed"            -> AbsoluteTime[] -
                              Lookup[async, "StartTime", AbsoluteTime[]],
      "RunningIndices"     -> Map[Lookup[#, "Index", 0] &,
                                Lookup[async, "Running", {}]],
      "QueueIndices"       -> Map[Lookup[#, "Index", 0] &,
                                Lookup[async, "Queue", {}]],
      "CollectedIndices"   -> Sort[Keys[
                                Lookup[async, "CollectedByIndex", <||>]]]|>
  ];

ClaudeRuntimeToolExecDiagnose[___] :=
  <|"Active" -> False, "Error" -> "Invalid args"|>;

(* Public: \:975e\:540c\:671f\:5b9f\:884c\:30b9\:30c6\:30fc\:30bf\:30b9\:53d6\:5f97 *)
ClaudeRuntimeAsyncExecutionStatus[runtimeId_String] :=
  Module[{rt, async},
    rt = Quiet @ Check[$iClaudeRuntimes[runtimeId], None];
    If[!AssociationQ[rt], Return[<|"Running" -> False|>]];
    async = Lookup[rt, "AsyncExecution", None];
    If[!AssociationQ[async] || Length[async] === 0,
      Return[<|"Running" -> False|>]];
    <|
      "Running"   -> True,
      "Elapsed"   -> AbsoluteTime[] -
                     Lookup[async, "StartTime", AbsoluteTime[]],
      "Timeout"   -> Lookup[async, "Timeout", 30],
      "StartTime" -> Lookup[async, "StartTime", None],
      "PollKey"   -> Lookup[async, "PollKey", None]
    |>
  ];

ClaudeRuntimeAsyncExecutionStatus[___] := <|"Running" -> False|>;

(* Public: \:975e\:540c\:671f\:5b9f\:884c\:306e\:5f37\:5236\:30ad\:30e3\:30f3\:30bb\:30eb *)
ClaudeRuntimeCancelAsyncExecution[runtimeId_String] :=
  Module[{rt, async, pollKey, execResult},
    rt = Quiet @ Check[$iClaudeRuntimes[runtimeId], None];
    If[!AssociationQ[rt],
      Return[<|"Status" -> "NotFound"|>]];
    async = Lookup[rt, "AsyncExecution", None];
    If[!AssociationQ[async] || Length[async] === 0,
      Return[<|"Status" -> "NotRunning"|>]];
    pollKey = Lookup[async, "PollKey", None];
    
    iAppendEvent[runtimeId, <|
      "Type"   -> "AsyncExecutionCancelled",
      "Reason" -> "UserRequest"|>];
    
    (* Kernel \:3092\:5f37\:5236\:7d42\:4e86\:5f8c\:518d\:8d77\:52d5 *)
    Quiet @ Check[
      AbortKernels[]; LaunchKernels[];,
      Null];
    
    execResult = <|
      "Success"   -> False,
      "RawResult" -> None,
      "HeldExpr"  -> Lookup[async, "HeldExpr", None],
      "Error"     -> "Async execution cancelled by user"|>;
    
    iAsyncExecutionFinalize[runtimeId, execResult];
    <|"Status" -> "Cancelled", "PollKey" -> pollKey|>
  ];

ClaudeRuntimeCancelAsyncExecution[___] := <|"Status" -> "NotFound"|>;

(* Phase 32k (2026-05-14): \:975e\:540c\:671f\:5b9f\:884c\:7d4c\:8def\:5168\:4f53\:306e\:8a3a\:65ad
   ParallelKernel \:8d77\:52d5\:72b6\:614b\:3001\:30d5\:30e9\:30b0\:7fa4\:3001UI \:512a\:5148\:30e2\:30fc\:30c9\:3001\:5404 runtime \:306e
   async \:5b9f\:884c\:72b6\:6cc1\:3092\:307e\:3068\:3081\:3066\:8fd4\:3059\:3002\:30e6\:30fc\:30b6\:30fc\:304c
   \"ClaudeEval \:304c\:30d6\:30ed\:30c3\:30af\:3057\:305f\" \:6642\:306b\:3053\:308c\:3092\:898b\:308c\:3070\:539f\:56e0\:3092\:7d5e\:308a\:8fbc\:3081\:308b\:3002 *)
ClaudeRuntimeAsyncDiagnose[] :=
  Module[{kernels, kernelsCount, ready, exec, force, highPrio,
          runtimeIds, runtimeInfo},
    kernels      = Quiet @ Check[Kernels[], {}];
    kernelsCount = If[ListQ[kernels], Length[kernels], 0];
    ready        = TrueQ[Quiet @ Check[
      ClaudeCode`Private`$iParallelKernelsReady, False]];
    exec         = TrueQ[Quiet @ Check[
      ClaudeCode`$ClaudeRuntimeAsyncExecution, True]];
    force        = TrueQ[Quiet @ Check[
      ClaudeCode`$ClaudeRuntimeAsyncForce, False]];
    highPrio     = TrueQ[Quiet @ Check[
      ClaudeCode`Private`iClaudeIsHighPriorityMode[], False]];

    runtimeIds = Quiet @ Check[Keys[$iClaudeRuntimes], {}];
    If[!ListQ[runtimeIds], runtimeIds = {}];

    runtimeInfo = Map[
      Function[rid,
        Module[{rt, async, futureState, elapsed},
          rt = Quiet @ Check[$iClaudeRuntimes[rid], None];
          If[!AssociationQ[rt],
            <|"RuntimeId" -> rid, "Status" -> "Missing"|>,
            async = Lookup[rt, "AsyncExecution", None];
            futureState = If[AssociationQ[async],
              Quiet @ Check[
                Lookup[async, "Future", None]["State"],
                "?"],
              None];
            elapsed = If[AssociationQ[async],
              AbsoluteTime[] -
                Lookup[async, "StartTime", AbsoluteTime[]],
              None];
            <|"RuntimeId"        -> rid,
              "Status"           -> Lookup[rt, "Status", "?"],
              "Phase"            -> Lookup[rt, "Phase", "?"],
              "TurnCount"        -> Lookup[rt, "TurnCount", 0],
              "AsyncActive"      -> AssociationQ[async],
              "AsyncFutureState" -> futureState,
              "AsyncElapsed"     -> elapsed|>]]],
      runtimeIds];

    <|"ParallelKernels"       -> kernelsCount,
      "ParallelKernelsReady"  -> ready,
      "AsyncExecutionEnabled" -> exec,
      "AsyncExecutionForced"  -> force,
      "HighPriorityMode"      -> highPrio,
      "RuntimeCount"          -> Length[runtimeIds],
      "Runtimes"              -> runtimeInfo|>
  ];

(* Phase frontend-blocking-queue (2026-06-03, spec 案3-lite 5A.1):
   いずれかの runtime で非同期実行 / 非同期 tool 実行が走行中か。
   NBAccess の NBFinalActionTick はこれが True の間 final action を
   実行せず Pending のまま待つ。WaitAll はしない。 *)
ClaudeRuntimeAsyncActiveQ[] :=
  Module[{ids},
    ids = Quiet @ Check[Keys[$iClaudeRuntimes], {}];
    If[!ListQ[ids], ids = {}];
    AnyTrue[ids,
      Function[rid,
        Module[{rt, async, toolExec, running},
          rt = Quiet @ Check[$iClaudeRuntimes[rid], None];
          If[!AssociationQ[rt], Return[False, Module]];
          (* 非同期コード実行が走行中 *)
          async = Lookup[rt, "AsyncExecution", None];
          If[AssociationQ[async], Return[True, Module]];
          (* 非同期 tool 実行の Running が非空 *)
          toolExec = Lookup[rt, "AsyncToolExec", None];
          running = If[AssociationQ[toolExec],
            Lookup[toolExec, "Running", {}], {}];
          AssociationQ[toolExec] && ListQ[running] && Length[running] > 0
        ]]]
  ];
ClaudeRuntimeAsyncActiveQ[___] := False;

ClaudeRuntimeAsyncDiagnose[___] :=
  <|"Error" -> "ClaudeRuntimeAsyncDiagnose[] takes no arguments"|>;

(* \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550
   10. Repair / failure recording / checkpoint
   \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550 *)

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
    (* Phase C-lite (2026-06-03, spec 5A.9/5A.13-7): ユーザーが承認 UI で
       明示承認したことを proposal に刻む。adapter ExecuteProposal は
       このマーカーを見て NBExecuteHeldExpr に ApprovalMode -> "UserApproved"
       を渡し、NeedsApproval を Permit 昇格させる。これが無いと承認しても
       NBExecuteHeldExpr が再び NeedsApproval を返し「承認しても実行されない」。 *)
    proposal = If[AssociationQ[proposal],
      Append[proposal, "UserApproved" -> True], proposal];
    rt["PendingApproval"] = None;
    $iClaudeRuntimes[runtimeId] = rt;
    iUpdateStatus[runtimeId, "Running"];
    iAppendEvent[runtimeId, <|"Type" -> "ApprovalGranted"|>];
    (* Phase frontend-blocking-queue (2026-06-03, spec 案3-lite 12):
       FrontEnd ブロックリスクのある action は、Approve で即同期実行せず
       PendingFinalActionQueue へ積む (Approve = queue 投入許可)。
       ユーザーが Approve ボタンを押した瞬間 (= FrontEnd ビジー) の
       同期実行を避け、共有 tick が安全な隙に実行する。
       判定: BlockingRisk=MayBlockFrontEnd または ExecutionPlacement が
       DesktopAction/FrontEndRequired。 *)
    Module[{blockingRisk, placement, heldExpr, accessSpec, enq},
      blockingRisk = Lookup[valResult, "BlockingRisk", "None"];
      placement = Lookup[valResult, "ExecutionPlacement", "SubkernelSafe"];
      If[(blockingRisk === "MayBlockFrontEnd" ||
          MemberQ[{"DesktopAction", "FrontEndRequired"}, placement]) &&
         AssociationQ[proposal] && KeyExistsQ[proposal, "HeldExpr"],
        heldExpr = proposal["HeldExpr"];
        (* accessSpec は ctxPacket から Committer role で生成する。
           空 <||> だと PermissionMode 等が欠落し、tick での
           NBExecuteHeldExpr 二重 validate が想定と食い違うため。 *)
        accessSpec = Quiet @ Check[
          NBAccess`NBMakeRuntimeAccessSpec[
            If[AssociationQ[ctxPacket], ctxPacket, <||>], "Committer"],
          <|"PermissionMode" -> "InteractiveSafe"|>];
        If[!AssociationQ[accessSpec],
          accessSpec = <|"PermissionMode" -> "InteractiveSafe"|>];
        (* spec 案3-lite: AsyncActive かどうかで分岐。
           - AsyncActive でない (通常ケース): 承認ボタンの ScheduledTask
             コンテキストは FrontEnd 操作可能なメインカーネル評価機会なので、
             ここで直接同期実行する。これで即フォルダが開く。
           - AsyncActive (非同期タスク走行中): 直接実行すると競合するため
             queue に積み、共有 tick が安全な隙に実行する。 *)
        If[!TrueQ[Quiet @ Check[ClaudeRuntimeAsyncActiveQ[], False]],
          (* 即同期実行: まず context 非依存の final action 正規化を試し、
             対象外なら通常の NBExecuteHeldExpr。 *)
          Module[{execR, special},
            special = Quiet @ Check[
              NBAccess`NBTryExecuteFinalActionHeld[heldExpr, accessSpec,
                "ApprovalMode" -> "UserApproved"],
              <|"Handled" -> False|>];
            execR = If[TrueQ[Lookup[special, "Handled", False]],
              KeyDrop[special, "Handled"],
              Quiet @ Check[
                NBAccess`NBExecuteHeldExpr[heldExpr, accessSpec,
                  "ApprovalMode" -> "UserApproved"],
                <|"Success" -> False, "ReasonClass" -> "ExecutorError"|>]];
            iUpdateStatus[runtimeId, "Done"];
            iAppendEvent[runtimeId, <|"Type" -> "FinalActionExecuted",
              "Success" -> TrueQ[Lookup[execR, "Success", False]]|>];
            Return[<|"Outcome" -> "FinalActionExecuted",
              "Success" -> TrueQ[Lookup[execR, "Success", False]],
              "Result" -> execR,
              "VisibleExplanation" ->
                iL["\:5b9f\:884c\:3057\:307e\:3057\:305f\:3002", "Executed."]|>]],
          (* AsyncActive: queue 化して安全な隙に実行 *)
          enq = Quiet @ Check[
            ClaudeCode`ClaudeEnqueueFinalAction[heldExpr, accessSpec],
            <|"Enqueued" -> False|>];
          If[TrueQ[Lookup[enq, "Enqueued", False]],
            iUpdateStatus[runtimeId, "Done"];
            iAppendEvent[runtimeId, <|"Type" -> "FinalActionEnqueued",
              "ActionID" -> Lookup[enq, "ActionID", ""]|>];
            Return[<|"Outcome" -> "FinalActionEnqueued",
              "ActionID" -> Lookup[enq, "ActionID", ""],
              "VisibleExplanation" ->
                iL["\:627f\:8a8d\:3055\:308c\:307e\:3057\:305f\:3002\:5b89\:5168\:306a\:30bf\:30a4\:30df\:30f3\:30b0\:3067\:5b9f\:884c\:3057\:307e\:3059\:3002",
                   "Approved. Will execute at a safe time."]|>]]]
      ]];
    result = iExecuteAndContinue[runtimeId, adapter, proposal, valResult, ctxPacket];
    (* Phase 32 (2026-05-13): AsyncExecutionScheduled \:306e\:5834\:5408\:306f\:5373\:6642 return\:3002
       \:5f8c\:7d9a\:51e6\:7406 (Continuation \:8d77\:52d5\:30fbnotebook callback) \:306f
       iAsyncExecutionFinalize \:304c polling tick \:7d4c\:7531\:3067\:884c\:3046\:3002
       Phase 32k Step 3 Phase D (2026-05-14): AsyncToolExecScheduled \:3082\:540c\:69d8\:306b\:6271\:3046\:3002 *)
    If[AssociationQ[result] &&
       (Lookup[result, "Outcome", ""] === "AsyncExecutionScheduled" ||
        Lookup[result, "Outcome", ""] === "AsyncToolExecScheduled"),
      Return[result]];
    (* DAG 外で呼ばれるため onComplete が発火しない \[RightArrow] 手動で continuation 起動 *)
    If[AssociationQ[result] &&
       Lookup[result, "Outcome", ""] === "ContinuationPending",
      Module[{contInput = $iClaudeRuntimes[runtimeId]["ContinuationInput"]},
        iUpdateStatus[runtimeId, "Done"];
        ClaudeRunTurn[runtimeId, contInput, "Notebook" -> $Failed]]];
    result
  ];

(* 承認 wrapper context 修正 (2026-06-03): 承認 UI 側が desktop action
   (SystemOpen) をメインカーネル評価コンテキストで既に実行した場合に、
   runtime の承認待ち状態を消費して Done にする軽量関数。
   ClaudeApproveProposal の実行ロジックは呼ばない (二重実行を避ける)。 *)
ClaudeMarkApprovalConsumed[runtimeId_String, reason_String:"ConsumedExternally"] :=
  Module[{rt},
    rt = $iClaudeRuntimes[runtimeId];
    If[!AssociationQ[rt], Return[Missing["NoRuntime"]]];
    rt["PendingApproval"] = None;
    $iClaudeRuntimes[runtimeId] = rt;
    iUpdateStatus[runtimeId, "Done"];
    iAppendEvent[runtimeId, <|"Type" -> "FinalActionExecuted",
      "Reason" -> reason|>];
    <|"Outcome" -> "FinalActionExecuted", "Reason" -> reason|>
  ];

(* Phase 30 (2026-05-13): タイムアウト延長承認版。
   timeout に Infinity を渡すとタイムアウト解除、整数を渡すとその秒数に上書き。
   adapter の DefaultTimeoutSeconds を一時的に上書きしてから iExecuteAndContinue を呼ぶ。
   Phase 32 (2026-05-13): AsyncExecutionScheduled \:5bfe\:5fdc\:8ffd\:52a0\:3002 *)
ClaudeApproveProposalWithTimeout[runtimeId_String, timeout_] :=
  Module[{rt, pending, adapter, proposal, valResult, ctxPacket, result,
          modifiedAdapter, modifiedProposal, effectiveTimeout},
    rt = $iClaudeRuntimes[runtimeId];
    If[!AssociationQ[rt] || rt["Status"] =!= "AwaitingApproval",
      Return[Missing["NotAwaitingApproval"]]];
    pending   = rt["PendingApproval"];
    adapter   = rt["Adapter"];
    proposal  = pending["Proposal"];
    valResult = pending["ValidationResult"];
    ctxPacket = pending["ContextPacket"];
    
    (* timeout 値を正規化: Infinity / 正整数 / 正実数のみ受理 *)
    effectiveTimeout = Which[
      timeout === Infinity, Infinity,
      IntegerQ[timeout] && timeout > 0, timeout,
      NumericQ[timeout] && timeout > 0, Round[timeout],
      True, 30
    ];
    
    (* adapter を timeout 上書き版に置き換え *)
    modifiedAdapter = If[AssociationQ[adapter],
      Append[adapter, "DefaultTimeoutSeconds" -> effectiveTimeout],
      adapter];
    
    (* proposal にも ExpectedSeconds を上書きで埋めておく (実行側で参照される) *)
    (* Phase C-lite: ユーザー明示承認マーカーも刻む (UserApproved 経路と同じ)。 *)
    modifiedProposal = If[AssociationQ[proposal],
      Append[proposal, <|"ExpectedSeconds" -> effectiveTimeout,
        "UserApproved" -> True|>],
      proposal];
    
    rt["PendingApproval"] = None;
    $iClaudeRuntimes[runtimeId] = rt;
    iUpdateStatus[runtimeId, "Running"];
    iAppendEvent[runtimeId, <|"Type" -> "ApprovalGranted",
      "TimeoutOverride" -> effectiveTimeout|>];
    result = iExecuteAndContinue[runtimeId, modifiedAdapter,
      modifiedProposal, valResult, ctxPacket];
    (* Phase 32 (2026-05-13): AsyncExecutionScheduled \:306f\:5373\:6642 return\:3002
       Phase 32k Step 3 Phase D (2026-05-14): AsyncToolExecScheduled \:3082\:540c\:69d8\:306b\:6271\:3046\:3002 *)
    If[AssociationQ[result] &&
       (Lookup[result, "Outcome", ""] === "AsyncExecutionScheduled" ||
        Lookup[result, "Outcome", ""] === "AsyncToolExecScheduled"),
      Return[result]];
    (* DAG 外で呼ばれるため onComplete が発火しない \[RightArrow] 手動で continuation 起動 *)
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

(* ════════════════════════════════════════════════════════
   ClaudeRuntimeExecuteTransition Implementation
   (Stage B Day 4c, runtime-orchestrator-boundary 厳守)
   ════════════════════════════════════════════════════════ *)

(* iCallAdapterStage: adapter[stage] が無い / 失敗したときに
   Quiet @ Check で防御し、$Failed を捕捉して構造化エラーに変換する。 *)

iCallAdapterStage[adapter_Association, stage_String, args_List] :=
  Module[{fn, result},
    fn = Lookup[adapter, stage, None];
    Which[
      fn === None,
        <|"Stage" -> stage, "OK" -> False,
          "Reason" -> "MissingStage: " <> stage|>,
      
      (* Function[{...}, ...] / 純関数 / Symbol (DownValues 持ち) を許容 *)
      Head[fn] =!= Function && Head[fn] =!= Symbol,
        <|"Stage" -> stage, "OK" -> False,
          "Reason" -> "InvalidStageType: " <> stage|>,
      
      True,
        result = Quiet @ Check[Apply[fn, args], $Failed];
        If[result === $Failed,
          <|"Stage" -> stage, "OK" -> False,
            "Reason" -> "ExceptionInStage: " <> stage|>,
          <|"Stage" -> stage, "OK" -> True, "Value" -> result|>
        ]
    ]
  ];

(* iValidationOK: ValidateProposal の戻り値を解釈する。
   Association なら "Valid" キーを見る、True/False なら直接、
   それ以外は False (= 不正) として扱う。 *)

iValidationOK[validateResult_] :=
  Which[
    validateResult === True,            True,
    validateResult === False,           False,
    AssociationQ[validateResult],       TrueQ[Lookup[validateResult, "Valid", False]],
    True,                               False
  ];

ClaudeRuntimeExecuteTransition[
  adapter_Association, contextPacket_Association] :=
  Module[{required, missing,
          ctxStage, ctx, propStage, prop,
          valStage, validateResult,
          execStage, execResult,
          redStage, redacted},
    
    (* 0. 必須 stage 存在チェック *)
    required = {"BuildContext", "QueryProvider",
                "ValidateProposal", "ExecuteProposal",
                "RedactResult"};
    missing  = Select[required, !KeyExistsQ[adapter, #]&];
    If[Length[missing] > 0,
      Return[<|"Status" -> "Failed",
               "Reason" -> "AdapterMissingStages: " <>
                           StringRiffle[missing, ", "],
               "MissingStages" -> missing|>]
    ];
    
    (* 1. BuildContext *)
    ctxStage = iCallAdapterStage[adapter, "BuildContext", {contextPacket}];
    If[!ctxStage[["OK"]],
      Return[<|"Status" -> "Failed",
               "Reason" -> ctxStage[["Reason"]],
               "Stage"  -> "BuildContext"|>]
    ];
    ctx = ctxStage[["Value"]];
    
    (* 2. QueryProvider *)
    propStage = iCallAdapterStage[adapter, "QueryProvider", {ctx, contextPacket}];
    If[!propStage[["OK"]],
      Return[<|"Status" -> "Failed",
               "Reason" -> propStage[["Reason"]],
               "Stage"  -> "QueryProvider",
               "Context" -> ctx|>]
    ];
    prop = propStage[["Value"]];
    
    (* 3. ValidateProposal *)
    valStage = iCallAdapterStage[adapter, "ValidateProposal", {prop, contextPacket}];
    If[!valStage[["OK"]],
      Return[<|"Status" -> "Failed",
               "Reason" -> valStage[["Reason"]],
               "Stage"  -> "ValidateProposal",
               "Proposal" -> prop|>]
    ];
    validateResult = valStage[["Value"]];
    
    If[!iValidationOK[validateResult],
      Return[<|"Status" -> "Failed",
               "Reason" -> "ValidationFailed",
               "Stage"  -> "ValidateProposal",
               "Proposal" -> prop,
               "Validation" -> validateResult|>]
    ];
    
    (* 4. ExecuteProposal *)
    execStage = iCallAdapterStage[adapter, "ExecuteProposal", {prop, contextPacket}];
    If[!execStage[["OK"]],
      Return[<|"Status" -> "Failed",
               "Reason" -> execStage[["Reason"]],
               "Stage"  -> "ExecuteProposal",
               "Proposal" -> prop|>]
    ];
    execResult = execStage[["Value"]];
    
    (* 5. RedactResult *)
    redStage = iCallAdapterStage[adapter, "RedactResult", {execResult, contextPacket}];
    If[!redStage[["OK"]],
      Return[<|"Status" -> "Failed",
               "Reason" -> redStage[["Reason"]],
               "Stage"  -> "RedactResult",
               "ExecResult" -> execResult|>]
    ];
    redacted = redStage[["Value"]];
    
    (* 全 stage 成功 *)
    <|"Status"     -> "Success",
      "Output"     -> redacted,
      "Proposal"   -> prop,
      "Validation" -> validateResult,
      "ExecResult" -> execResult|>
  ];

$ClaudeRuntimeVersion = "2026-05-15-phase-32k-step3-route-unification-trace-v3";

End[];
EndPackage[];

(* \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550
   Phase 32k (2026-05-14): ParallelKernels \:306e\:524d\:7f6e\:8d77\:52d5

   \:65e7\:5b9f\:88c5: \:521d\:56de\:306e ClaudeEval \:5b9f\:884c\:6642\:306b iEnsureParallelKernelsForRuntime \:5185\:3067
   LaunchKernels[] \:3092\:540c\:671f\:547c\:3073\:51fa\:3057\:3057\:3066\:3044\:305f\:305f\:3081\:3001\:30e6\:30fc\:30b6\:30fc\:306e\:521d\:56de
   ClaudeEval \:304c 3\[Dash]10 \:79d2\:30e1\:30a4\:30f3\:30ab\:30fc\:30cd\:30eb\:3092\:30d6\:30ed\:30c3\:30af\:3057\:3001\:300c\:540c\:671f\:5b9f\:884c\:306b\:898b\:3048\:308b\:300d
   \:73fe\:8c61\:304c\:8d77\:304d\:3066\:3044\:305f\:3002

   \:65b0\:5b9f\:88c5: ClaudeRuntime.wl \:30ed\:30fc\:30c9\:6642\:306b ClaudeCode\`ClaudeBeginParallelKernels[]
   \:3092\:547c\:3073\:3001\:3053\:306e\:30bf\:30a4\:30df\:30f3\:30b0\:3067 LaunchKernels[] \:3092\:5b8c\:4e86\:3055\:305b\:308b\:3002
   \:30ed\:30fc\:30c9\:6642\:9593\:306f 3\[Dash]10 \:79d2\:5897\:3048\:308b\:304c\:3001\:305d\:306e\:5f8c\:306e ClaudeEval \:306f\:521d\:56de\:304b\:3089
   ParallelSubmit \:7d4c\:7531\:3067\:5373\:6642\:306b\:5b9f\:884c\:3055\:308c\:3001\:30e1\:30a4\:30f3\:30ab\:30fc\:30cd\:30eb\:30fb\:30d5\:30ed\:30f3\:30c8\:30a8\:30f3\:30c9\:3092
   \:30d6\:30ed\:30c3\:30af\:3057\:306a\:3044\:3002

   Phase 32j v1 \:306e\:6559\:8a13: SessionSubmit + ScheduledTask \:306e\:7d44\:307f\:5408\:308f\:305b\:306f
   Mathematica \:30af\:30e9\:30c3\:30b7\:30e5\:3092\:5f15\:304d\:8d77\:3053\:3057\:305f\:305f\:3081\:3001\:3053\:3053\:3067\:306f\:540c\:671f LaunchKernels
   \:306e\:307f\:3092\:4f7f\:3044\:3001ScheduledTask \:7cfb\:3092\:7d4c\:7531\:3055\:305b\:306a\:3044\:3002
   \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550 *)

If[!ValueQ[$iClaudeRuntimeParallelKernelsPrelaunched] ||
   !TrueQ[$iClaudeRuntimeParallelKernelsPrelaunched],
  $iClaudeRuntimeParallelKernelsPrelaunched = True;
  Quiet @ Check[
    Module[{prelaunchResult},
      (* Phase 32k v2 (2026-05-14) fix: \:65e7\:5b9f\:88c5\:306f ValueQ[ClaudeCode\:0060ClaudeBeginParallelKernels]
         \:3067\:5b58\:5728\:30c1\:30a7\:30c3\:30af\:3092\:3057\:3066\:3044\:305f\:304c\:3001ValueQ \:306f OwnValue \:3092\:898b\:308b\:5224\:5b9a\:306a\:306e\:3067
         DownValue \:3057\:304b\:6301\:305f\:306a\:3044\:95a2\:6570\:306b\:3064\:3044\:3066\:5e38\:306b False \:3092\:8fd4\:3057\:305f\:3002
         \:7d50\:679c\:3001ClaudeBeginParallelKernels \:304c\:5b9f\:984c\:3055\:308c\:308b\:305a LaunchKernels \:304c\:8d70\:3089\:306a\:304b\:3063\:305f\:3002
         Names[] \:3067\:30b7\:30f3\:30dc\:30eb\:540d\:5b58\:5728\:3092\:30c1\:30a7\:30c3\:30af\:3059\:308b\:65b9\:5f0f\:306b\:5909\:66f4\:3002 *)
      If[Length[Names["ClaudeCode`ClaudeBeginParallelKernels"]] === 0,
        (* claudecode \:672a\:30ed\:30fc\:30c9: \:30c6\:30b9\:30c8\:74b0\:5883\:7b49 \:2192 \:30b9\:30ad\:30c3\:30d7 *)
        Null,
        prelaunchResult = ClaudeCode`ClaudeBeginParallelKernels[];
        (* \:8d77\:52d5\:7d50\:679c\:306f Quiet \:7d4c\:7531\:306a\:306e\:3067\:5931\:6557\:3057\:3066\:3082\:30ed\:30fc\:30c9\:306f\:7d99\:7d9a\:3002
           Length[Kernels[]] == 0 \:306e\:5834\:5408\:306f iEnsureParallelKernelsForRuntime
           \:304c\:540c\:671f fallback \:3057\:3001\:7d50\:5c40\:540c\:671f\:5b9f\:884c\:306b\:306a\:308b\:304c\:30af\:30e9\:30c3\:30b7\:30e5\:306f\:3057\:306a\:3044\:3002 *)
        prelaunchResult]
    ],
    Null]];

(* \:2500\:2500 $UseClaudeRuntime \:2500\:2500
   Phase 32j v2 (2026-05-13): \:30c7\:30d5\:30a9\:30eb\:30c8\:3092 False \:306b\:623b\:3057\:305f\:3002
   
   Phase 32j v1 \:3067\:306f Runtime Bridge \:7d4c\:8def\:3092 iScheduleAtAsync (SessionSubmit + 
   ScheduledTask) \:3067\:975e\:540c\:671f\:5316\:3057\:3001$UseClaudeRuntime = True \:3092\:30c7\:30d5\:30a9\:30eb\:30c8\:306b
   \:3057\:3088\:3046\:3068\:3057\:305f\:304c\:3001ClaudeEval \:5b9f\:884c\:6642\:306b Mathematica \:81ea\:4f53\:304c
   \:30af\:30e9\:30c3\:30b7\:30e5\:3057\:305f\:3002SessionSubmit \:3067 ScheduledTask \:3092\:6295\:3052\:305f\:4e2d\:3067
   \:3055\:3089\:306b ClaudeRegisterPollingTick \:304c\:547c\:3070\:308c LLMGraphDAGCreate \:304c
   \:53e5\:90fd\:306e $iSharedPollingTask \:306b\:767b\:9332\:3055\:308c\:308b\:305f\:3081\:3001\:30bf\:30b9\:30af\:30b9\:30b1\:30b8\:30e5\:30fc\:30e9\:30fc
   \:304c\:4e88\:671f\:3057\:306a\:3044\:30ec\:30fc\:30b9\:72b6\:614b\:306b\:9665\:3063\:305f\:3068\:63a8\:6e2c\:3055\:308c\:308b\:3002
   
   \:73fe\:72b6\:306f Phase 32i v2 \:3068\:540c\:3058\:30c7\:30d5\:30a9\:30eb\:30c8 False \:306b\:623b\:3057\:3001
   \:30e6\:30fc\:30b6\:30fc\:304c\:660e\:793a\:7684\:306b True \:306b\:8a2d\:5b9a\:3057\:305f\:5834\:5408\:3060\:3051 Runtime \:7d4c\:8def\:3092\:4f7f\:3046\:3002
   \:30e6\:30fc\:30b6\:30fc\:306e\:300c\:7d4c\:8def\:7d71\:4e00\:300d\:306e\:8981\:6c42\:3092\:8fbc\:3081\:305f\:672c\:8cea\:7684\:89e3\:6c7a\:306f
   ClaudeRuntime \:5185\:90e8\:306e DAG \:8d77\:52d5\:30bb\:30af\:30b7\:30e7\:30f3\:3092\:3088\:308a\:614e\:91cd\:306b\:5206\:6790\:3057\:3066
   \:5225\:9014\:8a2d\:8a08\:3059\:308b\:5fc5\:8981\:304c\:3042\:308b\:3002 *)

If[!ValueQ[ClaudeCode`$UseClaudeRuntime],
  ClaudeCode`$UseClaudeRuntime = False];


(* ════════════════════════════════════════════════════════
   Phase R-5 Stage B: RunStateGraph 名称互換 alias
   
   仕様書 §2.1 (ClaudePackageManager_integrated_spec_v3.md) では
   ClaudeRuntime`RunStateGraph という名称で API を提案している。
   実装本体は ClaudeStateGraph`RunStateGraph (v0.4 以降; ファイル名は
   ClaudeOrchestrator_stategraph.wl - 2026-05-06 にリネーム、
   旧名 ClaudeRuntime_stategraph.wl) にあり、ここでは OwnValue alias で名称
   互換を提供する。
   
   優先順位:
     - ClaudeStateGraph` 名前空間がロードされていれば: alias 設定
     - ロードされていなければ: メッセージ表示の仕様 stub
   
   alias パターンは Q-* シリーズ (PM 移管) と同じ。
   ════════════════════════════════════════════════════════ *)

If[Quiet @ Check[ValueQ[ClaudeStateGraph`RunStateGraph], False],
  Quiet[
    Unprotect[ClaudeRuntime`RunStateGraph];
    ClearAll[ClaudeRuntime`RunStateGraph];
    ClaudeRuntime`RunStateGraph =
      ClaudeStateGraph`RunStateGraph;
    , {General::shdw}],
  (* ClaudeStateGraph 未ロード: stub *)
  ClaudeRuntime`RunStateGraph::needstategraph =
    "ClaudeRuntime`RunStateGraph requires ClaudeOrchestrator_stategraph.wl to \
be loaded first. Run Get[\"ClaudeOrchestrator_stategraph.wl\"] then re-load \
ClaudeRuntime.wl, or call ClaudeStateGraph`RunStateGraph directly.";
  ClaudeRuntime`RunStateGraph[___] := (
    Message[ClaudeRuntime`RunStateGraph::needstategraph];
    $Failed)];

(* ロード時メッセージは廃止 (2026-04-29).
   バージョン情報は ClaudeRuntime`$ClaudeRuntimeVersion 変数で参照可能。
   $UseClaudeRuntime の現在値は ClaudeCode`$UseClaudeRuntime で確認可能。 *)

(* ═══ 経路統一 (2026-05-15) ═══
   ClaudeRuntime をロードした時点で以下を一括設定する:

     $UseClaudeRuntime              = True   (Bridge 経路)
     $ClaudeRuntimeAsyncExecution   = False  (ExecuteProposal は同期評価)
     $ClaudeRuntimeToolAsyncDefault = True   (tool は AsyncToolExec)

   これは result11.nb (2026-05-14) で 54.4 秒完走実証済みの組み合わせ。

   なぜ $ClaudeRuntimeAsyncExecution = False か:
   ParallelSubmit 経路 (Phase 32) は別カーネルが起動済みでも
   30 秒 timeout する症状が確認されている (rt-1778820834-47472)。
   原因未特定のため、安定動作する sync 評価に倒す。

   sync 評価でもメインカーネルは tool 実行中は解放される (AsyncToolExec 経由)
   ので、UX への影響は限定的。Phase 32 経路の修復は別フェーズで行う。

   ユーザーが明示的に変更したい場合は ClaudeRuntime ロード後に再設定する。 *)
ClaudeCode`$UseClaudeRuntime              = True;
ClaudeCode`$ClaudeRuntimeAsyncExecution   = False;

(* ═══ 並列カーネルの前置起動 (2026-05-15) ═══
   $UseClaudeRuntime = True 経路では Phase 32 が ParallelSubmit で
   コード評価を別カーネルに投げる。別カーネルが未起動だと 30 秒 timeout で
   AsyncExecutionTimedOut → ExecutionFailed になり、notebook に結果が
   表示されない (callback が "Done" の場合のみ起動する設計のため)。

   ClaudeRuntime ロード時に同期 LaunchKernels[] を 1 回だけ呼んで
   $iParallelKernelsReady = True にし、以降の ClaudeEval をすべて
   非同期で動かす。3-5 秒のロード時コストを払う代わりに、初回 ClaudeEval が
   timeout する事故を防ぐ。 *)
Module[{result},
  result = Quiet @ Check[
    ClaudeCode`ClaudeBeginParallelKernels[],
    <|"Ready" -> False, "KernelCount" -> 0, "Action" -> "Error"|>];
  If[!TrueQ[Lookup[result, "Ready", False]],
    Message[General::warning,
      "ClaudeRuntime: ClaudeBeginParallelKernels[] failed. ClaudeEval may time out."]]];
