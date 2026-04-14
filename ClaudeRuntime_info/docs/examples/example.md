# ClaudeRuntime 使用例集

ClaudeRuntime パッケージの代表的な使用パターンを紹介します。

---

## 例 1: ランタイムの作成と基本ターンの実行

```mathematica
(* アダプターを定義して RuntimeState を作成する *)
adapter = <|
  "BuildContext"      -> Function[{state, input}, {"role" -> "user", "content" -> input}],
  "QueryProvider"     -> Function[{ctx, opts}, {"role" -> "assistant", "content" -> "42"}],
  "ValidateProposal"  -> Function[proposal, True],
  "ExecuteProposal"   -> Function[proposal, proposal],
  "RedactResult"      -> Function[result, result],
  "ShouldContinue"    -> Function[state, False]
|>;

rid = CreateClaudeRuntime[adapter];
jobId = ClaudeRunTurn[rid, "1 + 1 を計算してください"];
```

**期待される出力:** `"job-xxxx-xxxx"`（DAG ジョブ ID の文字列）

---

## 例 2: ランタイム状態の確認

```mathematica
(* 実行中または完了後の RuntimeState を取得する *)
state = ClaudeRuntimeState[rid];
state["Phase"]
```

**期待される出力:** `"Idle"` または `"Running"` など状態フェーズ文字列

---

## 例 3: イベントトレースの取得

```mathematica
(* ターン全体のイベント履歴を確認する *)
trace = ClaudeTurnTrace[rid];
trace[[All, "EventType"]]
```

**期待される出力:** `{"TurnStarted", "ProviderQueried", "ProposalValidated", "TurnCompleted"}` など

---

## 例 4: AwaitingApproval 状態での提案の承認・拒否

```mathematica
(* 承認待ちの提案を承認する *)
ClaudeApproveProposal[rid]

(* または拒否する場合 *)
ClaudeDenyProposal[rid]
```

**期待される出力:** `"Approved"` または `"Denied"`

---

## 例 5: 前回ターンの継続

```mathematica
(* 前回ターンの続きから実行を再開する *)
ClaudeContinueTurn[rid]
```

**期待される出力:** 新しい DAG ジョブ ID 文字列

---

## 例 6: 会話履歴の取得

```mathematica
(* 全ターンの Messages を Association のリストとして取得する *)
msgs = ClaudeGetConversationMessages[rid];
msgs[[1]]
```

**期待される出力:**
```
<|"Turn" -> 1, "ProposedCode" -> "1 + 1", "ExecutionResult" -> 2, "TextResponse" -> "結果は 2 です。"|>
```

---

## 例 7: リトライポリシーの確認と適用

```mathematica
(* Eval プロファイルの RetryPolicy を取得する *)
ClaudeRetryPolicy["Eval"]

(* UpdatePackage プロファイルの RetryPolicy を取得する *)
ClaudeRetryPolicy["UpdatePackage"]
```

**期待される出力:** `<|"MaxRetries" -> 3, "BackoffSeconds" -> {1, 2, 4}, ...|>` など

---

## 例 8: DAG ジョブのキャンセル

```mathematica
(* 実行中のターンを中断してキャンセルする *)
ClaudeRuntimeCancel[rid]
ClaudeRuntimeState[rid]["Phase"]
```

**期待される出力:** `"Cancelled"`