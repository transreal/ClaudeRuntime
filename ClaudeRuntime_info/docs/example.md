# ClaudeRuntime 実行例

## ClaudeEval の概要

`ClaudeEval` は、自然言語のプロンプトから Wolfram Language コードを生成・実行する関数です。以前は `claudecode` パッケージで定義されていましたが、現在は **ClaudeRuntime** パッケージで再実装されており、より堅牢な Expression-Proposal ループと状態管理を提供しています。

---

## `$UseClaudeRuntime` スイッチ

`ClaudeRuntime` をロードすると、`$UseClaudeRuntime = True` が自動的に設定されます。このフラグにより、`claudecode` の旧 `ClaudeEval` 実装の代わりに ClaudeRuntime ベースの新しい `ClaudeEval` が使用されます。

```mathematica
(* ClaudeRuntime をロード *)
<< ClaudeRuntime`
(* 出力:
   ClaudeRuntime package loaded. (v2026-04-14T02-phase27)
     $UseClaudeRuntime = True

     CreateClaudeRuntime[adapter]         → Create runtimeId
     ClaudeRunTurn[runtimeId, input]      → Launch DAG jobId
     ClaudeContinueTurn[runtimeId]        → Continue turn
     ClaudeRuntimeState[runtimeId]        → Query state
     ClaudeTurnTrace[runtimeId]           → Event trace
     ClaudeApproveProposal[runtimeId]     → Approve
     ClaudeDenyProposal[runtimeId]        → Deny
     ClaudeRuntimeCancel[runtimeId]       → Cancel
     ClaudeRuntimeRetry[runtimeId]        → Retry failed nodes
     ClaudeRetryPolicy[profile]           → Get RetryPolicy
     ClaudeClassifyFailure[failure]       → Classify failure
*)
```

旧実装に戻す場合は、`$UseClaudeRuntime = False` を設定します。

```mathematica
$UseClaudeRuntime = False   (* レガシーの claudecode 版 ClaudeEval を使用 *)
$UseClaudeRuntime = True    (* ClaudeRuntime 版を使用（既定） *)
```

---

## 基本的な使い方

使い方は従来の `ClaudeEval` とほぼ同様です。プロンプトを渡すと、Wolfram Language コードが生成・実行されます。

### 例 1 — 自然言語プロンプトからグラフを生成

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
      PlotLabel -> Style[Row[{"Projectile Motion (", Subscript["v", 0], " = ", v0, " m/s)"}], Bold, 14],
      Filling -> Axis,
      FillingStyle -> Directive[Opacity[0.15], Blue],
      GridLines -> Automatic,
      ImageSize -> 500
    ],
    Graphics[{
      {Red, PointSize[0.015], Point[{tMax, hMax}]},
      Text[Style[Row[{"Max: ", NumberForm[hMax, {4, 1}], " m"}], 11, Red], {tMax, hMax + 1}],
      {Dashed, Gray, Line[{{tMax, 0}, {tMax, hMax}}]},
      Text[Style[Row[{NumberForm[tFlight, {3, 1}], " s"}], 11, Darker[Green]], {tFlight, -1}]
    }]
  ]
]
```

---

## 承認フロー（NeedsApproval）

危険なコードの自動実行は強制的に停止されます。たとえば、コアパッケージの内部状態を書き換えようとするコードは承認待ち状態になります。

### 例 2 — コア変数への上書きは承認が必要

```mathematica
ClaudeEval["Assign {} to ClaudeRuntime`Private`$iClaudeRuntimes"]
```

実行すると、承認ダイアログが表示されます。

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

ユーザーが拒否した場合の出力例：

```
⛔ User denied the proposed expression.
```

手動で承認・拒否する場合は以下のように呼び出します。

```mathematica
ClaudeApproveProposal[$ClaudeLastRuntimeId]   (* 承認 *)
ClaudeDenyProposal[$ClaudeLastRuntimeId]      (* 拒否 *)
```

---

## ランタイム状態の確認

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
      <|
        "RuntimeId" -> id,
        "Status"    -> rt["Status"],
        "TurnCount" -> rt["TurnCount"],
        "Profile"   -> rt["Profile"],
        "LastFailure" -> Lookup[rt, "LastFailure", None]
      |>
    ],
    ClaudeRuntime`Private`$iClaudeRuntimes
  ]
]
```

**出力例（Dataset）：**

| RuntimeId              | Status | TurnCount | Profile | LastFailure             |
|------------------------|--------|-----------|---------|-------------------------|
| rt-1776160445-93123    | Done   | 3         | Eval    | None                    |
| rt-1776160517-17165    | Failed | 1         | Eval    | `<\|"ReasonClass" -> "UserDenied"\|>` |

`Status` の取りうる値：`"Initialized"` / `"Running"` / `"AwaitingApproval"` / `"Retrying"` / `"Done"` / `"Failed"`

---

## 失敗時のリトライ

LLMGraph とスケジューラを分離しているため、ネットワーク断や Claude の利用制限で `queryProvider` が失敗した場合は、その場でリトライできます。

```mathematica
ClaudeRuntimeRetry[$ClaudeLastRuntimeId]
```

`Done` ノードの結果は保持され、`Failed` / `Pending` ノードのみ新しい DAG で再実行されます。

スナップショットを使ってディスクに保存・復元することも可能です。

```mathematica
(* 現在の状態をディスクに保存 *)
ClaudeRuntimeSnapshot[$ClaudeLastRuntimeId]

(* 保存済みスナップショットをロードして再実行 *)
ClaudeRuntimeRestore["C:/.../snapshots/...", "Resume"]
```

---

## LLMGraph の可視化

実行グラフ（LLMGraph）を可視化して、各フェーズの依存関係や実行状況を確認できます。

```mathematica
NotebookLLMGraphPlot[]
```

`"Detail" -> True` を指定すると、各フェーズに対応するノードが表示されます。

```mathematica
NotebookLLMGraphPlot["Detail" -> True]
```

---

## RetryPolicy の確認

各プロファイルのリトライポリシーは `ClaudeRetryPolicy` で確認できます。

```mathematica
ClaudeRetryPolicy["Eval"]
```

**出力例：**

```mathematica
<|
  "Profile" -> "Eval",
  "Limits" -> <|
    "MaxTotalSteps"          -> 6,
    "MaxProposalIterations"  -> 3,
    "MaxTransportRetries"    -> 2,
    "MaxFormatRetries"       -> 2,
    "MaxValidationRepairs"   -> 1,
    "MaxExecutionRetries"    -> 0,
    "MaxReloadRepairs"       -> 0,
    "MaxTestRepairs"         -> 0,
    "MaxPatchApplyRetries"   -> 0,
    "MaxFullReplans"         -> 0
  |>,
  "Backoff" -> <| ... |>,
  "ClassificationRules" -> <| ... |>,
  "CheckpointPolicy" -> <| ... |>,
  "ApprovalPolicy" -> <| ... |>,
  "Accounting" -> <| ... |>
|>