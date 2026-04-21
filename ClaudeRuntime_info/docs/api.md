# ClaudeRuntime API Reference

**パッケージ**: `ClaudeRuntime\``
**リポジトリ**: https://github.com/transreal/ClaudeRuntime
**責務**: ターンループ / proposal ループ / プロバイダとのやり取り / validation・execution の進行管理 / continuation / usage・event の構造化 / セッション状態の論理モデル

不変条件: Notebook・secret・アクセスポリシー・ラベル代数を知らない。安全判定は adapter 経由で NBAccess が行う。実行形式は claudecode の LLMGraph DAG で展開する。

## ロード

```wolfram
Block[{$CharacterEncoding = "UTF-8"}, Get["ClaudeRuntime.wl"]]
```

## 変数

### $ClaudeRuntimeVersion
型: String
パッケージバージョン。

### $ClaudeRuntimeRetryProfile
型: String
RetryPolicy の既定プロファイル。`ClaudeRetryPolicy` に渡すデフォルト値。

## ランタイム管理

### CreateClaudeRuntime[adapter, opts] → runtimeId
RuntimeState を生成し runtimeId (String) を返す。

adapter は以下のキーを持つ Association:
```
<|
  "BuildContext"      -> fn,   (* コンテキスト構築 *)
  "QueryProvider"     -> fn,   (* プロバイダ呼び出し *)
  "ValidateProposal"  -> fn,   (* 提案の検証 *)
  "ExecuteProposal"   -> fn,   (* 提案の実行 *)
  "RedactResult"      -> fn,   (* 結果の秘匿化 *)
  "ShouldContinue"    -> fn    (* ループ継続判定 *)
|>
```

### ClaudeRuntimeState[runtimeId] → Association
RuntimeState の軽量表示版を返す。NotebookObject・ConversationState・LastProviderResponse 等の巨大中間結果を除外。FrontEnd のフォーマット負荷を軽減する。完全な状態が必要なら `ClaudeRuntimeStateFull` を使う。

### ClaudeRuntimeStateFull[runtimeId] → Association
RuntimeState 全体 (Adapter キーを除く) を返す。Dynamic や直接評価での使用は避けること (FrontEnd がブロックする可能性がある)。

### ClaudeRuntimeCancel[runtimeId] → Null
DAG ジョブをキャンセルする。

## ターン実行

### ClaudeRunTurn[runtimeId, input] → jobId
expression-proposal ループを LLMGraph DAG として起動し jobId を返す。

### ClaudeContinueTurn[runtimeId] → jobId
前回ターンの continuation を起動する。

### ClaudeRuntimeRetry[runtimeId] → jobId
直前ターンの Failed ノードを再実行する。Done ノードの結果は保持し、Failed/Pending ノードのみ新しい DAG で再起動する。アクティブ DAG が残っている場合は `LLMGraphDAGRetry` に委譲する。

例: `ClaudeRuntimeRetry[$ClaudeLastRuntimeId]`

## Proposal 制御

### ClaudeApproveProposal[runtimeId] → Null
AwaitingApproval 状態の proposal を承認する。

### ClaudeDenyProposal[runtimeId] → Null
AwaitingApproval 状態の proposal を拒否する。

## 状態・トレース取得

### ClaudeTurnTrace[runtimeId] → List
EventTrace 全体を返す。

### ClaudeGetConversationMessages[runtimeId] → List
全ターンの Messages を返す。各要素の形式:
```
<|
  "Turn"            -> n,
  "ProposedCode"    -> ...,
  "ExecutionResult" -> ...,
  "TextResponse"    -> ...
|>
```

## リトライ・エラー分類

### ClaudeRetryPolicy[profile] → Association
指定プロファイルの RetryPolicy を返す。`profile`: `"Eval"` | `"UpdatePackage"`

### ClaudeClassifyFailure[failure] → String
failure の分類クラスを返す。

## 関連パッケージ

- [claudecode](https://github.com/transreal/claudecode) — LLMGraph DAG スケジューラ (`iLLMGraphNode` / `LLMGraphDAGCreate`)
- [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) — タスク分解・マルチエージェント機構
- [NBAccess](https://github.com/transreal/NBAccess) — アクセスポリシー・安全判定の実装