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

---

## トラブルシューティング

| 症状 | 対処 |
|------|------|
| `Needs` でパッケージが見つからない | `$Path` に `$packageDirectory` が含まれているか確認 |
| 文字化けが発生する | `Block[{$CharacterEncoding = "UTF-8"}, ...]` でロードしているか確認 |
| API エラーが返る | API キーが正しく設定されているか確認 |
| `CreateClaudeRuntime` が失敗する | adapter の全キー（6 個）が揃っているか確認 |

---

## 関連リンク

- [ClaudeRuntime リポジトリ](https://github.com/transreal/ClaudeRuntime)
- [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator)
- [NBAccess](https://github.com/transreal/NBAccess)
- [claudecode](https://github.com/transreal/claudecode)