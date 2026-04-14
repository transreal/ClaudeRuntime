# ClaudeRuntime

Wolfram Language / Mathematica 上で動作する **Expression-Proposal ループ状態機械**エンジンです。LLM（外部プロバイダー）への問い合わせ・安全性検証・実行・継続判定を一貫した状態機械として管理します。

## 設計思想と実装の概要

ClaudeRuntime は、「進行管理のみを担当する」という単一責任の原則に基づいて設計されています。機密データの保持・アクセス可否の判定・安全性チェックはすべて [NBAccess](https://github.com/transreal/NBAccess) に委譲され、ClaudeRuntime は **抽象 adapter インターフェース** を通じてこれらの機能を利用します。この設計により、ClaudeRuntime は Notebook・secret・access policy・label algebra を一切知らないまま動作することができます。

### ループの構造

ClaudeRuntime の中核は **Expression-Proposal ループ**です。各ターンは以下のフェーズで構成されます。

1. **BuildContext** — adapter の `BuildContext` 関数を呼び出してコンテキストパケットを構築します。
2. **QueryProvider** — LLM プロバイダーに問い合わせます。非同期モード（`claudecode` の LLMGraph DAG 経由）と同期モード（テスト・ローカル LLM 用）の両方に対応します。
3. **ParseProposal** — LLM の応答を解析し、Mathematica 式（`HoldComplete[...]`）またはテキスト応答として構造化します。
4. **ValidateProposal** — NBAccess の `$NBDenyHeads` / `$NBApprovalHeads` を参照して安全性を判定します。コアパッケージ（NBAccess / ClaudeCode / ClaudeRuntime / ClaudeTestKit）の関数を上書きするコードはここで検出・停止されます。
5. **DispatchDecision** — 検証結果（`Permit` / `NeedsApproval` / `Deny` / `RepairNeeded` / `TextOnly` / `ToolUse`）に応じて実行・承認待ち・修復ターンのいずれかに分岐します。

### ClaudeEval の移行

以前は [claudecode](https://github.com/transreal/claudecode) パッケージで定義されていた `ClaudeEval` が、ClaudeRuntime パッケージに移行しました。ClaudeRuntime をロードすると `$UseClaudeRuntime = True` が自動設定され、以降の `ClaudeEval` 呼び出しはすべて ClaudeRuntime ベースの新実装で処理されます。レガシー実装に戻す場合は `$UseClaudeRuntime = False` を設定します。

### DAG による非同期実行

ターンの実行は [claudecode](https://github.com/transreal/claudecode) の `LLMGraphDAGCreate` を使って DAG ジョブとして展開されます。各フェーズは DAG ノードとして定義され、依存関係に従って順次実行されます。非同期モードでは `queryProvider` ノードが CLI プロセスを起動し、`collectProvider` ノードが結果を RuntimeState に書き戻すことで、LLM 呼び出しをノンブロッキングに処理します。

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
| `ClaudeRuntimeState[runtimeId]` | 現在の RuntimeState（`Status` / `TurnCount` / `LastProposal` / `BudgetsUsed` 等）を返します。 |
| `ClaudeTurnTrace[runtimeId]` | EventTrace 全体をリストで返します。デバッグや実行過程の可視化に利用します。 |
| `ClaudeGetConversationMessages[runtimeId]` | 全ターンの会話メッセージを返します。各要素は `<|"Turn"->n, "ProposedCode"->..., "ExecutionResult"->..., "TextResponse"->...|>` の形式です。 |
| `ClaudeApproveProposal[runtimeId]` | `AwaitingApproval` 状態のプロポーザルを承認して実行を再開します。 |
| `ClaudeDenyProposal[runtimeId]` | `AwaitingApproval` 状態のプロポーザルを拒否します。 |
| `ClaudeRuntimeCancel[runtimeId]` | 実行中の DAG ジョブをキャンセルします。 |
| `ClaudeRuntimeRetry[runtimeId]` | 直前ターンの Failed ノードを再実行します。Done ノードの結果は保持し、Failed/Pending ノードのみ新しい DAG で再起動します。 |
| `ClaudeRetryPolicy[profile]` | `"Eval"` または `"UpdatePackage"` プロファイルの RetryPolicy を返します。 |
| `ClaudeClassifyFailure[failure]` | failure を `TransportTransient` / `ProviderRateLimit` / `SecurityViolation` 等のクラスに分類します。 |
| `$ClaudeRuntimeVersion` | パッケージバージョン文字列。 |
| `$ClaudeRuntimeRetryProfile` | RetryPolicy の既定プロファイル名（初期値: `"Eval"`）。 |
| `$UseClaudeRuntime` | `True` のとき ClaudeRuntime ベースの `ClaudeEval` が有効になります。ClaudeRuntime ロード時に自動設定されます。 |

### ドキュメント一覧

| ファイル | 内容 |
|---------|------|
| `api.md` | API リファレンス（全公開シンボルの仕様） |
| `setup.md` | インストール手順・トラブルシューティング |
| `user_manual.md` | カテゴリ別ユーザーマニュアル |
| `example.md` | 代表的な使用パターン集 |
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
(* 出力例:
   ClaudeRuntime package loaded. (v2026-04-14T02-phase27)
     $UseClaudeRuntime = True
     ...
*)
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

### リポジトリ

- [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime)
- [ClaudeRuntime_test](https://github.com/transreal/ClaudeRuntime_test)
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