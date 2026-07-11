# ClaudeRuntime_seatbroker API Reference

## 概要
Wolfram ライセンス席 (controller 4 / subkernel 16、strixhalo128 実測) を単一のアロケータで管理し、席枯渇による wolframscript 起動不能・サービスカーネルの silent 死・ParallelSubmit のフリーズを構造的に防ぐパッケージである。仕様は SourceVault_info/design/system_hardening_operations_guideline/01_seatbroker_spec_v0.2.md。

設計要点 (v0.2):
- Acquire は固定 lock (acquire.lock ディレクトリ、CreateDirectory の原子性) で直列化する。UUID token ファイルの作成自体は entry 書き込みとして原子的だが、token ごとにパスが異なるため相互排他にはならない (レビュー r1 P1-1 で指摘)。
- lock は TTL 30s で stale 破棄する (owner PID が死んでいる場合も破棄対象)。
- ledger entry には TTL が必須。TTL 失効または owner kernel の死亡を reaper が回収し、回収時に SeatLeaked を emit する。**返却漏れが席を恒久占有しないこと**が不変条件。
- 台帳は「実測 ($LicenseProcesses 等) にまだ現れていない spawn 中」の状態を補正するためのもの。spawn 完了後は実測側に現れて二重計上になるため、capacity 計算では若い entry (SpawnGraceSeconds 以内) だけを差し引く。
- 置き場所は $UserBaseDirectory 配下 (Dropbox 外)。席はマシンローカル資源であるため。

ロード:
```
Block[{$CharacterEncoding -> "UTF-8"}, Get["ClaudeRuntime_seatbroker.wl"]]
```
claudecode.wl が先にロードされていれば SeatDenied/SeatLeaked 等を SIEM spool へ emit する。ロードされていなければ emit は no-op になる。

## 関数
### ClaudeSeatAcquire[purpose, opts]
ライセンス席を1つ確保し token association を返す。確保できない場合は Failure を返す (呼び出し側が tick / RetryPolicy で再試行する設計)。
→ Association | Failure["NoSeat" | "SeatBrokerBusy", <|"Deferred"->True, ...|>]
Options: "Pool" -> "Controller" (既定。"Subkernel" も指定可), "Priority" -> 40 (既定の整数優先度。>=90 は Reserve に食い込み可能), "TTLSeconds" -> 600 (既定。失効すると reaper が回収し SeatLeaked を記録する), "JobId" -> _String (ジョブ識別子)
Acquire に成功した呼び出し元は、spawn 失敗時に必ず ClaudeSeatRelease を呼ぶこと (spec 01 §5.1)。

### ClaudeSeatRelease[token] → Success | Failure["UnknownToken"]
確保済みの席を返却する。既に reaper が回収済みの token を渡した場合は Failure["UnknownToken"] を返すが、これは致命エラー扱いにしないこと。

### ClaudeSeatWithSeat[purpose, fn, opts]
席を確保して fn[token] を実行し、終了時 (異常終了含む) に必ず返却する同期スコープ用ラッパ。
→ fn[token] の戻り値 | Failure (確保失敗時。この場合 fn は呼ばれない)
Options: ClaudeSeatAcquire と同じ ("Pool", "Priority", "TTLSeconds", "JobId")

### ClaudeSeatLedger[] → Association
現在の席台帳と実測 free の診断情報を返す。<|"Pools"->..., "Entries"->Dataset|> の形。

### ClaudeSeatReap[] → Association
TTL 失効 / owner kernel 死亡の ledger entry を回収する。回収時は SeatLeaked を SIEM に記録する。
→ <|"Expired"->n, "OrphanOwner"->m|>

## 変数
### $ClaudeSeatPools
型: Association, 初期値: <|name -> <|"CapacityFn":>expr, "Reserve"->n|>, ...|>
プール定義。各プール名 (例: "Controller", "Subkernel") に対して容量算出式 "CapacityFn" と予約席数 "Reserve" を持つ。Controller の Reserve 1 は FE (フロントエンド) 対話用の予約席である。