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
StartProcess を 2相 manifest 記録付きで実行する。spawn 前に PendingSpawn を書き、成功後に Running へ確定する。
→ <|"Process"->proc, "JobId"->jobId, "Manifest"->path|> | Failure["SpawnFailed"|"SpawnManifestFinalizeFailed", ...]
Options: "DeadlineSeconds" -> 1800 (超過すると reap が対象プロセスを kill する), "DoneMarker" -> None (指定パスの存在を正常完了とみなすマーカー), "SeatToken" -> None (cleanup 時に ClaudeSeatRelease を呼ぶための紐付け), "JobId" -> Automatic (未指定時は自動採番), "Persistent" -> False (True の場合は manifest に登録のみ行い reap の回収対象外にする)

### ClaudeSupervisedComplete[jobId] → cleanup結果
正常完了を通知する。対象 manifest を State->Completed にし、DoneMarker 検出時の reap と同一の cleanup 経路 (seat release + archive 移動) を実行する。

### ClaudeProcessReap[] → <|カテゴリ->件数, ...|>
manifest を全走査し孤児プロセスを回収する。分類: DoneMarker 検出による完了、プロセス消滅 (Vanished)、deadline 超過による kill、owner カーネル死亡、PendingSpawn の期限切れ、CleanupFailed の再試行。カーネル起動時・低頻度 tick・手動呼び出しのいずれからも呼べる。

### ClaudeProcessInventory[] → Dataset
生存中の manifest 一覧を、実プロセスの生存照合付きで Dataset として返す。診断用。

### ClaudeProcessManifestCounts[] → <|State->件数, ...|>
manifest の State 別件数を OS 照会なしで高速集計して返す。"Active" は非 Persistent の件数を指す。SystemDoctor probe や reap tick の自己解除判定に使う軽量 API。