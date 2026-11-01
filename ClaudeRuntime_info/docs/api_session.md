# ClaudeRuntime_session API Reference

## 概要
ClaudeRuntime`Session` 名前空間。RuntimeSession episode 層 (仕様: ClaudeOrchestrator_info/design/claude_orchestrator_runtime_session_episode_petri_spec_v0_1.md) の Runtime 側 facade (§12) と in-kernel backend (§8.2 ClaudeRuntimeInKernel) を提供する。

現行スコープは Inc4a + Inc4b(一部) + Inc5 + Inc6 + Inc7 + IncE + IncG/IncI:
- adapter factory registry (§12.1)
- control event journal (§12.5: 発行前 durable 保存、EventSeq は attempt 内単調増加)
- session facade (§12.1: Open/StartEpisode/Poll/Command/Stop/Info)
- §8.1 backend protocol 実装 ClaudeRuntimeSessionBackendSpec[] ((EpisodeId, Attempt, StartCommandId) 冪等 start / ExpectedAfterEventSeq precondition / Cancel の stale 免除 / ReuseEpisode)
- tool 単位 pre-execution gate (§12.4) と budget guard (Inc4b/Inc5, §14)
- tool effect journal (Prepared/Committed) + checkpoint/resume (Inc6, §15)
- Inc10 前提の session reuse 安全ガードと reuse 機構本体 (IncE, §14.5/§16.4/§26.3)

adapter factory は2モードを返せる:
- `"Compute"`: 1-turn 純計算 episode (headless 検証可。runtime-orchestrator-boundary: turn 内で閉じる純関数実行は Runtime の領分)。`<|"Mode"->"Compute", "Compute"->fn2|>` を返し、fn2[startSpec] が結果になる。
- `"ClaudeRuntime"`: CreateClaudeRuntime + ClaudeRunTurn を包み、既存 AwaitingApproval (proposal 粒度) を ApprovalRequired event に変換する (§12.2)。`<|"Mode"->"ClaudeRuntime", "Adapter"-><|BuildContext,..|>, "InitialInput"->_|>` を返す。実 turn は ClaudeCode\` 環境 (NB) で検証する。

checkpoint からの resume 時も同名 factory で再構築する (§7.5)。

tool gate (`ClaudeRuntime`$ClaudeRuntimeToolGate`) と tool result hook (`$ClaudeRuntimeToolResultHook`) は本モジュールのロード時に ClaudeRuntime 側 seam へ注入される。session に紐づかない runtime (逆引きに無い) は Permit 素通し。
- 許可判定: startSpec `Access["AllowedCapabilities"]` (tool 名の明示 allowlist、空 = 全 tool 要承認の fail-closed)。allowlist 外でも NBAccess の ToolCallId scoped permit (one-shot) があれば通す (Inc7, §13.2)。違反は Suspend (`CapabilityNotAllowed`) → ApprovalRequired event。
- budget guard (Inc5, §14.2): `BudgetGrant["HardLimits"]` の `MaxToolCalls` 超過は SuspendBudget (`ToolCalls`)、`MaxCostUSD` があり `UnknownCostPolicy`="Reject" (既定) で `CostEstimateUSD` の無い call は SuspendBudget (`UnknownCost`)。permit 時は ToolCalls を保守的に即時計上し Prepared を durable journal に書く。
- poll 時 harvest が Runtime 状態を control event に変換: BudgetSuspended→BudgetInterrupt、ToolAwaitingApproval→ApprovalRequired (ToolCallId/ToolCallIds 付き)、AwaitingApproval→ApprovalRequired (proposal 粒度、ToolCallId="proposal-<rid>")、Done/Completed/Succeeded→Completed、Failed/Fatal→Failed。

SessionCommand 種別: `GrantScopedApproval` (保留 tool を解禁。NBAccess permit があれば ToolCallId 単位 ApproveScoped、無ければ full Approve。tool 保留でなければ ClaudeApproveProposal)、`GrantBudget` (`BudgetGrant` の Version が現行より大きい場合のみ受理、新しい累積上限を送る。BudgetSuspended なら ClaudeResumeBudget)、`Cancel`。Version が古い GrantBudget は Rejected["StaleBudgetGrantVersion"]。

Inc4b 残 (未実装、ClaudeRuntime.wl 本体の改修待ち): routine/boundary checkpoint export の一部拡張。

依存規則 (§22): ClaudeRuntime_session -> ClaudeRuntime (public API のみ)。ClaudeOrchestrator には依存しない (event hash は §7.9 の canonical 算法を自己完結に実装し、orchestrator 側 ClaudeSessionEventHash との一致は cross-implementation テストで保証する)。

## Adapter Factory Registry

### ClaudeRegisterRuntimeAdapterFactory[name, fn] → Association
adapter factory を登録する (§12.1)。fn[startSpec] は上記の "Compute"/"ClaudeRuntime" いずれかの Association を返す関数。startSpec `Worker["AdapterFactory"]` が name を指す。戻り値は `<|"Status"->"Registered", "Factory"->name|>`。

### ClaudeRuntimeAdapterFactories[] → {name...}
登録済み adapter factory 名の一覧を返す。

## Session Facade

### ClaudeRuntimeOpenSession[startSpec] → Association
session 状態を作る (§12.1)。まだ episode は開始しない。sessionId は startSpec `"SessionId"` (無ければ `ses-<uuid>` を採番)。
→ `<|"Status"->"Opened", "SessionId"->sid|>`。同 id が既存なら `<|"Status"->"AlreadyOpen", "SessionId"->sid|>`。

### ClaudeRuntimeStartEpisode[sessionId] → Association
adapter factory を解決して episode を開始する。Compute モードは同期実行して terminal event まで journal に積む。ClaudeRuntime モードは CreateClaudeRuntime + ClaudeRunTurn を起動し、以後の event は poll 時に harvest する。
→ `<|"Status"->"Started", "SessionId"->_, "Mode"->_|>` / `<|"Status"->"Failed", "Reason"->_|>` (NoSuchSession / UnknownAdapterFactory / InvalidAdapterMode 等) / `<|"Status"->"AlreadyStarted", "SessionId"->_|>` (Status が Open でない場合)。

### ClaudeRuntimeSessionPoll[sessionId, cursor] → Association
cursor (`<|"Attempt"->_, "EventSeq"->_|>`) 以降の control event を返す (§12.1)。ClaudeRuntime モードでは runtime 状態を harvest してから返す。
→ `<|"Status"->("OK"|"Lost"|"Unavailable"), "Events"->{...}, "NextCursor"->cursor, "HeartbeatAt"->_|>`。session 不在は Lost、Disposed は Unavailable。cursor の Attempt 不一致/EventSeq 不正は Events={} で現行末尾の NextCursor を返す。

### ClaudeRuntimeSessionCommand[sessionId, command] → Association
SessionCommand を冪等に受理する (§7.8: CommandId dedup / Attempt 不一致は Rejected["StaleAttempt"] / ExpectedAfterEventSeq 不一致は Rejected["StaleContext"]、Cancel のみ stale context を免除)。
→ `<|"Status"->("Accepted"|"AlreadyAccepted"|"Rejected"|"Unavailable"), "CommandId"->_, "Reason"->_|>`。CommandId 欠落は Rejected("InvalidCommand: missing CommandId")、GrantBudget の Version 不正/非増加は Rejected("StaleBudgetGrantVersion")。受理時は CommandAccepted event、Cancel は更に Cancelled event を積み Status を "Cancelled" にする。GrantScopedApproval の ToolCallId は `command["PayloadRefs"]["ToolCallId"]`。

### ClaudeRuntimeStopSession[sessionId, reason] → Association
runtime を cancel し Cancelled event (Reason 付き、既に terminal なら積まない) を journal に積んで session を閉じる。reason の既定は "Stopped"。
→ `<|"Status"->"Stopped", "SessionId"->_|>` / `<|"Status"->"NoSuchSession"|>`

### ClaudeRuntimeSessionInfo[sessionId] → Association
session の状態 summary を返す。
→ `<|"SessionId","Mode","Status","RuntimeId","EventCount","LastEmittedSeq","AcceptedCommandIds","EpisodeCount","AccumulatedPrivacyLabel","BudgetUsedToolCalls","Disposed"|>`。不在は `Failure["NoSuchSession", <|"SessionId"->_|>]`。

### ClaudeRuntimeSessionResult[sessionId] → Association
Compute/ClaudeRuntime episode の最終結果 (redacted) を返す。event の PayloadRefs は ref のみを運ぶ (I4) ため、本文はこの accessor で取得する。結果が無ければ None。

## Backend Protocol

### ClaudeRuntimeSessionBackendSpec[] → Association
§8.1 契約の in-kernel backend Association を返す (ClaudeRuntimeInKernel)。ClaudeOrchestrator 側の ClaudeRegisterRuntimeSessionBackend に渡して使う (wiring は claudecode.wl / テスト側が行い、本ファイルは Orchestrator に依存しない)。
キー: ProtocolVersion->1, Capabilities->{"ToolLoop","EventReplay","Interrupt","SessionReuse"}, StartEpisode[startSpec], ReuseEpisode[priorHandle, newStartSpec], PollEvents[h, cursor], SendCommand[h, cmd], Inspect[h], Recover[rec], Dispose[h, pol]。
- StartEpisode: (EpisodeId, Attempt, StartCommandId) で冪等。新規は `<|"Status"->"Started","SessionId","EpisodeId","HandleRef","BackendInstanceId","InitialEventCursor","PIDRef"|>`、重複は Status="AlreadyStarted"、EpisodeId 欠落/起動失敗は `<|"Status"->"Failed","Reason"->_|>`。
- ReuseEpisode: ClaudeRuntimeReuseSessionForEpisode + StartEpisode の薄い橋 (IncI)。成功時は Status="Started", Reused->True, EpisodeCount/CarriedToolCalls/AccumulatedPrivacyLabel 付き。priorHandle が文字列でなければ "NoPriorHandle"、不可なら reuse の Status (Ineligible/NotReusableYet/NoSession/Disposed) と Reasons を返し、caller が fresh start に fallback する。
- Recover: HandleRef の session が生存なら "Reattached"、無ければ "LostUnrecoverable"。
- Dispose: runtime を cancel し Disposed->True にする。既に dispose 済み/不在は "AlreadyDisposed"、それ以外は "Disposed"。

## Tool Journal / Checkpoint / Resume (Inc6)

### ClaudeRuntimeSessionToolJournal[sessionId] → {entry...}
tool effect journal (§15.3: Prepared/Committed) を返す。gate Permit 時に Prepared、実行結果で Committed へ durable に更新される。実行が失敗/不確定の tool は Prepared のまま (LastError を記録) 残り、自動 resume を塞ぐ (I9)。
entry: `<|"ToolCallId","Name","Id","Phase","PreparedAt","CommittedAt","ResultRef","LastError"|>`。ResultRef は `rtses://<sid>/tool/<ToolCallId>` (ref のみ, I4)。journal が無ければ {}。

### ClaudeRuntimeSessionCheckpoint[sessionId, opts]
RuntimeCheckpointManifest (§7.5) を `$ClaudeRuntimeSessionJournalRoot/<sid>/checkpoints/ckpt-NNNN.wxf` に durable 保存する (ContentHash 付き)。
→ Association (`"Status"`: "CheckpointCreated"|"RoutineCheckpointed", `"CheckpointRef"`: file path, `"Manifest"`: manifest)。session 不在は `Failure["NoSuchSession", ...]`。
Options: "Kind" -> "Boundary" ("Boundary" は CheckpointCreated control event を emit する。"Routine" は event を出さない。granularity 条件は §9.6)

### ClaudeRuntimeSessionResumeDecision[checkpointRef] → Association
§15.2/§15.3 の resume 可否を返す。Prepared のままの (non-idempotent かもしれない) tool effect があれば `<|"Decision"->"NeedsRestartApproval","PreparedToolCallIds"->{...}|>`、無ければ `<|"Decision"->"ResumeAllowed","CheckpointRef"->_|>`。manifest 読込不可/ContentHash 不一致は `<|"Decision"->"Invalid","Reason"->"UnreadableManifest"|"ContentHashMismatch"|>`。

### ClaudeRuntimeResumeSession[checkpointRef, startSpec, opts]
checkpoint から Attempt+1 で新 session を作る (§12.2 resume / §15)。manifest の ContentHash / policy hash / Attempt 連番を検証し、budget counter は manifest から引き継いで後退させない。journal に Prepared が残る場合は Options で `"ApproveRestart"->True` を明示しない限り `"NeedsRestartApproval"` を返して session を作らない (I9)。
→ Association。成功時 `<|"Status"->"Resumed","SessionId","CarriedToolCalls","Attempt"|>`、Prepared 残存時は ResumeDecision と同形の NeedsRestartApproval。検証失敗は Failure["UnreadableManifest"|"ContentHashMismatch"|"AttemptMismatch"|"PolicyHashMismatch", ...] (startSpec の Attempt は manifest Attempt+1、Access の AccessSpecHash/PolicySnapshotHash は manifest と一致必須)。
Options: "ApproveRestart" -> False (Prepared 状態の tool effect が残っていても resume を強行するか)

## Session Reuse (IncE, Inc10 前提)

### ClaudeSessionReuseEligibleQ[sessionId, newStartSpec] → Association
open session を新 episode に再利用してよいか判定する (Inc10 前提の安全ガード)。全条件 AND で eligible: startSpec `ReusePolicy`=="SameWorkflowSameTrust" (既定 "Never") / 同一 WorkflowId / 同一 AccessSpecHash / 同一 PolicySnapshotHash / Prepared な非冪等 tool effect が残っていない (I9)。session 累積 PrivacyLabel は CarryForward で max を持ち越す (§16.4 taint 単調)。Disposed または Status=="Failed" の session は不可。
→ `<|"Eligible"->_, "Reasons"->{...}, "CarryForward"->_|>`
Reasons: NoSession / SessionNotAlive:<Status> / ReusePolicyNotReusable / DifferentWorkflow / DifferentAccessSpec / DifferentPolicySnapshot / PendingPreparedEffect。CarryForward: `<|"AccumulatedPrivacyLabel"->Max[累積,新], "BudgetUsedToolCalls", "SessionId", "FromWorkflowId"|>` (eligible でなくても「再利用したら持ち越されるもの」を示す)。
本関数は判定のみ。

### ClaudeSessionRaiseAccumulatedPrivacy[sessionId, label] → Real
session の累積 PrivacyLabel を単調に引き上げる (§16.4)。読んだ input/artifact/tool result の最大値へ。下げられない。現在値を返す。session 不在は Missing["NoSession"]。label は数値。

### ClaudeRuntimeReuseSessionForEpisode[sessionId, newStartSpec] → Association
Inc10 本体 = session reuse の機構。Status が "Completed" または "Open" の生きた session を、同一 workflow / 同一 trust domain の次 episode 用に再オープンする。ClaudeSessionReuseEligibleQ の gate を通り、eligible なら per-episode 状態 (RuntimeId/Journal/NextSeq/Result/AcceptedCommands/Emitted/Reservations 等) を reset しつつ、累積の BudgetUsed.ToolCalls と AccumulatedPrivacyLabel は reset せず carry forward する (Inc10 受け入れ)。EpisodeCount を +1 する。物理 session id は維持し (startSpec に SessionId を上書き)、新 BackendInstanceId を採番、Status を "Open" に戻して次の StartEpisode を可能にする。『いつ reuse するか』の判断は Petri net の ReusePolicy (Orchestrator) の領分で、本関数は worker runtime 側の機構のみを提供する。
→ `<|"Status"->("Reused"|"Ineligible"|"NotReusableYet"|"NoSession"|"Disposed"), "SessionId"->_, "EpisodeId"->_, "Attempt"->_, "CarriedToolCalls"->_, "AccumulatedPrivacyLabel"->_, "EpisodeCount"->_, "Reasons"->{...}|>`
Ineligible は Reasons、NotReusableYet は SessionStatus を返す。

## Testing

### ClaudeRuntimeSessionReset[] → Association
facade の内部状態 (全 session / start 冪等 index / runtime→session 逆引き) をクリアする。durable journal/checkpoint file は残る (kernel crash の模擬にも使える)。テスト用。戻り値は `<|"Status"->"Reset"|>`。

## Variables

### $ClaudeRuntimeSessionVersion
型: String, 初期値: `"v0.1 (Inc4a, 2026-07-11)"`
本モジュールのバージョン文字列。

### $ClaudeRuntimeSessionJournalRoot
型: String, 初期値: 未設定 (未設定/空文字列時は `$UserBaseDirectory/ClaudeRuntime/session-journal`)
control event journal の durable 保存先 root (§12.5)。`<root>/<sid>/evt-NNNNNN.wxf` に event、`tool-journal.wxf` に tool journal、`checkpoints/` に manifest を置く。