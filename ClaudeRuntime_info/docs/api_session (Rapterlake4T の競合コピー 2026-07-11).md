# ClaudeRuntime_session API リファレンス

## 概要
`ClaudeRuntime`Session`` は RuntimeSession episode 層の Runtime 側 facade (§12) と in-kernel backend (§8.2 ClaudeRuntimeInKernel) を実装する。現行スコープは Inc4a + Inc6。

- adapter factory registry (§12.1)
- control event journal (§12.5: 発行前 durable 保存、EventSeq は attempt 内単調増加)
- session facade (Open/StartEpisode/Poll/Command/Stop/Info/Result)
- §8.1 backend protocol 実装 (ClaudeRuntimeSessionBackendSpec[])
- Inc6: tool effect journal (Prepared/Committed) + checkpoint/resume

adapter factory は2モードを返す。
- `"Compute"`: 1-turn 純計算 episode。headless 検証可。turn 内で閉じる純関数実行が対象 (runtime-orchestrator-boundary)。
- `"ClaudeRuntime"`: `CreateClaudeRuntime` + `ClaudeRunTurn` を包み、既存 AwaitingApproval (proposal 粒度) を ApprovalRequired event (§12.2) に変換する。実 turn は ClaudeCode` 環境 (NB) で検証する。

依存規則 (§22): `ClaudeRuntime_session` → `ClaudeRuntime` (public API のみ)。`ClaudeOrchestrator` への依存は禁止 (event hash は §7.9 canonical 算法を自己完結に実装し、orchestrator 側 `ClaudeSessionEventHash` との一致は cross-implementation テストで保証する)。

Inc4b (未実装、ClaudeRuntime.wl 本体側の改修が必要):
- tool 単位 pre-execution approval gate (ToolCallId scoped)
- BudgetInterrupt suspend / versioned grant / resume
- routine/boundary checkpoint export の全機能 (Inc6 で一部実装済み)

## Facade / セッションライフサイクル

### ClaudeRegisterRuntimeAdapterFactory[name, fn]
adapter factory を名前で登録する (§12.1)。
`fn[startSpec]` は次のいずれかを返す関数:
`<|"Mode"->"Compute", "Compute"->fn2|>` (`fn2[startSpec]` が結果を返す)、または
`<|"Mode"->"ClaudeRuntime", "Adapter"-><|BuildContext,...|>, "InitialInput"->_|>`。
checkpoint からの resume 時も同名 factory で再構築される (§7.5)。

### ClaudeRuntimeAdapterFactories[] → {name...}
登録済み adapter factory 名の一覧を返す。

### ClaudeRuntimeOpenSession[startSpec] → sessionId
session 状態を作成し sessionId を返す (§12.1)。この時点ではまだ episode を開始しない。

### ClaudeRuntimeStartEpisode[sessionId]
adapter factory を解決して episode を開始する。Compute モードは同期実行し terminal event まで journal に積む。ClaudeRuntime モードは `CreateClaudeRuntime` + `ClaudeRunTurn` を起動し、以後の event は poll 時に harvest する。

### ClaudeRuntimeSessionPoll[sessionId, cursor] → {event...}
`cursor` (`<|Attempt, EventSeq|>`) 以降の control event を返す (§12.1)。ClaudeRuntime モードでは runtime 状態を harvest してから返す。

### ClaudeRuntimeSessionCommand[sessionId, command]
SessionCommand を冪等に受理する (§7.8)。
CommandId が既知なら dedup。Attempt 不一致は `Rejected(StaleAttempt)`。`ExpectedAfterEventSeq` 不一致は `Rejected(StaleContext)`。Cancel コマンドのみ stale context チェックを免除される。

### ClaudeRuntimeStopSession[sessionId, reason]
runtime を cancel し、Cancelled event を journal に積んで session を閉じる。

### ClaudeRuntimeSessionInfo[sessionId] → Association
session の状態 summary を返す。

### ClaudeRuntimeSessionResult[sessionId] → Association
Compute/ClaudeRuntime episode の最終結果 (redacted) を返す。event の PayloadRefs は ref のみを運ぶ (I4) ため、本文はこの accessor で取得する。

### ClaudeRuntimeSessionReset[]
facade の内部状態 (全 session / start 冪等 index) をクリアする。durable journal/checkpoint file は残る (kernel crash の模擬にも使える)。テスト用。

## Backend protocol (§8.1)

### ClaudeRuntimeSessionBackendSpec[] → Association
§8.1 契約の in-kernel backend Association を返す (ClaudeRuntimeInKernel)。ClaudeOrchestrator 側の `ClaudeRegisterRuntimeSessionBackend` に渡して使う。wiring は claudecode.wl / テスト側が行い、本ファイルは ClaudeOrchestrator に依存しない。

## Tool effect journal / checkpoint / resume (Inc6)

### ClaudeRuntimeSessionToolJournal[sessionId] → {entry...}
tool effect journal (§15.3: Prepared/Committed) を返す。gate Permit 時に Prepared として記録され、実行結果が確定すると Committed へ durable に更新される。実行が失敗/不確定な tool は Prepared のまま残り、自動 resume を塞ぐ (I9)。

### ClaudeRuntimeSessionCheckpoint[sessionId, opts] → <|"CheckpointRef"->path, "Manifest"->manifest|>
RuntimeCheckpointManifest (§7.5) を durable に保存する。
Options: `"Kind" -> "Boundary"` (Boundary は CheckpointCreated control event を emit、"Routine" は event を出さない。granularity 条件は §9.6 参照)

### ClaudeRuntimeSessionResumeDecision[checkpointRef] → "ResumeAllowed" | "NeedsRestartApproval"
§15.2/§15.3 の resume 可否判定を返す。Prepared のままの (non-idempotent かもしれない) tool effect が journal に残っていれば `NeedsRestartApproval`、無ければ `ResumeAllowed`。

### ClaudeRuntimeResumeSession[checkpointRef, startSpec, opts] → sessionId
checkpoint から Attempt+1 で新 session を作る (§12.2 resume / §15)。manifest の ContentHash / policy hash / Attempt 連番を検証し、budget counter は manifest から引き継いで後退させない。
Options: `"ApproveRestart" -> False` (True でない限り、journal に Prepared が残る場合は NeedsRestartApproval を返して session を作らない (I9))

## 変数

### $ClaudeRuntimeSessionVersion
型: String
本モジュールのバージョン文字列。

### $ClaudeRuntimeSessionJournalRoot
型: String, 初期値: `$UserBaseDirectory/ClaudeRuntime/session-journal` (未設定時)
control event journal の durable 保存先 root (§12.5)。