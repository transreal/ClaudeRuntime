# ClaudeRuntime

Wolfram Language / Mathematica 上で動作する **Expression-Proposal ループ状態機械**エンジンです。LLM（外部プロバイダー）への問い合わせ・安全性検証・実行・継続判定を一貫した状態機械として管理します。

## 設計思想と実装の概要

ClaudeRuntime は、「進行管理のみを担当する」という単一責任の原則に基づいて設計されています。機密データの保持・アクセス可否の判定・安全性チェックはすべて [NBAccess](https://github.com/transreal/NBAccess) に委譲され、ClaudeRuntime は **抽象 adapter インターフェース** を通じてこれらの機能を利用します。この設計により、ClaudeRuntime は Notebook・secret・access policy・label algebra を一切知らないまま動作することができます。

タスク分解・マルチエージェント機構は [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) が担います。ClaudeOrchestrator は複数の ClaudeRuntime インスタンスをオーケストレーションし、複雑なタスクをサブタスクに分解して並列・順次実行する上位レイヤーです。ClaudeOrchestrator が各サブエージェントに発行する `ClaudeEval` 呼び出しは非同期化されており、各サブタスクは DAG ジョブとして即座に起動し、呼び出し側はブロックせずに結果を後から取得できます。ClaudeRuntime 単体では 1 ターンの提案ループ進行管理に専念しており、複数エージェントの協調動作が必要な場合は ClaudeOrchestrator を追加でロードします。

### ループの構造

ClaudeRuntime の中核は **Expression-Proposal ループ**です。各ターンは以下のフェーズで構成されます。

1. **BuildContext** — adapter の `BuildContext` 関数を呼び出してコンテキストパケットを構築します。
2. **QueryProvider** — LLM プロバイダーに問い合わせます。本番経路では `claudecode` の LLMGraph DAG 経由でノンブロッキングに実行されます(テスト・ローカル LLM 用に同期経路も内部に残っていますが、通常の利用では使われません)。
3. **ParseProposal** — LLM の応答を解析し、Mathematica 式（`HoldComplete[...]`）またはテキスト応答として構造化します。
4. **ValidateProposal** — NBAccess の `$NBDenyHeads` / `$NBApprovalHeads` を参照して安全性を判定します。コアパッケージ（NBAccess / ClaudeCode / ClaudeRuntime / ClaudeTestKit）の関数を上書きするコードはここで検出・停止されます。
5. **DispatchDecision** — 検証結果（`Permit` / `NeedsApproval` / `Deny` / `RepairNeeded` / `TextOnly` / `ToolUse`）に応じて実行・承認待ち・修復ターンのいずれかに分岐します。

### ClaudeEval の移行

以前は [claudecode](https://github.com/transreal/claudecode) パッケージで定義されていた `ClaudeEval` が、ClaudeRuntime パッケージに移行しました。ClaudeRuntime をロードすると `$UseClaudeRuntime = True` が自動設定され、以降の `ClaudeEval` 呼び出しはすべて ClaudeRuntime ベースの新実装で処理されます。レガシー実装に戻す場合は `$UseClaudeRuntime = False` を設定します。

### DAG による実行

ターンの実行は [claudecode](https://github.com/transreal/claudecode) の `LLMGraphDAGCreate` を使って DAG ジョブとして展開されます。各フェーズは DAG ノードとして定義され、依存関係に従って順次実行されます。`queryProvider` ノードが CLI プロセスを起動し、`collectProvider` ノードが結果を RuntimeState に書き戻すことで、LLM 呼び出しをノンブロッキングに処理します。

ClaudeOrchestrator 経由での `ClaudeEval` 呼び出しも同様に DAG ジョブとして展開され、複数サブタスクの並列起動が可能です。オーケストレーター側は各サブタスクの完了を非同期に待機し、結果は `ClaudeRuntimeState` で随時確認できます。

### 非同期コード実行 / 非同期 Tool 実行（Phase 32）

`ExecuteProposal` ハンドラが非同期実行を要求した場合（別 OS プロセス・別カーネルでのコード実行、あるいは web_search 等の非同期 tool 実行）にも対応しています。実行後段階（RedactResult / ShouldContinue / Continuation）は polling tick に接続され、メインカーネルをブロックせずに進行します。

- 非同期コード実行の状態は `ClaudeRuntimeAsyncExecutionStatus` / `ClaudeRuntimeAsyncDiagnose` で確認でき、`ClaudeRuntimeCancelAsyncExecution` で中断できます。
- 非同期 tool 実行（AsyncToolExec）の状態は `ClaudeRuntimeToolExecDiagnose` で確認でき、`ClaudeRuntimeCancelAsyncToolExec` でキャンセルできます。
- いずれかの runtime で非同期実行が走行中かどうかは `ClaudeRuntimeAsyncActiveQ[]` で判定できます。NBAccess の `PendingFinalActionQueue` は、これが `True` の間、FrontEnd をブロックし得る desktop action を実行せず Pending のまま待機します。

### 外部 wolframscript runner と タスク配置分類器（コンパニオンパッケージ）

ClaudeRuntime には、用途に応じて追加ロードできる 2 つのコンパニオンパッケージがあります。

- [ClaudeRuntime_externalrunner](https://github.com/transreal/ClaudeRuntime_externalrunner) — 外部 wolframscript runner / launcher。Orchestrator（親）側に launcher / killer / job dir / manifest を提供し、runner（子プロセス）側に manifest 駆動の handler 実行を提供します。長時間タスクを別プロセスへ切り出して main kernel を解放するための層です。
- [ClaudeRuntime_taskplacement](https://github.com/transreal/ClaudeRuntime_taskplacement) — タスク配置分類器。taskSpec を正規化・分類し、実行 backend（Subkernel / MainKernel / WolframScript 等）の助言的推奨を行います。1 ターン内で閉じる純関数的な分類のみを担い、最終 backend 決定は Orchestrator が行います。

### 経路統一(2026-05-15)

ClaudeRuntime をロードすると、安定動作が確認済みの組み合わせが自動的に設定されます。

```
$UseClaudeRuntime              = True   (Bridge 経路 — ClaudeEval を ClaudeRuntime にルーティング)
$ClaudeRuntimeAsyncExecution   = False  (ExecuteProposal は同期評価 — Phase 32 経路は安定化作業中のため迂回)
$ClaudeRuntimeToolAsyncDefault = True   (tool 呼び出しは AsyncToolExec 経由)
```

加えてロード時に `ClaudeBeginParallelKernels[]` が同期で 1 回だけ呼ばれ、4 個のサブカーネルを起動します(3〜5 秒のロード時コスト)。これは初回 `ClaudeEval` 呼び出しが timeout する事故を防ぐためで、`LaunchKernels[4]` に制限することで全コア起動による無駄なメモリ消費(14 コア × 90MB ≒ 1.3 GB → 4 × 90MB ≒ 360 MB)を抑えています。

ParallelSubmit 経路 (Phase 32) は別カーネルが起動済みでも 30 秒 timeout する症状があるため、現状は `$ClaudeRuntimeAsyncExecution = False` で sync 評価に倒しています。sync 評価でもメインカーネルは tool 実行中は解放される(AsyncToolExec 経由)ので、UX への影響は限定的です。Phase 32 経路の修復は別フェーズで対応予定。

### 予算管理とリトライポリシー

無限ループや過剰なリソース消費を防ぐため、すべての反復操作に**予算（budget）**が設定されています。`ClaudeRetryPolicy` は `"Eval"` と `"UpdatePackage"` の 2 プロファイルを持ち、`MaxTotalSteps`・`MaxProposalIterations`・`MaxTransportRetries` などのキーで上限を管理します。予算切れは `BudgetExhausted` イベントとして EventTrace に記録されます。

### 安全設計の不変条件

設計仕様書（NBAccess / claudecode / ClaudeRuntime 向けプライバシー・アクセス制御仕様 v0.2）に基づき、以下の不変条件が維持されます。

- 機密データの実体は NBAccess だけが扱います。
- 外部 LLM はリソースへ直接アクセスしません。
- LLM は必ず Mathematica 式を生成し、その式は実行前に検証されます。
- ClaudeRuntime は進行管理のみを行い、安全判定そのものは NBAccess に委ねます。

### Transaction パイプライン（UpdatePackage プロファイル）

`"UpdatePackage"` プロファイルでは、式の実行に加えて Snapshot → ShadowApply → StaticCheck → ReloadCheck → TestPhase → Commit という多段トランザクションパイプラインが動作します。各フェーズで失敗した場合はロールバックと修復ターンのスケジューリングが行われます。

---

## 詳細説明

### 動作環境

| 項目 | 要件 |
|------|------|
| Mathematica | 13.2 以降（14.x 推奨） |
| OS | Windows 11（64-bit） |
| Anthropic API キー | 必須 |

**依存パッケージ（先にインストールが必要）:**

- [NBAccess](https://github.com/transreal/NBAccess) — ノートブックアクセス制御・安全判定 adapter
- [claudecode](https://github.com/transreal/claudecode) — LLMGraph DAG スケジューラ・`$Path` 自動設定

**オプションパッケージ:**

- [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) — タスク分解・マルチエージェント実行機構。複数の ClaudeRuntime インスタンスを協調動作させ、複雑なタスクを自動分解して並列・順次実行します。ClaudeOrchestrator が発行する `ClaudeEval` 呼び出しは非同期化されており、各サブタスクは DAG ジョブとして即座に起動してノンブロッキングで実行されます。ClaudeRuntime 単体では 1 ターン実行に専念するため、マルチエージェント機能が必要な場合に追加でロードしてください。
- [ClaudeRuntime_externalrunner](https://github.com/transreal/ClaudeRuntime_externalrunner) — 外部 wolframscript runner / launcher。長時間タスクを別プロセスへ切り出す場合にロードします。
- [ClaudeRuntime_taskplacement](https://github.com/transreal/ClaudeRuntime_taskplacement) — タスク配置分類器。実行 backend の助言的推奨が必要な場合にロードします。

### インストール

#### 1. パッケージファイルの配置

`ClaudeRuntime.wl` を `$packageDirectory` 直下に配置します。

```
$packageDirectory\
  ClaudeRuntime.wl   ← ここに配置
  claudecode.wl
  NBAccess.wl
  ...
```

サブフォルダには配置しないでください。

#### 2. `$Path` の設定

claudecode を使用している場合、`$Path` は自動的に設定されます。手動で設定する場合は以下のとおりです。

```mathematica
(* 正しい例: $packageDirectory 自体を追加する *)
If[!MemberQ[$Path, $packageDirectory],
  AppendTo[$Path, $packageDirectory]
]
```

```mathematica
(* 誤った例: サブディレクトリを指定しない *)
(* NG: AppendTo[$Path, "C:\\path\\to\\ClaudeRuntime"] *)
```

#### 3. パッケージのロード

```mathematica
Block[{$CharacterEncoding = "UTF-8"},
  Needs["NBAccess`",      "NBAccess.wl"];
  Needs["ClaudeRuntime`", "ClaudeRuntime.wl"]
]
```

タスク分解・マルチエージェント機能を使用する場合は、ClaudeOrchestrator もロードします。

```mathematica
Block[{$CharacterEncoding = "UTF-8"},
  Needs["NBAccess`",            "NBAccess.wl"];
  Needs["ClaudeRuntime`",       "ClaudeRuntime.wl"];
  Needs["ClaudeOrchestrator`",  "ClaudeOrchestrator.wl"]
]
```

#### 4. API キーの設定

```mathematica
(* claudecode が提供するキー設定関数で登録する *)
ClaudeSetAPIKey["sk-ant-..."]
```

キーはノートブックにハードコードしないでください。詳細は [claudecode](https://github.com/transreal/claudecode) の `api-key-handling` ドキュメントを参照してください。

### クイックスタート

以下はダミー adapter を用いた最小構成の例です。

```mathematica
(* 1. パッケージのロード *)
Block[{$CharacterEncoding = "UTF-8"},
  Needs["ClaudeRuntime`", "ClaudeRuntime.wl"]
]

(* 2. ダミー adapter の定義 *)
adapter = <|
  "BuildContext"      -> Function[{input, convState},
    <|"Input" -> input, "Messages" -> {}|>],
  "QueryProvider"     -> Function[{ctx, convState},
    <|"response" -> "```mathematica\n1 + 1\n```"|>],
  "ParseProposal"     -> Function[{raw},
    <|"HasProposal" -> True, "HeldExpr" -> HoldComplete[1 + 1],
      "RawCode" -> "1 + 1", "TextResponse" -> ""|>],
  "ValidateProposal"  -> Function[{proposal, ctx},
    <|"Decision" -> "Permit", "ReasonClass" -> "None",
      "VisibleExplanation" -> "", "SanitizedExpr" -> proposal["HeldExpr"]|>],
  "ExecuteProposal"   -> Function[{proposal, valResult},
    <|"Success" -> True, "RawResult" -> 2, "Error" -> None|>],
  "RedactResult"      -> Function[{execResult, ctx},
    <|"RedactedResult" -> execResult["RawResult"], "Summary" -> "2"|>],
  "ShouldContinue"    -> Function[{redacted, convState, turnCount}, False]
|>;

(* 3. RuntimeState の作成 *)
runtimeId = CreateClaudeRuntime[adapter];

(* 4. ターンの実行 *)
jobId = ClaudeRunTurn[runtimeId, "1 + 1 を計算してください"];

(* 5. 状態の確認 *)
ClaudeRuntimeState[runtimeId]["Status"]
(* "Done" *)

(* 6. イベントトレースの確認 *)
Dataset[ClaudeTurnTrace[runtimeId]]
```

**通常の用途では、adapter を直接定義するのではなく [claudecode](https://github.com/transreal/claudecode) が提供する `ClaudeEval` / `ClaudeUpdatePackage` 経由でこの機能を利用します。**

### 主な機能

| 関数 / 変数 | 説明 |
|------------|------|
| `CreateClaudeRuntime[adapter, opts]` | RuntimeState を生成し `runtimeId` を返します。adapter には 7 つのキー（BuildContext / QueryProvider / ParseProposal / ValidateProposal / ExecuteProposal / RedactResult / ShouldContinue）が必要です。 |
| `ClaudeRunTurn[runtimeId, input]` | Expression-Proposal ループを LLMGraph DAG として起動し、`jobId` を返します。 |
| `ClaudeContinueTurn[runtimeId]` | 直前のターンの continuation を起動します。`Done` 状態からの再開に使います。 |
| `ClaudeRuntimeState[runtimeId]` | 現在の RuntimeState の軽量表示版を返します。NotebookObject や巨大な中間結果を除外し FrontEnd の負荷を軽減します。 |
| `ClaudeRuntimeStateFull[runtimeId]` | RuntimeState 全体（Adapter 以外）を返します。Dynamic や直接評価での使用は避けてください。 |
| `ClaudeTurnTrace[runtimeId]` | EventTrace 全体をリストで返します。デバッグや実行過程の可視化に利用します。 |
| `ClaudeGetConversationMessages[runtimeId]` | 全ターンの会話メッセージを返します。各要素は `<|"Turn"->n, "ProposedCode"->..., "ExecutionResult"->..., "TextResponse"->...|>` の形式です。 |
| `ClaudeApproveProposal[runtimeId]` | `AwaitingApproval` 状態のプロポーザルを承認して実行を再開します。 |
| `ClaudeApproveProposalWithTimeout[runtimeId, timeout]` | adapter のタイムアウトを一時的に上書きして承認します（タイムアウト延長承認フロー）。 |
| `ClaudeDenyProposal[runtimeId]` | `AwaitingApproval` 状態のプロポーザルを拒否します。 |
| `ClaudeMarkApprovalConsumed[runtimeId, reason]` | 承認 UI が desktop action を既に実行済みの場合に承認待ち状態を消費し Done にします（二重実行防止）。 |
| `ClaudeRuntimeCancel[runtimeId]` | 実行中の DAG ジョブをキャンセルします。 |
| `ClaudeRuntimeRetry[runtimeId]` | 直前ターンの Failed ノードを再実行します。Done ノードの結果は保持し、Failed/Pending ノードのみ新しい DAG で再起動します。 |
| `ClaudeRuntimeExecuteTransition[adapter, contextPacket]` | WorkflowNet の Transition 1 つを 1 ターン内で純関数的に実行する adapter API（multi-turn / retry / approval は Orchestrator が担当）。 |
| `ClaudeRuntimeAsyncActiveQ[]` | いずれかの runtime で非同期コード実行または非同期 tool 実行が走行中なら `True` を返します。 |
| `ClaudeRuntimeAsyncExecutionStatus[runtimeId]` | 非同期実行中タスクの状態（Running / Elapsed / Timeout 等）を返します。 |
| `ClaudeRuntimeCancelAsyncExecution[runtimeId]` | 実行中の非同期コードを中断し、並列カーネルを再起動します。 |
| `ClaudeRuntimeAsyncDiagnose[]` | 非同期実行経路全体の現在状態を返す診断関数です。 |
| `ClaudeRuntimeCancelAsyncToolExec[runtimeId]` | 走行中の AsyncToolExec をキャンセルします。 |
| `ClaudeRuntimeToolExecDiagnose[runtimeId]` | 現在の AsyncToolExec state を返す診断関数です。 |
| `ClaudeRetryPolicy[profile]` | `"Eval"` または `"UpdatePackage"` プロファイルの RetryPolicy を返します。 |
| `ClaudeClassifyFailure[failure]` | failure を `TransportTransient` / `ProviderRateLimit` / `SecurityViolation` 等のクラスに分類します。 |
| `$ClaudeRuntimeVersion` | パッケージバージョン文字列。 |
| `$ClaudeRuntimeRetryProfile` | RetryPolicy の既定プロファイル名（初期値: `"Eval"`）。 |
| `$ClaudeRuntimeToolAsyncDefault` | AsyncToolExec の既定有効フラグ。`True` で web_search 等を別 OS プロセスで実行しメインカーネルをブロックしません。 |
| `$UseClaudeRuntime` | `True` のとき ClaudeRuntime ベースの `ClaudeEval` が有効になります。ClaudeRuntime ロード時に自動設定されます。 |

### ドキュメント一覧

| ファイル | 内容 |
|---------|------|
| `api.md` | API リファレンス（全公開シンボルの仕様） |
| `api_externalrunner.md` | ClaudeRuntime_externalrunner（外部 wolframscript runner / launcher）の API リファレンス |
| `api_taskplacement.md` | ClaudeRuntime_taskplacement（タスク配置分類器）の API リファレンス |
| `setup.md` | インストール手順・トラブルシューティング |
| `user_manual.md` | カテゴリ別ユーザーマニュアル（ClaudeOrchestrator との非同期連携を含む） |
| `examples/example.md` | 代表的な使用パターン集（ClaudeEval ユーザー向け / 低レベル API） |
| `design/ClaudeRuntime_EventTrace_Reference.md` | EventTrace Type / ReasonClass の完全一覧 |
| `design/NBAccess_claudecode_privacy_spec_v0_2.md` | プライバシー・アクセス制御仕様 v0.2 |

---

## 使用例・デモ

### ClaudeEval — 基本的な使い方

`ClaudeEval` は、自然言語のプロンプトから Wolfram Language コードを生成・実行する関数です。以前は [claudecode](https://github.com/transreal/claudecode) で定義されていましたが、現在は ClaudeRuntime パッケージに移行しています。

#### `$UseClaudeRuntime` スイッチ

ClaudeRuntime をロードすると `$UseClaudeRuntime = True` が自動設定されます。

```mathematica
<< ClaudeRuntime`
```

レガシーの claudecode 版実装に戻す場合は手動で切り替えます。

```mathematica
$UseClaudeRuntime = False   (* 旧 claudecode 版 ClaudeEval を使用 *)
$UseClaudeRuntime = True    (* ClaudeRuntime 版を使用（既定） *)
```

#### 例 1 — 自然言語プロンプトからグラフを生成

```mathematica
ClaudeEval["Graph of projectile motion thrown upward"]
```

Claude がプロンプトを解釈し、以下のようなコードを生成して実行します。

```mathematica
Module[{v0 = 20, g = 9.8, tMax, hMax, tFlight},
  tMax = v0/g;
  hMax = v0^2/(2 g);
  tFlight = 2 v0/g;
  Show[
    Plot[v0 t - g t^2/2, {t, 0, tFlight},
      PlotStyle -> {Thick, Blue},
      PlotRange -> {All, {0, hMax + 2}},
      AxesLabel -> {"t (s)", "h (m)"},
      PlotLabel -> Style["Projectile Motion", Bold, 14],
      Filling -> Axis,
      GridLines -> Automatic,
      ImageSize -> 500
    ],
    Graphics[{
      {Red, PointSize[0.015], Point[{tMax, hMax}]},
      Text[Style[Row[{"Max: ", NumberForm[hMax, {4,1}], " m"}], 11, Red],
        {tMax, hMax + 1}]
    }]
  ]
]
```

### ClaudeEval — 承認フロー（NeedsApproval）

コアパッケージの内部変数を書き換えるなど、安全性が疑われる提案は自動停止され、承認ダイアログが表示されます。

#### 例 2 — コア変数への上書きは承認が必要

```mathematica
ClaudeEval["Assign {} to ClaudeRuntime`Private`$iClaudeRuntimes"]
```

```
? Approval required: CoreContextOverwrite — Code overwrites core package functions
  (NBAccess/ClaudeCode/ClaudeRuntime/ClaudeTestKit).
  This may break system functionality. Approval required.

  提案されたコード:
    HoldComplete[ClaudeRuntime`Private`$iClaudeRuntimes = {}]

  [Approve]  [Cancel]
```

プログラムから操作する場合は以下を使います。

```mathematica
ClaudeApproveProposal[$ClaudeLastRuntimeId]   (* 承認して実行を継続 *)
ClaudeDenyProposal[$ClaudeLastRuntimeId]      (* 拒否 *)
```

> **メモ（Deny は即時失敗）:** 検証結果が `Deny` の提案は、承認しても実行されません。`ClaudeApproveProposal` を呼んでも `"Execution refused: Deny"` として失敗が記録されます（以前あった Deny → 承認待ち遷移の挙動は廃止されました）。

> **メモ（FrontEnd ブロック action の遅延実行）:** フォルダを開く・ダイアログを出すといった FrontEnd 操作を伴う action は、Approve してもその場では同期実行されず、NBAccess の `PendingFinalActionQueue` に積まれて FrontEnd が空いた安全な隙に実行されます。承認直後にイベント `"FinalActionEnqueued"`、実際の実行時に `"FinalActionExecuted"` が記録されます。

### ClaudeOrchestrator と非同期 ClaudeEval

ClaudeOrchestrator が各サブエージェントに発行する `ClaudeEval` 呼び出しは非同期化されており、各サブタスクは DAG ジョブとして即座に起動し、呼び出し側はブロックせずに結果を後から取得できます。戻り値は `jobId`(DAG ジョブ識別子)で、サブタスクは並列起動が可能です。実行結果は `ClaudeRuntimeState[runtimeId]` で確認します。

```mathematica
(* ClaudeOrchestrator をロードしてマルチエージェント実行 *)
Block[{$CharacterEncoding = "UTF-8"},
  Needs["NBAccess`",            "NBAccess.wl"];
  Needs["ClaudeRuntime`",       "ClaudeRuntime.wl"];
  Needs["ClaudeOrchestrator`",  "ClaudeOrchestrator.wl"]]

(* 複数のサブタスクが非同期で並列起動される *)
result = ClaudeEvalDecomposed["複数ファイルを解析して統計レポートを生成して"]
(* → 各サブエージェントが ClaudeRunTurn で DAG を起動し、
      呼び出し側はブロックせず待機状態に入る *)
```

非同期実行中のサブエージェントの状態確認は以下のとおりです。

```mathematica
Dataset[KeyValueMap[
  Function[{id, rt},
    <|"RuntimeId" -> id,
      "Status"    -> rt["Status"],
      "Profile"   -> rt["Profile"],
      "CurrentJobId" -> Lookup[rt, "CurrentJobId", None]|>],
  ClaudeRuntime`Private`$iClaudeRuntimes
]]
```

承認が必要なサブタスクが発生した場合、そのサブエージェントのみ `"AwaitingApproval"` 状態になります。他のサブエージェントは影響を受けず実行を継続します。

### ClaudeEval — ランタイム状態の確認

```mathematica
(* 直近のランタイム状態 *)
ClaudeRuntimeState[$ClaudeLastRuntimeId]

(* 全ランタイムを Dataset で一覧表示 *)
Dataset[
  KeyValueMap[
    Function[{id, rt},
      <|
        "RuntimeId"   -> id,
        "Status"      -> rt["Status"],
        "TurnCount"   -> rt["TurnCount"],
        "Profile"     -> rt["Profile"],
        "LastFailure" -> Lookup[rt, "LastFailure", None]
      |>
    ],
    ClaudeRuntime`Private`$iClaudeRuntimes
  ]
]
```

**出力例（Dataset）：**

| RuntimeId           | Status | TurnCount | Profile | LastFailure |
|---------------------|--------|-----------|---------|-------------|
| rt-1776160445-93123 | Done   | 3         | Eval    | None        |
| rt-1776160517-17165 | Failed | 1         | Eval    | `<\|"ReasonClass" -> "UserDenied"\|>` |

`Status` の取りうる値：`"Initialized"` / `"Running"` / `"AwaitingApproval"` / `"Retrying"` / `"Done"` / `"Failed"`

### ClaudeEval — 失敗時のリトライ

ネットワーク断や API レート制限で `queryProvider` が失敗した場合は、その場でリトライできます。

```mathematica
ClaudeRuntimeRetry[$ClaudeLastRuntimeId]
```

`Done` ノードの結果は保持され、`Failed` / `Pending` ノードのみ新しい DAG で再実行されます。

### 非同期実行の診断とキャンセル

```mathematica
(* 非同期実行が走行中かどうか *)
ClaudeRuntimeAsyncActiveQ[]

(* 非同期実行経路の全体状態 *)
ClaudeRuntimeAsyncDiagnose[]

(* 特定 runtime の非同期コード実行状態 *)
ClaudeRuntimeAsyncExecutionStatus[$ClaudeLastRuntimeId]

(* 走行中の非同期コード実行を中断 *)
ClaudeRuntimeCancelAsyncExecution[$ClaudeLastRuntimeId]

(* AsyncToolExec の状態確認とキャンセル *)
ClaudeRuntimeToolExecDiagnose[$ClaudeLastRuntimeId]
ClaudeRuntimeCancelAsyncToolExec[$ClaudeLastRuntimeId]
```

### ランタイムの作成と基本ターンの実行

```mathematica
adapter = <|
  "BuildContext"      -> Function[{state, input}, <|"input" -> input|>],
  "QueryProvider"     -> Function[{ctx, opts}, <|"response" -> "42"|>],
  "ParseProposal"     -> Function[{raw}, <|"HasProposal" -> False,
    "TextResponse" -> raw|>],
  "ValidateProposal"  -> Function[{p, ctx}, <|"Decision" -> "Permit",
    "ReasonClass" -> "None", "VisibleExplanation" -> "",
    "SanitizedExpr" -> None|>],
  "ExecuteProposal"   -> Function[{p, v}, <|"Success" -> True,
    "RawResult" -> None, "Error" -> None|>],
  "RedactResult"      -> Function[{r, ctx}, <|"RedactedResult" -> None,
    "Summary" -> ""|>],
  "ShouldContinue"    -> Function[{r, s, n}, False]
|>;

rid = CreateClaudeRuntime[adapter];
jobId = ClaudeRunTurn[rid, "テスト入力"];
```

### AwaitingApproval 状態での提案の承認・拒否

```mathematica
(* 承認待ちの提案を承認する *)
ClaudeApproveProposal[rid]

(* または拒否する場合 *)
ClaudeDenyProposal[rid]
```

### イベントトレースの可視化

```mathematica
trace = ClaudeTurnTrace[rid];
Dataset[trace]
(* EventType, Timestamp, Phase 等を含む構造化データとして表示 *)
```

### DAG ジョブのキャンセル

```mathematica
ClaudeRuntimeCancel[rid]
ClaudeRuntimeState[rid]["Status"]
(* "Cancelled" *)
```

### LLMGraph の可視化

```mathematica
NotebookLLMGraphPlot[]
NotebookLLMGraphPlot["Detail" -> True]
```

### リトライポリシーの確認

```mathematica
ClaudeRetryPolicy["Eval"]
(* <|"Profile" -> "Eval", "Limits" -> <|"MaxTotalSteps" -> 6, ...|>, ...|> *)
```

### 外部 wolframscript runner の利用（ClaudeRuntime_externalrunner）

長時間タスクを別プロセスへ切り出す場合は、コンパニオンパッケージ `ClaudeRuntime_externalrunner` を使います。親（Orchestrator）側で結線し、launcher 経由でジョブを起動します。

```mathematica
ClaudeWireExternalRunner[];
ClaudeRegisterExternalTaskHandler["Echo", Function[ctx, <|"Result" -> ctx["Input"]|>]];
res = ClaudeExternalWolframScriptLauncher[jobSpec];
(* <|"Status"->"Launched", "JobID"->..., "JobDir"->..., "PID"->...|> *)
```

runner（子プロセス）側は `run.wls` 内で `ClaudeRunTaskFromManifest[jobDir]` を呼び、`output.wxf` / `status.json` を書き出します。

### タスク配置分類（ClaudeRuntime_taskplacement）

```mathematica
spec = ClaudeNormalizeTaskSpec[raw];
ct   = ClaudeClassifyTask[spec, <||>];
rec  = ClaudeSelectExecutionBackend[ct, <||>];   (* backend の助言的推奨 *)
act  = ClaudeBuildTaskAction[ct];                (* Orchestrator が NBValidateAction で検証 *)
```

### リポジトリ

- [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime)
- [ClaudeRuntime_externalrunner](https://github.com/transreal/ClaudeRuntime_externalrunner)
- [ClaudeRuntime_taskplacement](https://github.com/transreal/ClaudeRuntime_taskplacement)
- [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator)
- [NBAccess](https://github.com/transreal/NBAccess)
- [claudecode](https://github.com/transreal/claudecode)
- [ClaudeTestKit](https://github.com/transreal/ClaudeTestKit)

---

## 免責事項

本ソフトウェアは "as is"（現状有姿）で提供されており、明示・黙示を問わずいかなる保証もありません。
本ソフトウェアの使用または使用不能から生じるいかなる損害についても責任を負いません。
今後の動作保証のための更新が行われるとは限りません。
本ソフトウェアとドキュメントはほぼすべてが生成AIによって生成されたものです。
Windows 11上での実行を想定しており、MacOS, LinuxのMathematicaでの動作検証は一切していません(生成AIの処理で対応可能と想定されます)。

---

## ライセンス

```
MIT License

Copyright (c) 2026 Katsunobu Imai

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.