# api_externalrunner.md — ClaudeRuntime_externalrunner API リファレンス

外部 wolframscript runner / launcher (Phase 4.A)。ClaudeOrchestrator_external_executor_task_placement_spec_v7 Phase 4 のプランビング核。Orchestrator (親) 側に launcher/killer/job dir/manifest を提供し、runner (子プロセス) 側に manifest 駆動の handler 実行を提供する。

Load:
```
Block[{$CharacterEncoding = "UTF-8"}, Get["ClaudeRuntime_externalrunner.wl"]]
```

依存・関連: ClaudeOrchestrator_workflow (External executor フック: $ClaudeExternalJobLauncher / StatusReader / Killer に実体を与える)、ClaudeRuntime、NBAccess (Phase 4.B で I/O guard 適用予定)。

## Runner (子プロセス) エントリポイント

### ClaudeRunTaskFromManifest[jobDir] → status (Association)
runner (子プロセス) のエントリポイント。jobDir 内の manifest.wl を読み、input.wxf を読み、登録済み Handler を実行し、output.wxf と status.json (Completed/Failed) を書く。status.json は atomic write (tmp → rename)。

### ClaudeRegisterExternalTaskHandler[name, fn, opts] → name
External task handler を登録する。fn は `<|"Manifest"->m, "Input"->inputData|>` を受け取り Association を返す。
例: `ClaudeRegisterExternalTaskHandler["Echo", Function[ctx, <|"Result" -> ctx["Input"]|>]]`

## wolframscript / job root 解決

### ClaudeResolveWolframScriptExecutable[] → String (path)
wolframscript 実行ファイルを解決する。優先順: $ClaudeWolframScriptExecutable > Environment["WOLFRAMSCRIPT"] > $InstallationDirectory 近傍 > PATH 上の "wolframscript"。

### ClaudeExternalJobRoot[] → String (dir path)
durable な job root ($ClaudeExternalJobRoot または $UserBaseDirectory/ClaudeRuntime/jobs) を返す。無ければ作成する。

## Launcher / Killer (親側)

### ClaudeExternalWolframScriptLauncher[jobSpec] → Association
job dir を作り manifest/input/run.wls を書き、wolframscript runner を StartProcess で起動する。$ClaudeExternalJobLauncher へ結線して使う。
→ `<|"Status"->"Launched", "JobID"->_, "JobDir"->_, "PID"->_|>`

### ClaudeExternalInProcessLauncher[jobSpec] → Association
job dir/manifest を準備し runner を現在のカーネルで同期実行する (別プロセスを起こさない)。テスト・単一ライセンス環境・短時間タスク用。long-running には使わない (main kernel をブロックする)。

### ClaudeExternalWolframScriptKiller[awaitMeta] → result
起動済み ProcessObject を同一性確認後に終了する。$ClaudeExternalJobKiller へ結線して使う。

## 結線・回復

### ClaudeWireExternalRunner[] → 結線結果
ClaudeOrchestrator`Workflow` の External executor フック ($ClaudeExternalJobLauncher / StatusReader / Killer) を本パッケージの実装へ結線する。

### ClaudeExternalJobRecover[] → {orphanJobs...}
job root を走査し、status が Running だが対応プロセスが生きていない孤児 job を検出する (Phase 4.A は検出のみ、回復本体は未実装)。

## Lint / 出力ハンドリング

### ClaudeLintExternalHandler[HoldComplete[body]] → Association
handler 本体に raw I/O (Export/Import/URLRead/StartProcess/OpenWrite/DeleteFile/DialogInput/AuthenticationDialog 等) が直書きされていないか検査する。handler は NBChecked* / NBCheck* 経由で I/O すべき (v7 §13/§16)。
→ `<|"Clean"->_, "Violations"->{...}|>`

### ClaudeExternalJobSummary[output, completion] → Association
外部ジョブ出力の summary を返す。サイズが $ClaudeExternalInlineLimit 超なら Preview を省く (巨大出力を inline しない)。
→ `<|"Head"->_, "ByteCount"->_, "OutputRef"->_, "Preview"->_|>`

### ClaudeExternalJobFinalAction[completion] → Association
完了 payload の OutputRef を解決し、Notebook へ反映する final action (WriteNotebookCell, summary のみ) を構築して返す。本体は inline せず、反映は FinalActionQueue / 承認経由 (single committer)。
→ `<|"Status"->_, "FinalAction"->_|>`

### ClaudeExternalInlineAllowedQ[bytes] → True | False
出力を Notebook へ inline してよいサイズか ($ClaudeExternalInlineLimit 以下か) を返す。Unknown は安全側 False。

## 変数

### $ClaudeBatchProcessorOverrides
型: Association, 初期値: `<||>`
batch handler (BulkFileProcessing/BulkLLMProcessing/MailFetch/SourceVaultIngest) の per-item processor を差し替える。`handlerName -> Function[{item,idx,ctx}, <|"Status"->"OK"|"Failed", "Result"->_|>]`。実 provider 接続前のテスト・mock 用。

### $ClaudeExternalInlineLimit
型: Integer (bytes), 初期値: 64KB (65536)
Notebook へ inline できる出力 ByteCount の上限。超過時は ref/summary のみ。

### $ClaudeWolframScriptExecutable
型: String | 未設定, 初期値: 未設定
wolframscript 実行ファイルの明示パス。未設定なら自動解決。

### $ClaudeExternalJobRoot
型: String | 未設定, 初期値: 未設定
External job の durable root の明示パス。未設定なら $UserBaseDirectory/ClaudeRuntime/jobs。

## 典型ワークフロー
親 (Orchestrator) 側で結線し、launcher 経由でジョブ起動:
```
ClaudeWireExternalRunner[];
ClaudeRegisterExternalTaskHandler["Echo", Function[ctx, <|"Result" -> ctx["Input"]|>]];
res = ClaudeExternalWolframScriptLauncher[jobSpec];   (* <|"Status"->"Launched", "JobID"->..., "JobDir"->..., "PID"->...|> *)
```
runner (子) 側は run.wls 内で `ClaudeRunTaskFromManifest[jobDir]` を呼び、output.wxf / status.json を書く。