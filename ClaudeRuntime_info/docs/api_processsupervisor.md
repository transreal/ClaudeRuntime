# ClaudeRuntime_processsupervisor API リファレンス

## 概要
外部プロセス spawn を 2 相 manifest 記録付きヘルパ経由にし、poll tick 死亡等で生じる孤児プロセスを決定論的に回収するパッケージ。mail jobs や $iExternalProcs のような「manifest なしで spawn する」構造を閉じることが目的。

設計要点:
- 2 相 manifest: Phase A (PendingSpawn を spawn 前に永続化) → Phase B (StartProcess 後、PID/StartTime で Running 確定) → Phase C (finalize 失敗時は kill + seat release + emit)。どのタイミングで親プロセスが死んでも manifest なしの孤児は生じない。
- PID 再利用ガード: 回収時は PID 生存だけでなく ProcessStartTimeUTC の一致を要求する。不一致 (= 別プロセスが PID を再利用) の場合は kill しない。本パッケージの最重要正しさ要件。
- cleanup 順序は固定: ①SeatToken release → ②archive。release 失敗時は manifest を CleanupFailed のまま残し、次回 reap で再試行する (席リークの追跡可能性を優先)。SeatBroker 側の TTL 失効が最終防衛線。
- manifest 置き場所は $UserBaseDirectory 配下 (Dropbox 外の同期対象外領域)。PID はマシンローカルな値のため。

状態機械:
PendingSpawn -> Running -> Completed | Reaped | Vanished
いずれの状態からも cleanup 失敗時は CleanupFailed に遷移し、再試行対象になる。

Load:
Block[{$CharacterEncoding -> "UTF-8"}, Get["ClaudeRuntime_processsupervisor.wl"]]

## 公開関数

### ClaudeSupervisedStartProcess[cmd, purpose, opts]
StartProcess を 2 相 manifest 記録付きで実行する。
→ <|"Process"->proc, "JobId"->jobId, "Manifest"->path|> | Failure["SpawnFailed"|"SpawnManifestFinalizeFailed", ...]
Options: "DeadlineSeconds" -> 1800 (超過で reap が kill), "DoneMarker" -> None (存在パス指定で正常完了とみなす), "SeatToken" -> None (cleanup 時に ClaudeSeatRelease を呼ぶ), "JobId" -> Automatic, "Persistent" -> False (True の場合は登録のみで回収対象外)

### ClaudeSupervisedComplete[jobId]
正常完了を通知する。対象 manifest の State を Completed とし、cleanup (seat release + archive 移動) を行う。DoneMarker 検出による reap と同一の cleanup 経路を通る。
→ 成功/失敗を表す結果 (cleanup 経路は ClaudeProcessReap と共通)

### ClaudeProcessReap[]
manifest を全走査し孤児を回収する。対象: DoneMarker による完了、プロセス消滅 (Vanished)、deadline 超過による kill、owner kernel 死亡、PendingSpawn の期限切れ、CleanupFailed の再試行。
→ 分類別カウントを返す (Dataset/Association)
カーネル起動時・低頻度 tick・手動呼び出しのいずれからも呼ぶことを想定する。

### ClaudeProcessInventory[]
生存 manifest の一覧を実プロセス照合付きで返す。診断用。
→ Dataset

### ClaudeProcessManifestCounts[]
manifest の State 別件数を返す。OS へのプロセス照会を行わないため高速。
→ Association (State -> 件数)。"Active" キーは非 Persistent の件数を表す。SystemDoctor probe や reap tick の自己解除判定に用いる。