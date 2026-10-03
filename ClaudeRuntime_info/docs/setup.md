# ClaudeRuntime インストール手順書

macOS/Linux ではパス区切りやシェルコマンドを適宜読み替えてください。

---

## 動作要件

| 項目 | 要件 |
|------|------|
| Mathematica | 13.2 以降（14.x 推奨） |
| OS | Windows 11（64-bit） |
| Anthropic API キー | 必須 |

---

## 依存パッケージ

ClaudeRuntime は以下のパッケージに依存しています。先にインストールしてください。

- **[NBAccess](https://github.com/transreal/NBAccess)** — ノートブックアクセス制御・安全判定 adapter
- **[claudecode](https://github.com/transreal/claudecode)** — LLMGraph DAG スケジューラ・`$Path` 自動設定

### オプションパッケージ

- **[ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator)** — タスク分解・マルチエージェント実行機構。ClaudeRuntime 単体ではプレーンな 1 ターン実行に専念しますが、複数エージェントの協調動作やタスクの自動分解が必要な場合は ClaudeOrchestrator.wl を追加でロードしてください。

---

## インストール手順

### 1. `$packageDirectory` の確認

Mathematica カーネルで以下を実行し、パッケージ格納ディレクトリを確認します。

```mathematica
$packageDirectory
```

出力例: `C:\Users\YourName\Dropbox\Mathematica\MyPackages`

### 2. パッケージファイルの配置

リポジトリから `ClaudeRuntime.wl` を入手し、**`$packageDirectory` 直下**に配置します。

```
$packageDirectory\
  ClaudeRuntime.wl   ← ここに配置
  claudecode.wl
  NBAccess.wl
  ...
```

> サブフォルダには配置しないでください。

### 3. `$Path` の設定

claudecode を使用している場合、`$Path` は自動的に設定されます。手動で設定する場合は次のとおりです。

```mathematica
If[!MemberQ[$Path, $packageDirectory],
  AppendTo[$Path, $packageDirectory]
]
```

**正しい例**（`$packageDirectory` 自体を追加）:

```mathematica
AppendTo[$Path, $packageDirectory]
```

**誤った例**（サブディレクトリを追加しない）:

```mathematica
(* NG: AppendTo[$Path, "C:\\path\\to\\ClaudeRuntime"] *)
```

### 4. パッケージのロード

```mathematica
Block[{$CharacterEncoding = "UTF-8"},
  Needs["ClaudeRuntime`", "ClaudeRuntime.wl"]
]
```

依存パッケージも同様にロードしてください。

```mathematica
Block[{$CharacterEncoding = "UTF-8"},
  Needs["NBAccess`",      "NBAccess.wl"];
  Needs["ClaudeRuntime`", "ClaudeRuntime.wl"]
]
```

タスク分解・マルチエージェント機能を使用する場合は、ClaudeOrchestrator もロードしてください。

```mathematica
Block[{$CharacterEncoding = "UTF-8"},
  Needs["NBAccess`",            "NBAccess.wl"];
  Needs["ClaudeRuntime`",       "ClaudeRuntime.wl"];
  Needs["ClaudeOrchestrator`",  "ClaudeOrchestrator.wl"]
]
```

---

## API キーの設定

ClaudeRuntime は Anthropic API を使用します。claudecode のキー設定手順に従って登録してください。

```mathematica
(* claudecode が提供するキー設定関数で登録する *)
ClaudeSetAPIKey["sk-ant-..."]
```

> キーは安全な場所に保管し、ノートブックにハードコードしないでください。  
> 詳細は [claudecode](https://github.com/transreal/claudecode) の `api-key-handling` ドキュメントを参照してください。

---

## 動作確認

### バージョン確認

```mathematica
$ClaudeRuntimeVersion
```

### 最小動作テスト

```mathematica
(* ダミー adapter を用いた最小構成 *)
adapter = <|
  "BuildContext"      -> ({"テスト入力: " <> ToString[#1]} &),
  "QueryProvider"     -> ({"print[1+1]"} &),
  "ValidateProposal"  -> (True &),
  "ExecuteProposal"   -> (2 &),
  "RedactResult"      -> (# &),
  "ShouldContinue"    -> (False &)
|>;

runtimeId = CreateClaudeRuntime[adapter];
jobId     = ClaudeRunTurn[runtimeId, "テスト"]
```

正常に `runtimeId` と `jobId` が返れば動作しています。

### 状態の確認

```mathematica
ClaudeRuntimeState[runtimeId]
ClaudeTurnTrace[runtimeId]
```

adapter の `QueryProvider` が返す結果に `"Provider"` / `"Model"` キーが含まれている場合、`ClaudeTurnTrace[runtimeId]` に記録される再試行イベントには、その試行回数 (`"Attempt"`) とともに `"Provider"` / `"Model"` の値が併記されます（adapter がこれらを報告しない場合は `Missing["NotReported"]` として記録）。この情報は ClaudeOrchestrator_turnwiki がモデルプロファイル別にトレースを分類する際に使用されます。

---

## プロバイダーエラーの扱い

CLI プロバイダーの応答がエラー本文の場合、ClaudeRuntime は次のように扱います。

- **API エラー**: 応答が `Error: API Error` で始まる場合（例: `400 claude_code_version_too_old`）、エラー本文をそのまま失敗表示に出し、`ClaudeTurnTrace` に `"ProviderFailed"` イベント（`"Error"` と `"RawLength"` を含む）を記録します。失敗の `ReasonClass` は `"ProviderAPIError"` です。`ClaudeEval` の抽出器は `"Error: ..."` として結果を返します。
- **未定義関数の呼び出し**: 定義の無い関数の呼び出しがそのまま返った場合（パッケージ未ロードや関数名の誤り）、失敗は `"UndefinedFunction"` クラス（`Retryable -> True`、`Fatal -> False`）に分類され、理由を添えて修復ターンへ回されます。

どちらも特別な設定は不要です。API エラーが出た場合は、表示されたエラー本文（CLI のバージョン不足など）に従って対処してください。

---

## 実行結果の表示専用フック（`"OnExecutionResult"`）

adapter に任意で `"OnExecutionResult"` キーを追加すると、コード実行が成功したターンごとに生の実行結果 (execResult) を受け取れます。ノートブックに「実際の出力」をそのまま表示したい場合など、LLM に渡る経路とは別に生データが必要なユースケース向けの表示専用フックです。

```mathematica
adapter = <|
  ...,
  "OnExecutionResult" -> Function[{runtimeId, turn, proposal, execResult, redacted},
    (* 例: 生の execResult をノートブックセルに直接出力する *)
    Null
  ]
|>;
```

- **呼び出し元**: `iExecuteAndContinueSyncFinalize`（コード実行が成功した各ターンの末尾）。
- **シグネチャ**: `"OnExecutionResult"[runtimeId, turn, proposal, execResult, redacted]`（`redacted` は `RedactResult` 適用後の値）。
- **既存経路との分離**: LLM に渡る経路（`redacted` → `Messages` → `ContinuationInput`）とは完全に独立しており、このフックへ渡した生の値が runtime state（`ConversationState` やスナップショット）に新たに保存されることはありません。保持が必要な場合は adapter 側で行ってください。
- **省略可能**: `"OnExecutionResult"` を持たない adapter では何も起きません（`iValidateAdapter` の必須キーには含まれません）。
- **戻り値は無視**: フックの戻り値は使用されません。
- **失敗してもターンは止まらない**: フック内で例外が発生しても、ターンの進行には影響しません。

---

## 非同期実行・最終アクションの承認に関する補足

ClaudeRuntime は、`ExecuteProposal` ハンドラが非同期実行を要求した場合（別 OS プロセスでのコード実行、非同期 tool 実行）に対応しています。これらは ClaudeRuntime と NBAccess の連携で安全に進行管理されます。インストール時に特別な設定は不要ですが、以下の点に留意してください。

- 非同期実行が走行中かどうかは `ClaudeRuntimeAsyncActiveQ[]` で確認できます。いずれかの runtime で非同期コード実行または非同期 tool 実行が走行中であれば `True` を返します。NBAccess の `PendingFinalActionQueue`（`NBFinalActionTick`）は、これが `True` の間、FrontEnd をブロックし得る desktop action を実行せず Pending のまま待機します。runtimes が存在しない場合や引数ありで呼び出した場合も安全に `False` を返します。

- 承認 UI（Approve ボタン）側がデスクトップ操作をすでに実行済みの場合は、`ClaudeMarkApprovalConsumed[runtimeId, reason]` で承認待ち状態を消費し、Done に遷移させます（実行ロジックは呼ばれず、二重実行を防ぎます）。`reason` の省略時は `"ConsumedExternally"` が使用されます。

- 承認時の実行パスは以下の 3 段階で決定されます:
  1. **AsyncActive**: `ClaudeRuntimeAsyncActiveQ[]` が `True` のとき — 直接実行すると非同期タスクと競合するため、`ClaudeEnqueueFinalAction` 経由でキューに追加し、安全な隙に実行します。
  2. **FrontEnd ブロックリスクあり**: `ClaudeRuntimeAsyncActiveQ[]` が `False` で、かつ `BlockingRisk` が `MayBlockFrontEnd`、または `ExecutionPlacement` が `DesktopAction`/`FrontEndRequired` のとき — 承認ボタン押下時に即座に同期実行せず、NBAccess の `PendingFinalActionQueue`（`NBFinalActionTick`）経由で安全な隙に実行されます。
  3. **通常ケース**: 上記いずれにも該当しないとき — 承認ボタンの ScheduledTask 内でそのまま同期実行されます。

- 承認後の実行可否判定は、adapter が `ValidateProposal` キーを持つ場合はそれを経由します（NBAccess がロードされている環境では、アダプタ内で `NBValidateHeldExpr` へ委譲済みです）。`ValidateProposal` を持たない adapter では、ClaudeRuntime がインライン blacklist（`$NBDenyHeads` / `$NBApprovalHeads`）を直接確認します。実行は `NBExecuteHeldExpr` に `ApprovalMode -> "UserApproved"` を渡して行われます。

- `Deny` と判定された提案は、承認しても実行されません。ユーザーが Approve ボタンを押しても `NBExecuteHeldExpr` 側で拒否されるため、承認待ちには遷移させず、その場で実行拒否（`Execution refused: Deny`）として記録し、bridge 側で拒否理由のみを表示します。

これらは通常のインストール・最小動作テストでは意識する必要はありません。

---

## トラブルシューティング

| 症状 | 対処 |
|------|------|
| `Needs` でパッケージが見つからない | `$Path` に `$packageDirectory` が含まれているか確認 |
| 文字化けが発生する | `Block[{$CharacterEncoding = "UTF-8"}, ...]` でロードしているか確認 |
| API エラーが返る | API キーが正しく設定されているか確認 |
| 失敗表示に `Error: API Error ...`（例: `claude_code_version_too_old`）が出る | CLI が返した API エラー本文がそのまま表示されています（`ReasonClass` は `ProviderAPIError`）。本文の指示（CLI の更新など）に従ってください |
| `UndefinedFunction: ...` で修復ターンが走る | 定義の無い関数が呼ばれています。必要なパッケージがロードされているか、関数名に誤りがないか確認してください |
| `CreateClaudeRuntime` が失敗する | adapter の全キー（6 個）が揃っているか確認 |
| 承認ボタンを押しても action が実行されない | 非同期実行が走行中の可能性があります。`ClaudeRuntimeAsyncActiveQ[]` を確認し、走行中であれば完了後に再度承認してください |
| 承認しても提案が実行されず拒否される | `Deny` 判定の提案は承認しても実行されません。提案内容が `$NBDenyHeads` に該当していないか確認してください |

---

## 関連リンク

- [ClaudeRuntime リポジトリ](https://github.com/transreal/ClaudeRuntime)
- [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator)
- [NBAccess](https://github.com/transreal/NBAccess)
- [claudecode](https://github.com/transreal/claudecode)