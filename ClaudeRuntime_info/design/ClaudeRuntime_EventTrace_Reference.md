# ClaudeRuntime EventTrace Type / ReasonClass リファレンス

## EventTrace の Type 一覧

### ライフサイクル

| Type | 発生箇所 | 説明 |
|------|----------|------|
| `Created` | CreateClaudeRuntime | Runtime 生成 |
| `StatusChange` | iUpdateStatus | 状態遷移（Running / Done / Failed / AwaitingApproval） |
| `TurnStarted` | ClaudeRunTurn | ターン開始（TurnCount, JobId 付き） |
| `TurnComplete` | iExecuteAndContinue | ターン正常完了 |
| `Cancelled` | ClaudeRuntimeCancel | ユーザーキャンセル |

### Provider（LLM 呼び出し）

| Type | 発生箇所 | 説明 |
|------|----------|------|
| `ContextBuilt` | iStepBuildContext | コンテキスト構築完了 |
| `ProviderLaunched` | iStepQueryProviderAsync | 非同期 CLI プロセス起動 |
| `ProviderQueried` | iStepQueryProvider / collectProvider | LLM 応答受信（Async, ResponseLength 等） |
| `ProviderFailed` | iStepCollectProviderResult | Provider 空応答 |
| `ProviderFatalError` | iStepQueryProvider | 致命的 Provider エラー |
| `AsyncLaunchFailed` | iStepQueryProviderAsync | 非同期プロセス起動失敗 |
| `TransportRetry` | iStepQueryProvider | 通信リトライ（Attempt, Delay） |
| `TransportRetryExhausted` | iStepQueryProvider | リトライ上限到達 |

### Parse / Validation

| Type | 発生箇所 | 説明 |
|------|----------|------|
| `ProposalParsed` | iStepParseProposal | コード提案パース完了（HasProposal, CodeLength） |
| `FormatRetry` | iStepParseProposal | フォーマット修復リトライ |
| `ValidationComplete` | iStepValidateProposal | 検証完了（Decision, Detail） |
| `ValidationMissing` | iStepDispatchDecision | LastValidationResult 未設定のフォールバック |
| `ValidationRepairAttempt` | iStepDispatchDecision | 検証修復試行 |
| `ToolUseDetected` | iStepValidateProposal | ツール使用検出 |

### Dispatch / Execution

| Type | 発生箇所 | 説明 |
|------|----------|------|
| `TextOnlyRepair` | iStepDispatchDecision | テキストのみ応答の修復要求 |
| `TextOnlyResponse` | iStepDispatchDecision | テキストのみ完了 |
| `AwaitingApproval` | iStepDispatchDecision | 承認待ち（NeedsApproval / Deny） |
| `ApprovalGranted` | ClaudeApproveProposal | ユーザー承認 |
| `ExecutionFailed` | iExecuteAndContinue | 式実行失敗 |
| `ResultRedacted` | iExecuteAndContinue | 結果 redact 完了 |
| `ContinuationScheduled` | iExecuteAndContinue | 継続ターンスケジュール |

### Tool Loop

| Type | 発生箇所 | 説明 |
|------|----------|------|
| `ToolsExecuted` | iToolUseAndContinue | ツール実行完了 |
| `ToolContinuationScheduled` | iToolUseAndContinue | ツール結果で継続 |
| `ToolLoopBudgetExhausted` | iToolUseAndContinue | ツールループ上限 |

### Transaction（UpdatePackage）

| Type | 発生箇所 | 説明 |
|------|----------|------|
| `SnapshotCreated` | iTransactionExecute | スナップショット成功 |
| `SnapshotFailed` | iTransactionExecute | スナップショット失敗 |
| `ShadowApplied` | iTransactionExecute | Shadow 適用成功 |
| `ShadowApplyFailed` | iTransactionExecute | Shadow 適用失敗 |
| `StaticCheckPassed` | iTransactionExecute | 静的チェック通過 |
| `StaticCheckFailed` | iTransactionExecute | 静的チェック失敗 |
| `ReloadCheckPassed` | iTransactionExecute | リロードチェック通過 |
| `ReloadCheckFailed` | iTransactionExecute | リロードチェック失敗 |
| `TestsPassed` | iTransactionExecute | テスト通過（Passed 件数付き） |
| `TestsFailed` | iTransactionExecute | テスト失敗（Passed / Failed 件数付き） |
| `TransactionCommitted` | iTransactionExecute | コミット成功 |
| `CommitFailed` | iTransactionExecute | コミット失敗 |
| `RolledBack` | iRollbackAndRepair / Fail | ロールバック実行 |
| `CheckpointSaved` | iSaveCheckpoint | チェックポイント保存 |
| `FullReplanAttempt` | iAttemptFullReplan | 全面再計画試行 |

### Budget

| Type | 発生箇所 | 説明 |
|------|----------|------|
| `BudgetExhausted` | 各所 | 予算上限到達（Budget キーで種別特定） |
| `FatalFailure` | iRecordFatalFailure | 致命的失敗（Detail に ReasonClass 名） |

---

## ReasonClass 一覧

### Retryable（自動リトライ可能）

| ReasonClass | 説明 |
|-------------|------|
| `TransportTransient` | 通信障害（タイムアウト、ネットワークエラー等） |
| `ProviderRateLimit` | レート制限（HTTP 429） |
| `ProviderTimeout` | Provider タイムアウト |
| `ModelFormatError` | LLM 応答のフォーマット不正（コードブロック欠落等） |
| `ValidationRepairable` | 検証失敗（修復可能） |
| `PatchApplyConflict` | パッチ適用の競合 |
| `ReloadError` | パッケージリロードエラー |
| `TestFailure` | テスト失敗 |
| `ExecutionTransient` | 実行時の一時的エラー |

### Fatal（即時停止、リトライ不可）

| ReasonClass | 説明 |
|-------------|------|
| `SecurityViolation` | セキュリティ違反 |
| `ConfidentialLeakRisk` | 機密データの漏洩リスク |
| `ActsForInsufficient` | ActsFor 権限不足（半順序ラベル） |
| `ForbiddenHead` | 禁止 head の使用（`$NBDenyHeads` に該当） |
| `ExplicitDeny` | 明示的拒否 |
| `PolicyFlowViolation` | ポリシーフロー違反 |
| `ReleasePolicyMissing` | リリースポリシー未設定 |

### その他

| ReasonClass | 説明 |
|-------------|------|
| `AccessEscalationRequired` | 承認が必要（`$NBApprovalHeads` に該当、または AutoEvaluate 禁止操作） |
| `ValidationError` | 検証処理自体のエラー（ValidateProposal の例外等） |
| `UserDenied` | ユーザーが承認ダイアログで拒否 |
| `CommitFailed` | Transaction のコミット失敗 |
| `SnapshotFailed` | スナップショット作成失敗 |
| `StaticCheckFailed` | 静的チェック失敗 |
| `None` | 検証通過（Decision = Permit） |
| `UnknownFailure` | 分類不能な失敗 |

---

## Decision 一覧（ValidateProposal の判定結果）

| Decision | 後続処理 | 説明 |
|----------|----------|------|
| `Permit` | 式を実行 | 安全と判定、自動実行 |
| `Deny` | 承認 UI 表示 | 禁止 head 検出。ユーザーに詳細を見せて判断を仰ぐ |
| `NeedsApproval` | 承認 UI 表示 | 承認必要 head 検出、または AutoEvaluate 禁止操作 |
| `TextOnly` | テキスト表示のみ | LLM がコードを提案せずテキストで回答 |
| `ToolUse` | ツール実行 → 継続 | LLM がツール呼び出しを要求 |
| `RepairNeeded` | 修復ターン起動 | フォーマット不正、修復を要求 |

---

## RuntimeState の Status 遷移

```
Initialized → Running → Done
                ↓         ↑
                ↓    (continuation)
                ↓         ↑
                → AwaitingApproval → Running → Done
                ↓                          ↓
                → Failed                   → Failed
```

| Status | 説明 |
|--------|------|
| `Initialized` | 生成直後、未起動 |
| `Running` | ターン実行中 |
| `Done` | 正常完了（continuation 可能） |
| `AwaitingApproval` | ユーザー承認待ち（Deny / NeedsApproval） |
| `Failed` | 失敗（LastFailure に詳細） |

---

## 診断関数

```mathematica
(* 直近の runtimeId *)
$ClaudeLastRuntimeId

(* 状態照会 *)
ClaudeRuntimeState[$ClaudeLastRuntimeId]
ClaudeRuntimeState[$ClaudeLastRuntimeId]["LastFailure"]
ClaudeRuntimeState[$ClaudeLastRuntimeId]["Status"]

(* イベントトレース *)
ClaudeTurnTrace[$ClaudeLastRuntimeId]

(* 会話メッセージ *)
ClaudeGetConversationMessages[$ClaudeLastRuntimeId]

(* DAG ジョブ状態 *)
LLMGraphDAGStatus[ClaudeRuntimeState[$ClaudeLastRuntimeId]["CurrentJobId"]]

(* 全 runtime の一覧 *)
Dataset[KeyValueMap[
  Function[{id, rt},
    <|"RuntimeId" -> id, "Status" -> rt["Status"],
      "TurnCount" -> rt["TurnCount"],
      "LastFailure" -> Lookup[rt, "LastFailure", None]|>],
  ClaudeRuntime`Private`$iClaudeRuntimes]]

(* 失敗した runtime のみ *)
Select[Keys[ClaudeRuntime`Private`$iClaudeRuntimes],
  ClaudeRuntime`Private`$iClaudeRuntimes[#]["Status"] === "Failed" &]
```
