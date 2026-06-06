# ClaudeOrchestrator External Executor / WolframScript タスク配置・ワークフロー投入仕様 v7 統合版

作成日: 2026-06-05  
対象: `ClaudeRuntime.wl`, `ClaudeOrchestrator.wl`, `ClaudeOrchestrator_workflow.wl`, `NBAccess.wl`, `SourceVault`, Claude Directives  
前版: `ClaudeOrchestrator_external_executor_task_placement_spec_v6_consolidated.md`  
位置づけ: v6統合版のマージ漏れを復元し、retry/checkpoint・credential・機密gate・role既定・manifest/job-dirを再統合した実装用正本

---

## 0. v6の目的

v7では、v6の正本化方針を維持しつつ、統合時に落ちたv4/v5の規範を復元する。対象は retry/checkpoint、credential、PlaintextDebug/degrade、NBAccess role既定、MayAccessFileSystem enum、manifest/job-dir、poller per-status分岐である。

v6では、追補形式をやめ、実装者が参照する正本を一本化した。v7では、その正本をv5/v4の上位集合に戻す。

特に次を解消する。

```text
S1:
  preemptive link / UI起点ブロッキング / blocking dialog禁止の反映漏れを修正する。

S2:
  metadata schemaを1表に統合し、重複fieldを解消する。

S3:
  v3/v4/v5の追補を本体へ畳み込み、古い§2.3/§2.4やstale labelを残さない。

S4:
  巨大データ内省の適用範囲を held expression を持つ task に限定する。

S5:
  内省コスト自体がmain kernelを重くしないよう、概算・time limit・Unknown safe defaultを定義する。

S6:
  Subkernel P1のfile outputもconfidential/encryption/cleanup要件を継承する。

S7:
  hard abort後のexternal orphan job回収を明記する。
```

---

## 1. 責務境界

### 1.1 ClaudeRuntime

Runtimeに置いてよいものは、1ターン内で閉じる純関数分類器だけである。

```wl
ClaudeClassifyTask[taskSpec_, context_] -> classifiedTask
ClaudeSelectExecutionBackend[classifiedTask_, context_] -> backendRecommendation
ClaudeNormalizeTaskSpec[raw_] -> taskSpec
```

Runtimeが保持してはならないもの:

```text
workflow state
job registry
ProcessObject registry
retry state
checkpoint state
dependency scheduling
concurrency slot
final action queue
WolframScript job lifecycle
```

### 1.2 ClaudeOrchestrator

Orchestratorが持つ。

```text
workflow state
Petri net places / transitions / tokens
dependency scheduling
External executor state
WolframScript job registry
polling state
retry / checkpoint / resume
pause / cancel / restore
concurrency resource places
final action node
AwaitingLLMTransitionsへのExternal job登録
```

### 1.3 NBAccess

NBAccessはhard safety boundaryである。

```text
AccessSpec生成・正規化
PolicySnapshot生成・per-call適用
role定義
EffectClass / ApprovalEligibility policy
scoped permit / scoped approval
I/O許可検査
runner用scope検査
credential-ref解決
final action executor
```

### 1.4 WolframScript runner

runnerは外部processで動くexecutorである。  
ただし真のOS sandboxではないため、I/O制御はcooperative enforcementである。

runnerが行うこと:

```text
manifest検証
NBAccessロード
AccessSpec / PolicySnapshot per-call適用
handler実行
NBCheck*経由のI/O
progress/status出力
checkpoint
redaction/encryption
cancel.flag確認
```

runnerが直接行ってはならないこと:

```text
NotebookObject操作
FrontEndExecute
SelectionMove
NotebookWrite
承認UI表示
EvaluationNotebook依存
blocking dialog
無制限の外部プロセス起動
許可外filesystem/network access
```

---

## 2. 正本metadata schema

### 2.1 正本schema

TaskSpec / classified task は次のmetadataを持つ。  
この表を正本とする。

| Field | 値域 | 意味 | 導出主体 | 閾値/判定に使う箇所 |
|---|---|---|---|---|
| `TaskKind` | string | 宣言的タスク種別 | Orchestrator / PromptRouter | backend候補 |
| `PlacementEffect` | string | 配置用ラベル | Orchestrator / Runtime | backend候補 |
| `DeclaredEffectClasses` | list | 自己申告EffectClass | Planner / LLM / Tool | UI説明・初期分類 |
| `NBAccessEffectClasses` | list | NBAccess用EffectClass | NBAccess | security decision |
| `Decision` | Permit / NeedsApproval / Deny / RepairNeeded | NBAccessの最終安全判定 | NBAccess | backend投入可否 |
| `ApprovalEligibility` | AutoPermit / AskUserAllowed / HardDeny / RepairRequired | 承認可能性 | NBAccess | permission mode |
| `PreferredBackend` | MainKernelAsync / SubkernelAsync / WolframScriptProcess / FinalActionQueue | 希望backend | Planner / user | 最終決定ではない |
| `SelectedBackend` | 同上 | 最終backend | Orchestrator | executor選択 |
| `DataSize` | Small / Medium / Large / Huge / Unknown | ワークロード全体の規模 | Planner / Runtime | WolframScript誘因 |
| `InputDataSize` | Small / Medium / Large / Huge / Unknown | 入力データ規模 | Runtime内省 / TaskSpec | 値渡し可否 |
| `EstimatedResidentBytes` | integer / Unknown | main memory常駐概算 | Runtime内省 | 参考 |
| `EstimatedTransferBytes` | integer / Unknown | WSTP/WXF等の転送概算 | Runtime内省 | 転送閾値 |
| `EstimatedMaterializationBytes` | integer / Unknown | materialize概算 | Runtime内省 | materialize可否 |
| `EstimatedOutputBytes` | integer / Unknown | 出力概算 | Runtime / declaration | raw result返却可否 |
| `DataTransferRisk` | Low / Medium / High / Prohibitive / Unknown | 転送リスク | Runtime | transfer-safe |
| `MainKernelBlockingRisk` | Low / Medium / High / Unknown | main kernel停止リスク | Runtime / Orchestrator | main実行可否 |
| `FrontEndBlockingRisk` | Low / Medium / High / Unknown | FEロックリスク | Runtime / Orchestrator | UI起点制御 |
| `FileSystemConflictRisk` | Low / Medium / High / Unknown | ファイル競合リスク | Orchestrator | lock/unique dir |
| `ResourceContentionRisk` | Low / Medium / High / Unknown | CPU/RAM/I/O競合 | Orchestrator | concurrency |
| `MasterCallbackRisk` | Low / Medium / High / Unknown | master callback過多 | Runtime内省 | subkernel可否 |
| `AbortRecoveryRisk` | Low / Medium / High / Unknown | abort後残留リスク | Orchestrator | cleanup必須 |
| `ReferencesMainKernelSymbols` | True / False / Unknown | main symbol値捕捉 | Runtime内省 | transfer-safe |
| `ReferencedSymbols` | list | 参照symbol | Runtime内省 | confidential照合 |
| `MainMemoryResident` | True / False / Unknown | main memory resident | Runtime内省 | transfer-safe |
| `RequiresVariableCapture` | True / False / Unknown | 値捕捉が必要 | Runtime内省 | transfer-safe |
| `CanPassByReference` | True / False / Unknown | ref渡し可能 | Planner / Runtime | WolframScript可否 |
| `CanRecomputeInTarget` | True / False / Unknown | targetで再計算可能 | Planner | Recipe可否 |
| `MaterializationRequired` | True / False | materialize要否 | Planner | net構築 |
| `MaterializationTarget` | None / WXFRef / SourceVaultRef / EncryptedBundle / Recipe / Streaming | 正規化先 | Planner | runner入力 |
| `TransferApproval` | NotRequired / Required / Denied | 転送承認 | NBAccess / Orchestrator | workflow pre-approval |
| `UsesDynamic` | True / False / Unknown | Dynamic起点 | Runtime内省 | FE risk |
| `UsesDialog` | True / False / Unknown | dialog使用 | Runtime内省 / lint | headless禁止 |
| `UsesNotebookIO` | True / False / Unknown | Notebook操作 | Runtime内省 | headless禁止 |
| `UsesDistributeDefinitions` | True / False / Unknown | 定義配布 | Runtime内省 | kernel copy |
| `UsesSharedVariable` | True / False / Unknown | SetSharedVariable | Runtime内省 | master callback |
| `UsesSharedFunction` | True / False / Unknown | SetSharedFunction | Runtime内省 | master callback |
| `UsesRunProcess` | True / False / Unknown | 同期外部process | Runtime内省 | main blocking |
| `UsesStartProcess` | True / False / Unknown | 非同期外部process | Runtime内省 | external process |
| `UsesLaunchKernels` | True / False / Unknown | 追加kernel起動 | Runtime / runner manifest | resource contention |
| `WolframScriptLaunchesSubkernels` | True / False / Unknown | runner内LaunchKernels | manifest / lint | kernel budget |
| `EstimatedKernelCopies` | integer / Unknown | 実コピー数見積り | Orchestrator | aggregate memory |
| `AggregateWorkerResidentBytes` | integer / Unknown | worker合計常駐概算 | Orchestrator | subkernel可否 |
| `EstimatedMasterCallbacks` | integer / Unknown | master callback回数 | Runtime | subkernel可否 |
| `HeadlessSafe` | True / False / Unknown | headless実行可能 | NBAccess / Runtime | WolframScript可否 |
| `AbortCleanupRequired` | True / False | cleanup必須 | Orchestrator | cleanup policy |

### 2.2 非推奨・別名

以下は後方互換の別名としてのみ扱う。

```text
EstimatedInputBytes:
  deprecated alias of EstimatedTransferBytes

TransferCost:
  deprecated alias of DataTransferRisk
```

新規実装では `EstimatedTransferBytes` と `DataTransferRisk` を使う。

### 2.3 DataSize と InputDataSize の区別

```text
DataSize:
  ワークロード全体・処理規模の大きさ。
  WolframScriptProcessを選ぶ誘因。

InputDataSize:
  入力データの転送サイズ。
  Subkernel/WolframScriptへ値渡しできるかの判定。
```

`DataSize -> Large` はWolframScriptを選ぶ誘因であり、巨大inputを値渡ししてよいという意味ではない。

### 2.4 転送サイズ閾値

閾値は `EstimatedTransferBytes` または `EstimatedMaterializationBytes` に適用する。  
`ByteCount` そのものではない。

```wl
$ClaudeTaskPlacementDataSizeLimits = <|
  "SubkernelAutoTransferBytes" -> 10*1024^2,
  "SubkernelApprovalTransferBytes" -> 100*1024^2,
  "WolframScriptInlineInputBytes" -> 10*1024^2,
  "RequireReferenceAboveBytes" -> 100*1024^2,
  "HardDenyValueTransferAboveBytes" -> 1024^3
|>;
```


### 2.5 v7で追加・復元するschema field

以下は §2.1 の正本schemaに正式追加する。実装上は §2.1 の表へ統合されたものとして扱う。

| Field | 値域 | 意味 | 導出主体 | 閾値/判定に使う箇所 |
|---|---|---|---|---|
| `EstimatedRuntimeSeconds` | number / Unknown | 推定実行時間 | Runtime / Planner | UI起点preemptive禁止 |
| `RequestedWolframScriptKernels` | integer / Unknown | WolframScript側で要求する追加kernel数 | Manifest / lint | kernel budget |
| `UsesSharedFiles` | True / False / Unknown | 共通file/cache/log/settingsを触る | Planner / lint | file conflict |
| `RequiresFileLocks` | True / False | lock/atomic rename必須 | Orchestrator | file conflict mitigation |
| `CredentialRefs` | list | secret本体ではないcredential参照 | Planner / AccessSpec | runner credential解決 |
| `SecretRefs` | list | secret参照 | Planner / AccessSpec | secret handling |
| `ConfidentialHandling` | `EncryptedBundle` / `ReferenceOnly` / `Redacted` / `PlaintextDebug` | 機密入出力の保存方式 | NBAccess / Orchestrator | job I/O policy |
| `Idempotent` | True / False / Unknown | retryしても副作用が重複しないか | Planner / handler | retry policy |
| `Checkpointable` | True / False / Unknown | checkpoint/resume可能か | Planner / handler | retry policy |
| `RetryPolicy` | Association | retry回数・checkpoint要件 | Workflow transition | retry/checkpoint |
| `Attempt` | integer | retry attempt番号 | Orchestrator | retry/checkpoint |
| `CheckpointRef` | ref / None | checkpoint保存先 | runner / Orchestrator | retry/checkpoint |
| `ErrorRef` | ref / None | terminal failure detail参照 | runner / Orchestrator | Failed payload |
| `FailureSummaryRef` | ref / None | terminal failure要約参照 | runner / Orchestrator | Failed payload |
| `AllowedDirectories` | list | scoped filesystem対象 | AccessSpec | NBAccess I/O guard |
| `AllowedNetworkTargets` | list | scoped network対象 | AccessSpec | NBAccess network guard |
| `AllowedExternalCommands` | list | scoped external command対象 | AccessSpec | runner launch許可 |
| `MayAccessFileSystem` | enum | filesystem権限 | AccessSpec | NBAccess I/O guard |
| `CleanupPolicy` | Association | abort/temporary/secret cleanup | Orchestrator / manifest | cleanup |
| `JobDirectoryPolicy` | Association | durable job root / retention | Orchestrator / manifest | job lifecycle |

`EstimatedInputBytes` は引き続き非推奨aliasであり、正本は `EstimatedTransferBytes` である。`TransferCost` は非推奨aliasであり、正本は `DataTransferRisk` である。

---

## 3. 実行先選択フロー

workflowへ投入された処理は、次の順で実行先が決まる。

```text
1. Orchestrator / PromptRouter が宣言的 TaskSpec を作る。
2. held exprを持つtaskだけ、main kernelでdispatch前に軽量内省する。
3. Runtime分類器が補助分類する。
4. NBAccess が NBValidateAction / NBValidateHeldExpr で安全判定する。
5. scoped permit / permission mode / workflow pre-approval を適用する。
6. データ転送・出力転送・confidential・FE riskを評価する。
7. Orchestrator がPetri net transitionとresource placeを見て実行可能性を判定する。
8. backendを選ぶ。
9. executorへ投入する。
```

重要:

```text
分類器は助言的。
NBAccess Decisionが安全性の正本。
Orchestratorが最終的な配置と実行順序を決める。
```

---

## 4. MainKernelAsync / FinalActionQueue

### 4.1 Main側に残すもの

```text
RequiresFrontEnd -> True
RequiresNotebookObject -> True
ApprovalUI
FinalActionQueueTick
NotebookMutation
DesktopAction
軽量Notebook notice
現在のNotebook/Selectionに依存する処理
UI起点で事前承認や認証を行う処理
```

FrontEndブロックリスクがあるものは、直接同期実行せずFinalActionQueueへ送る。

### 4.2 UI起点・preemptive link規則

`Dynamic`, `Manipulate`, `Button`, `ActionMenu`, `EventHandler`, palette等から起動される処理は、推定実行時間が1〜2秒を超える場合、preemptive linkで直接実行してはならない。

```text
UI起点
  + EstimatedRuntimeSeconds > 1〜2
  -> FrontEndBlockingRisk = High
  -> direct preemptive execution 禁止
  -> Queued / async dispatch / external executor へ逃がす
```

`Method -> "Queued"` はpreemptive lock回避には有効だが、main linkを占有し得る。重い処理はSubkernelまたはWolframScriptへ逃がす。

### 4.3 blocking dialog禁止

次は自動workflow、subkernel、WolframScript runner、headless external executorで禁止する。

```wl
DialogInput
ChoiceDialog
Input
InputString
AuthenticationDialog
```

承認・認証はdispatch前にmain FE上で完了させる。

```text
NeedsApproval:
  main FEで承認

Authentication:
  main FEでcredential-refを確立

runner/subkernel:
  blocking dialog禁止
```

### 4.4 FE依存操作のheadless禁止

次はSubkernel/WolframScriptへ配置しない。

```wl
NotebookGet
NotebookWrite
NotebookPut
FrontEndExecute
FrontEndTokenExecute
SelectionMove
CurrentValue[$FrontEnd, ...]
UsingFrontEnd
CreateDocument
NotebookPrint
```

WolframScript taskにこれらが含まれる場合:

```text
HeadlessSafe -> False
SelectedBackend -> FinalActionQueue or MainKernelAsync
```

---

## 5. SubkernelAsync

### 5.1 選択条件

SubkernelAsyncに選ばれるもの:

```text
FrontEnd不要
NotebookObject不要
副作用なし
入力・出力がserializable
transfer-safe
短〜中程度のCPU bound
confidential raw cross-kernel serialization不要
巨大main-memory resident dataを値捕捉していない
EstimatedOutputBytesがraw返却可能範囲
MasterCallbackRiskがLow
```

### 5.2 Subkernelへ自動送信してはならない条件

```text
ReferencesMainKernelSymbols -> True
InputDataSize -> Large | Huge
EstimatedTransferBytes > SubkernelAutoTransferBytes
TransferCost/DataTransferRisk -> High | Prohibitive | Unknown
RequiresVariableCapture -> True
CanPassByReference -> False
ReferencedSymbols ∩ ConfidentialSymbols != ∅
EstimatedOutputBytes -> Large | Huge
UsesSharedVariable / UsesSharedFunction with high callback frequency
UsesDistributeDefinitions with AggregateWorkerResidentBytes over threshold
```

### 5.3 DistributeDefinitions

`DistributeDefinitions[symbol]` は、値や各種Valuesも配布し得る。巨大symbolを配ると、カーネル数分のコピーが発生する。

```wl
EstimatedKernelCopies = Length[Kernels[]]
AggregateWorkerResidentBytes = EstimatedTransferBytes * EstimatedKernelCopies
```

`EstimatedKernelCopies` はslot上限ではなく、実際に起動済みのworker kernel数を基準にする。

閾値超過時:

```text
DistributeDefinitions禁止
worker-local loadへ変換
chunk分割
WolframScript/file-backed化
MainKernelChunked
```

### 5.4 SetSharedVariable / SetSharedFunction

`SetSharedVariable` / `SetSharedFunction` は本物の共有メモリではなくmaster callbackを発生させる。

高頻度callback予測時:

```text
SubkernelAsync不可
Parallelizationをバッチ化
file/log/ref集約へ変更
MainKernelBlockingRisk -> High
```

### 5.5 Subkernel P1 file output

Subkernelが巨大結果をscoped output directoryへ書き、refだけmainへ返すP1設計では、WolframScript outputと同じ要件を継承する。

```text
confidentialならEncryptedBundle / SourceVaultRef
cleanup policy必須
plain output禁止
OutputRefのみworkflow payloadへ入れる
```

---

## 6. WolframScriptProcess / External executor

### 6.1 選択条件

WolframScriptProcessに選ばれるもの:

```text
MailFetch
BulkFileProcessing
BulkLLMProcessing
SourceVaultIngest
NetworkBatch
LongRunningExternalIO
CheckpointableBatch
ExpectedDuration -> Long
DataSize -> Large
多数ファイル
API rate limit / retryが必要
checkpoint/resumeが必要
main kernelを巻き込みたくない
入力がfile/ref/SourceVaultRef/EncryptedBundle/Recipeとして渡せる
```

main kernel上の巨大symbolを直接参照するtaskは、そのままWolframScriptへ送らない。先にMaterializeInput transitionを入れ、値渡しではなく参照渡しへ変換する。

### 6.2 通常のWolframScriptは別process

CLI / external executorで起動されるWolframScriptは、main Mathematica kernelとは別processであるため、通常はMainKernelBlockingRiskは低い。  
ただし次を共有する。

```text
CPU
RAM
swap
disk I/O
GPU
network
file system
license / kernel slots
```

### 6.3 RunProcess禁止

main kernelから `RunProcess` で長時間WolframScriptを呼ぶのは禁止する。

```text
RunProcess[{"wolframscript", ...}]
  -> MainKernelBlockingRisk = High
```

runner起動は `StartProcess` またはExternal executor経由にする。

### 6.4 WolframScript内LaunchKernels

WolframScript内で `LaunchKernels[]` を使う場合、独立したサブカーネル群を起動するものとして扱う。

```text
WolframScriptLaunchesSubkernels -> True
RequestedWolframScriptKernels -> n
ResourceContentionRisk -> evaluate
```

GlobalKernelBudget / license / RAMを超える場合は起動しない。

### 6.5 ファイル競合

WolframScriptは変数を共有しないが、ファイルシステムは共有する。

競合対象:

```text
同じ .nb
同じ .mx / .wxf / .wl / .json / .csv
同じlog
同じcache
Paclet
init.m
設定ディレクトリ
```

必要条件:

```text
unique job dir
lock file
atomic rename
job ID付きファイル名
```

---

## 7. External executor と AwaitingLLM

### 7.1 submit

External transition fire時:

```text
1. NBValidateAction[action, accessSpec]
2. scoped-permit適用
3. job dir作成
4. manifest作成
5. runner起動
6. Status -> AwaitingLLM を返す
```

返り値:

```wl
<|
  "Status" -> "AwaitingLLM",
  "AwaitMeta" -> <|
    "AwaitKind" -> "ExternalWolframScriptJob",
    "JobID" -> jobID,
    "JobDir" -> jobDir,
    "PID" -> pid,
    "Timeout" -> timeout
  |>
|>
```

External jobでは `AwaitingLLMTimeout` を設定しない。  
timeoutはpollerが単独で所有する。

### 7.2 timeout

```text
elapsed > Timeout:
  cancel.flag
  grace period
  pid.json同一性確認
  OS kill
  status.json = Expired
  RetryPolicy or Failed/Expired
```

timeout時に下流tokenを成功produceしてはならない。

### 7.3 output payload

`ClaudeCompleteHandlerOutput` に渡すpayloadには本文をinlineしない。

許可:

```wl
<|
  "Payload" -> <|
    "OutputRef" -> outputRef,
    "SourceVaultRef" -> svRef,
    "SummaryRef" -> summaryRef,
    "JobID" -> jobID
  |>
|>
```

禁止:

```text
メール本文
大量LLM出力本文
ファイル内容
credential
secret
```


### 7.4 poller per-status分岐

External job pollerは `AwaitingLLMTransitions` からExternal jobを列挙し、`status.json` を読む。

```text
status == Running:
  no-op
  slotは保持またはRetryPolicy指定に従う

status == Completed:
  OutputRef / SourceVaultRef / SummaryRefのみをpayloadにして
  ClaudeCompleteHandlerOutput[wid, awaitId, payload] を呼ぶ
  slotを返却する

status == Failed:
  RetryPolicyを評価する
  retry可能なら同一JobDir/checkpointから再開する
  retry不可またはMaxRetries超過ならterminal Failedを伝播する
  slotを返却する

status == Expired:
  timeout処理済みとしてRetryPolicyを評価する
  retry可能なら同一JobDir/checkpointから再開する
  retry不可ならterminal Failed/Expiredを伝播する
  slotを返却する

status == Cancelled:
  terminal Cancelledとして伝播する
  slotを返却する
```

`Failed` / `Expired` は、成功扱いで下流tokenをproduceしてはならない。retryが尽きた場合のみterminal failureを明示的に伝播する。

### 7.5 retry / checkpoint semantics

awaiting中にExternal jobがFailedまたはExpiredになった場合、input tokenを再消費してtransitionを再fireしてはならない。

P0の規則:

```text
同一 AwaitingLLMTransitions entry を維持する
同一 JobDir を使う
CheckpointRef から resume する
Attempt を増やす
slotは一旦返却し、再試行時に再取得する
input tokenは再消費しない
```

`MaxRetries` を超えた場合、初めてworkflowへterminal failureを伝播する。

terminal failure payloadは本文やsecretを含まない。

```wl
<|
  "Payload" -> <|
    "Status" -> "Failed",
    "JobID" -> jobID,
    "ErrorRef" -> errorRef,
    "FailureSummaryRef" -> failureSummaryRef
  |>
|>
```

禁止:

```text
メール本文
LLM prompt/response本文
credential
OAuth token
API key
巨大file内容
```

### 7.6 非冪等taskのretry

`Idempotent -> False` かつ `Checkpointable -> False` のtaskは、自動retry不可とする。

```text
Idempotent -> False
Checkpointable -> False
  -> retry不可
  -> NeedsApproval or terminal Failed
```

MailFetchは一般に安易に `Idempotent -> True` としてはならない。既読フラグ、移動、サーバ状態変化、連番採番、二重取得があり得るためである。

BulkLLMProcessingも、二重課金・二重登録・SourceVault重複ingestの可能性があるため、checkpoint-aware retryを必須にする。

---

## 8. Resource-place concurrency

WolframScript concurrencyはresource-place semaphoreで表現する。

```text
WolframScriptSlots place:
  MaxWolframScriptJobs 個のslot tokenを持つ
```

External transitionのInputArcsにslot tokenを要求する。slot tokenが無ければtransitionはenableされず、input tokenは元placeに留まる。

Subkernelも同様に `SubkernelSlots` を使える。

---

## 9. Metadata内省の適用範囲とコスト上限

### 9.1 適用範囲

巨大データ内省は、held expressionを持つtaskに適用する。

対象:

```text
Subkernel候補
MainKernel候補
held exprを含むMaterializeInput候補
```

対象外:

```text
MailFetch
BulkLLMProcessing
SourceVaultIngest
宣言的ExternalTaskで入力refが明示されているもの
```

宣言的ExternalTaskは、held expr内省ではなく、InputRef / SourceVaultRef / NetworkTarget / Directory scope宣言を正とする。

### 9.2 内省コスト上限

内省自体がmain kernelをブロックしてはならない。

規則:

```text
packed array / known type:
  Dimensions + element size でO(1)概算

未知の巨大候補:
  厳密ByteCountを避け、UnknownまたはHuge扱い

内省時間上限:
  $ClaudeTaskInspectionTimeLimit 秒以内

上限超過:
  InspectionTimedOut
  Unknown safe default
```

P0では、巨大な入れ子式に対する厳密 `ByteCount` を避ける。

---

## 10. MaterializeInput

### 10.1 materializationは万能ではない

main-memory-only Huge objectをWolframScriptへ送るためにWXFやEncryptedBundleへ書き出す操作は、それ自体が重いmain kernel処理である。

```text
main-memory-only Huge dataを別backendへ逃がしても、
materializationが必要ならmain kernel blocking riskは消えない。
```

### 10.2 有効なケース

```text
元データがfile-backedである
外部ソースから再取得・再読込できる
recomputation recipeが使える
chunked / streaming materializationが可能
SourceVaultRefとして既に存在する
```

### 10.3 有効でないケース

```text
main-memory-only
Huge
streaming不可
recompute不可
confidential raw value
```

この場合:

```text
MainKernelChunked
RepairNeeded
ユーザーにfile-backed化を提案
```

### 10.4 事前計画方式

P0では、実行中のworkflow netを動的に改変しない。  
`MaterializationRequired -> True` の場合、plannerがnet構築時に組み込む。

```text
OriginalInputPlace
  -> MaterializeInput transition
  -> MaterializedRefPlace
  -> External WolframScript transition
```

---

## 11. Recipe

`MaterializationTarget -> "Recipe"` は、次を満たす場合だけ使える。

```text
計算が決定的
入力ファイル・外部ソース・パラメータがtarget backendから再現可能
必要なPackage/Paclet/WL versionが一致または許容範囲
乱数seed・時刻依存・環境変数依存が固定
入力hash / recipe hashをtarget側で検証可能
```

Recipe manifest:

```wl
<|
  "Recipe" -> heldOrSerializedRecipe,
  "InputRefs" -> {...},
  "InputHashes" -> {...},
  "PackageVersions" -> {...},
  "RandomSeed" -> ...,
  "WLVersion" -> $VersionNumber
|>
```

---

## 12. TransferApproval / workflow pre-approval

`TransferApproval -> Required` は独自承認経路を持たない。workflow pre-approvalへ統合する。

```wl
<|
  "ApprovedTransfers" -> {
    <|
      "Symbol" -> "big",
      "EstimatedTransferBytesMax" -> 200*1024^2,
      "Purpose" -> "SubkernelAsyncTransfer",
      "WorkflowID" -> wid,
      "ExpiresAt" -> ...,
      "Confidentiality" -> "NonConfidentialOnly"
    |>
  }
|>
```

confidential symbolには `ApprovedTransfers` を使わず、EncryptedBundle / SourceVaultRefのみ許可する。

---

## 13. PolicySnapshot / NBAccess

runnerはsnapshotをglobalへ焼き込まない。AccessSpec経由でper-callに渡す。

```wl
accessSpec = Join[
  manifest["AccessSpec"],
  <|"PolicySnapshot" -> manifest["PolicySnapshot"]|>
];
```

すべての検証にこのAccessSpecを渡す。

```wl
NBValidateAction[action, accessSpec]
NBCheckFileRead[path, accessSpec]
NBCheckFileWrite[path, accessSpec]
NBCheckNetworkAccess[target, accessSpec]
NBCheckExternalProcess[cmd, accessSpec]
```


---

## 13A. NBAccess role既定AccessSpec

`NBMakeRuntimeAccessSpec` に次のroleを追加する。未知roleは黙って最小権限化せず、`UnknownExecutionRole` failureにする。

### 13A.1 SubkernelTask

```wl
<|
  "ExecutionRole" -> "SubkernelTask",
  "ExecutionKernel" -> "SubkernelAllowed",
  "ExecutionBackend" -> "SubkernelAsync",
  "MayUseFrontEnd" -> False,
  "MayWriteNotebook" -> False,
  "MayUseExternalProcess" -> False,
  "MayAccessFileSystem" -> "None",
  "MayUseNetwork" -> False
|>
```

### 13A.2 WolframScriptTask

```wl
<|
  "ExecutionRole" -> "WolframScriptTask",
  "ExecutionKernel" -> "ExternalProcess",
  "ExecutionBackend" -> "WolframScriptProcess",
  "MayUseFrontEnd" -> False,
  "MayWriteNotebook" -> False,
  "MayUseExternalProcess" -> True,
  "MayAccessFileSystem" -> "ScopedReadWrite",
  "MayUseNetwork" -> True | False,
  "AllowedDirectories" -> {...},
  "AllowedNetworkTargets" -> {...},
  "AllowedExternalCommands" -> {"wolframscript-runner"},
  "CredentialRefs" -> {...},
  "SecretRefs" -> {...},
  "ConfidentialHandling" -> "EncryptedBundle" | "ReferenceOnly" | "Redacted"
|>
```

`MayUseExternalProcess -> True` は任意外部process許可ではない。resolved `wolframscript` runner起動専用の限定許可である。

### 13A.3 MainKernelTask

```wl
<|
  "ExecutionRole" -> "MainKernelTask",
  "ExecutionBackend" -> "MainKernelAsync",
  "MayUseFrontEnd" -> False,
  "MayWriteNotebook" -> False,
  "MayUseExternalProcess" -> False,
  "MayAccessFileSystem" -> "None"
|>
```

### 13A.4 FinalAction

```wl
<|
  "ExecutionRole" -> "FinalAction",
  "ExecutionBackend" -> "FinalActionQueue",
  "MayUseFrontEnd" -> True,
  "MayWriteNotebook" -> True,
  "RequiresApproval" -> True
|>
```

## 13B. MayAccessFileSystem enum

`MayAccessFileSystem` はBooleanと文字列を混在させない。次のenumに正規化する。

```text
"None":
  filesystem access不可

"ReadOnly":
  readのみ許可

"ScopedRead":
  AllowedDirectories内のreadのみ許可

"ScopedWrite":
  AllowedDirectories内のwriteのみ許可

"ScopedReadWrite":
  AllowedDirectories内のread/write許可
```

`WolframScriptTask` の標準は `"ScopedReadWrite"` とする。ただし、書き込み先はjobDir/checkpoint/output bundle等に限定する。

## 13C. CredentialRef / SecretRef

manifest/inputに資格情報本体を書かない。

許可:

```wl
"CredentialRefs" -> {"imap-default", "openai-default"}
"SecretRefs" -> {"sourcevault-key-default"}
```

禁止:

```wl
"Password" -> "..."
"APIKey" -> "..."
"OAuthToken" -> "..."
"Secret" -> "..."
```

runnerはsame-user環境でcredential storeまたは `NBGetAPIKey` 相当を呼ぶ。API keyは `NBGetAPIKey` 経由をP0 hard requirementとし、ログ・stdout/stderr・manifest・progressに出してはならない。

credential解決に失敗した場合、runner内でblocking dialogを出さない。`CredentialResolutionFailed` としてFailedにし、main FE側でcredential-ref確立を求める。

## 13D. ConfidentialHandling / degrade mode

暗号化バンドルAPIやSourceVault暗号化が未成熟な場合でも、平文保存に安易に倒さない。`ConfidentialHandling` は次のいずれかである。

```text
"EncryptedBundle":
  暗号化bundleとして保存する。

"ReferenceOnly":
  本文をjob dirへ書かず、SourceVaultRef / external refのみ渡す。

"Redacted":
  progress/log/statusへredacted要約だけを書く。

"PlaintextDebug":
  明示的debug時のみ。標準禁止。
```

標準modeでは `EncryptedBundle`, `ReferenceOnly`, `Redacted` のいずれかを使う。暗号化が間に合わない場合のP0 degradeは `ReferenceOnly` または `Redacted` とする。

### 13D.1 PlaintextDebug gate

`ConfidentialHandling -> "PlaintextDebug"` は以下をすべて満たす場合だけ有効化できる。

```text
$ClaudeAllowPlaintextExternalJobDebug === True
PermissionMode == "DangerFullAccess" または explicit DeveloperDebugMode
user-visible warning を出す
audit log に記録する
job retentionを短くする
```

次のmodeでは拒否する。

```text
ReviewOnly
StrictSafe
InteractiveSafe
WorkflowSafe
```

PlaintextDebugはcredential本体の出力を許可しない。API key / password / token は常にredact対象である。

---

## 14. Scoped permit

`NetworkAccess` / `ExternalProcess` は既定HardDenyである。  
`WolframScriptTask` role + 明示scope + target in scope の場合だけ昇格できる。

```text
NetworkAccess + WolframScriptTask + target in AllowedNetworkTargets:
  InteractiveSafe:
    AskUserAllowed

  WorkflowSafe:
    AskUserAllowed
    or workflow pre-approved scope内なら AutoPermit

  StrictSafe:
    HardDeny
```

任意外部processはHardDeny。runner起動用のresolved `wolframscript` だけ限定許可可能。

---

## 15. AllowedNetworkTargets

標準はhost+port完全一致。

```wl
<|"Scheme" -> "imap", "Host" -> "imap.example.com", "Port" -> 993|>
<|"Scheme" -> "https", "Host" -> "api.openai.com", "Port" -> 443|>
```

HTTP redirect先は接続直前に再度 `NBCheckNetworkAccess` する。  
P0ではhostname+portで判定し、DNS pinningはP1とする。

---

## 16. Runner I/O enforcement

runner内I/O enforcementはcooperativeである。OS sandboxではない。

handler本体で禁止:

```wl
Export[...]
Import[...]
URLRead[...]
URLExecute[...]
StartProcess[...]
Run[...]
OpenWrite[...]
WriteString[...]
DeleteFile[...]
DialogInput[...]
ChoiceDialog[...]
InputString[...]
AuthenticationDialog[...]
```

許可:

```wl
NBCheckedImport
NBCheckedExport
NBCheckedURLRead
NBCheckedFileWrite
NBCheckedFileRead
NBCheckedExternalProcess
```

または実行直前に:

```wl
NBCheckFileRead[path, accessSpec]
NBCheckFileWrite[path, accessSpec]
NBCheckNetworkAccess[target, accessSpec]
NBCheckExternalProcess[cmd, accessSpec]
```

を呼ぶ。

---

## 17. job root / PID / abort recovery

### 17.1 durable job root

External jobはdurable rootに置く。

```text
$UserBaseDirectory/ClaudeRuntime/jobs
```

NotebookDirectoryにはjob実体を置かない。

### 17.2 pid.json

```json
{
  "PID": 12345,
  "Executable": "wolframscript.exe",
  "CommandLineContainsJobID": true,
  "JobID": "...",
  "StartedAt": "...",
  "ProcessStartTime": "...",
  "ManifestHash": "..."
}
```

kill前に同一性を確認する。

### 17.3 hard abort後の孤児回収

Alt+. 等でmain evaluationが中断され、cleanup handlerが走らない場合がある。  
この場合も次回shared tickまたは明示recoveryでjob rootをscanする。

```text
ClaudeExternalJobRecover[]:
  job root scan
  status.json / pid.json確認
  orphan Running job検出
  cancel.flag送出
  必要ならpid同一性確認後kill
```


### 17.4 job directory layout

各External jobは専用job directoryを持つ。

```text
<job-root>/<job-id>/
  manifest.wl
  input.enc | input.ref
  output.enc | output.ref
  status.json
  stdout.log
  stderr.log
  progress.jsonl
  checkpoint/
  cancel.flag
  pid.json
  cleanup.json
```

平文 `input.wxf` / `output.wxf` は標準禁止である。debug時のみ `PlaintextDebug` gateを通す。

### 17.5 manifest schema

manifestにはcredentialや本文を入れない。

```wl
<|
  "JobID" -> jobID,
  "TaskID" -> taskID,
  "WorkflowID" -> wid,
  "CreatedAt" -> DateObject[],
  "Runner" -> runnerPath,
  "Handler" -> "MailFetch" | "BulkLLMProcessing" | ...,
  "InputRef" -> inputRef,
  "OutputRef" -> outputRef,
  "StatusFile" -> "status.json",
  "ProgressFile" -> "progress.jsonl",
  "AccessSpec" -> accessSpec,
  "PolicySnapshot" -> policySnapshot,
  "PermissionMode" -> "WorkflowSafe",
  "CredentialRefs" -> {...},
  "SecretRefs" -> {...},
  "Timeout" -> 3600,
  "RetryPolicy" -> <|
    "MaxRetries" -> 2,
    "RequiresCheckpoint" -> True
  |>,
  "CleanupPolicy" -> <|
    "DeletePlaintext" -> True,
    "RetainLogs" -> "Redacted",
    "RetainJobDirFor" -> Quantity[7, "Days"]
  |>,
  "ConfidentialHandling" -> "EncryptedBundle" | "ReferenceOnly" | "Redacted"
|>
```

禁止:

```text
API key本体
IMAP password本体
OAuth token本体
メール本文平文
LLM prompt/response平文
巨大file本文
```

### 17.6 cleanup policy

job完了・失敗・cancel・abort後に、cleanup policyを適用する。

```text
plaintext temporary削除
credential cache削除
incomplete outputをmark
logs redaction確認
期限付きjob dir cleanup
```

hard abortでcleanupが走らなかった場合は、`ClaudeExternalJobRecover[]` が次回tickまたは明示実行時に `cleanup.json` / `status.json` を参照して回収する。

---

## 18. 実装フェーズ

### Phase 1: 分類器・schema

```text
正本metadata schema実装
held expr内省
内省範囲をsubkernel/main候補に限定
内省時間上限
Unknown safe default
FrontEndBlockingRisk判定
UsesDynamic / UsesDialog / UsesNotebookIO検出
NBValidateAction接続
```

### Phase 2: NBAccess拡張

```text
role追加
AccessSpec schema拡張
scoped permit
PolicySnapshot per-call
AllowedNetworkTargets
blocking dialog禁止lint
```

### Phase 2.5: 暗号化・credential基盤

```text
EncryptedBundle
SourceVaultRef
CredentialRef
PlaintextDebug gate
```

### Phase 3: External executor

```text
Executor -> External
AwaitingLLM接続
AwaitingLLMTimeout不使用
poller-owned timeout
resource-place concurrency
output ref payload
durable job root
pid.json
```

### Phase 3.5: Subkernel executor

```text
Executor -> Subkernel
ParallelSubmit wrapper
NBExecuteHeldExprSubkernelRaw
SubkernelSlots
EstimatedOutputBytes制御
DistributeDefinitions copy estimate
SetSharedVariable/SetSharedFunction検出
```

### Phase 4: runner

```text
WolframScript runner
cooperative enforcement
handler lint
file lock / unique job dir / atomic rename
LaunchKernels resource budget
hard abort orphan recovery
```

### Phase 5: handlers

```text
MailFetch
BulkFileProcessing
BulkLLMProcessing
SourceVaultIngest
checkpoint-aware retry
```

### Phase 6: final action

```text
Notebook反映はFinalActionQueue
OutputRef/SourceVaultRefから必要なsummaryだけ表示
巨大inline出力禁止
```

---

## 19. 受け入れ条件

```text
1. UI起点で1〜2秒超の処理がpreemptive linkで直接実行されない。

2. automated/headless/subkernel/runner経路で DialogInput / AuthenticationDialog 等が呼ばれない。

3. 正本metadata schemaが1箇所にあり、EstimatedInputBytes / TransferCost はdeprecated alias扱いになる。

4. Subkernel条件に transfer-safe が入っている。

5. WolframScript条件に input ref / SourceVaultRef / EncryptedBundle / Recipe が必要条件として入っている。

6. held-expr内省はsubkernel/main候補に限定され、宣言的ExternalTaskは対象外。

7. 内省time limit超過時はUnknown safe defaultになる。

8. DistributeDefinitionsのAggregateWorkerResidentBytesはLength[Kernels[]]等の起動済みworker数基準で計算される。

9. Subkernel P1 file outputはEncryptedBundle/SourceVaultRef/cleanup要件を継承する。

10. hard abort後にClaudeExternalJobRecover[]で孤児external jobを検出・停止できる。

11. EstimatedOutputBytesがLarge/Hugeの結果はNotebookにinline表示されない。

12. NetworkAccess/ExternalProcessはscope内のみ昇格し、scope外はDenyされる。


13. awaiting→Failed retryは同一JobDir/checkpointから再開し、input tokenを再消費しない。

14. MaxRetries超過時のterminal Failed payloadは ErrorRef / FailureSummaryRef のみを含み、本文・secretを含まない。

15. Idempotent -> False かつ Checkpointable -> False のtaskは自動retryされない。

16. manifest/input/status/progress/stdout/stderrにcredential本体が残らない。

17. CredentialRefsはrunner側でcredential storeまたはNBGetAPIKey相当から解決される。

18. PlaintextDebugはDangerFullAccessまたはDeveloperDebugMode以外で拒否される。

19. ConfidentialHandlingがEncryptedBundle未対応の場合でも、ReferenceOnlyまたはRedactedでP0運用できる。

20. WolframScriptTask roleの既定AccessSpecがMayUseExternalProcess/AllowedDirectories/AllowedNetworkTargets/AllowedExternalCommands/CredentialRefs/ConfidentialHandlingを持つ。

21. MayAccessFileSystemはNone/ReadOnly/ScopedRead/ScopedWrite/ScopedReadWriteに正規化される。

22. job directoryはmanifest.wl, input.enc|ref, output.enc|ref, status.json, progress.jsonl, checkpoint/, cancel.flag, pid.jsonを持つ。

23. pollerはRunning/Completed/Failed/Expired/Cancelledを分岐し、Failed/Expired時にRetryPolicyへ接続する。
```

---

## 20. 最終判断

v7を実装用正本とする。

v7で確定する主要原則:

```text
Runtime:
  分類器のみ

Orchestrator:
  Petri net workflow / executor / job lifecycle

NBAccess:
  hard safety boundary / scoped permit / per-call snapshot

Subkernel:
  serializableかつtransfer-safeな純粋計算のみ

WolframScript:
  長時間・外部I/O・大量batchをref/EncryptedBundle/Recipeで処理

Main/FinalAction:
  FE/Notebook/承認/認証/軽量notice

UI起点:
  preemptive長時間実行禁止

blocking dialog:
  headless/subkernel/runner/automated workflowで禁止

巨大main-memory data:
  自動転送禁止。ref化・recipe・chunked・RepairNeededへ倒す。

Unknown:
  安全側に倒す。
```

これにより、ClaudeOrchestratorの既存Petri net / AwaitingLLM / NBAccessを土台に、MainKernelAsync / SubkernelAsync / WolframScriptProcess の3系統分離を実装フェーズへ進められる。
