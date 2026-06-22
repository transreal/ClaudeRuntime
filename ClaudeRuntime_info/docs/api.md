# ClaudeRuntime API リファレンス

ClaudeRuntime は expression-proposal loop の状態機械。turn loop / proposal loop / provider 連携 / validation・execution の進行管理 / continuation / usage・event の構造化 / session state の論理モデルを担う。Notebook・secret・access policy・label algebra は知らず、抽象 adapter interface のみを扱う。安全判定は adapter 経由で [NBAccess](https://github.com/transreal/NBAccess) が行う。実行形式は [claudecode](https://github.com/transreal/claudecode) の LLMGraph DAG で展開する。

ロード: `Block[{$CharacterEncoding = "UTF-8"}, Get["ClaudeRuntime.wl"]]`

## バージョン

### $ClaudeRuntimeVersion
型: String
パッケージバージョン。

## Adapter 仕様
CreateClaudeRuntime / ClaudeRunTurn 系で使う adapter は Association:
```
<|"BuildContext"    -> fn,
  "QueryProvider"    -> fn,
  "ParseProposal"    -> fn,
  "ValidateProposal" -> fn,
  "ExecuteProposal"  -> fn,
  "RedactResult"     -> fn,
  "ShouldContinue"   -> fn|>
```
安全判定・実行可否は adapter 側 (NBAccess) が決める。

## ランタイム生成・実行

### CreateClaudeRuntime[adapter, opts]
RuntimeState を生成する。
→ runtimeId
adapter は上記 Adapter 仕様の Association。

### ClaudeRunTurn[runtimeId, input]
expression-proposal loop を LLMGraph DAG として起動する。
→ jobId

### ClaudeContinueTurn[runtimeId]
前回の turn の continuation を起動する。
→ jobId

### ClaudeRuntimeRetry[runtimeId]
直前ターンの Failed ノードを再実行する。Done ノードの結果は保持し、Failed/Pending ノードのみ新しい DAG で再起動する。アクティブ DAG が残っている場合は LLMGraphDAGRetry に委譲。
→ jobId
例: `ClaudeRuntimeRetry[$ClaudeLastRuntimeId]`

### ClaudeRuntimeCancel[runtimeId]
DAG ジョブをキャンセルする。

## 状態・トレース参照

### ClaudeRuntimeState[runtimeId] → Association
RuntimeState の軽量表示版。NotebookObject や巨大な中間結果 (ConversationState, LastProviderResponse 等) を除外し FrontEnd のフォーマット負荷を軽減。

### ClaudeRuntimeStateFull[runtimeId] → Association
RuntimeState 全体 (Adapter 以外) を返す。Dynamic や直接評価での使用は避けること (FrontEnd がブロックする可能性)。

### ClaudeTurnTrace[runtimeId] → List
EventTrace 全体を返す。

### ClaudeGetConversationMessages[runtimeId] → List
全ターンの Messages を返す。各要素は `<|"Turn"->n, "ProposedCode"->..., "ExecutionResult"->..., "TextResponse"->...|>`。

## 承認フロー
AwaitingApproval 状態の proposal に対する操作。PendingApproval は Kind="TimeoutExtension" の場合 ExpectedSeconds / DefaultTimeoutSeconds を含む。原則として初期設定のタイムアウトを順守し、延長すれば計算できる場合のみ問い合わせる。

### ClaudeApproveProposal[runtimeId]
AwaitingApproval 状態の proposal を承認する。

### ClaudeApproveProposalWithTimeout[runtimeId, timeout]
proposal を承認し、adapter の DefaultTimeoutSeconds を一時的に timeout 秒に上書きする。timeout は Infinity または正整数。タイムアウト延長承認フロー (Phase 30) で使用。

### ClaudeDenyProposal[runtimeId]
AwaitingApproval 状態の proposal を拒否する。

### ClaudeMarkApprovalConsumed[runtimeId, reason]
承認 UI 側が desktop action を既に実行した場合に承認待ち状態を消費し Done にする (実行ロジックは呼ばない)。

## RetryPolicy / 失敗分類

### $ClaudeRuntimeRetryProfile
型: String
RetryPolicy の既定プロファイル。

### ClaudeRetryPolicy[profile] → RetryPolicy
指定プロファイルの RetryPolicy を返す。profile: "Eval" | "UpdatePackage"。

### ClaudeClassifyFailure[failure] → failureClass
failure の分類を返す。

## WorkflowNet 連携 (Transition 実行)

### ClaudeRuntimeExecuteTransition[adapter, contextPacket]
WorkflowNet の Transition 1 つを 1 turn 内で実行する adapter API。BuildContext -> QueryProvider -> ValidateProposal -> ExecuteProposal -> RedactResult を順に呼ぶ純関数的実行。multi-turn / retry / approval は扱わず [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) の Workflow が担当する。
→ 成功時 `<|"Status"->"Success", "Output"->redactedResult, "Proposal"->..., "Validation"->..., "ExecResult"->...|>` / 失敗時 `<|"Status"->"Failed", "Reason"->..., "Diagnostics"->...|>`
adapter は ShouldContinue 不要の `<|"BuildContext", "QueryProvider", "ValidateProposal", "ExecuteProposal", "RedactResult"|>`。contextPacket の主キー: "TransitionName", "Binding", "InputTokens", "Role", "DirectiveBundle", "DirectivePrompt", "AllowedCapabilities", "OutputSchema"。

## 非同期コード実行 (Phase 32)
ExecuteProposal handler が `<|"Async"->True, "Future"->EvaluationObject[...], "HeldExpr"->..., "Timeout"->seconds|Infinity, "StartTime"->AbsoluteTime[]|>` を返すと、実行後段 (RedactResult / ShouldContinue / Continuation) を polling tick に繋ぐ。同期形式も従来通りサポート。

### ClaudeRuntimeAsyncExecutionStatus[runtimeId] → Association
非同期実行中タスクの状態を返す。`<|"Running"->True|False, "Elapsed"->seconds, "Timeout"->seconds|Infinity, "StartTime"->AbsoluteTime, "PollKey"->string|>`。async 実行がなければ `<|"Running"->False|>`。

### ClaudeRuntimeCancelAsyncExecution[runtimeId]
実行中の非同期コードを中断し AbortKernels[] で強制停止する。中断後 LaunchKernels[] で並列カーネルを再起動する。

### ClaudeRuntimeAsyncDiagnose[] → Association
非同期実行経路の現在状態を返す。`<|"ParallelKernels"->_Integer, "ParallelKernelsReady"->Bool, "AsyncExecutionEnabled"->Bool, "AsyncExecutionForced"->Bool, "HighPriorityMode"->Bool, "RuntimeCount"->_Integer, "Runtimes"->{<|...|>,...}|>`。各 Runtime は Status / Phase / TurnCount / AsyncActive / AsyncFutureState / AsyncElapsed を含む。

### ClaudeRuntimeAsyncActiveQ[] → Bool
いずれかの runtime で非同期実行 (AsyncExecution) または非同期 tool 実行 (AsyncToolExec の Running 非空) が走行中なら True。NBAccess の PendingFinalActionQueue はこれが True の間 FrontEnd ブロック action を Pending のまま待つ ($NBFinalActionAsyncActiveFunction 経由)。

## 非同期 Tool 実行 (Phase 32k)

### ClaudeRuntimeCancelAsyncToolExec[runtimeId] → Association
走行中の AsyncToolExec をキャンセルする。Running の全 entry に adapter["CancelToolAsync"] を呼び、Queue の call も Cancelled に下ろし polling tick を解除する。
→ `<|"Success"->_, "CancelledCount"->_Integer, "PollKey"->_String|>`

### ClaudeRuntimeToolExecDiagnose[runtimeId] → Association
現在の AsyncToolExec state を返す診断関数。`<|"Active"->_, "Finalized"->_, "PollKey"->_String, "QueueSize"->_Integer, "RunningSize"->_Integer, "CollectedSize"->_Integer, "ToolCount"->_Integer, "MaxConcurrent"->_Integer, "Elapsed"->_Real, "RunningIndices"->_List, "QueueIndices"->_List, "CollectedIndices"->_List|>`。

### $ClaudeRuntimeToolAsyncDefault
型: Boolean, 初期値: True
AsyncToolExec の既定有効フラグ。True にすると web_search 等を別 OS プロセスで実行しメインカーネルをブロックしない。Runtime ごとに Metadata["ToolAsync"]、Adapter ごとに adapter["ToolAsync"] で上書き可能。