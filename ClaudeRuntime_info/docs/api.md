# ClaudeRuntime API リファレンス

Expression-Proposal Loop ステートマシン。turn loop / proposal loop / provider 連携 / validation・execution の進行管理 / continuation / usage・event の構造化 / session state の論理モデルを担う。Notebook・secret・access policy・label algebra は知らず、abstract adapter interface 経由で操作する。安全判定は adapter 経由で [NBAccess](https://github.com/transreal/NBAccess) が行い、実行形式は [claudecode](https://github.com/transreal/claudecode) の LLMGraph DAG で展開する。

## バージョン

### $ClaudeRuntimeVersion
型: String
パッケージバージョン。

## Runtime 生成・実行

### CreateClaudeRuntime[adapter, opts] → runtimeId
RuntimeState を生成し runtimeId を返す。
adapter は次の形式の Association:
```
<|"BuildContext"    -> fn,
  "QueryProvider"    -> fn,
  "ValidateProposal" -> fn,
  "ExecuteProposal"  -> fn,
  "RedactResult"     -> fn,
  "ShouldContinue"   -> fn|>
```

### ClaudeRunTurn[runtimeId, input] → jobId
expression-proposal loop を LLMGraph DAG として起動し jobId を返す。

### ClaudeContinueTurn[runtimeId] → jobId
前回の turn の continuation を起動する。

### ClaudeRuntimeCancel[runtimeId]
DAG ジョブをキャンセルする。

### ClaudeRuntimeRetry[runtimeId]
直前ターンの Failed ノードを再実行する。Done ノードの結果は保持し、Failed/Pending ノードのみ新しい DAG で再起動。アクティブ DAG が残っている場合は LLMGraphDAGRetry に委譲する。
例: ClaudeRuntimeRetry[$ClaudeLastRuntimeId]

## 状態取得

### ClaudeRuntimeState[runtimeId] → Association
RuntimeState の軽量表示版。NotebookObject や巨大な中間結果 (ConversationState, LastProviderResponse 等) を除外し FrontEnd のフォーマット負荷を軽減する。完全版が必要なら ClaudeRuntimeStateFull を使う。

### ClaudeRuntimeStateFull[runtimeId] → Association
RuntimeState 全体 (Adapter 以外) を返す。Dynamic や直接評価での使用は避けること (FrontEnd がブロックする可能性)。

### ClaudeTurnTrace[runtimeId] → list
EventTrace 全体を返す。

### ClaudeGetConversationMessages[runtimeId] → list
全ターンの Messages を返す。各ターンは `<|"Turn"->n, "ProposedCode"->..., "ExecutionResult"->..., "TextResponse"->...|>` の形式。

## 承認フロー

### ClaudeApproveProposal[runtimeId]
AwaitingApproval 状態の proposal を承認する。

### ClaudeApproveProposalWithTimeout[runtimeId, timeout]
AwaitingApproval 状態の proposal を、adapter の DefaultTimeoutSeconds を一時的に timeout 秒に上書きして承認する。timeout に Infinity / 正整数を指定可。Phase 30 のタイムアウト延長承認フローで使用。

### ClaudeDenyProposal[runtimeId]
AwaitingApproval 状態の proposal を拒否する。

### ClaudeMarkApprovalConsumed[runtimeId, reason]
承認 UI 側が desktop action を既に実行した場合に承認待ち状態を消費し Done にする (実行ロジックは呼ばない)。

## RetryPolicy / 失敗分類

### $ClaudeRuntimeRetryProfile
RetryPolicy の既定プロファイル。

### ClaudeRetryPolicy[profile] → RetryPolicy
指定プロファイルの RetryPolicy を返す。profile: "Eval" | "UpdatePackage"

### ClaudeClassifyFailure[failure] → class
failure class を返す。

## Workflow 連携 (Transition adapter)

### ClaudeRuntimeExecuteTransition[adapter, contextPacket] → Association
WorkflowNet の Transition 1 つを 1 turn 内で実行する adapter API。BuildContext → QueryProvider → ValidateProposal → ExecuteProposal → RedactResult を順に呼ぶ純関数的実行。multi-turn / retry / approval は扱わず、それらは [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) の Workflow が担当する。
adapter 形式 (CreateClaudeRuntime と同じだが ShouldContinue 不要):
```
<|"BuildContext"    -> fn[contextPacket] -> ctx,
  "QueryProvider"    -> fn[ctx, contextPacket] -> proposal,
  "ValidateProposal" -> fn[proposal, contextPacket] -> validateResult,
  "ExecuteProposal"  -> fn[proposal, contextPacket] -> execResult,
  "RedactResult"     -> fn[execResult, contextPacket] -> redactedResult|>
```
contextPacket の主なキー: "TransitionName", "Binding", "InputTokens", "Role", "DirectiveBundle", "DirectivePrompt", "AllowedCapabilities", "OutputSchema"。
戻り値 (成功): `<|"Status"->"Success", "Output"->redactedResult, "Proposal"->..., "Validation"->..., "ExecResult"->...|>`
戻り値 (失敗): `<|"Status"->"Failed", "Reason"->..., "Diagnostics"->...|>`

## 非同期コード実行 (Phase 32)

ExecuteProposal handler が `<|"Async"->True, "Future"->EvaluationObject[...], "HeldExpr"->heldExpr, "Timeout"->seconds|Infinity, "StartTime"->AbsoluteTime[]|>` を返すと、実行後段階 (RedactResult, ShouldContinue, Continuation) を polling tick に繋ぐ。同期形式も従来通りサポート。

### ClaudeRuntimeAsyncExecutionStatus[runtimeId] → Association
非同期実行中タスクの状態を返す。`<|"Running"->True|False, "Elapsed"->seconds, "Timeout"->seconds|Infinity, "StartTime"->AbsoluteTime, "PollKey"->string|>`。async 実行がなければ `<|"Running"->False|>`。

### ClaudeRuntimeCancelAsyncExecution[runtimeId]
実行中の非同期コードを中断し AbortKernels[] で強制停止する。中断後は LaunchKernels[] で並列カーネルを再起動する。

### ClaudeRuntimeAsyncDiagnose[] → Association
非同期実行経路の現在状態を返す。`<|"ParallelKernels"->_Integer, "ParallelKernelsReady"->_, "AsyncExecutionEnabled"->_, "AsyncExecutionForced"->_, "HighPriorityMode"->_, "RuntimeCount"->_Integer, "Runtimes"->{<|...|>,...}|>`。各 Runtime は Status / Phase / TurnCount / AsyncActive / AsyncFutureState / AsyncElapsed を含む。

### ClaudeRuntimeAsyncActiveQ[] → True|False
いずれかの runtime で非同期実行 (AsyncExecution) または非同期 tool 実行 (AsyncToolExec の Running 非空) が走行中なら True。NBAccess の PendingFinalActionQueue は、これが True の間 FrontEnd ブロック action を実行せず Pending のまま待つ。

## 非同期 Tool 実行 (AsyncToolExec, Phase 32k)

### ClaudeRuntimeCancelAsyncToolExec[runtimeId] → Association
走行中の AsyncToolExec をキャンセルする。Running の全 entry に対し adapter["CancelToolAsync"] を呼び、Queue の call も Cancelled に倒して polling tick を解除する。
戻り値: `<|"Success"->_, "CancelledCount"->_Integer, "PollKey"->_String|>`

### ClaudeRuntimeToolExecDiagnose[runtimeId] → Association
現在の AsyncToolExec state を返す診断関数。`<|"Active"->_, "Finalized"->_, "PollKey"->_String, "QueueSize"->_Integer, "RunningSize"->_Integer, "CollectedSize"->_Integer, "ToolCount"->_Integer, "MaxConcurrent"->_Integer, "Elapsed"->_Real, "RunningIndices"->_List, "QueueIndices"->_List, "CollectedIndices"->_List|>`

### $ClaudeRuntimeToolAsyncDefault
型: True|False, 初期値: False
AsyncToolExec の既定有効フラグ。True にすると web_search 等を別 OS プロセスで実行しメインカーネルをブロックしない。初期値 False (legacy sync 経路維持)。Runtime ごとに Metadata["ToolAsync"]、Adapter ごとに adapter["ToolAsync"] で上書き可能。