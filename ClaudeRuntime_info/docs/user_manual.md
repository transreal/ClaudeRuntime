# ClaudeRuntime ユーザーマニュアル

ClaudeRuntime は、Wolfram Language / Mathematica 上で動作する **expression-proposal ループ**の進行管理エンジンです。  
LLM（外部プロバイダー）に Mathematica 式の提案を求め、安全性検証・実行・継続を状態機械として管理します。

---

## 概要

ClaudeRuntime の役割は「提案ループの進行管理」に限定されています。  
機密データの保持・アクセス可否の判定・実行の安全性チェックは、必ず [NBAccess](https://github.com/transreal/NBAccess) を通じて行われます。  
通常のユーザーは、ClaudeRuntime を直接操作するのではなく、[claudecode](https://github.com/transreal/claudecode) が提供する `ClaudeEval` / `ClaudeUpdatePackage` 経由でこの機能を利用します。

タスク分解・マルチエージェント機構は [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) が担います。ClaudeOrchestrator は複数の ClaudeRuntime インスタンスをオーケストレーションし、複雑なタスクをサブタスクに分解して並列・順次実行する上位レイヤーです。  
**2026-04-16 以降、ClaudeOrchestrator が発行する `ClaudeEval` 呼び出しは非同期化されました。** 各サブタスクは DAG ジョブとして即座に起動し、呼び出し側はブロックせずに結果を後から取得できます（詳細は「ClaudeOrchestrator と非同期 ClaudeEval」節を参照）。

---

## ClaudeEval の使い方

### ClaudeEval とは

`ClaudeEval` は、プロンプト（自然言語）から Wolfram Language のコードを LLM に生成させ、安全性チェックを経て自動実行する関数です。  
以前は [claudecode](https://github.com/transreal/claudecode) 内部で定義されていましたが、現在は ClaudeRuntime パッケージによる実装に移行しています。

### 切り替えの仕組み（$UseClaudeRuntime）

`$UseClaudeRuntime = True` に設定すると、ClaudeRuntime ベースの新実装が有効になります。  
`ClaudeRuntime`` パッケージをロードすると自動的に `$UseClaudeRuntime = True` に設定され、以降の `ClaudeEval` 呼び出しは ClaudeRuntime 経由で処理されます。

```mathematica
(* ClaudeRuntime をロードすると $UseClaudeRuntime = True が自動設定される *)
<< ClaudeRuntime`
```

> **注意**: バージョン `2026-04-16T14-phase31-removed` 以降、ロード時のメッセージ表示は廃止されました。  
> バージョン情報は `ClaudeRuntime`$ClaudeRuntimeVersion` 変数で、`$UseClaudeRuntime` の現在値は `ClaudeCode`$UseClaudeRuntime` で確認できます。

依存関係の構成は以下のとおりです。

```
NBAccess.wl
   ↑
   │  (public safe API only)
   │
claudecode.wl ─────────→ ClaudeRuntime.wl
   ↑                    ↑
   └────────────────────
         ClaudeTestKit.wl
         (mock provider / mock adapter / NBAccess fixture)
```

- `$UseClaudeRuntime = False`（既定値、claudecode のみロード時）— 旧来の claudecode 内部実装が使われます。
- `$UseClaudeRuntime = True`（ClaudeRuntime ロード時）— ClaudeRuntime ベースの実装が使われます。

### 基本的な使い方

使い方は従来の `ClaudeEval` とほぼ同様です。プロンプトを渡すと LLM が Wolfram Language の式を提案し、自動実行されます。

**例 1 — 斜方投射のグラフを描く**

```mathematica
ClaudeEval["Graph of projectile motion thrown upward"]
```

LLM が以下のような式を提案し、実行します。

```mathematica
Module[{v0 = 20, g = 9.8, tMax, hMax, tFlight},
  tMax = v0/g;
  hMax = v0^2/(2 g);
  tFlight = 2 v0/g;
  Show[
    Plot[v0 t - (1/2) g t^2, {t, 0, tFlight},
      PlotRange -> All, AxesLabel -> {"t (s)", "h (m)"}, ...],
    ...
  ]
]
```

**例 2 — 危険なコードは自動停止される**

コアパッケージの内部変数を書き換えるなど、安全性が疑われる提案には承認ダイアログが表示されます。

```mathematica
ClaudeEval["Assign {} to ClaudeRuntime`Private`$iClaudeRuntimes"]
```

```
❓ Approval required: CoreContextOverwrite
  — Code overwrites core package functions (NBAccess/ClaudeCode/ClaudeRuntime/ClaudeTestKit).
    This may break system functionality. Approval required.
```

ノートブックに [Approve] / [Cancel] ボタンが表示され、ユーザーが判断します。  
プログラムで操作する場合は `ClaudeApproveProposal` / `ClaudeDenyProposal` を使います（詳細は「承認操作」節を参照）。

`DeleteFile` / `RunProcess` / `Run` など明示的に禁止された head を含む提案は `Deny`（即時停止）になります。

**例 3 — セキュリティポリシーと機密データ**

ユーザーが秘匿すべきセルや変数の情報はクラウド LLM に渡らず、スキーマ情報のみが渡ります。  
ローカル LLM（`$ClaudePrivateModel`）を指定すれば機密データも処理できます。

```mathematica
{$ClaudeModel, $ClaudePrivateModel}
(* {"claude-opus-4-6", {"lmstudio", "qwen/qwen3.5-35b-a3b", "http://127.0.0.1:1234"}} *)
```

### 実行中の状態確認

`ClaudeEval` 実行中・実行後のランタイム状態は以下で確認できます。

```mathematica
(* 直近のランタイム ID *)
$ClaudeLastRuntimeId

(* 全ランタイムの状態一覧 *)
Dataset[KeyValueMap[
  Function[{id, rt},
    <|"RuntimeId" -> id,
      "Status"    -> rt["Status"],
      "TurnCount" -> rt["TurnCount"],
      "Profile"   -> rt["Profile"],
      "LastFailure" -> Lookup[rt, "LastFailure", None]|>],
  ClaudeRuntime`Private`$iClaudeRuntimes
]]
```

---

## ClaudeOrchestrator と非同期 ClaudeEval

### 概要

[ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) は、複雑なタスクを複数のサブタスクに分解し、それぞれを独立した `ClaudeRuntime` インスタンスで並列または順次実行するオーケストレーション層です。

**2026-04-16 以降（バージョン `phase31-removed` 〜）、ClaudeOrchestrator が各サブエージェントに発行する `ClaudeEval` 呼び出しは非同期化されました。**

### 変更前との違い

| 動作 | 変更前 | 変更後 |
|------|--------|--------|
| 呼び出しの性質 | 同期（ブロッキング） | **非同期（ノンブロッキング）** |
| 戻り値 | 実行結果 | `jobId`（DAG ジョブ識別子） |
| サブタスクの実行 | 順次（直列） | **並列起動可能** |
| 結果の取得 | 呼び出し直後 | `ClaudeRuntimeState` で後から確認 |

### 非同期化の仕組み

ClaudeOrchestrator からの `ClaudeEval` 呼び出しは内部で `ClaudeRunTurn` を経由します。`ClaudeRunTurn` は expression-proposal ループを **LLMGraph DAG ジョブ**として即座に起動し、`jobId` を返してブロックしません。オーケストレーター側は複数のサブタスクを並列に起動し、それぞれの完了を非同期に待機できます。

```mathematica
(* ClaudeOrchestrator によるマルチエージェント実行のイメージ *)
(* タスク分解・マルチエージェント実行は ClaudeOrchestrator.wl を導入すること *)
<< ClaudeOrchestrator`

(* 複数のサブタスクが非同期で並列起動される *)
result = ClaudeEvalDecomposed["複数ファイルを解析して統計レポートを生成して"]
(* → 各サブエージェントが ClaudeRunTurn で DAG を起動し、
      呼び出し側はブロックせず待機状態に入る *)
```

### サブエージェントの状態確認

非同期実行中のサブエージェントの状態は `ClaudeRuntimeState` で確認できます。

```mathematica
(* サブエージェントの runtimeId 一覧と状態 *)
Dataset[KeyValueMap[
  Function[{id, rt},
    <|"RuntimeId" -> id,
      "Status"    -> rt["Status"],
      "Profile"   -> rt["Profile"],
      "CurrentJobId" -> Lookup[rt, "CurrentJobId", None]|>],
  ClaudeRuntime`Private`$iClaudeRuntimes
]]
```

| Status | 意味 |
|--------|------|
| `"Running"` | DAG ジョブ実行中（非同期） |
| `"Done"` | サブタスク完了（結果取得可能） |
| `"AwaitingApproval"` | ユーザー承認待ち |
| `"Failed"` | 失敗（`"LastFailure"` に詳細） |

### 注意事項

- **Phase 31 の API（`ClaudeRunTurnDecomposed` / `ClaudeEvalDecomposed` の旧実装）は撤去済みです。** タスク分解・マルチエージェント機構は ClaudeOrchestrator.wl（別パッケージ）が担います。
- 非同期実行中に DAG を強制停止するには `ClaudeRuntimeCancel[runtimeId]` を使用します。
- 承認が必要なサブタスクが発生した場合、そのサブエージェントのみ `"AwaitingApproval"` 状態になります。他のサブエージェントは影響を受けず実行を継続します。

---

## カテゴリ別リファレンス

### 1. Runtime 管理

#### `$ClaudeRuntimeVersion`

パッケージのバージョン文字列を返します。

```mathematica
$ClaudeRuntimeVersion
(* "2026-04-16T14-phase31-removed" など *)
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
戻り値は `jobId` です。**呼び出しはノンブロッキングです。**

**シグネチャ:**
```mathematica
ClaudeRunTurn[runtimeId, input]
```

**例:**

```mathematica
jobId = ClaudeRunTurn[runtimeId, "この関数の処理内容を3行で要約して"];
(* → 即座に jobId が返り、DAG はバックグラウンドで実行される *)
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
| `"ProviderRateLimited"` | レート制限検出 |
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
ターンの途中でも即時停止します。非同期実行中のサブエージェントの強制終了にも使用できます。

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
| `RateLimitExceeded` | ✗ | CLI レート上限超過（即時 Fatal） |
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
| `Running` | ターン実行中（非同期 DAG ジョブ稼働中） |
| `Done` | 正常完了（継続可能） |
| `AwaitingApproval` | ユーザー承認待ち |
| `Failed` | 失敗（`"LastFailure"` に詳細） |

---

## 診断コード例

```mathematica
(* 直近の runtimeId を確認 *)
$ClaudeLastRuntimeId

(* バージョン確認 *)
ClaudeRuntime`$ClaudeRuntimeVersion

(* $UseClaudeRuntime の現在値を確認 *)
ClaudeCode`$UseClaudeRuntime

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

(* 全サブエージェントの状態一覧（ClaudeOrchestrator 使用時） *)
Dataset[KeyValueMap[
  Function[{id, rt},
    <|"RuntimeId" -> id,
      "Status"    -> rt["Status"],
      "Profile"   -> rt["Profile"],
      "CurrentJobId" -> Lookup[rt, "CurrentJobId", None]|>],
  ClaudeRuntime`Private`$iClaudeRuntimes
]]
```

---

## 関連パッケージ

- [NBAccess](https://github.com/transreal/NBAccess) — 機密データの保持・アクセス可否判定・式の安全性検証
- [claudecode](https://github.com/transreal/claudecode) — Notebook UI・アダプター実装・`ClaudeEval` / `ClaudeUpdatePackage` の提供
- [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) — 複数の ClaudeRuntime インスタンスをオーケストレーションするタスク分解・マルチエージェント機構（`ClaudeEval` の非同期並列実行を提供）
- [ClaudeTestKit](https://github.com/transreal/ClaudeTestKit) — モックプロバイダー・シナリオテスト基盤