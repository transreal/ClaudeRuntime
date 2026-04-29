# ClaudeRuntime API Reference

パッケージ: `ClaudeRuntime`
リポジトリ: https://github.com/transreal/ClaudeRuntime

Expression-Proposal Loop State Machine。ターンループ・プロバイダ通信・バリデーション・実行進行管理・usage/event 構造化・セッション状態論理モデルを担う。Notebook・シークレット・アクセスポリシーは知らない。安全判定は adapter 経由で NBAccess が行う。実行形式は claudecode の LLMGraph DAG で展開する。

## 変数

### $ClaudeRuntimeVersion
型: String
パッケージバージョン。

### $ClaudeRuntimeRetryProfile
型: String
RetryPolicy の既定プロファイル。

## ランタイム生成・制御

### CreateClaudeRuntime[adapter, opts] → runtimeId
RuntimeState を生成し runtimeId を返す。
adapter の形式: `<|"BuildContext" -> fn, "QueryProvider" -> fn, "ValidateProposal" -> fn, "ExecuteProposal" -> fn, "RedactResult" -> fn, "ShouldContinue" -> fn|>`

### ClaudeRunTurn[runtimeId, input] → jobId
expression-proposal loop を LLMGraph DAG として起動し jobId を返す。

### ClaudeContinueTurn[runtimeId] → jobId
前回ターンの continuation を起動する。

### ClaudeRuntimeCancel[runtimeId]
DAG ジョブをキャンセルする。

### ClaudeRuntimeRetry[runtimeId]
直前ターンの Failed ノードを再実行する。Done ノードの結果は保持し、Failed/Pending ノードのみ新しい DAG で再起動する。アクティブ DAG が残っている場合は LLMGraphDAGRetry に委譲する。
例: `ClaudeRuntimeRetry[$ClaudeLastRuntimeId]`

## 状態参照

### ClaudeRuntimeState[runtimeId] → Association
RuntimeState の軽量表示版を返す。NotebookObject や巨大な中間結果 (ConversationState, LastProviderResponse 等) を除外する。FrontEnd のフォーマット負荷を軽減するため。

### ClaudeRuntimeStateFull[runtimeId] → Association
RuntimeState 全体 (Adapter 以外) を返す。Dynamic や直接評価での使用は避けること (FrontEnd がブロックする可能性あり)。

### ClaudeTurnTrace[runtimeId] → List
EventTrace 全体を返す。

### ClaudeGetConversationMessages[runtimeId] → List
全ターンの Messages を返す。各ターンの形式: `<|"Turn" -> n, "ProposedCode" -> ..., "ExecutionResult" -> ..., "TextResponse" -> ...|>`

## Proposal 承認

### ClaudeApproveProposal[runtimeId]
AwaitingApproval 状態の proposal を承認する。

### ClaudeDenyProposal[runtimeId]
AwaitingApproval 状態の proposal を拒否する。

## リトライ・障害分類

### ClaudeRetryPolicy[profile] → Association
指定プロファイルの RetryPolicy を返す。profile: `"Eval"` | `"UpdatePackage"`

### ClaudeClassifyFailure[failure] → String
failure class を返す。