# ClaudeRuntime_sessionrunner API リファレンス

## 概要
`ClaudeRuntime\`Session\`` 名前空間の一部 (ClaudeRuntime_session.wl の続き)。RuntimeSession episode の external process backend (§8.2 ClaudeRuntimeExternalProcess) を実装する。

双方向 durable spool を採用する。one-shot job (externalrunner.wl) と異なり長寿命・双方向:
- `inbox/<seq>-<id>.wxf` : Runtime event (runner → orchestrator)。実ファイル名は `<6桁seq>.wxf`
- `outbox/<command-id>.wxf` : SessionCommand (orchestrator → runner)。処理済みは `outbox-processed/<command-id>.wxf` に印を付ける

§8.1 backend 契約 (StartEpisode / PollEvents / SendCommand / Inspect / Recover / Dispose) を実装し、(EpisodeId, Attempt, StartCommandId) による冪等 start、PID identity による誤 kill 防止 (externalrunner.wl の probe/kill seam を再利用)、orphan recovery (reattach/lost)、cancel → grace → pid-verified kill、ref-only manifest/status (secret/prompt/artifact 本文を出さない) を備える。

launcher seam ($ClaudeSessionRunnerLauncher) により、既定では simulator (別プロセスを起こさず spool 実ファイルを駆動、席を消費しない) が使われる。本番では `ClaudeSessionRunnerRealLauncher` を代入して実 wolframscript/カーネル子プロセスが `ClaudeRunSessionFromSpool[spoolDir]` を実行する。backend option `"Launcher"` で per-backend に上書きもできる。

worker seam (IncE): backend option `"WorkerSpec"` (InitFiles + Function 名) を manifest に保存すると、子プロセスの `ClaudeRunSessionFromSpool` は simulator loop の代わりに指定した worker 関数を実行する。任意の長時間作業を episode protocol 上で走らせる口になる。worker は ctx (Emit/PollCommands/CancelRequestedQ 等) 経由で spool と対話する。worker が terminal event を emit せず終了した場合は fail-closed で Failed を emit する。

依存規則: ClaudeRuntime_sessionrunner → ClaudeRuntime (public)。ClaudeRuntime_session の Private helper (iRtEventHash / iRtCanonicalHash / iRtNewId / iRtAtomicExport / iRtWXFImport) を共有 Private として再利用する。ClaudeRuntime → ClaudeOrchestrator への依存は禁止。

ロード順: ClaudeRuntime.wl → ClaudeRuntime_session.wl → ClaudeRuntime_externalrunner.wl (probe/kill seam) → ClaudeRuntime_sessionrunner.wl。

## 変数

### $ClaudeRuntimeSessionRunnerVersion
型: String, 初期値: "v0.2 (Inc9+IncE, 2026-07-12)"
本モジュールのバージョン。

### $ClaudeSessionRunnerRoot
型: String (パス), 初期値: 未設定
external session runner の spool root。未設定時は `$UserBaseDirectory/ClaudeRuntime/session-runners` を使う。spool dir は `<root>/<SessionId>/<EpisodeId>/attempts/<Attempt>`。

### $ClaudeSessionRunnerLauncher
型: Function[<|"SpoolDir"->_, "StartSpec"->_, "RunnerScript"->_|>] → <|"Status"->"Launched"|"Failed", "PID"->_, "Executable"->_|>
初期値: simulator launcher (未設定時のみ設定。席を消費しない)
runner プロセスの起動 seam。テストでは simulator (別プロセスを起こさず spool 実ファイルを駆動する関数) を使う。本番では `ClaudeSessionRunnerRealLauncher` を代入する。backend option `"Launcher"` で per-backend に上書き可能。

### $ClaudeSessionRunnerPristineKernel
型: True | False, 初期値: True (Private 文脈 `ClaudeRuntime\`Session\`` 内、未定義時のみ設定)
True なら RealLauncher は素のカーネル (`wolfram.exe` 等、`-noinit -script run.wls`) を優先して起動する (init.m 経由のクラッシュ回避)。False なら従来の `wolframscript -file run.wls`。

## Backend 構築

### ClaudeRuntimeExternalProcessBackendSpec[opts]
§8.1 契約 (StartEpisode/PollEvents/SendCommand/Inspect/Recover/Dispose) を満たす external process backend (ClaudeRuntimeExternalProcess) を返す。双方向 spool + PID identity + orphan recovery を実装する。`ClaudeRegisterRuntimeSessionBackend` に渡して使う。
→ Association: "ProtocolVersion"->1, "Capabilities"->{"ExternalProcess","ToolLoop","EventReplay","Checkpoint","Resume","Interrupt"}, "StartEpisode", "PollEvents", "SendCommand", "Inspect", "Recover", "Dispose" (各 Function)
Options: "RunnerScript" -> Automatic (simulator の event 台本。script 駆動時に使用。Automatic は <|"Events"->{<|"Type"->"Completed"|>}, "AckCommands"->True, "TerminalOnCancel"->True|>), "WorkerSpec" -> None (None | <|"InitFiles"->{path...}, "Function"->"Context`symbol"|>。子プロセスで実行する worker をデータのみで指定。Function 本体は保存しない), "Launcher" -> Automatic (per-backend launcher。Automatic/None は $ClaudeSessionRunnerLauncher を使用)

backend 契約の戻り値:
- StartEpisode[startSpec] → <|"Status"->"Started"|"AlreadyStarted"|"Failed", "SessionId", "EpisodeId", "HandleRef", "BackendInstanceId", "InitialEventCursor"->, "PIDRef"|>。冪等キーは {EpisodeId, Attempt, StartCommandId}。EpisodeId 欠落は Failed/"MissingEpisodeId"。launcher 失敗は Failed (Reason は launcher の Reason、既定 "LaunchFailed")。
- PollEvents[handle, cursor] → <|"Status"->"OK"|"Lost"|"Unavailable", "Events", "NextCursor"-><|"Attempt","EventSeq"|>, "HeartbeatAt"|>。handle 不明は Lost、Disposed は Unavailable。
- SendCommand[handle, cmd] → <|"Status"->"Accepted"|"AlreadyAccepted"|"Rejected"|"Unavailable", "CommandId", "Reason"|>。CommandId 欠落は Rejected/"MissingCommandId"、cmd の Attempt 不一致は Rejected/"StaleAttempt"、handle 不明は Unavailable/"NoSuchHandle"。outbox に既存なら AlreadyAccepted (冪等)。
- Inspect[handle] → <|"HandleRef","SpoolDir","SessionId","EpisodeId","Attempt","PID","Disposed","Status"|> | Failure["NoSuchHandle", ...]
- Recover[episodeRecord] → <|"Status"->"Reattached"|"LostUnrecoverable", "HandleRef", "ResumedCheckpointRef"|>。in-kernel handle が生きていれば即 Reattached。handle 消失時は episodeRecord の "SessionSpoolRef" (無ければ "SpoolDir") から status/PID identity を検証し、alive かつ identity 一致なら新 handle を登録して Reattached。status が Completed なら LostUnrecoverable/"AlreadyCompleted"。
- Dispose[handle, cleanupPolicy] → <|"Status"->"Disposed"|"AlreadyDisposed"|"Quarantined", "Killed", "Reason"|>。PID identity 検証済みなら kill。identity 不明は kill せず Quarantined (§18.3)。ただし NotAlive かつ直前 status が Completed/Failed/Cancelled/Disposed なら正常終了済みとして Disposed (Killed->False)。

## Runner エントリポイント

### ClaudeRunSessionFromSpool[spoolDir, opts]
runner (子プロセス) の entrypoint。start-spec と runner-script を読み、outbox の command を読みつつ inbox に event を書く loop を回す。manifest に WorkerSpec があれば worker mode (IncE) で動作する: InitFiles を Get し、Function を ctx 付きで実行する。WorkerSpec が無ければ MVP script 駆動 (deterministic) で動作する。script 駆動では terminal か MaxRunSeconds 超過まで outbox を polling する。
→ <|"Status"->"RunnerCompleted", "Mode"->"Worker"|> (worker mode) | <|"Status"->"RunnerCompleted"|> | <|"Status"->"Failed"|> (manifest/script 読込不可。status に "SpoolUnreadable")
Options: "MaxRunSeconds" -> 60 (script 駆動時の wall-clock 上限。超過時 status は "RunnerTimeout"), "PollIntervalSeconds" -> 0.3 (script 駆動時の polling 間隔)

worker mode の失敗:
- InitFiles の Get 失敗/不存在 → Failed event (Reason "WorkerInitFailed") + status Failed
- Function 解決不可 → Failed event (Reason "WorkerFunctionUnresolved")
- abort / 未捕捉 Throw → Failed event (Reason "WorkerException")。message は例外扱いしない
- terminal event 無し終了 → Failed event (Reason "WorkerNoTerminalEvent")
- 終了時 status: 最終 event が Cancelled → "Cancelled"、Failed/EnvironmentLost → "Failed"、他 → "Completed"

ctx (worker に渡される Association) のキー:
- SpoolDir : spool ディレクトリパス
- Manifest : manifest Association
- StartSpec : start spec Association (start-spec.wxf 優先、無ければ manifest から再構成)
- BackendInstanceId : backend instance id
- Emit[type, payloadRefs] : inbox へ event を書き込む
- PollCommands[] : outbox から未処理 command (Association) のリストを取得する
- AckCommand[cid] : CommandAccepted を emit し command を処理済みにする
- CancelRequestedQ[] : 未処理 Cancel command の有無を返す
- WriteStatus[status, extra] : status ファイルを更新する
- CanonicalHash : 共有ハッシュ関数
- NewId : 共有 id 生成関数

worker が terminal event (ArtifactProposed/Completed/Failed/Cancelled/EnvironmentLost) を emit せずに終了した場合は fail-closed で Failed event を emit する。

## テスト/検査用ユーティリティ

### ClaudeSessionRunnerSimulatorTick[spoolDir] → Association
simulator runner を一歩進める (outbox command 処理 + scripted event emit)。テスト用。実プロセス経路では runner 自身が loop するため使わない。
→ <|"Status"->"Ticked", "Emitted"->n, "Terminal"->bool|> | <|"Status"->"NoSim"|> | <|"Status"->"Terminal"|>
script キー: "Events" (template 列: "Type", "PayloadRefs", "BudgetSnapshot"), "AckCommands" (True で CommandAccepted を emit), "TerminalOnCancel" (True で Cancel に Cancelled を emit し terminal)。Completed/Failed/EnvironmentLost の emit で terminal になり status は "Completed"。

### ClaudeSessionRunnerReset[] → Association
runner backend の in-kernel 状態 (handles/starts/sims/real procs) をクリアする。テスト用。spool file は残すため crash 模擬に使える。→ <|"Status"->"Reset"|>

### ClaudeSessionRunnerRealLauncher[spec, opts]
実子プロセスを StartProcess で起動する launcher (IncD)。spec は <|"SpoolDir"->_, ...|>。run.wls bootstrap で本パッケージ群 (ClaudeRuntime.wl / _session / _externalrunner / _sessionrunner) を Get し、解決済み `$ClaudeSessionRunnerRoot` を literal で設定して `ClaudeRunSessionFromSpool[spoolDir, "MaxRunSeconds" -> n]` を実行する。実 PID を pid.wxf に記録する。$ClaudeSessionRunnerLauncher に代入して使う。ライセンス席を消費する (子プロセス1つ)。起動実行体は $ClaudeSessionRunnerPristineKernel が True なら素のカーネル (`-noinit -script`)、それ以外は wolframscript (`-file`)。
→ <|"Status"->"Launched", "PID"->_, "Executable"->_, "BackendInstanceId"->_, "Process"->ProcessObject|> | <|"Status"->"Failed", "Reason"->"NoSpoolDir"|"StartProcessFailed"|>
Options: "PackageDir" -> Automatic (パッケージ .wl の所在。既定は本ファイル所在), "MaxRunSeconds" -> 60 (子 runner の wall-clock 上限)

### ClaudeSessionRunnerInspectSpool[spoolDir] → Association
spool の manifest/status/pid/inbox/outbox 一覧を返す (検査用)。
→ <|"SpoolDir","Manifest","Status","Pid","InboxFiles","OutboxFiles"|>