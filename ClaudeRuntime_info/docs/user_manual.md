# ClaudeRuntime ユーザーマニュアル

ClaudeRuntime は、Wolfram Language / Mathematica 上で動作する **expression-proposal ループ**の進行管理エンジンです。  
LLM（外部プロバイダー）に Mathematica 式の提案を求め、安全性検証・実行・継続を状態機械として管理します。

---

## 概要

ClaudeRuntime の役割は「提案ループの進行管理」に限定されています。  
機密データの保持・アクセス可否の判定・実行の安全性チェックは、必ず [NBAccess](https://github.com/transreal/NBAccess) を通じて行われます。  
通常のユーザーは、ClaudeRuntime を直接操作するのではなく、[claudecode](https://github.com/transreal/claudecode) が提供する `ClaudeEval` / `ClaudeUpdatePackage` 経由でこの機能を利用します。

---

## カテゴリ別リファレンス

### 1. Runtime 管理

#### `$ClaudeRuntimeVersion`

パッケージのバージョン文字列を返します。

```mathematica
$ClaudeRuntimeVersion
(* "1.0.0" など *)
```

---

#### `CreateClaudeRuntime`

RuntimeState を生成し、`runtimeId` を返します。  
`adapter` には BuildContext / QueryProvider / ValidateProposal / ExecuteProposal / RedactResult / ShouldContinue の 6 つのキーを持つ Association を渡します。

**シグネチャ:**
```mathematica
CreateClaudeRuntime[adapter, opts]
```

**例:** claudecode が提供するアダプターを使って runtime を作成する場合

```mathematica
adapter = ClaudeBuildRuntimeAdapter[];
runtimeId = CreateClaudeRuntime[adapter,
  "Profile" -> "Eval",
  "MaxTotalSteps" -> 6
];
```

---

### 2. ターン実行

#### `ClaudeRunTurn`

ユーザー入力を受け取り、expression-proposal ループを LLMGraph DAG として起動します。  
戻り値は `jobId` です。

**シグネチャ:**
```mathematica
ClaudeRunTurn[runtimeId, input]
```

**例:**

```mathematica
jobId = ClaudeRunTurn[runtimeId, "この関数の処理内容を3行で要約して"];
```

---

#### `ClaudeContinueTurn`

直前のターンの実行結果を踏まえて、継続ターンを起動します。  
前回のターンが `Done` 状態のときに呼び出します。

**シグネチャ:**
```mathematica
ClaudeContinueTurn[runtimeId]
```

**例:**

```mathematica
(* 前回ターンが Done になった後 *)
ClaudeContinueTurn[runtimeId]
```

---

### 3. 状態照会

#### `ClaudeRuntimeState`

現在の RuntimeState（Association）を返します。  
`"Status"` / `"LastFailure"` / `"BudgetsUsed"` などのキーを持ちます。

**シグネチャ:**
```mathematica
ClaudeRuntimeState[runtimeId]
```

**例:**

```mathematica
state = ClaudeRuntimeState[runtimeId];
state["Status"]
(* "Done" | "Running" | "AwaitingApproval" | "Failed" など *)
```

主なキー:

| キー | 内容 |
|------|------|
| `"Status"` | 現在の状態 |
| `"TurnCount"` | 実行ターン数 |
| `"LastProposal"` | 直近の提案内容 |
| `"LastFailure"` | 直近の失敗情報 |
| `"BudgetsUsed"` | 消費済み予算 |
| `"CurrentJobId"` | 実行中 DAG ジョブ ID |

---

#### `ClaudeTurnTrace`

このセッションで記録された EventTrace 全体をリストで返します。  
デバッグや実行過程の可視化に使います。

**シグネチャ:**
```mathematica
ClaudeTurnTrace[runtimeId]
```

**例:**

```mathematica
trace = ClaudeTurnTrace[runtimeId];
Dataset[trace]
```

各イベントの主な `"Type"` 値:

| Type | 意味 |
|------|------|
| `"TurnStarted"` | ターン開始 |
| `"ProviderQueried"` | LLM 応答受信 |
| `"ProposalParsed"` | 提案パース完了 |
| `"ValidationComplete"` | 検証完了 |
| `"AwaitingApproval"` | 承認待ち |
| `"TurnComplete"` | ターン正常完了 |
| `"BudgetExhausted"` | 予算上限到達 |
| `"FatalFailure"` | 致命的失敗 |

---

#### `ClaudeGetConversationMessages`

全ターンの会話メッセージを返します。  
各ターンは `"Turn"` / `"ProposedCode"` / `"ExecutionResult"` / `"TextResponse"` を持つ Association です。

**シグネチャ:**
```mathematica
ClaudeGetConversationMessages[runtimeId]
```

**例:**

```mathematica
msgs = ClaudeGetConversationMessages[runtimeId];
msgs[[1]]["TextResponse"]
```

---

### 4. 承認操作

LLM の提案に対して `NeedsApproval` または `Deny` の判定が出ると、  
RuntimeState が `"AwaitingApproval"` になります。  
このとき以下の関数で承認・拒否を行います。

#### `ClaudeApproveProposal`

`"AwaitingApproval"` 状態の提案をユーザーが承認し、実行を再開します。

**シグネチャ:**
```mathematica
ClaudeApproveProposal[runtimeId]
```

**例:**

```mathematica
If[ClaudeRuntimeState[runtimeId]["Status"] === "AwaitingApproval",
  ClaudeApproveProposal[runtimeId]
]
```

---

#### `ClaudeDenyProposal`

`"AwaitingApproval"` 状態の提案をユーザーが拒否します。  
状態は `"Failed"` に移行します。

**シグネチャ:**
```mathematica
ClaudeDenyProposal[runtimeId]
```

**例:**

```mathematica
ClaudeDenyProposal[runtimeId]
```

---

#### `ClaudeRuntimeCancel`

実行中の DAG ジョブをキャンセルします。  
ターンの途中でも即時停止します。

**シグネチャ:**
```mathematica
ClaudeRuntimeCancel[runtimeId]
```

**例:**

```mathematica
ClaudeRuntimeCancel[runtimeId]
```

---

### 5. リトライポリシー

ClaudeRuntime は「再帰回数制限」の代わりに、**複数の予算**で実行を制御します。  
リトライポリシーは `"Eval"` と `"UpdatePackage"` の 2 種のプロファイルが用意されています。

#### `$ClaudeRuntimeRetryProfile`

現在のデフォルトのリトライポリシープロファイル名（文字列）を返します。

```mathematica
$ClaudeRuntimeRetryProfile
(* "Eval" など *)
```

---

#### `ClaudeRetryPolicy`

指定プロファイルのリトライポリシー（Association）を返します。  
`"Eval"` は対話的・即時反映型、`"UpdatePackage"` はトランザクション型です。

**シグネチャ:**
```mathematica
ClaudeRetryPolicy[profile]
(* profile: "Eval" | "UpdatePackage" *)
```

**例:**

```mathematica
ClaudeRetryPolicy["Eval"]
(* <|"Profile" -> "Eval", "Limits" -> <|"MaxTotalSteps" -> 6, ...|>, ...|> *)
```

主な予算キー（`"Limits"` 内）:

| キー | 意味 |
|------|------|
| `"MaxTotalSteps"` | 全ステップ上限 |
| `"MaxProposalIterations"` | 提案ループ上限 |
| `"MaxTransportRetries"` | 通信リトライ上限 |
| `"MaxFormatRetries"` | フォーマット修復上限 |
| `"MaxValidationRepairs"` | 検証修復上限 |
| `"MaxTestRepairs"` | テスト修復上限（UpdatePackage のみ） |
| `"MaxFullReplans"` | 全面再計画上限（UpdatePackage のみ） |

> 承認待ち（`AwaitingApproval`）は失敗ではないため、これらの予算を消費しません。

---

#### `ClaudeClassifyFailure`

失敗情報（Association）を受け取り、失敗クラス名（文字列）を返します。

**シグネチャ:**
```mathematica
ClaudeClassifyFailure[failure]
```

**例:**

```mathematica
lastFailure = ClaudeRuntimeState[runtimeId]["LastFailure"];
ClaudeClassifyFailure[lastFailure]
(* "TransportTransient" | "SecurityViolation" | ... *)
```

失敗クラスの主な区分:

| クラス | リトライ可否 | 説明 |
|--------|------------|------|
| `TransportTransient` | ○ | 通信障害 |
| `ProviderRateLimit` | ○ | レート制限 |
| `ModelFormatError` | ○ | LLM 応答フォーマット不正 |
| `ValidationRepairable` | ○ | 修復可能な検証失敗 |
| `ReloadError` | ○ | パッケージリロードエラー |
| `TestFailure` | ○ | テスト失敗 |
| `SecurityViolation` | ✗ | セキュリティ違反（即時停止） |
| `ConfidentialLeakRisk` | ✗ | 機密漏洩リスク（即時停止） |
| `ForbiddenHead` | ✗ | 禁止 head の使用（即時停止） |
| `ExplicitDeny` | ✗ | 明示的拒否（即時停止） |

---

## Status 遷移

```
Initialized → Running → Done
                ↓         ↑（継続ターン）
                → AwaitingApproval → Running → Done
                ↓                          ↓
                → Failed                   → Failed
```

| Status | 説明 |
|--------|------|
| `Initialized` | 生成直後・未起動 |
| `Running` | ターン実行中 |
| `Done` | 正常完了（継続可能） |
| `AwaitingApproval` | ユーザー承認待ち |
| `Failed` | 失敗（`"LastFailure"` に詳細） |

---

## 診断コード例

```mathematica
(* 直近の runtimeId を確認 *)
$ClaudeLastRuntimeId

(* 状態の確認 *)
ClaudeRuntimeState[$ClaudeLastRuntimeId]["Status"]
ClaudeRuntimeState[$ClaudeLastRuntimeId]["LastFailure"]

(* イベントトレースの確認 *)
Dataset[ClaudeTurnTrace[$ClaudeLastRuntimeId]]

(* 会話履歴の確認 *)
Dataset[ClaudeGetConversationMessages[$ClaudeLastRuntimeId]]

(* DAG ジョブの状態確認 *)
LLMGraphDAGStatus[
  ClaudeRuntimeState[$ClaudeLastRuntimeId]["CurrentJobId"]
]
```

---

## 関連パッケージ

- [NBAccess](https://github.com/transreal/NBAccess) — 機密データの保持・アクセス可否判定・式の安全性検証
- [claudecode](https://github.com/transreal/claudecode) — Notebook UI・アダプター実装・`ClaudeEval` / `ClaudeUpdatePackage` の提供
- [ClaudeTestKit](https://github.com/transreal/ClaudeTestKit) — モックプロバイダー・シナリオテスト基盤