# ClaudeRuntime ユーザーマニュアル

ClaudeRuntime は、Wolfram Language / Mathematica 上で動作する **expression-proposal ループ**の進行管理エンジンです。  
LLM（外部プロバイダー）に Mathematica 式の提案を求め、安全性検証・実行・継続を状態機械として管理します。

---

## 概要

ClaudeRuntime の役割は「提案ループの進行管理」に限定されています。  
機密データの保持・アクセス可否の判定・実行の安全性チェックは、必ず [NBAccess](https://github.com/transreal/NBAccess) を通じて行われます。  
通常のユーザーは、ClaudeRuntime を直接操作するのではなく、[claudecode](https://github.com/transreal/claudecode) が提供する `ClaudeEval` / `ClaudeUpdatePackage` 経由でこの機能を利用します。

タスク分解・マルチエージェント機構は [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) が担います。ClaudeOrchestrator は複数の ClaudeRuntime インスタンスをオーケストレーションし、複雑なタスクをサブタスクに分解して並列・順次実行する上位レイヤーです。  
ClaudeOrchestrator が発行する `ClaudeEval` 呼び出しは非同期化されており、各サブタスクは DAG ジョブとして即座に起動し、呼び出し側はブロックせずに結果を後から取得できます(詳細は「ClaudeOrchestrator と非同期 ClaudeEval」節を参照)。

さらに ClaudeRuntime には、サブタスクを**別の wolframscript プロセス**として起動・回収する **External Executor**（外部ランナー）層が含まれます。これは ClaudeOrchestrator のタスク配置（task placement）機構の実体を提供するもので、メインカーネルを占有しない長時間ジョブの実行を可能にします(詳細は「External Executor（外部 WolframScript ランナー）」節を参照)。

---

## ClaudeEval の使い方

### ClaudeEval とは

`ClaudeEval` は、プロンプト（自然言語）から Wolfram Language のコードを LLM に生成させ、安全性チェックを経て自動実行する関数です。  
以前は [claudecode](https://github.com/transreal/claudecode) 内部で定義されていましたが、現在は ClaudeRuntime パッケージによる実装に移行しています。

### 切り替えの仕組み($UseClaudeRuntime)

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

- `$UseClaudeRuntime = False`(既定値、claudecode のみロード時)— 旧来の claudecode 内部実装が使われます。
- `$UseClaudeRuntime = True`(ClaudeRuntime ロード時)— ClaudeRuntime ベースの実装が使われます。

#### 経路統一(2026-05-15)

ClaudeRuntime をロードすると、以下の設定が一括で適用されます。これは安定動作が確認されている組み合わせです。

| 変数 | 値 | 役割 |
|---|---|---|
| `ClaudeCode\`$UseClaudeRuntime` | `True` | ClaudeEval を ClaudeRuntime にルーティング |
| `ClaudeCode\`$ClaudeRuntimeAsyncExecution` | `False` | ExecuteProposal は同期評価(Phase 32 経路は安定化作業中のため迂回) |
| `ClaudeRuntime\`$ClaudeRuntimeToolAsyncDefault` | `True` | tool 呼び出しは AsyncToolExec 経由(メインカーネルは解放される) |

加えてロード時に `ClaudeBeginParallelKernels[]` が呼ばれ、4 個のサブカーネルが起動されます(`LaunchKernels[4]`)。これは初回 `ClaudeEval` での timeout を防ぐためで、全コア起動による無駄なメモリ消費を抑える設計です。

> **メモ:** sync 評価(`$ClaudeRuntimeAsyncExecution = False`)でもメインカーネルは tool 実行中は解放される(`$ClaudeRuntimeToolAsyncDefault = True` 経由)ので、長時間の Web 検索や CLI 呼び出し中も Notebook はブロックされません。ParallelSubmit 経路 (Phase 32) の修復は別フェーズで予定。

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

`DeleteFile` / `RunProcess` / `Run` など明示的に禁止された head を含む提案は `Deny`（即時停止）になります。Deny 判定は承認待ちには遷移せず、その場で失敗として記録されます。承認しても実行されない（`NBExecuteHeldExpr` が拒否する）action に対して承認ダイアログを出してはならない、という設計に基づきます。

> **メモ（head チェックの委譲）:** 提案中の head ブラックリスト判定（`$NBDenyHeads` / `$NBApprovalHeads`）は、NBAccess がロードされている場合は adapter の `ValidateProposal`（内部で `NBValidateHeldExpr` へ委譲）が担当します。インラインのブラックリスト判定は、`ValidateProposal` を持たない adapter のときだけフォールバックとして使われます。

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

ClaudeOrchestrator が各サブエージェントに発行する `ClaudeEval` 呼び出しは非同期化されており、各サブタスクは DAG ジョブとして即座に起動し、呼び出し側はブロックせずに結果を後から取得できます。戻り値は `jobId`(DAG ジョブ識別子)で、サブタスクは並列起動が可能です。実行結果は `ClaudeRuntimeState[runtimeId]` で確認します。

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
    <|"RuntimeId"    -> id,
      "Status"       -> rt["Status"],
      "Profile"      -> rt["Profile"],
      "CurrentJobId" -> Lookup[rt, "CurrentJobId", None]|>],
  ClaudeRuntime`Private`$iClaudeRuntimes]]
```

| Status | 意味 |
|--------|------|
| `"Running"` | DAG ジョブ実行中 |
| `"Done"` | サブタスク完了(結果取得可能) |
| `"AwaitingApproval"` | ユーザー承認待ち |
| `"Failed"` | 失敗(`"LastFailure"` に詳細) |

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

現在の RuntimeState（Association）の**軽量表示版**を返します。  
FrontEnd のフォーマット負荷を軽減するため、NotebookObject や巨大な中間結果（ConversationState, LastProviderResponse など）は除外されます。  
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

#### `ClaudeRuntimeStateFull`

RuntimeState 全体（Adapter を除く）を返します。中間結果まで含む完全な状態が必要なデバッグ用途で使用します。  

> **注意:** NotebookObject や巨大な中間結果を含むため、`Dynamic` 内や直接評価での使用は避けてください（FrontEnd をブロックする可能性があります）。通常は軽量版の `ClaudeRuntimeState` を使用してください。

**シグネチャ:**
```mathematica
ClaudeRuntimeStateFull[runtimeId]
```

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
| `"FinalActionEnqueued"` | FrontEnd ブロックリスクのある action を queue に投入 |
| `"FinalActionExecuted"` | final action（desktop action）の実行完了 |
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

#### `ClaudeRuntimeAsyncActiveQ`

いずれかの runtime で**非同期実行（AsyncExecution）**または**非同期 tool 実行（AsyncToolExec の Running が非空）**が走行中であれば `True` を返します。引数は取りません。

この関数は NBAccess との FrontEnd ブロック協調に用いられます。NBAccess の `PendingFinalActionQueue` は、本関数が `True` を返している間は FrontEnd をブロックする可能性のある final action を実行せず（`NBFinalActionTick` はスキップし）、Pending のまま安全な隙を待ちます（`$NBFinalActionAsyncActiveFunction` 経由）。

**シグネチャ:**
```mathematica
ClaudeRuntimeAsyncActiveQ[]
```

**例:**

```mathematica
ClaudeRuntimeAsyncActiveQ[]
(* True なら非同期タスクが走行中。FrontEnd ブロック action は保留される *)
```

---

### 4. 承認操作

LLM の提案に対して `NeedsApproval` の判定が出ると、  
RuntimeState が `"AwaitingApproval"` になります。  
このとき以下の関数で承認・拒否を行います。

> **メモ:** FrontEnd をブロックするリスクのある action（`BlockingRisk` が `MayBlockFrontEnd`、または `ExecutionPlacement` が `DesktopAction` / `FrontEndRequired`）は、承認しても即座に同期実行されず、NBAccess の `PendingFinalActionQueue` に積まれて安全な隙に実行されます（イベント `FinalActionEnqueued`）。一方、非同期タスクが走行していない通常ケースでは、承認ボタンを押した時点で同期実行されます（イベント `FinalActionExecuted`）。

#### `ClaudeApproveProposal`

`"AwaitingApproval"` 状態の提案をユーザーが承認し、実行を再開します。  
承認後、提案に応じて即時同期実行されるか、FrontEnd ブロックリスクがある場合は final action queue へ投入されます。

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

#### `ClaudeApproveProposalWithTimeout`

`"AwaitingApproval"` 状態の提案を承認すると同時に、adapter の `DefaultTimeoutSeconds` を一時的に `timeout` 秒（`Infinity` 可）に上書きして実行を再開します。  
提案の想定実行時間（`ExpectedSeconds`）が既定タイムアウトを超えたために承認待ちとなった場合に、タイムアウトを延長して実行を続行するために使用します（タイムアウト延長承認フロー）。

> **設計原則:** 原則として初期設定のタイムアウトを順守し、延長すれば計算できる場合に限り問い合わせダイアログを表示します。

**シグネチャ:**
```mathematica
ClaudeApproveProposalWithTimeout[runtimeId, timeout]
(* timeout: 正整数（秒） | Infinity *)
```

**例:**

```mathematica
ClaudeApproveProposalWithTimeout[runtimeId, Infinity]
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

#### `ClaudeMarkApprovalConsumed`

承認 UI 側が desktop action を**既に実行した**場合に、承認待ち状態を消費して `"Done"` に遷移させます。  
この関数は実行ロジックを呼ばないため、UI 側で実行済みの action を二重実行することはありません。承認ボタンを押した瞬間（FrontEnd がビジー）に UI 側が直接 desktop action を実行し、ランタイムの状態だけを整合させたい場合に使用します。

**シグネチャ:**
```mathematica
ClaudeMarkApprovalConsumed[runtimeId, reason]
(* reason: 省略時は "ConsumedExternally" *)
```

**例:**

```mathematica
ClaudeMarkApprovalConsumed[runtimeId, "UIExecutedDesktopAction"]
(* → <|"Outcome" -> "FinalActionExecuted", "Reason" -> "UIExecutedDesktopAction"|> *)
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

#### `ClaudeRuntimeRetry`

直前ターンの `Failed` ノードを再実行します。  
`Done` ノードの結果は保持し、`Failed` / `Pending` ノードのみ新しい DAG で再起動します。アクティブな DAG ジョブが残っている場合は `LLMGraphDAGRetry` に委譲します。

**シグネチャ:**
```mathematica
ClaudeRuntimeRetry[runtimeId]
```

**例:**

```mathematica
ClaudeRuntimeRetry[$ClaudeLastRuntimeId]
```

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

### 6. Workflow 連携

#### `ClaudeRuntimeExecuteTransition`

WorkflowNet の Transition 1 つを **1 ターン内で実行する** adapter API です。  
`BuildContext → QueryProvider → ValidateProposal → ExecuteProposal → RedactResult` を順に呼ぶ純関数的なパイプラインで、multi-turn ループ・継続・承認・リトライは一切持ちません。それらの責務は [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) の Workflow 層が担当します。

`CreateClaudeRuntime` とは別系統の実行 adapter であり、`adapter` には `ShouldContinue` を除く 5 つのキー（BuildContext / QueryProvider / ValidateProposal / ExecuteProposal / RedactResult）を渡します。

**シグネチャ:**
```mathematica
ClaudeRuntimeExecuteTransition[adapter, contextPacket]
```

`contextPacket` の主なキー（Workflow 側が組み立てる）: `"TransitionName"` / `"Binding"` / `"InputTokens"` / `"Role"` / `"DirectiveBundle"` / `"DirectivePrompt"` / `"AllowedCapabilities"` / `"OutputSchema"`

**戻り値:**

```mathematica
(* 成功時 *)
<|"Status" -> "Success",
  "Output" -> redactedResult,
  "Proposal" -> proposal,
  "Validation" -> validateResult,
  "ExecResult" -> execResult|>

(* 失敗時 *)
<|"Status" -> "Failed", "Reason" -> "...", "Diagnostics" -> ...|>
```

---

### 7. External Executor（外部 WolframScript ランナー）

External Executor は、サブタスクを**別の wolframscript プロセス**として起動・監視・回収する層です。  
ClaudeOrchestrator のタスク配置（task placement）機構の実体を提供し、メインカーネルを占有しない長時間ジョブを durable な job dir（manifest / input.wxf / status.json / output.wxf）ベースで実行します。

> **位置付け:** この層は ClaudeOrchestrator から利用される基盤プラミングです。通常の `ClaudeEval` ユーザーが直接触れる必要はありません。

#### 起動・結線

##### `ClaudeActivateExternalExecutor`

External executor を live 稼働させます。launcher / killer を結線（`ClaudeWireExternalRunner`）し、ジョブの poll tick を共有 polling tick（`ClaudeCode`ClaudeRegisterPollingTick`）へ登録、完了 hook を設定してジョブ完了時に summary final action を FinalActionQueue へ enqueue します。返り値は結線状況です。

```mathematica
ClaudeActivateExternalExecutor[opts]
```

##### `ClaudeDeactivateExternalExecutor`

poll tick の登録解除と完了 hook のクリアを行います。

```mathematica
ClaudeDeactivateExternalExecutor[]
```

##### `ClaudeWireExternalRunner`

ClaudeOrchestrator`Workflow` の External executor フック（`$ClaudeExternalJobLauncher` / StatusReader / Killer）を本パッケージの実装へ結線します。

```mathematica
ClaudeWireExternalRunner[]
```

#### Launcher / Killer

##### `ClaudeExternalWolframScriptLauncher`

job dir を作り manifest / input / run.wls を書き、wolframscript runner を `StartProcess` で起動します。`<|"Status" -> "Launched", "JobID", "JobDir", "PID"|>` を返します。`$ClaudeExternalJobLauncher` へ結線して使います。

```mathematica
ClaudeExternalWolframScriptLauncher[jobSpec]
```

##### `ClaudeExternalInProcessLauncher`

job dir / manifest を準備し、runner を**現在のカーネルで同期実行**します（別プロセスを起こしません）。テスト・単一ライセンス環境・短時間タスク用です。メインカーネルをブロックするため long-running には使いません。

```mathematica
ClaudeExternalInProcessLauncher[jobSpec]
```

##### `ClaudeExternalWolframScriptKiller`

起動済み ProcessObject を同一性確認後に終了します。`$ClaudeExternalJobKiller` へ結線して使います。

```mathematica
ClaudeExternalWolframScriptKiller[awaitMeta]
```

##### `ClaudeResolveWolframScriptExecutable`

wolframscript 実行ファイルを解決します。優先順は `$ClaudeWolframScriptExecutable` > `Environment["WOLFRAMSCRIPT"]` > `$InstallationDirectory` 近傍 > PATH 上の `wolframscript` です。

```mathematica
ClaudeResolveWolframScriptExecutable[]
```

#### Job 管理

##### `ClaudeExternalJobRoot`

durable な job root（`$ClaudeExternalJobRoot` または `$UserBaseDirectory/ClaudeRuntime/jobs`）を返し、無ければ作成します。

```mathematica
ClaudeExternalJobRoot[]
```

##### `ClaudeExternalJobRecover`

job root を走査し、status が Running だが registry に無い**孤児 job**を回収します。`"Kill" -> True` で pid.json の同一性確認後に kill、`"Mark" -> True` で status を `Expired` に更新します。返り値に回収結果が入ります。

```mathematica
ClaudeExternalJobRecover[opts]
```

##### `ClaudeRunTaskFromManifest`

runner（子プロセス）のエントリポイントです。`manifest.wl` を読み、`input.wxf` を読み、Handler を実行し、`output.wxf` と `status.json`（Completed / Failed）を書きます。

```mathematica
ClaudeRunTaskFromManifest[jobDir]
```

#### Handler 登録・検査

##### `ClaudeRegisterExternalTaskHandler`

External task handler を登録します。`fn` は `<|"Manifest" -> m, "Input" -> inputData|>` を受け取り Association を返します。

```mathematica
ClaudeRegisterExternalTaskHandler[name, fn, opts]
```

##### `ClaudeLintExternalHandler`

handler 本体に raw I/O（`Export` / `Import` / `URLRead` / `StartProcess` / `OpenWrite` / `DeleteFile` / `DialogInput` / `AuthenticationDialog` 等）が直書きされていないか検査します。handler は `NBChecked*` / `NBCheck*` 経由で I/O すべき、という設計に基づきます。`<|"Clean" -> _, "Violations" -> {...}|>` を返します。

```mathematica
ClaudeLintExternalHandler[HoldComplete[body]]
```

##### `$ClaudeBatchProcessorOverrides`

batch handler（BulkFileProcessing / BulkLLMProcessing / MailFetch / SourceVaultIngest）の per-item processor を差し替える Association です（`handlerName -> Function[{item, idx, ctx}, <|"Status" -> "OK" | "Failed", "Result" -> _|>]`）。連結され、override が最優先となります。

#### Provider connector 結線

##### `ClaudeWireExternalProviders`

provider connector を結線します（spec キー: `"LLM"` / `"SourceVaultIngest"` / `"MailFetch"`）。引数を省略すると各 connector の現在の利用可否を返します。実 provider は claudecode.wl / SourceVault.wl ロード時に `Automatic` 経由で自動利用されます。

```mathematica
ClaudeWireExternalProviders[spec]
```

| 変数 | 役割 |
|------|------|
| `$ClaudeLLMConnector` | BulkLLMProcessing が使う LLM 呼出関数（`fn[prompt]`）。`Automatic` は `ClaudeCode`ClaudeQuerySync` へ解決。鍵は ClaudeQuerySync 側が `NBGetAPIKey` で扱う |
| `$ClaudeSourceVaultIngestConnector` | SourceVaultIngest が使う取込関数（`fn[source]`）。`Automatic` は `SourceVault`SourceVaultIngest` へ解決 |
| `$ClaudeMailFetchConnector` | MailFetch が使う取得関数（`fn[mbox, period]`）。`Automatic` は `SourceVault`SourceVaultMailEnsureLoaded` へ解決 |

#### 出力ハンドリング

##### `ClaudeExternalJobSummary`

外部ジョブ出力の summary（Head / ByteCount / OutputRef / Preview）を返します。サイズが `$ClaudeExternalInlineLimit` を超える場合は Preview を省きます（巨大出力を inline しない）。

```mathematica
ClaudeExternalJobSummary[output, completion]
```

##### `ClaudeExternalJobFinalAction`

完了 payload の OutputRef を解決し、Notebook へ反映する final action（WriteNotebookCell、summary のみ）を構築して返します。本体は inline せず、反映は FinalActionQueue / 承認経由（single committer）で行います。`<|"Status" -> _, "FinalAction" -> _|>` を返します。

```mathematica
ClaudeExternalJobFinalAction[completion]
```

##### `ClaudeExternalInlineAllowedQ`

出力を Notebook へ inline してよいサイズか（`$ClaudeExternalInlineLimit` 以下か）を返します。Unknown は安全側の `False` です。

```mathematica
ClaudeExternalInlineAllowedQ[bytes]
```

#### 設定変数

| 変数 | 説明 |
|------|------|
| `$ClaudeExternalInlineLimit` | Notebook へ inline できる出力 ByteCount の上限（既定 64KB）。超過時は ref/summary のみ |
| `$ClaudeWolframScriptExecutable` | wolframscript 実行ファイルの明示パス（未設定なら自動解決） |
| `$ClaudeExternalJobRoot` | External job の durable root の明示パス（未設定なら `$UserBaseDirectory/ClaudeRuntime/jobs`） |
| `$ClaudeExternalProcessProbe` | PID のプロセス情報を返す関数（`fn[pid] -> <|"Alive" -> _, "Executable" -> _|>` | None）。`Automatic` は OS 問い合わせ（Windows: tasklist）。cross-restart kill の同一性確認に使う。テストで mock 注入可 |
| `$ClaudeExternalProcessKill` | PID を強制終了する関数（`fn[pid] -> Bool`）。`Automatic` は OS kill（Windows: taskkill /F）。テストで mock 注入可 |
| `$ClaudeExternalFinalActionEnqueue` | 完了 final action を enqueue する関数（`fn[action, accessSpec]`）。`Automatic` は `ClaudeCode`ClaudeEnqueueFinalAction`。テストで mock 注入可 |
| `$ClaudeExternalPollTickKey` | 共有 polling tick への登録 key（既定 `"external-job-poll"`） |

> **機密データの扱い:** 機密 input/output は実暗号化（`ConfidentialHandling == "EncryptedBundle"`）され、SourceVault crypto（`SourceVaultSealPayload` / `UnsealPayload`）に委譲されます。鍵は NBAccess credential store に閉じ、cross-process 共有のため SystemCredential 必須・fail-closed です。また機密ジョブでは error.txt に result 本文を吐かない redaction が施されます。

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

(* 状態の確認（軽量版） *)
ClaudeRuntimeState[$ClaudeLastRuntimeId]["Status"]
ClaudeRuntimeState[$ClaudeLastRuntimeId]["LastFailure"]

(* 完全な状態が必要な場合（FrontEnd 負荷に注意） *)
ClaudeRuntimeStateFull[$ClaudeLastRuntimeId]

(* 非同期タスク走行中かどうか *)
ClaudeRuntimeAsyncActiveQ[]

(* イベントトレースの確認 *)
Dataset[ClaudeTurnTrace[$ClaudeLastRuntimeId]]

(* 会話履歴の確認 *)
Dataset[ClaudeGetConversationMessages[$ClaudeLastRuntimeId]]

(* DAG ジョブの状態確認 *)
LLMGraphDAGStatus[
  ClaudeRuntimeState[$ClaudeLastRuntimeId]["CurrentJobId"]
]

(* External job root と孤児 job の回収（ClaudeOrchestrator 使用時） *)
ClaudeExternalJobRoot[]
ClaudeExternalJobRecover["Mark" -> True]

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
- [SourceVault](https://github.com/transreal/SourceVault) — External executor の機密 input/output 暗号化（crypto）・SourceVaultIngest / MailFetch connector の提供元
- [ClaudeTestKit](https://github.com/transreal/ClaudeTestKit) — モックプロバイダー・シナリオテスト基盤