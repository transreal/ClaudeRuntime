# ClaudeRuntime API リファレンス

ClaudeRuntime は expression-proposal loop の状態機械。turn loop / proposal loop / provider 連携 / validation・execution の進行管理 / continuation / usage・event の構造化 / session state の論理モデルを担う。Notebook・secret・access policy・label algebra は知らず、抽象 adapter interface のみを扱う。安全判定は adapter 経由で [NBAccess](https://github.com/transreal/NBAccess) が行う。実行形式は [claudecode](https://github.com/transreal/claudecode) の LLMGraph DAG で展開する。

ロード: `Block[{$CharacterEncoding = "UTF-8"}, Get["ClaudeRuntime.wl"]]`

関連 companion API を使う場合:
```
Block[{$CharacterEncoding = "UTF-8"},
  Get["ClaudeRuntime_taskplacement.wl"];
  Get["ClaudeRuntime_externalrunner.wl"];
]
```

## バージョン
### $ClaudeRuntimeVersion
型: String
パッケージバージョン。

## Adapter 仕様
CreateClaudeRuntime / ClaudeRunTurn 系で使う adapter は Association:
```
<|"BuildContext"    -> fn,
  "QueryProvider"    -> fn,
  "ValidateProposal" -> fn,
  "ExecuteProposal"  -> fn,
  "RedactResult"     -> fn,
  "ShouldContinue"   -> fn|>
```
`ParseProposal` は現行の public usage には含まれない。安全判定・実行可否は adapter 側 (NBAccess) が決める。

### $ClaudeCallContractValidator
型: None (既定) | Function (heldExpr → `<|"Status"->"OK"|"Failed", "RepairText"->_String, ...|>`)
提案式の呼び出し契約検証 hook (function_contract_wiring spec v0.3 §6.1、rule 11 の弱結合)。SourceVault ロード時に `SourceVaultCallContractValidatorHook` (深いスキャン: Module 内の契約付き呼び出しも検証、幻 option / deprecated alias / 引数個数 / enum 値域を実行前拒否) が両側 handshake で自動登録される。ValidateProposal で Permit と判定された式のみに適用され、契約違反は Decision="RepairNeeded" (RepairText がそのまま修復ターンのプロンプト) へ降格する。Deny / NeedsApproval は上書きしない。hook 例外 / timeout (5s) / 非 Association は fail-open。trace イベント: `CallContractViolation`。

## ランタイム生成・実行
### CreateClaudeRuntime[adapter, opts]
RuntimeState を生成する。
→ runtimeId
adapter は上記 Adapter 仕様の Association。
Options: `"Profile" -> Automatic`, `"Metadata" -> <||>`。

### ClaudeRunTurn[runtimeId, input]
expression-proposal loop を LLMGraph DAG として起動する。
→ jobId
Options: `"Notebook" -> Automatic`。

### ClaudeContinueTurn[runtimeId] → jobId
前回の turn の continuation を起動する。

### ClaudeRuntimeRetry[runtimeId] → jobId
直前ターンの Failed ノードを再実行する。Done ノードの結果は保持し、Failed/Pending ノードのみ新しい DAG で再起動する。アクティブ DAG が残っている場合は LLMGraphDAGRetry に委譲。
例: `ClaudeRuntimeRetry[$ClaudeLastRuntimeId]`

### ClaudeRuntimeCancel[runtimeId]
DAG ジョブをキャンセルする。

## 状態・トレース参照
### ClaudeRuntimeState[runtimeId] → Association
RuntimeState の軽量表示版。NotebookObject や巨大な中間結果 (ConversationState, LastProviderResponse 等) を除外し FrontEnd のフォーマット負荷を軽減。

### ClaudeRuntimeStateFull[runtimeId] → Association
RuntimeState 全体 (Adapter 以外) を返す。Dynamic や直接評価での使用は避けること (FrontEnd がブロックする可能性)。

### ClaudeTurnTrace[runtimeId] → List
EventTrace 全体を返す。

### ClaudeGetConversationMessages[runtimeId] → List
全ターンの Messages を返す。各要素は `<|"Turn"->n, "ProposedCode"->..., "ExecutionResult"->..., "TextResponse"->...|>`。

## 承認フロー
AwaitingApproval 状態の proposal に対する操作。PendingApproval は Kind="TimeoutExtension" の場合 ExpectedSeconds / DefaultTimeoutSeconds を含む。原則として初期設定のタイムアウトを順守し、延長すれば計算できる場合のみ問い合わせる。

### ClaudeApproveProposal[runtimeId]
AwaitingApproval 状態の proposal を承認する。

### ClaudeApproveProposalWithTimeout[runtimeId, timeout]
proposal を承認し、adapter の DefaultTimeoutSeconds を一時的に timeout 秒に上書きする。timeout は Infinity または正整数。タイムアウト延長承認フロー (Phase 30) で使用。

### ClaudeDenyProposal[runtimeId]
AwaitingApproval 状態の proposal を拒否する。

### ClaudeMarkApprovalConsumed[runtimeId, reason]
承認 UI 側が desktop action を既に実行した場合に承認待ち状態を消費し Done にする (実行ロジックは呼ばない)。

## RetryPolicy / 失敗分類
### $ClaudeRuntimeRetryProfile
型: String
RetryPolicy の既定プロファイル。

### ClaudeRetryPolicy[profile] → RetryPolicy
指定プロファイルの RetryPolicy を返す。profile: `"Eval"` | `"UpdatePackage"`。

### ClaudeClassifyFailure[failure] → failureClass
failure の分類を返す。

## WorkflowNet 連携 (Transition 実行)
### ClaudeRuntimeExecuteTransition[adapter, contextPacket]
WorkflowNet の Transition 1 つを 1 turn 内で実行する adapter API。BuildContext -> QueryProvider -> ValidateProposal -> ExecuteProposal -> RedactResult を順に呼ぶ純関数的実行。multi-turn / retry / approval は扱わず [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) の Workflow が担当する。
→ 成功時 `<|"Status"->"Success", "Output"->redactedResult, "Proposal"->proposal, "Validation"->validateResult, "ExecResult"->execResult|>` / 失敗時 `<|"Status"->"Failed", "Reason"->..., "Diagnostics"->...|>`
adapter は ShouldContinue 不要の `<|"BuildContext", "QueryProvider", "ValidateProposal", "ExecuteProposal", "RedactResult"|>`。contextPacket の主キー: "TransitionName", "Binding", "InputTokens", "Role", "DirectiveBundle", "DirectivePrompt", "AllowedCapabilities", "OutputSchema"。

## 非同期コード実行 (Phase 32)
ExecuteProposal handler が `<|"Async"->True, "Future"->EvaluationObject[...], "HeldExpr"->..., "Timeout"->seconds|Infinity, "StartTime"->AbsoluteTime[]|>` を返すと、実行後段 (RedactResult / ShouldContinue / Continuation) を polling tick に繋ぐ。同期形式も従来通りサポート。

### ClaudeRuntimeAsyncExecutionStatus[runtimeId] → Association
非同期実行中タスクの状態を返す。`<|"Running"->True|False, "Elapsed"->seconds, "Timeout"->seconds|Infinity, "StartTime"->AbsoluteTime, "PollKey"->string|>`。async 実行がなければ `<|"Running"->False|>`。

### ClaudeRuntimeCancelAsyncExecution[runtimeId]
実行中の非同期コードを中断し AbortKernels[] で強制停止する。中断後 LaunchKernels[] で並列カーネルを再起動する。

### ClaudeRuntimeAsyncDiagnose[] → Association
非同期実行経路の現在状態を返す。`<|"ParallelKernels"->_Integer, "ParallelKernelsReady"->Bool, "AsyncExecutionEnabled"->Bool, "AsyncExecutionForced"->Bool, "HighPriorityMode"->Bool, "RuntimeCount"->_Integer, "Runtimes"->{<|...|>,...}|>`。各 Runtime は Status / Phase / TurnCount / AsyncActive / AsyncFutureState / AsyncElapsed を含む。

### ClaudeRuntimeAsyncActiveQ[] → Bool
いずれかの runtime で非同期実行 (AsyncExecution) または非同期 tool 実行 (AsyncToolExec の Running 非空) が走行中なら True。NBAccess の PendingFinalActionQueue はこれが True の間 FrontEnd ブロック action を Pending のまま待つ ($NBFinalActionAsyncActiveFunction 経由)。

## 非同期 Tool 実行 (Phase 32k)
### ClaudeRuntimeCancelAsyncToolExec[runtimeId] → Association
走行中の AsyncToolExec をキャンセルする。Running の全 entry に adapter["CancelToolAsync"] を呼び、Queue の call も Cancelled に下ろし polling tick を解除する。
→ `<|"Success"->_, "CancelledCount"->_Integer, "PollKey"->_String|>`

### ClaudeRuntimeToolExecDiagnose[runtimeId] → Association
現在の AsyncToolExec state を返す診断関数。`<|"Active"->_, "Finalized"->_, "PollKey"->_String, "QueueSize"->_Integer, "RunningSize"->_Integer, "CollectedSize"->_Integer, "ToolCount"->_Integer, "MaxConcurrent"->_Integer, "Elapsed"->_Real, "RunningIndices"->_List, "QueueIndices"->_List, "CollectedIndices"->_List|>`。

### $ClaudeRuntimeToolAsyncDefault
型: Boolean, 初期値: False
AsyncToolExec の既定有効フラグ。True にすると web_search 等を別 OS プロセスで実行しメインカーネルをブロックしない。既定は False で legacy sync 経路を維持する。Runtime ごとに Metadata["ToolAsync"]、Adapter ごとに adapter["ToolAsync"] で上書き可能。

## Task Placement 分類 API
`ClaudeRuntime_taskplacement.wl` が同じ `ClaudeRuntime`` context に追加する companion API。Orchestrator の external executor / task placement のために、1 turn 内で閉じる task metadata の正規化・内省・backend 推奨だけを扱う。workflow state / job registry / retry / concurrency は持たず、最終決定は ClaudeOrchestrator と NBAccess Decision が行う。

### ClaudeTaskPlacementSchema[] → Association
正本 metadata schema の default template を返す。TaskKind / PlacementEffect / Decision / PreferredBackend / SelectedBackend、サイズ・転送リスク、FrontEnd 依存、credential / confidential、retry / checkpoint、scope / cleanup、HeldExpr / InspectionStatus などのキーを含む。

### ClaudeNormalizeTaskSpec[raw] → Association
raw Association を正本 metadata schema へ正規化した taskSpec を返す。未指定キーは `"Unknown"` や `Missing[...]` など安全側 default で補完する。deprecated alias として `"EstimatedInputBytes"` → `"EstimatedTransferBytes"`、`"TransferCost"` → `"DataTransferRisk"` も解決する。

### ClaudeClassifyTask[taskSpec, context] → Association
taskSpec を補助分類した classifiedTask を返す。held expression を持つ Subkernel/MainKernel 候補では dispatch 前の軽量内省を行い、ReferencedSymbols / EstimatedTransferBytes / UsesDynamic / UsesDialog / UsesNotebookIO / FrontEndBlockingRisk / HeadlessSafe などを埋める。内省は `$ClaudeTaskInspectionTimeLimit` 秒以内、未確定は Unknown safe default に倒す。`context` 省略時は `<||>`。

### ClaudeSelectExecutionBackend[classifiedTask, context] → Association
backend 推奨 (advisory) を返す。返り値は `<|"SelectedBackend", "ReasonClass", "Rejections", "Fallbacks", "RequiresApproval", "Notes"|>`。候補は `"MainKernelAsync"`, `"SubkernelAsync"`, `"WolframScriptProcess"`, `"FinalActionQueue"`, `"Deny"`, `"RepairNeeded"`。NBAccess Decision (context または classifiedTask の `"Decision"`) を最優先し、最終 backend 決定は Orchestrator が行う。`context` 省略時は `<||>`。

### ClaudeBuildTaskAction[classifiedTask] → Association
NBValidateAction[action, accessSpec] に渡す action Association を組み立てる。Action は `"ExternalTask"`、TaskKind / PlacementEffect / DeclaredEffectClasses / Target / RequestedBackend を含む。本分類器は NBAccess を直接呼ばず、検証用 artifact だけを返す。

### $ClaudeTaskPlacementDataSizeLimits
型: Association
転送サイズ閾値 (bytes)。主なキーは `"SubkernelAutoTransferBytes"`, `"SubkernelApprovalTransferBytes"`, `"WolframScriptInlineInputBytes"`, `"RequireReferenceAboveBytes"`, `"HardDenyValueTransferAboveBytes"`。

### $ClaudeTaskInspectionTimeLimit
型: Number
held-expr 内省の時間上限 (秒)。既定は 0.5。超過時は Unknown safe default に倒す。

### $ClaudeTransferSizeEstimateFactors
型: Association
型別の転送サイズ概算安全係数。PackedArray / SparseArray / Image / Graph / Association / Dataset / GeneralExpression などに適用する。

## External WolframScript Runner API
`ClaudeRuntime_externalrunner.wl` が追加する external executor companion API。ClaudeOrchestrator の External executor hook に launcher / killer / job dir / manifest runner を提供し、別 wolframscript プロセスまたは in-process runner で長時間・batch task を実行する。

### ClaudeRunTaskFromManifest[jobDir] → Association
runner (子プロセス) のエントリポイント。`manifest.wl` と `input.wxf` を読み、登録済み Handler を実行し、`output.wxf` と `status.json` (`Completed` / `Failed`) を書く。ConfidentialHandling が `"EncryptedBundle"` の job では input/output の封印・復号に SourceVault crypto を使う。

### ClaudeRegisterExternalTaskHandler[name, fn, opts]
External task handler を登録する。`fn` は `<|"Manifest"->m, "Input"->inputData, "JobDir"->jobDir, "AccessSpec"->accessSpec|>` を受け取り Association を返す。組込 handler として `"Echo"`, `"GuardedWrite"`, `"ApprovedHeldExpr"` が登録される。

### ClaudeResolveWolframScriptExecutable[] → String | $Failed
wolframscript 実行ファイルを解決する。優先順は `$ClaudeWolframScriptExecutable`、環境変数 `WOLFRAMSCRIPT`、`$InstallationDirectory` 近傍、PATH 上の `wolframscript`。

### ClaudeExternalJobRoot[] → Directory
durable な job root を返し、無ければ作成する。`$ClaudeExternalJobRoot` が明示されていればそれを使い、未設定なら `$UserBaseDirectory/ClaudeRuntime/jobs`。

### ClaudeExternalWolframScriptLauncher[jobSpec] → Association
job dir を作り、`manifest.wl` / `input.wxf` / `run.wls` を書き、wolframscript runner を StartProcess で起動する。成功時は `<|"Status"->"Launched", "JobID", "JobDir", "PID"|>` を返す。`$ClaudeExternalJobLauncher` へ結線して使う。

### ClaudeExternalInProcessLauncher[jobSpec] → Association
job dir / manifest を準備し、runner を現在のカーネルで同期実行する。別プロセスを起こさないため、テスト・単一ライセンス環境・短時間タスク用。long-running には使わない。

### ClaudeExternalWolframScriptKiller[awaitMeta] → Association
起動済み ProcessObject、または `pid.json` の PID 同一性確認に基づいて外部 runner を終了する。`$ClaudeExternalJobKiller` へ結線して使う。誤 kill 回避のため、PID が生存する wolframscript と確認できない場合は skip する。

### ClaudeWireExternalRunner[] → "Wired" | "WorkflowNotLoaded"
ClaudeOrchestrator`Workflow` の External executor hook (`$ClaudeExternalJobLauncher` / `$ClaudeExternalJobKiller`) を本パッケージの実装へ結線する。

### ClaudeExternalJobRecover[opts] → Association
job root を走査し、status が Running だが registry に無い孤児 job を回収する。Options: `"Kill" -> True`, `"Mark" -> True`。Kill 有効時は pid.json 同一性確認後に kill し、Mark 有効時は status を Expired に更新する。

### ClaudeLintExternalHandler[HoldComplete[body]] → Association
handler 本体に raw I/O (`Export`, `Import`, `URLRead`, `StartProcess`, `OpenWrite`, `DeleteFile`, `DialogInput`, `AuthenticationDialog` 等) が直書きされていないか検査する。handler は NBChecked* / NBCheck* 経由で I/O すべき。返り値は `<|"Clean"->_, "Violations"->{...}|>`。

### ClaudeWireExternalProviders[spec] → Association
provider connector を結線する。`spec` の主キーは `"LLM"`, `"SourceVaultIngest"`, `"MailFetch"`。引数省略時は各 connector の現在の利用可否を返す。実 provider は claudecode.wl / SourceVault.wl ロード時に Automatic 経由で自動利用される。

### ClaudeActivateExternalExecutor[opts] → Association
External executor を live 稼働させる。launcher / killer を結線し、ClaudeCode`ClaudeRegisterPollingTick に External / Subkernel poll tick を登録し、完了 hook を設定して job 完了時に summary final action を FinalActionQueue へ enqueue する。`opts` は `"RegisterPoll"` と `"ReflectToNotebook"` を既定 True として扱う。

### ClaudeDeactivateExternalExecutor[] → Association
poll tick 登録解除と完了 hook クリアを行う。返り値は `<|"Deactivated" -> True|>`。

### ClaudeExternalJobSummary[output, completion] → Association
外部ジョブ出力の summary を返す。Head / ByteCount / OutputRef / SourceVaultRef / Inlined / Preview を含む。ByteCount が `$ClaudeExternalInlineLimit` を超える場合は Preview を省き、ref / summary のみ扱う。

### ClaudeExternalJobFinalAction[completion, opts] → Association
完了 payload の OutputRef を解決し、Notebook へ反映する summary-only final action (`WriteNotebookCell`) を構築する。本体は inline せず、反映は FinalActionQueue / 承認経由。Options: `"JobDir" -> None`, `"AccessSpec" -> <||>`。

### ClaudeExternalInlineAllowedQ[bytes] → Bool
出力を Notebook へ inline してよいサイズかを返す。整数 bytes が `$ClaudeExternalInlineLimit` 以下なら True。Unknown は安全側 False。

### $ClaudeExternalProcessProbe
型: Automatic | Function
PID のプロセス情報を返す関数。契約は `fn[pid] -> <|"Alive"->_, "Executable"->_|> | None`。Automatic は OS 問い合わせ (Windows: tasklist)。cross-restart kill の同一性確認に使う。テストで mock 注入可。

### $ClaudeExternalProcessKill
型: Automatic | Function
PID を強制終了する関数。契約は `fn[pid] -> Bool`。Automatic は OS kill (Windows: taskkill /F)。テストで mock 注入可。

### $ClaudeBatchProcessorOverrides
型: Association
batch handler (`BulkFileProcessing`, `BulkLLMProcessing`, `MailFetch`, `SourceVaultIngest`) の per-item processor 差し替え。handlerName -> Function[{item, idx, ctx}, `<|"Status"->"OK"|"Failed", "Result"->_|>`]。

### $ClaudeLLMConnector
型: Automatic | Function
`BulkLLMProcessing` が使う LLM 呼出関数 (`fn[prompt]`)。Automatic は ClaudeCode`ClaudeQuerySync へ解決し、未ロード時は graceful fail。鍵は ClaudeQuerySync 側が NBGetAPIKey で扱う。

### $ClaudeSourceVaultIngestConnector
型: Automatic | Function
`SourceVaultIngest` が使う取込関数 (`fn[source]`)。Automatic は SourceVault`SourceVaultIngest へ解決する。

### $ClaudeMailFetchConnector
型: Automatic | Function
`MailFetch` が使う取得関数 (`fn[mbox, period]`)。Automatic は SourceVault`SourceVaultMailEnsureLoaded へ解決する。

### $ClaudeExternalFinalActionEnqueue
型: Automatic | Function
完了 final action を enqueue する関数 (`fn[action, accessSpec]`)。Automatic は ClaudeCode`ClaudeEnqueueFinalAction へ解決する。テストで mock 注入可。

### $ClaudeExternalPollTickKey
型: String
共有 polling tick への登録 key。既定は `"external-job-poll"`。

### $ClaudeExternalInlineLimit
型: Integer
Notebook へ inline できる出力 ByteCount の上限。既定は 64KB。超過時は ref / summary のみ。

### $ClaudeWolframScriptExecutable
型: Automatic | String
wolframscript 実行ファイルの明示パス。未設定なら `ClaudeResolveWolframScriptExecutable[]` が自動解決する。

### $ClaudeExternalJobRoot
型: Automatic | String
External job の durable root の明示パス。未設定なら `$UserBaseDirectory/ClaudeRuntime/jobs`。