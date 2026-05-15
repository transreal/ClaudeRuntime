# ClaudeRuntime API リファレンス

Expression-Proposal Loop の状態機械を提供するパッケージ。turn loop / proposal loop / provider やり取り / validation・execution の進行管理 / continuation / usage・event の構造化 / session state の論理モデルを担当する。

## バージョン

### $ClaudeRuntimeVersion
型: String
パッケージバージョン。

## Runtime 生成・実行

### CreateClaudeRuntime[adapter, opts]
RuntimeState を生成し runtimeId を返す。
→ String (runtimeId)
adapter の形式:
```
<|"BuildContext"     -> fn,
  "QueryProvider"    -> fn,
  "ValidateProposal" -> fn,
  "ExecuteProposal"  -> fn,
  "RedactResult"     -> fn,
  "ShouldContinue"   -> fn|>
```

### ClaudeRunTurn[runtimeId, input] → String (jobId)
expression-proposal loop を LLMGraph DAG として起動する。

### ClaudeContinueTurn[runtimeId] → String (jobId)
前回 turn の continuation を起動する。

### ClaudeRuntimeCancel[runtimeId] → _
DAG ジョブをキャンセルする。

## State 参照

### ClaudeRuntimeState[runtimeId] → Association
RuntimeState の軽量表示版。NotebookObject や巨大な中間結果 (ConversationState, LastProviderResponse 等) を除外。FrontEnd のフォーマット負荷軽減用。

### ClaudeRuntimeStateFull[runtimeId] → Association
RuntimeState 全体 (Adapter 以外) を返す。Dynamic や直接評価での使用は避けること (FrontEnd をブロックする可能性)。

### ClaudeTurnTrace[runtimeId] → List
EventTrace 全体を返す。

### ClaudeGetConversationMessages[runtimeId] → List
全ターンの Messages を返す。各要素は `<|"Turn"->n, "ProposedCode"->..., "ExecutionResult"->..., "TextResponse"->...|>` の形式。

## 承認・拒否フロー

### ClaudeApproveProposal[runtimeId] → _
AwaitingApproval 状態の proposal を承認する。

### ClaudeApproveProposalWithTimeout[runtimeId, timeout] → _
AwaitingApproval 状態の proposal を、adapter の `DefaultTimeoutSeconds` を一時的に `timeout` 秒 (Infinity 可) に上書きして承認する。Phase 30 (2026-05-13) で追加されたタイムアウト延長承認フロー用。
timeout: Infinity | 正整数

### ClaudeDenyProposal[runtimeId] → _
AwaitingApproval 状態の proposal を拒否する。

## Retry / Failure 分類

### $ClaudeRuntimeRetryProfile
型: String, 初期値: 既定プロファイル名
RetryPolicy の既定プロファイル。

### ClaudeRetryPolicy[profile] → Association
指定プロファイルの RetryPolicy を返す。
profile: `"Eval"` | `"UpdatePackage"`

### ClaudeClassifyFailure[failure] → String
failure class を返す。

### ClaudeRuntimeRetry[runtimeId] → _
直前ターンの Failed ノードを再実行する。Done ノードの結果は保持し、Failed/Pending ノードのみ新しい DAG で再起動する。アクティブ DAG が残っている場合は `LLMGraphDAGRetry` に委譲する。
例: `ClaudeRuntimeRetry[$ClaudeLastRuntimeId]`

## Workflow Transition Adapter

### ClaudeRuntimeExecuteTransition[adapter, contextPacket] → Association
WorkflowNet の Transition 1 つを 1 turn 内で実行する adapter API。`BuildContext -> QueryProvider -> ValidateProposal -> ExecuteProposal -> RedactResult` を順に呼ぶ純関数的な実行。multi-turn / retry / approval は ClaudeOrchestrator`Workflow が担当しここでは扱わない。
adapter (ShouldContinue 不要):
```
<|"BuildContext"     -> fn[contextPacket] -> ctx,
  "QueryProvider"    -> fn[ctx, contextPacket] -> proposal,
  "ValidateProposal" -> fn[proposal, contextPacket] -> validateResult,
  "ExecuteProposal"  -> fn[proposal, contextPacket] -> execResult,
  "RedactResult"     -> fn[execResult, contextPacket] -> redactedResult|>
```
contextPacket の主なキー: `"TransitionName"`, `"Binding"`, `"InputTokens"`, `"Role"`, `"DirectiveBundle"`, `"DirectivePrompt"`, `"AllowedCapabilities"`, `"OutputSchema"`
戻り値 (成功時):
```
<|"Status" -> "Success",
  "Output" -> redactedResult,
  "Proposal" -> proposal,
  "Validation" -> validateResult,
  "ExecResult" -> execResult|>
```
戻り値 (失敗時):
```
<|"Status" -> "Failed", "Reason" -> "...", "Diagnostics" -> ...|>
```

## 非同期実行 (Phase 32)

ExecuteProposal handler が次の形式の Association を返した場合、ClaudeRuntime は実行後の段階 (RedactResult, ShouldContinue, Continuation) を `ClaudeRegisterPollingTick` 経由の tick に繋げる:
```
<|"Async"     -> True,
  "Future"    -> EvaluationObject[...],
  "HeldExpr"  -> heldExpr,
  "Timeout"   -> seconds | Infinity,
  "StartTime" -> AbsoluteTime[]|>
```
同期形式 (従来通り) もそのままサポートされる。`ClaudeApproveProposal[WithTimeout]` 経由の起動でも `"AsyncExecutionScheduled"` を検出したら polling tick に後処理を委ねる。

### ClaudeRuntimeAsyncExecutionStatus[runtimeId] → Association
runtime で非同期実行中のタスク状態を返す。
```
<|"Running"   -> True | False,
  "Elapsed"   -> seconds,
  "Timeout"   -> seconds | Infinity,
  "StartTime" -> AbsoluteTime,
  "PollKey"   -> string|>
```
async 実行がない場合は `<|"Running" -> False|>` を返す。

### ClaudeRuntimeCancelAsyncExecution[runtimeId] → _
実行中の非同期コードを中断し、`AbortKernels[]` で強制停止する。中断後は `LaunchKernels[]` で並列カーネルを再起動する。

### ClaudeRuntimeAsyncDiagnose[] → Association
ClaudeRuntime の非同期実行経路の現在状態を返す診断ツール (Phase 32k, 2026-05-14)。
```
<|"ParallelKernels"        -> _Integer,
  "ParallelKernelsReady"   -> True | False,
  "AsyncExecutionEnabled"  -> True | False,
  "AsyncExecutionForced"   -> True | False,
  "HighPriorityMode"       -> True | False,
  "RuntimeCount"           -> _Integer,
  "Runtimes"               -> {<|...|>, ...}|>
```
各 Runtime は Status / Phase / TurnCount / AsyncActive / AsyncFutureState / AsyncElapsed を含む。

## AsyncToolExec (Phase 32k Step 3)

### ClaudeRuntimeCancelAsyncToolExec[runtimeId] → Association
走行中の AsyncToolExec (非同期 tool 実行) をキャンセルする。Running の全 entry に対し `adapter["CancelToolAsync"]` を呼び、Queue の call も Cancelled に卸し、polling tick を解除する。
戻り値:
```
<|"Success"        -> _,
  "CancelledCount" -> _Integer,
  "PollKey"        -> _String|>
```

### ClaudeRuntimeToolExecDiagnose[runtimeId] → Association
現在の AsyncToolExec state を返す診断関数。
```
<|"Active"           -> _,
  "Finalized"        -> _,
  "PollKey"          -> _String,
  "QueueSize"        -> _Integer,
  "RunningSize"      -> _Integer,
  "CollectedSize"    -> _Integer,
  "ToolCount"        -> _Integer,
  "MaxConcurrent"    -> _Integer,
  "Elapsed"          -> _Real,
  "RunningIndices"   -> _List,
  "QueueIndices"     -> _List,
  "CollectedIndices" -> _List|>
```

### $ClaudeRuntimeToolAsyncDefault
型: Boolean, 初期値: False
AsyncToolExec の既定有効フラグ。True にすると web_search 等を別 OS プロセスで実行しメインカーネルをブロックしない。Runtime ごとに `Metadata["ToolAsync"]` で、Adapter ごとに `adapter["ToolAsync"]` で上書き可能。

## PendingApproval 追加フィールド (Phase 30)

`iDispatchDecision` の `"Permit"` 分岐で `proposal[ExpectedSeconds]` が `adapter[DefaultTimeoutSeconds]` を超える場合、`AwaitingApproval` に遷移する。PendingApproval は以下のフィールドを含む:
- `Kind` = `"TimeoutExtension"`
- `ExpectedSeconds`
- `DefaultTimeoutSeconds`

設計原則: 原則初期設定のタイムアウトを順守、延長すれば計算できる場合のみ問い合わせダイアログを出す。

## 関連パッケージ

- [claudecode](https://github.com/transreal/claudecode) — LLMGraph DAG / iLLMGraphNode / 共有スケジューラ
- [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) — multi-turn / approval / retry / snapshot を担う上位レイヤ
- [NBAccess](https://github.com/transreal/NBAccess) — adapter 経由の安全判定