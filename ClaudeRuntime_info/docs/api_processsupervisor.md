# ClaudeRuntime_processsupervisor API Reference

## 概要
外部プロセス spawn を manifest 記録付きヘルパ経由に統一し、poll tick 死亡時にプロセスが漏れる問題を閉じる。State machine: PendingSpawn -> Running -> Completed | Reaped | Vanished。どの状態からも cleanup 失敗時は CleanupFailed に遷移し、次回 reap で再試行される。

2相 manifest 方式:
- Phase A: spawn 前に PendingSpawn を永続化。
- Phase B: StartProcess 実行後、PID/StartTime を記録し Running に確定。
- Phase C: finalize 失敗時は kill + seat release + emit を行う。

これにより、どのタイミングで親カーネルが死んでも「manifest なしの孤児プロセス」は発生しない。

PID 再利用ガード: 回収 (reap) 時は PID の生存確認だけでなく ProcessStartTimeUTC の一致を要求する。不一致の場合は別プロセスが同一 PID を再利用したとみなし kill しない。これが本パッケージの最重要な正しさ要件。

cleanup 順序は固定: ① SeatToken release → ② archive。release 失敗時は manifest を CleanupFailed のまま残置し、次回 reap が再試行する (席リークの追跡可能性を優先する設計)。SeatBroker 側の TTL 失効が最終防衛線となる。

manifest の置き場所は $UserBaseDirectory 配下 (Dropbox 外)。PID はマシンローカルな値であるため同期対象外にしている。

コンテキストは ClaudeRuntime` (BeginPackage["ClaudeRuntime`"])。

ロード:
Block[{$CharacterEncoding -> "UTF-8"}, Get["ClaudeRuntime_processsupervisor.wl"]]

## 関数
### ClaudeSupervisedStartProcess[cmd, purpose, opts]
StartProcess を 2相 manifest 記録付きで実行する。spawn 前に PendingSpawn を書き、成功後に Running へ確定する。cmd は List (例: {"exe", "arg1"})、purpose は String。
→ <|"Process"->proc, "JobId"->jobId, "Manifest"->path|> | Failure["SpawnFailed"|"SpawnManifestFinalizeFailed", ...]
Options: "DeadlineSeconds" -> Automatic (未指定時 1800 秒に解決; 超過すると reap が対象プロセスを kill する), "DoneMarker" -> None (指定パスの存在を正常完了とみなすマーカー), "SeatToken" -> None (cleanup 時に ClaudeSeatRelease を呼ぶための紐付け), "JobId" -> Automatic (未指定時は purpose 由来の英数小文字 + UnixTime + 乱数で自動採番), "Persistent" -> False (True の場合は manifest に登録のみ行い reap の回収対象外にする), "ProcessOptions" -> {} (StartProcess へ渡す追加オプション列。ProcessDirectory / ProcessEnvironment 等)
Failure の詳細: "SpawnFailed" は Phase A の manifest 書き込み失敗または StartProcess 失敗、"SpawnManifestFinalizeFailed" は Phase B の finalize 失敗 (KillSucceeded キーを含む。kill 成功時は manifest 削除、失敗時は CleanupFailed(Step=Kill) で残置)。

### ClaudeSupervisedComplete[jobId] → True | Failure["UnknownJob"|"CleanupFailed", ...]
正常完了を通知する。対象 manifest を State->Completed にし、DoneMarker 検出時の reap と同一の cleanup 経路 (seat release + archive 移動) を実行する。manifest 不在なら Failure["UnknownJob"]、cleanup 失敗なら Failure["CleanupFailed", ...]。

### ClaudeProcessReap[] → <|カテゴリ->件数, ...|>
manifest を全走査し孤児プロセスを回収する。分類: DoneMarker 検出による完了、プロセス消滅 (Vanished)、deadline 超過による kill、owner カーネル死亡、PendingSpawn の期限切れ、CleanupFailed の再試行。カーネル起動時・低頻度 tick・手動呼び出しのいずれからも呼べる。
戻りキー: "Reaped" (kill したジョブ ID のリスト), "Expired", "OrphanOwner", "PendingExpired", "Completed", "Vanished", "CleanupRetried", "Skipped" (Persistent 等で対象外; 件数)。
Persistent は Skipped、CleanupFailed(Step=Kill かつ同一プロセス確認済み)は kill 再試行後に cleanup。読めない/壊れた manifest は削除される。archive は 7 日超過で削除される。呼び出しのたびに SystemDoctor probe 登録を冪等に試みる。
閾値 (内部変数): PendingSpawn 猶予 300 秒, owner kernel 死亡猶予 600 秒 (SpawnedAtAbs 起点)。

### ClaudeProcessInventory[] → Dataset
生存中の manifest 一覧を、実プロセスの生存照合付き Dataset として返す。診断用。列: JobId, State, Purpose, Pid, OwnerKernelPid, CreatedAtUTC, Persistent, ProcessAlive (State=Running のとき PID + StartTime 一致で True/False、それ以外は Missing["NA"])。

### ClaudeProcessManifestCounts[] → <|State->件数, ...|>
manifest の State 別件数を OS 照会なしで高速集計して返す。"Active" は非 Persistent の件数を指す。manifest が無い場合は <|"Active"->0|>。SystemDoctor probe や reap tick の自己解除判定に使う軽量 API。

## 内部動作メモ
manifest 場所: $UserBaseDirectory/ApplicationData/ClaudeRuntime/processes/<JobId>.json、archive は同 archive/<UTC日付>/ 配下。書き込みは temp-rename。
SIEM emit: ClaudeCode`Private`iClaudeDiagEmit がロード済みの場合のみ委譲 (Producer "ClaudeRuntime")。クラス: ProcessCleanupFailed, SpawnFailed, SpawnManifestFinalizeFailed, ProcessVanished, OrphanReaped。
SystemDoctor probe: SourceVault_diagnostics がロード済みなら "SupervisedProcesses" probe を登録 (ロード時 + Reap ごとに冪等)。CleanupFailed が 1 件以上なら Health "Degraded"、それ以外 "OK"。
OS 照会: PowerShell Get-Process による StartTime 取得、kill は taskkill /T /F (Windows 前提)。