# ClaudeRuntime_taskplacement API リファレンス

タスク配置分類器 (Phase 1)。`BeginPackage["ClaudeRuntime`"]` で `ClaudeRuntime`` context に公開シンボルを追加する。1 ターン内で閉じる純関数的な分類・正規化のみを担い、workflow state / job registry / retry / concurrency 等の永続状態は持たない (それらは ClaudeOrchestrator の責務)。NBAccess の Decision が安全性の正本であり、本分類器の backend 推奨は助言的 (advisory)。最終 backend 決定は Orchestrator が行う。

ロード:
```
Block[{$CharacterEncoding = "UTF-8"}, Get["ClaudeRuntime_taskplacement.wl"]]
```

## 公開関数

### ClaudeNormalizeTaskSpec[raw] → Association (taskSpec)
raw Association を正本 metadata schema へ正規化した taskSpec を返す。未指定キーは安全側 default (Unknown 等) で補完する。

### ClaudeClassifyTask[taskSpec, context] → Association (classifiedTask)
taskSpec を補助分類した classifiedTask を返す。held expression を持つ task (Subkernel/MainKernel 候補) には dispatch 前の軽量内省を行い、`ReferencedSymbols` / `EstimatedTransferBytes` / `Uses*` / `FrontEndBlockingRisk` 等を埋める。内省は `$ClaudeTaskInspectionTimeLimit` 秒以内、未確定値は Unknown (安全側) に倒す。packed array は O(1) 概算。context 省略時は `<||>` を使う。
例: `ClaudeClassifyTask[ClaudeNormalizeTaskSpec[raw], <||>]`

### ClaudeSelectExecutionBackend[classifiedTask, context] → Association
backend 推奨 (advisory) を返す。返り値キー: `"SelectedBackend"`, `"ReasonClass"`, `"Rejections"`, `"Fallbacks"`, `"RequiresApproval"`, `"Notes"`。NBAccess Decision (context または classifiedTask の `"Decision"`) を最優先する。最終決定は Orchestrator が行う。backend 優先順位: Decision > hard safety > ... > PreferredBackend > 推奨。

### ClaudeBuildTaskAction[classifiedTask] → Association (action)
`NBValidateAction[action, accessSpec]` に渡す action Association を組み立てる。本分類器は NBAccess を呼ばず、接続点 (artifact) を提供するのみ。検証は Orchestrator が行う。

### ClaudeTaskPlacementSchema[] → Association
正本 metadata schema の default template を返す。

## 公開変数

### $ClaudeTaskPlacementDataSizeLimits
型: Association (bytes 閾値)
転送サイズ閾値。`EstimatedTransferBytes` / `EstimatedMaterializationBytes` に適用する。

### $ClaudeTaskInspectionTimeLimit
型: Real (秒)
held-expr 内省の時間上限。超過時は Unknown safe default に倒す。

### $ClaudeTransferSizeEstimateFactors
型: Association
型別の転送サイズ概算安全係数。

## 設計対応 (v7 §)
- §2.1/§2.5 正本 metadata schema
- §9.1 内省適用範囲 = held expr を持つ task のみ
- §9.2 内省コスト上限 (packed array は O(1) 概算 / 時間上限 / Unknown safe)
- §4.2-4.4 FrontEndBlockingRisk / UI 起点 / blocking dialog / FE 依存 headless 禁止
- §5.2 Subkernel 自動送信禁止条件 (transfer-safe / confidential / output size)
- §6.1 WolframScript 選択条件
- §4.3 backend 優先順位 (Decision > hard safety > ... > PreferredBackend > 推奨)

## 典型ワークフロー
```
spec = ClaudeNormalizeTaskSpec[raw];
ct   = ClaudeClassifyTask[spec, <||>];
rec  = ClaudeSelectExecutionBackend[ct, <||>];
act  = ClaudeBuildTaskAction[ct];   (* Orchestrator が NBValidateAction[act, accessSpec] で検証 *)