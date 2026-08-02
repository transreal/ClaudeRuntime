# ClaudeRuntime_sessionrunner API リファレンス

## 概要
`ClaudeRuntime\`Session\`` 名前空間の一部 (ClaudeRuntime_session.wl の続き)。RuntimeSession episode の external process backend (§8.2 ClaudeRuntimeExternalProcess) を実装する。

双方向 durable spool を採用する。one-shot job (externalrunner.wl) と異なり長寿命・双方向:
- `inbox/<seq>-<id>.wxf` : Runtime event (runner → orchestrator)
- `outbox/<command-id>.wxf` : SessionCommand (orchestrator → runner)

§8.1 backend 契約 (StartEpisode / PollEvents / SendCommand / Inspect / Recover / Dispose) を実装し、(EpisodeId, Attempt, StartCommandId) による冪等 start、PID identity による誤 kill 防止 (externalrunner.wl の probe/kill seam を再利用)、orphan recovery (reattach/lost)、cancel → grace → pid-verified kill、ref-only manifest/status (secret/prompt/artifact 本文を出さない) を備える。

launcher seam ($ClaudeSessionRunnerLauncher) により、既定では実 wolframscript が `ClaudeRunSessionFromSpool[spoolDir]` を実行する子プロセスを起動する。テスト時は別プロセスを起こさない simulator に差し替え可能。backend option `"Launcher"` で per-backend に上書きもできる。

worker seam (IncE): backend option `"WorkerSpec"` (InitFiles + Function 名) を manifest に保存すると、子プロセスの `ClaudeRunSessionFromSpool` は simulator loop の代わりに指定した worker 関数を実行する。任意の長時間作業を episode protocol 上で走らせる口になる。worker は ctx (Emit/PollCommands/CancelRequestedQ 等) 経由で spool と対話する。worker が terminal event を emit せず終了した場合は fail-closed で Failed を emit する。

依存規則: ClaudeRuntime_sessionrunner → ClaudeRuntime (public)。ClaudeRuntime_session の Private helper (iRtEventHash / iRtCanonicalHash / iRtNewId / iRtAtomicExport / iRtWXFImport) を共有 Private として再利用する。ClaudeRuntime → ClaudeOrchestrator への依存は禁止。

ロード順: ClaudeRuntime.wl → ClaudeRuntime_session.wl → ClaudeRuntime_externalrunner.wl (probe/kill seam) → ClaudeRuntime_sessionrunner.wl。

## 変数

### $ClaudeRuntimeSessionRunnerVersion
型: String
本モジュールのバージョン。

### $ClaudeSessionRunnerRoot
型: String (パス), 初期値: 未設定
external session runner の spool root。未設定時は `$UserBaseDirectory/ClaudeRuntime/session-runners` を使う。

### $ClaudeSessionRunnerLauncher
型: Function[<|"SpoolDir"->_, "StartSpec"->_, "RunnerScript"->_|>] → <|"Status"->"Launched"|"Failed", "PID"->_, "Executable"->_|>
runner プロセスの起動 seam。既定は実 wolframscript を起動する launcher。テストでは simulator (別プロセスを起こさず spool 実ファイルを駆動する関数) を代入して差し替える。backend option `"Launcher"` で per-backend に上書き可能。

## Backend 構築

### ClaudeRuntimeExternalProcessBackendSpec[opts]
§8.1 契約 (StartEpisode/PollEvents/SendCommand/Inspect/Recover/Dispose) を満たす external process backend (ClaudeRuntimeExternalProcess) を返す。双方向 spool + PID identity + orphan recovery を実装する。`ClaudeRegisterRuntimeSessionBackend` に渡して使う。
→ Backend spec (Association 等)
Options: "RunnerScript" -> Automatic (simulator の event 台本。script 駆動時に使用), "WorkerSpec" -> None (None | <|"InitFiles"->{path...}, "Function"->"Context`symbol"|>。子プロセスで実行する worker をデータのみで指定。Function 本体は保存しない), "Launcher" -> Automatic (per-backend launcher。Automatic は $ClaudeSessionRunnerLauncher を使用)

## Runner エントリポイント

### ClaudeRunSessionFromSpool[spoolDir] → Null
runner (子プロセス) の entrypoint。start-spec と runner-script を読み、outbox の command を読みつつ inbox に event を書く loop を回す。manifest に WorkerSpec があれば worker mode (IncE) で動作する: InitFiles を Get し、Function を ctx 付きで実行する。WorkerSpec が無ければ MVP script 駆動 (deterministic) で動作する。

ctx (worker に渡される Association) のキー:
- SpoolDir : spool ディレクトリパス
- Manifest : manifest Association
- StartSpec : start spec Association
- BackendInstanceId : backend instance id
- Emit[type, payloadRefs] : inbox へ event を書き込む
- PollCommands[] : outbox から未読 command を取得する
- AckCommand[cid] : command を ack 済みにする
- CancelRequestedQ[] : cancel 要求の有無を返す
- WriteStatus[status, extra] : status ファイルを更新する
- CanonicalHash : 共有ハッシュ関数
- NewId : 共有 id 生成関数

worker が terminal event (ArtifactProposed/Completed/Failed/Cancelled/EnvironmentLost) を emit せずに終了した場合は fail-closed で Failed event を emit する。

## テスト/検査用ユーティリティ

### ClaudeSessionRunnerSimulatorTick[spoolDir] → Null
simulator runner を一歩進める (outbox command 処理 + scripted event emit)。テスト用。実プロセス経路では runner 自身が loop するため使わない。

### ClaudeSessionRunnerReset[] → Null
runner backend の in-kernel 状態をクリアする。テスト用。spool file は残すため crash 模擬に使える。

### ClaudeSessionRunnerRealLauncher[spec]
実 wolframscript 子プロセスを StartProcess で起動する launcher (IncD)。run.wls bootstrap で本パッケージ群を Get し `ClaudeRunSessionFromSpool[spoolDir]` を実行する。実 PID を pid.wxf に記録する。$ClaudeSessionRunnerLauncher に代入して使う。ライセンス席を消費する (子プロセス1つ)。
→ <|"Status"->"Launched"|"Failed", "PID"->_, "Executable"->_|>
Options: "PackageDir" -> Automatic (パッケージ .wl の所在。既定は本ファイル所在), "MaxRunSeconds" -> 60 (子 runner の wall-clock 上限)

### ClaudeSessionRunnerInspectSpool[spoolDir] → Association
spool の manifest/status/pid/inbox/outbox 一覧を返す (検査用)。