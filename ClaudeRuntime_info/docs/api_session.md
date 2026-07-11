# ClaudeRuntime_session API Reference

## 概要
ClaudeRuntime\`Session\` 名前空間。RuntimeSession episode 層 (仕様: ClaudeOrchestrator_info/design/claude_orchestrator_runtime_session_episode_petri_spec_v0_1.md) の Runtime 側 facade (§12) と in-kernel backend (§8.2 ClaudeRuntimeInKernel) を提供する。

現行スコープは Inc4a + Inc6:
- adapter factory registry (§12.1)
- control event journal (§12.5: 発行前 durable 保存、EventSeq は attempt 内単調増加)
- session facade (§12.1: Open/StartEpisode/Poll/Command/Stop/Info)
- §8.1 backend protocol 実装 ClaudeRuntimeSessionBackendSpec[] ((EpisodeId, Attempt, StartCommandId) 冪等 start / ExpectedAfterEventSeq precondition / Cancel の stale 免除)
- tool effect journal (Prepared/Committed) + checkpoint/resume (Inc6, §15)

adapter factory は2モードを返せる:
- `"Compute"`: 1-turn 純計算 episode (headless 検証可。runtime-orchestrator-boundary: turn 内で閉じる純関数実行は Runtime の領分)。`<|"Mode"->"Compute", "Compute"->fn2|>` を返し、fn2[startSpec] が結果になる。
- `"ClaudeRuntime"`: CreateClaudeRuntime + ClaudeRunTurn を包み、既存 AwaitingApproval (proposal 粒度) を ApprovalRequired event に変換する (§12.2)。`<|"Mode"->"ClaudeRuntime", "Adapter"-><|BuildContext,..|>, "InitialInput"->_|>` を返す。実 turn は ClaudeCode\` 環境 (NB) で検証する。

checkpoint からの resume 時も同名 factory で再構築する (§7.5)。

Inc4b (未実装、ClaudeRuntime.wl 本体の改修待ち): tool 単位 pre-execution approval gate (ToolCallId scoped)、BudgetInterrupt suspend / versioned grant / resume、routine/boundary checkpoint export の一部拡張。

依存規則 (§22): ClaudeRuntime_session -> ClaudeRuntime (public API のみ)。ClaudeOrchestrator には依存しない (event hash は §7.9 の canonical 算法を自己完結に実装し、orchestrator 側 ClaudeSessionEventHash との一致は cross-implementation テストで保証する)。

## Adapter Factory Registry

### ClaudeRegisterRuntimeAdapterFactory[name, fn] → Null
adapter factory を登録する (§12.1)。fn[startSpec] は上記の "Compute"/"ClaudeRuntime" いずれかの Association を返す関数。

### ClaudeRuntimeAdapterFactories[] → {name...}
登録済み adapter factory 名の一覧を返す。

## Session Facade

### ClaudeRuntimeOpenSession[startSpec] → sessionId
session 状態を作り sessionId を返す (§12.1)。まだ episode は開始しない。

### ClaudeRuntimeStartEpisode[sessionId] → Association
adapter factory を解決して episode を開始する。Compute モードは同期実行して terminal event まで journal に積む。ClaudeRuntime モードは CreateClaudeRuntime + ClaudeRunTurn を起動し、以後の event は poll 時に harvest する。

### ClaudeRuntimeSessionPoll[sessionId, cursor] → {event...}
cursor (`<|"Attempt"->_, "EventSeq"->_|>`) 以降の control event を返す (§12.1)。ClaudeRuntime モードでは runtime 状態を harvest してから返す。

### ClaudeRuntimeSessionCommand[sessionId, command] → Association
SessionCommand を冪等に受理する (§7.8: CommandId dedup / Attempt 不一致は Rejected["StaleAttempt"] / ExpectedAfterEventSeq 不一致は Rejected["StaleContext"]、Cancel のみ stale context を免除)。

### ClaudeRuntimeStopSession[sessionId, reason] → Association
runtime を cancel し Cancelled event を journal に積んで session を閉じる。

### ClaudeRuntimeSessionInfo[sessionId] → Association
session の状態 summary を返す。

### ClaudeRuntimeSessionResult[sessionId] → Association
Compute/ClaudeRuntime episode の最終結果 (redacted) を返す。event の PayloadRefs は ref のみを運ぶ (I4) ため、本文はこの accessor で取得する。

## Backend Protocol

### ClaudeRuntimeSessionBackendSpec[] → Association
§8.1 契約の in-kernel backend Association を返す (ClaudeRuntimeInKernel)。ClaudeOrchestrator 側の ClaudeRegisterRuntimeSessionBackend に渡して使う (wiring は claudecode.wl / テスト側が行い、本ファイルは Orchestrator に依存しない)。

## Tool Journal / Checkpoint / Resume (Inc6)

### ClaudeRuntimeSessionToolJournal[sessionId] → {entry...}
tool effect journal (§15.3: Prepared/Committed) を返す。gate Permit 時に Prepared、実行結果で Committed へ durable に更新される。実行が失敗/不確定の tool は Prepared のまま残り、自動 resume を塞ぐ (I9)。

### ClaudeRuntimeSessionCheckpoint[sessionId, opts]
RuntimeCheckpointManifest (§7.5) を durable に保存する。
→ Association (`"CheckpointRef"`: file path, `"Manifest"`: manifest)
Options: "Kind" -> "Boundary" ("Boundary" は CheckpointCreated control event を emit する。"Routine" は event を出さない。granularity 条件は §9.6)

### ClaudeRuntimeSessionResumeDecision[checkpointRef] → Association
§15.2/§15.3 の resume 可否を返す。Prepared のままの (non-idempotent かもしれない) tool effect があれば `"NeedsRestartApproval"`、無ければ `"ResumeAllowed"`。

### ClaudeRuntimeResumeSession[checkpointRef, startSpec, opts]
checkpoint から Attempt+1 で新 session を作る (§12.2 resume / §15)。manifest の ContentHash / policy hash / Attempt 連番を検証し、budget counter は manifest から引き継いで後退させない。journal に Prepared が残る場合は Options で `"ApproveRestart"->True` を明示しない限り `"NeedsRestartApproval"` を返して session を作らない (I9)。
→ Association (sessionId または NeedsRestartApproval 情報)
Options: "ApproveRestart" -> False (Prepared 状態の tool effect が残っていても resume を強行するか)

## Testing

### ClaudeRuntimeSessionReset[] → Null
facade の内部状態 (全 session / start 冪等 index) をクリアする。durable journal/checkpoint file は残る (kernel crash の模擬にも使える)。テスト用。

## Variables

### $ClaudeRuntimeSessionVersion
型: String
本モジュールのバージョン文字列。

### $ClaudeRuntimeSessionJournalRoot
型: String, 初期値: `$UserBaseDirectory/ClaudeRuntime/session-journal`
control event journal の durable 保存先 root (§12.5)。