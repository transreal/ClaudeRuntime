# ClaudeRuntime_seatbroker API リファレンス

ライセンス席 (controller/subkernel) を単一アロケータで管理し、席枯渇による wolframscript 起動不能・サービスカーネル silent 死・ParallelSubmit フリーズを防ぐパッケージ。

## 概要

Wolfram ライセンス席は有限資源 (例: strixhalo128 実測で controller 4 / subkernel 16) であり、複数プロセスが無調整に spawn すると枯渇し障害を起こす。本パッケージは:

- Acquire を固定 lock (`acquire.lock` ディレクトリ, `CreateDirectory` の原子性を利用) で直列化する。UUID token ファイル単体の作成では token ごとにパスが異なり相互排他にならないため、lock による直列化が必須。
- lock は TTL 30 秒で stale 破棄する (owner PID が死んでいても破棄される)。
- ledger (台帳) の各 entry は TTL 必須。TTL 失効または owner kernel 死亡時は `ClaudeSeatReap` が回収し `SeatLeaked` を emit する。**返却漏れが席を恒久占有しないこと**が不変条件。
- 台帳は「実測 ($LicenseProcesses 等) にまだ現れていない spawn 中」プロセスの補正用途。spawn 完了後は実測側に現れて二重計上になるため、capacity 計算では若い entry (SpawnGraceSeconds 以内) のみを差し引く。
- 台帳の置き場所は `$UserBaseDirectory` 配下 (Dropbox 外)。席はマシンローカル資源であり同期対象外。

## ロード

```
Block[{$CharacterEncoding = "UTF-8"}, Get["ClaudeRuntime_seatbroker.wl"]]
```

`claudecode.wl` が先にロードされていれば `SeatDenied`/`SeatLeaked` 等を SIEM spool へ emit する。ロードされていない場合、emit は no-op になる。

## 呼び出し規約

Acquire に成功した呼び出し元は、spawn に失敗した場合必ず `ClaudeSeatRelease` を呼ぶこと (spec 01 §5.1)。同期スコープでは `ClaudeSeatWithSeat` を使えば返却漏れを避けられる。

## 関数

### ClaudeSeatAcquire[purpose, opts]
ライセンス席を1つ確保し token association を返す。確保できない場合は `Failure["NoSeat"|"SeatBrokerBusy", <|"Deferred"->True, ...|>]` を返す (呼び出し側が tick/RetryPolicy で再試行する設計)。
→ Association | Failure
Options: "Pool" -> "Controller" (プール名。"Controller" | "Subkernel"), "Priority" -> 40 (優先度整数。90 以上は Reserve 席にも食い込み可能), "TTLSeconds" -> 600 (TTL。失効すると reaper が回収し SeatLeaked を記録), "JobId" -> Automatic (文字列。ジョブ識別子)

### ClaudeSeatRelease[token]
確保済みの席を返却する。
→ True | Failure["UnknownToken", ...]
既に reaper が回収済みの token を渡した場合は `Failure["UnknownToken"]` を返す。これは致命エラー扱いにしないこと (reaper との競合は正常系)。

### ClaudeSeatWithSeat[purpose, fn, opts]
席を確保して `fn[token]` を実行し、終了時 (異常終了含む) に必ず返却する同期スコープ用ラッパ。
→ fn の戻り値 | Failure
確保失敗時は fn を呼ばず `ClaudeSeatAcquire` と同型の Failure を返す。opts は `ClaudeSeatAcquire` と同じ ("Pool", "Priority", "TTLSeconds", "JobId")。

### ClaudeSeatLedger[]
現在の席台帳と実測 free の診断情報を返す。
→ Association (<|"Pools" -> ..., "Entries" -> Dataset|>)

### ClaudeSeatReap[]
TTL 失効または owner kernel 死亡の ledger entry を回収する。回収時は `SeatLeaked` を SIEM に記録する。
→ Association (<|"Expired" -> n, "OrphanOwner" -> m|>)

## 変数

### $ClaudeSeatPools
型: Association, 初期値: <|name -> <|"CapacityFn" :> expr, "Reserve" -> n|>, ...|>
プール定義。Controller プールの Reserve 1 は FE (フロントエンド) 対話用の予約席であり、通常の Acquire では消費されない。