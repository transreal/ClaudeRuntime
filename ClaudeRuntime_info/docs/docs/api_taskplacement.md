# ClaudeRuntime_taskplacement API Reference

パッケージ: `ClaudeRuntime``taskplacement`
文脈: `ClaudeRuntime``
GitHub: https://github.com/transreal/ClaudeRuntime_taskplacement

## 概要

タスク配置分類器 (Phase 1)。1 ターン内で閉じる純関数的な分類・正規化のみを担う。workflow state / job registry / retry / concurrency 等の永続状態は持たない (それらは [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) の責務)。本分類器の backend 推奨はあくまで advisory であり、最終決定は Orchestrator が行う。[NBAccess](https://github.com/transreal/NBAccess) の Decision が安全性の正本。

ロード:
```wolfram
Block[{$CharacterEncoding = "UTF-8"}, Get["ClaudeRuntime_taskplacement.wl"]]
```

## 公開シンボル

### ClaudeNormalizeTaskSpec[raw] → Association
`raw` Association を正本 metadata schema へ正規化した taskSpec を返す。未指定キーは安全側 default (Unknown 等) で補完する。

### ClaudeClassifyTask[taskSpec, context] → Association
`taskSpec` を補助分類した classifiedTask を返す。held expression を持つ task (Subkernel/MainKernel 候補) には dispatch 前の軽量内省を行い、`ReferencedSymbols` / `EstimatedTransferBytes` / `Uses*` / `FrontEndBlockingRisk` 等のフィールドを埋める。内省は `$ClaudeTaskInspectionTimeLimit` 秒以内に制限し、未確定値は Unknown (安全側) に倒す。`context` 省略時は `<||>` を渡す。

内省適用範囲は held expr を持つ task のみ (§9.1)。packed array は O(1) 概算 (§9.2)。

例:
```wolfram
ClaudeClassifyTask[ClaudeNormalizeTaskSpec[<|"HeldExpression" -> Hold[...], "PreferredBackend" -> "Subkernel"|>], <||>]
```

### ClaudeSelectExecutionBackend[classifiedTask, context] → Association
backend 推奨 (advisory) を返す。返り値キー:
- `"SelectedBackend"` — 推奨 backend 名
- `"ReasonClass"` — 選択理由クラス
- `"Rejections"` — 除外された backend と理由
- `"Fallbacks"` — フォールバック候補リスト
- `"RequiresApproval"` — 承認要否 (Boolean)
- `"Notes"` — 補足メモ

優先順位: `context` または `classifiedTask` の `"Decision"` (NBAccess Decision) → hard safety 制約 → FrontEndBlockingRisk / UI 起点 / blocking dialog / FE 依存 headless 禁止 (§4.2-4.4) → Subkernel 自動送信禁止条件 (transfer-safe / confidential / output size, §5.2) → WolframScript 選択条件 (§6.1) → `"PreferredBackend"` → 推奨。

### ClaudeBuildTaskAction[classifiedTask] → Association
`NBValidateAction[action, accessSpec]` に渡す action Association を組み立てる。本分類器は [NBAccess](https://github.com/transreal/NBAccess) を呼ばない (接続点の提供のみ)。実際の検証は Orchestrator が行う。

### ClaudeTaskPlacementSchema[] → Association
正本 metadata schema の default template (Association) を返す。`ClaudeNormalizeTaskSpec` が補完に使うスキーマ定義を直接参照したい場合に使う。

## 変数

### $ClaudeTaskPlacementDataSizeLimits
型: Association, 初期値: パッケージ定義値
転送サイズ閾値 (bytes) の Association。`EstimatedTransferBytes` および `EstimatedMaterializationBytes` の評価に適用する。

### $ClaudeTaskInspectionTimeLimit
型: Real (秒), 初期値: パッケージ定義値
held-expr 内省の時間上限。超過時は Unknown safe default に倒す。

### $ClaudeTransferSizeEstimateFactors
型: Association, 初期値: パッケージ定義値
型別の転送サイズ概算安全係数の Association。packed array 等の型ごとに係数が異なる。

## 設計対応 (v7 仕様書)

| 仕様節 | 内容 |
|--------|------|
| §2.1/§2.5 | 正本 metadata schema |
| §9.1 | 内省適用範囲 = held expr を持つ task のみ |
| §9.2 | 内省コスト上限 (packed array は O(1) 概算 / 時間上限 / Unknown safe) |
| §4.2-4.4 | FrontEndBlockingRisk / UI 起点 / blocking dialog / FE 依存 headless 禁止 |
| §5.2 | Subkernel 自動送信禁止条件 |
| §6.1 | WolframScript 選択条件 |
| §4.3 | backend 優先順位 |

## 関連パッケージ

- [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime) — Runtime 本体
- [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) — 最終 backend 決定・永続状態管理
- [NBAccess](https://github.com/transreal/NBAccess) — Decision (安全性の正本)
- [ClaudeRuntime_externalrunner](https://github.com/transreal/ClaudeRuntime_externalrunner) — 外部実行ランナー