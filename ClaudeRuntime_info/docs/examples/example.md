# ClaudeRuntime 使用例集

ClaudeRuntime パッケージの代表的な使用例をまとめます。

このドキュメントは大きく 2 部構成です。

- **Part A. ClaudeEval ユーザー向け** — 自然言語プロンプトから Wolfram Language コードを生成・実行する `ClaudeEval` が ClaudeRuntime ベースの再実装でどう変わったか、`$UseClaudeRuntime` スイッチ、承認フロー、状態確認、リトライまでの一連の使い方を示します。
- **Part B. ClaudeRuntime 低レベル API** — `CreateClaudeRuntime` / `ClaudeRunTurn` / `ClaudeApproveProposal` などを直接呼ぶ、開発者・拡張者向けの API を例で示します。

---

## 事前準備

```mathematica
Block[{$CharacterEncoding = "UTF-8"},
  Get[FileNameJoin[{$packageDirectory, "claudecode.wl"}]]];
Get[FileNameJoin[{$packageDirectory, "ClaudeRuntime.wl"}]];

(* バージョン確認 *)
{ClaudeRuntime`$ClaudeRuntimeVersion,
 ClaudeCode`$UseClaudeRuntime,
 ClaudeCode`$ClaudeRuntimeAsyncExecution,
 ClaudeRuntime`$ClaudeRuntimeToolAsyncDefault}
```

**期待される出力例:**

```
{"2026-05-15-phase-32k-step3-route-unification-trace-v3", True, False, True}
```

> **メモ (2026-05-15 経路統一):** ClaudeRuntime をロードした時点で `$UseClaudeRuntime = True`(Bridge 経路)、`$ClaudeRuntimeAsyncExecution = False`(ExecuteProposal は同期評価)、`$ClaudeRuntimeToolAsyncDefault = True`(tool は AsyncToolExec)が自動的に設定されます。これは安定実装が確認済みの組み合わせです。ParallelSubmit 経路 (Phase 32) は別カーネルが起動済みでも 30 秒 timeout する症状があるため、`$ClaudeRuntimeAsyncExecution = False` で迂回しています(原因調査は別フェーズ)。
>
> 加えて、ロード時に `ClaudeBeginParallelKernels[]` が同期で 1 回だけ呼ばれ、4 個のサブカーネルを起動します(3〜5 秒のロード時コスト)。これは初回 `ClaudeEval` 呼び出しが timeout する事故を防ぐためで、`LaunchKernels[4]` に制限することで全コア起動による無駄なメモリ消費を抑えています(2026-05-15 修正)。

---

# Part A. ClaudeEval ユーザー向け

## ClaudeEval の概要

`ClaudeEval` は、自然言語のプロンプトから Wolfram Language コードを生成・実行する関数です。以前は `claudecode` パッケージで定義されていましたが、現在は **ClaudeRuntime** パッケージで再実装されており、より堅牢な Expression-Proposal ループと状態管理を提供しています。

## `$UseClaudeRuntime` スイッチ

`ClaudeRuntime` をロードすると、`$UseClaudeRuntime = True` が自動的に設定されます。このフラグにより、`claudecode` の旧 `ClaudeEval` 実装の代わりに ClaudeRuntime ベースの新しい `ClaudeEval` が使用されます。

旧実装に戻したい場合は、`$UseClaudeRuntime = False` を設定します。

```mathematica
$UseClaudeRuntime = False   (* レガシーの claudecode 版 ClaudeEval を使用 *)
$UseClaudeRuntime = True    (* ClaudeRuntime 版を使用(既定) *)
```

---

## 例 A-1: 自然言語プロンプトからグラフを生成

使い方は従来の `ClaudeEval` とほぼ同じです。プロンプトを渡すと、Wolfram Language コードが生成・実行されます。

```mathematica
ClaudeEval["Graph of projectile motion thrown upward"]
```

Claude がプロンプトを解釈し、以下のようなコードを生成して実行します(出力例):

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
      PlotLabel -> Style[Row[{"Projectile Motion (", Subscript["v", 0], " = ", v0, " m/s)"}], Bold, 14],
      Filling -> Axis,
      FillingStyle -> Directive[Opacity[0.15], Blue],
      GridLines -> Automatic,
      ImageSize -> 500],
    Graphics[{
      {Red, PointSize[0.015], Point[{tMax, hMax}]},
      Text[Style[Row[{"Max: ", NumberForm[hMax, {4, 1}], " m"}], 11, Red], {tMax, hMax + 1}],
      {Dashed, Gray, Line[{{tMax, 0}, {tMax, hMax}}]},
      Text[Style[Row[{NumberForm[tFlight, {3, 1}], " s"}], 11, Darker[Green]], {tFlight, -1}]
    }]]]
```

実行が完了すると、Notebook 上に対応する `Plot` セルが生成され、放物運動のグラフが描かれます。

---

## 例 A-2: 承認フロー (NeedsApproval)

危険なコードの自動実行は強制的に停止されます。たとえば、コアパッケージの内部状態を書き換えようとするコードは承認待ち状態になります。

```mathematica
ClaudeEval["Assign {} to ClaudeRuntime`Private`$iClaudeRuntimes"]
```

実行すると、承認ダイアログが表示されます:

```
? Approval required: CoreContextOverwrite — Code overwrites core package functions
  (NBAccess/ClaudeCode/ClaudeRuntime/ClaudeTestKit).
  This may break system functionality. Approval required.

  提案されたコード:
    HoldComplete[ClaudeRuntime`Private`$iClaudeRuntimes = {}]

  [Approve]  [Cancel]
```

- **Approve** を押すと `ClaudeApproveProposal[runtimeId]` が呼ばれ、実行が継続されます。
- **Cancel** を押すと `ClaudeDenyProposal[runtimeId]` が呼ばれ、実行が拒否されます。

ユーザーが拒否した場合の出力例:

```
⛔ User denied the proposed expression.
```

手動で承認・拒否する場合は以下のように呼び出します:

```mathematica
ClaudeApproveProposal[$ClaudeLastRuntimeId]   (* 承認 *)
ClaudeDenyProposal[$ClaudeLastRuntimeId]      (* 拒否 *)
```

---

## 例 A-3: ランタイム状態の確認

`ClaudeRuntimeState` を使ってランタイムの状態を確認できます。

```mathematica
ClaudeRuntimeState[$ClaudeLastRuntimeId]
```

複数のランタイムをまとめて確認するには、`Dataset` を使うと見やすい一覧が得られます。

```mathematica
(* 各ランタイムのステータスと情報を Dataset で一覧表示 *)
Dataset[
  KeyValueMap[
    Function[{id, rt},
      <|"RuntimeId"   -> id,
        "Status"      -> rt["Status"],
        "TurnCount"   -> rt["TurnCount"],
        "Profile"     -> rt["Profile"],
        "LastFailure" -> Lookup[rt, "LastFailure", None]|>],
    ClaudeRuntime`Private`$iClaudeRuntimes]]
```

**出力例 (Dataset):**

| RuntimeId              | Status | TurnCount | Profile | LastFailure                              |
|------------------------|--------|-----------|---------|------------------------------------------|
| rt-1776160445-93123    | Done   | 3         | Eval    | None                                     |
| rt-1776160517-17165    | Failed | 1         | Eval    | `<\|"ReasonClass" -> "UserDenied"\|>`    |

`Status` の取りうる値: `"Initialized"` / `"Running"` / `"AwaitingApproval"` / `"Retrying"` / `"Done"` / `"Failed"`

---

## 例 A-4: 失敗時のリトライ

LLMGraph とスケジューラを分離しているため、ネットワーク断や Claude の利用制限で `queryProvider` が失敗した場合は、その場でリトライできます。

```mathematica
ClaudeRuntimeRetry[$ClaudeLastRuntimeId]
```

`Done` ノードの結果は保持され、`Failed` / `Pending` ノードのみ新しい DAG で再実行されます。

スナップショットを使ってディスクに保存・復元することも可能です:

```mathematica
(* 現在の状態をディスクに保存 *)
ClaudeRuntimeSnapshot[$ClaudeLastRuntimeId]

(* 保存済みスナップショットをロードして再実行 *)
ClaudeRuntimeRestore["C:/.../snapshots/...", "Resume"]
```

---

## 例 A-5: LLMGraph の可視化

実行グラフ (LLMGraph) を可視化して、各フェーズの依存関係や実行状況を確認できます。

```mathematica
NotebookLLMGraphPlot[]
```

`"Detail" -> True` を指定すると、各フェーズに対応するノードが表示されます。

```mathematica
NotebookLLMGraphPlot["Detail" -> True]
```

---

## 例 A-6: RetryPolicy の確認

各プロファイルのリトライポリシーは `ClaudeRetryPolicy` で確認できます。

```mathematica
ClaudeRetryPolicy["Eval"]
```

**出力例:**

```mathematica
<|"Profile" -> "Eval",
  "Limits"  -> <|
    "MaxTotalSteps"         -> 6,
    "MaxProposalIterations" -> 3,
    "MaxTransportRetries"   -> 2,
    "MaxFormatRetries"      -> 2,
    "MaxValidationRepairs"  -> 1,
    "MaxExecutionRetries"   -> 0,
    "MaxReloadRepairs"      -> 0,
    "MaxTestRepairs"        -> 0,
    "MaxPatchApplyRetries"  -> 0,
    "MaxFullReplans"        -> 0|>,
  "Backoff"             -> <|...|>,
  "ClassificationRules" -> <|...|>,
  "CheckpointPolicy"    -> <|...|>,
  "ApprovalPolicy"      -> <|...|>,
  "Accounting"          -> <|...|>|>
```

利用可能なプロファイル: `"Eval"`(対話用)、`"UpdatePackage"`(パッケージ更新用、より積極的なリトライ)など。

---

# Part B. ClaudeRuntime 低レベル API

`ClaudeEval` の内部で使われている API を直接呼ぶ例です。新しい adapter を作って独自の Expression-Proposal ループを構築したい場合や、デバッグ・テストのためにランタイムを手動で制御したい場合に使います。

---

## 例 B-1: ランタイムの作成と基本ターンの実行

```mathematica
(* adapter を定義して RuntimeState を作成する *)
adapter = <|
  "BuildContext"     -> Function[{state, input}, {"role" -> "user", "content" -> input}],
  "QueryProvider"    -> Function[{ctx, opts}, {"role" -> "assistant", "content" -> "42"}],
  "ValidateProposal" -> Function[proposal, True],
  "ExecuteProposal"  -> Function[proposal, proposal],
  "RedactResult"     -> Function[result, result],
  "ShouldContinue"   -> Function[state, False]|>;

rid   = CreateClaudeRuntime[adapter];
jobId = ClaudeRunTurn[rid, "1 + 1 を計算してください"];
```

**期待される出力:** `"job-xxxx-xxxx"` (DAG ジョブ ID の文字列)

実 adapter (NBAccess + claudecode の組み合わせなど) を使う場合は、これらの 6 つの関数キーすべてが揃った Association を渡します。

---

## 例 B-2: ランタイム状態の確認

```mathematica
(* 実行中または完了後の RuntimeState を取得する *)
state = ClaudeRuntimeState[rid];
state["Phase"]
```

**期待される出力例:** `"Idle"` / `"Running"` / `"Snapshot"` / `"ShadowApply"` / `"StaticCheck"` / `"ReloadCheck"` / `"Commit"` などのフェーズ文字列。

`ClaudeRuntimeStateFull[rid]` を使うと、`"Phase"` だけでなく `"Status"` / `"TurnCount"` / `"Profile"` / `"LastFailure"` / `"SnapshotInfo"` などを含む完全な Association を取得できます。

---

## 例 B-3: イベントトレースの取得

```mathematica
(* ターン全体のイベント履歴を確認する *)
trace = ClaudeTurnTrace[rid];
trace[[All, "EventType"]]
```

**期待される出力例:**

```
{"TurnStarted", "ContextBuilt", "ProviderQueried", "ProposalParsed",
 "ProposalValidated", "ExecutionRequested", "ExecutionCompleted",
 "TurnCompleted"}
```

各イベントには `"Timestamp"` / `"Phase"` / 関連 payload が含まれます。adapter tool-flow のデバッグや、提案ループのどこで時間がかかっているかを調べるときに使います。

---

## 例 B-4: AwaitingApproval 状態での提案の承認・拒否

```mathematica
(* 承認待ちの提案を承認する *)
ClaudeApproveProposal[rid]

(* または拒否する場合 *)
ClaudeDenyProposal[rid]
```

**期待される出力例:** `"Approved"` または `"Denied"`

タイムアウト付きで承認待ちにしたい場合は `ClaudeApproveProposalWithTimeout[rid, timeoutSec]` を使います(タイムアウト時は自動的に Deny 扱いになります)。

---

## 例 B-5: 前回ターンの継続

```mathematica
(* 前回ターンの続きから実行を再開する(同じ会話履歴を保持) *)
ClaudeContinueTurn[rid]
```

**期待される出力:** 新しい DAG ジョブ ID 文字列

`ClaudeRunTurn` が新しい input を受け取って新規ターンを開始するのに対し、`ClaudeContinueTurn` は既存の context を保持して LLM に「続けて」と促します。複数ターンにわたる会話を組み立てるときに使います。

---

## 例 B-6: 会話履歴の取得

```mathematica
(* 全ターンの Messages を Association のリストとして取得する *)
msgs = ClaudeGetConversationMessages[rid];
msgs[[1]]
```

**期待される出力例:**

```mathematica
<|"Turn"            -> 1,
  "ProposedCode"    -> "1 + 1",
  "ExecutionResult" -> 2,
  "TextResponse"    -> "結果は 2 です。"|>
```

ランタイム間でメッセージ履歴を引き継ぎたい場合や、過去ターンの提案・結果を後から再利用したい場合に使います。

---

## 例 B-7: DAG ジョブのキャンセル

```mathematica
(* 実行中のターンを中断してキャンセルする *)
ClaudeRuntimeCancel[rid]
ClaudeRuntimeState[rid]["Phase"]
```

**期待される出力:** `"Cancelled"`

LLM 呼び出しが長時間返ってこない、ユーザーが途中で気が変わった、などの場合に使います。

---

## 例 B-8: 失敗分類とリトライポリシー

`ClaudeClassifyFailure` でランタイムが失敗した理由を分類できます。

```mathematica
failure = ClaudeRuntimeStateFull[rid]["LastFailure"];
ClaudeClassifyFailure[failure]
```

**戻り値の `"ReasonClass"` の取りうる値:**

- `"TransportError"` — ネットワーク・CLI 通信エラー
- `"FormatError"` — LLM 応答のパース失敗
- `"ValidationFailed"` — 提案コードが ValidateProposal を通らない
- `"ExecutionFailed"` — ExecuteProposal で例外
- `"UserDenied"` — 承認ダイアログで拒否された
- `"SnapshotFailed"` — Snapshot 段で失敗
- `"Timeout"` — 各種 timeout

各クラスに対するリトライ上限は `ClaudeRetryPolicy[$ClaudeRuntimeRetryProfile]["Limits"]` で参照できます(例 A-6 を参照)。

---

## 関連ドキュメント

- **`user_manual.md`** — 各 API の詳しい引数・オプション・戻り値の説明
- **`README.md`** — 設計思想・アーキテクチャ・adapter インターフェースの仕様
- **`docs/architecture/`** — LLMGraph DAG・経路統一・Phase 32k 関連の設計メモ
