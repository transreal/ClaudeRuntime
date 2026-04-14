# ClaudeRuntime API Reference

パッケージ: `ClaudeRuntime`
GitHub: https://github.com/transreal/ClaudeRuntime
責務: expression-proposal ループのステートマシン。ターンループ・プロバイダ通信・validation/execution 進行管理・continuation・usage/event 構造化・セッション状態の論理モデルを担う。Notebook・secret・アクセスポリシーは知らない。

## 変数

### $ClaudeRuntimeVersion
型: String
パッケージバージョン文字列。

### $ClaudeRuntimeRetryProfile
型: String
`ClaudeRetryPolicy` が使う既定プロファイル名。

## ランタイム生成

### CreateClaudeRuntime[adapter, opts]
RuntimeState を生成して runtimeId を返す。
→ runtimeId (String)
adapter は以下キーを持つ Association:
`"BuildContext" -> fn` — コンテキスト構築関数
`"QueryProvider" -> fn` — プロバイダ問い合わせ関数
`"ValidateProposal" -> fn` — proposal 検証関数
`"ExecuteProposal" -> fn` — proposal 実行関数
`"RedactResult" -> fn` — 結果リダクション関数
`"ShouldContinue" -> fn` — 継続判定関数
例: `CreateClaudeRuntime[<|"BuildContext"->bc, "QueryProvider"->qp, "ValidateProposal"->vp, "ExecuteProposal"->ep, "RedactResult"->rr, "ShouldContinue"->sc|>]`

## ターン制御

### ClaudeRunTurn[runtimeId, input]
expression-proposal ループを LLMGraph DAG として起動し jobId を返す。
→ jobId

### ClaudeContinueTurn[runtimeId]
前回ターンの continuation を起動する。
→ jobId

### ClaudeRuntimeCancel[runtimeId]
DAG ジョブをキャンセルする。
→ Null

### ClaudeRuntimeRetry[runtimeId]
直前ターンの Failed ノードを再実行する。Done ノードの結果は保持し、Failed/Pending ノードのみ新しい DAG で再起動する。アクティブ DAG が残っている場合は `LLMGraphDAGRetry` に委譲する。
→ jobId
例: `ClaudeRuntimeRetry[$ClaudeLastRuntimeId]`

## 承認フロー

### ClaudeApproveProposal[runtimeId]
AwaitingApproval 状態の proposal を承認する。
→ Null

### ClaudeDenyProposal[runtimeId]
AwaitingApproval 状態の proposal を拒否する。
→ Null

## 状態参照

### ClaudeRuntimeState[runtimeId]
現在の RuntimeState を返す。
→ Association

### ClaudeTurnTrace[runtimeId]
EventTrace 全体を返す。
→ List

### ClaudeGetConversationMessages[runtimeId]
全ターンの Messages を返す。各ターンは `<|"Turn"->n, "ProposedCode"->..., "ExecutionResult"->..., "TextResponse"->...|>` の形式。
→ List[Association]

## リトライ・障害分類

### ClaudeRetryPolicy[profile]
指定プロファイルの RetryPolicy を返す。
→ Association
profile: `"Eval"` | `"UpdatePackage"`

### ClaudeClassifyFailure[failure]
failure の分類クラスを返す。
→ Symbol | String