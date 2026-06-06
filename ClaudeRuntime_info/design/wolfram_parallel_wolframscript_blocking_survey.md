# Wolfram Language 並列実行・WolframScript 実行におけるデータ受け渡しとブロッキングリスク調査メモ

作成日: 2026-06-05  
対象: Mathematica / Wolfram Language / WolframScript / サブカーネル / フロントエンド連携

## 1. 要約

Mathematica の並列計算は、基本的に **メインカーネルが master / controller、サブカーネルが worker** となる構造である。サブカーネル同士が直接メモリを共有したり、直接データを送り合ったりする設計ではない。標準的なデータの流れは、主に次の形である。

```text
Front End  ←WSTP→  Main Kernel  ←WSTP→  Subkernels
```

また、CLI から起動した通常の `wolframscript -file task.wls` や `wolframscript -code ...` は、Mathematica ノートブックのメインカーネルとは別の WolframKernel プロセスとして動くため、通常は **メインカーネルやフロントエンドを直接ブロックしない**。

ただし、完全に独立しているわけではない。次の経路では影響が出る。

- 同じ PC の CPU / RAM / ディスク I/O / GPU / ネットワークを奪う。
- `RunProcess` で Mathematica から同期的に WolframScript を呼ぶ。
- WolframScript 内で `LaunchKernels[]` して、さらにサブカーネル群を起動する。
- `UsingFrontEnd`, `FrontEndExecute`, `NotebookWrite` などフロントエンド依存処理を使う。
- 同じ `.nb`, `.mx`, `.wxf`, ログ、キャッシュ、設定ファイルを同時に読み書きする。
- WSTPServer などでカーネルプールを共有する。

したがって、実行先選択仕様では、単に「計算が重いか」だけでなく、少なくとも次のリスクを別々に評価すべきである。

```text
DataTransferRisk
MainKernelBlockingRisk
FrontEndBlockingRisk
FileSystemConflictRisk
ResourceContentionRisk
AbortRecoveryRisk
```

## 2. Mathematica の並列計算モデル

Wolfram の並列計算は、公式チュートリアル上も **single master, multiple worker kernels** の分散メモリ型モデルとして説明されている。サブカーネルは別プロセスであり、通常は独立したメモリ空間を持つ。

共有変数や共有関数は、本物の共有メモリではなく、WSTP メッセージ通信の上に実装された **virtual shared memory** である。

したがって、次のように理解するのが安全である。

| やりたいこと | 実際の仕組み |
|---|---|
| メインからサブカーネルへデータを渡す | WSTP 経由で式として送る |
| サブカーネルからメインへ結果を返す | WSTP 経由で結果式を返す |
| サブカーネル A から B へ直接渡す | 標準 API では基本的に直接ではなく、メインカーネル経由 |
| 共有変数を使う | メインカーネル上の中央管理値に各サブカーネルが問い合わせる |
| 共有関数を使う | サブカーネル上の `f[...]` がメインカーネルで評価され、結果が戻る |

## 3. サブカーネルへのデータ受け渡し

### 3.1 `DistributeDefinitions`

`DistributeDefinitions[s1, s2, ...]` は、指定したシンボルの定義を並列カーネルへ配布する。関数定義だけでなく、変数に格納された値、`OwnValues`, `DownValues`, `SubValues`, `UpValues`, 属性なども配布対象になる。

例:

```wl
LaunchKernels[];

data = Import["data.mx"];
f[x_] := someComputation[x, data];

DistributeDefinitions[f, data];
ParallelMap[f, inputs]
```

この方法は、小〜中規模の読み取り専用データには便利である。しかし、巨大データを配布すると、各サブカーネルにコピーされるため、メモリ使用量がサブカーネル数倍になりうる。

たとえば、4 GB のデータを 8 個のサブカーネルに配ると、理屈上はサブカーネル側だけで最大 32 GB 程度のコピーが必要になる可能性がある。メイン側のコピーも含めるとさらに大きくなる。

### 3.2 `ParallelEvaluate`

`ParallelEvaluate[expr]` は、各サブカーネル上で `expr` を評価する。巨大データでは、メインカーネルからデータを配るのではなく、各サブカーネルが自分でローカルに読み込む・生成する方が安定する場合が多い。

例:

```wl
LaunchKernels[];

ParallelEvaluate[
  localData = Import[
    FileNameJoin[{dataDir, "chunk" <> ToString[$KernelID] <> ".mx"}]
  ];
];

results = ParallelEvaluate[
  process[localData]
];
```

この設計では、`localData` は各サブカーネルのローカル状態であり、毎回メインカーネルから転送されるわけではない。

### 3.3 `SetSharedVariable`

`SetSharedVariable[x]` を使うと、複数カーネルから `x` を共有しているように見える。

```wl
SetSharedVariable[counter];
counter = 0;

ParallelDo[
  counter++,
  {1000}
]
```

しかし、これは本物の共有メモリではない。共有変数の唯一の値は master kernel に保持され、サブカーネルからのアクセスは master kernel を通じて同期される。

したがって、巨大データを共有変数にするのは危険である。

危険例:

```wl
SetSharedVariable[bigMatrix];

ParallelTable[
  Total[bigMatrix[[i]]],
  {i, n}
]
```

このような処理では、各サブカーネルが `bigMatrix` へのアクセスごとにメインカーネルへ問い合わせる可能性があり、通信ボトルネックになる。大きな行列の部分アクセスでも、書き方によっては行列全体が繰り返し転送される可能性がある。

### 3.4 `SetSharedFunction`

`SetSharedFunction[f]` も、本質的にはサブカーネル上で `f` を実行する仕組みではない。サブカーネル上で評価された `f[...]` は master kernel に送られ、そこで評価され、結果が戻る。

危険例:

```wl
SetSharedFunction[f];

ParallelTable[
  f[i],
  {i, 100000}
]
```

これは、`f[i]` が各サブカーネルで独立に高速実行されるというより、メインカーネルへの大量 callback を発生させる構造になる。

通常の関数定義をサブカーネルへ配るだけなら、次の方がよい。

```wl
f[x_] := x^2 + 1;
DistributeDefinitions[f];

ParallelMap[f, Range[100000]]
```

## 4. 巨大データを扱う場合の推奨設計

巨大データを使う処理では、次の順に設計を考えるのがよい。

### 4.1 小〜中規模の読み取り専用データ

```wl
data = Import["data.mx"];
f[x_] := someComputation[x, data];

DistributeDefinitions[f, data];
ParallelMap[f, inputs]
```

簡単だが、`data` は各サブカーネルへコピーされる。

### 4.2 巨大だが全サブカーネルが同じデータを読む

```wl
ParallelEvaluate[
  data = Import["largeData.mx"];
];

ParallelMap[
  computeWithLocalData,
  inputs
]
```

この場合でもメモリはサブカーネル数分必要になりうるが、少なくとも毎回メインカーネルから転送するよりは安定しやすい。

### 4.3 巨大データを分割できる

最も望ましいのは、データをサブカーネルごとに分割する設計である。

```wl
ParallelEvaluate[
  localChunk = Import[
    "chunk-" <> ToString[$KernelID] <> ".mx"
  ];
];

ParallelEvaluate[
  result = process[localChunk];
  Export["result-" <> ToString[$KernelID] <> ".mx", result];
];
```

結果が巨大な場合は、メインカーネルへ全部返さず、各サブカーネルがファイルに書き出し、メイン側ではファイル名や要約だけを受け取る方がよい。

### 4.4 メインメモリ上の巨大データを直接参照したい場合

これは最も危険である。`SetSharedVariable` で巨大データを共有すると、サブカーネルからメインカーネルへの通信が頻発し、並列化の効果が消える可能性が高い。

仕様上は、次の判定を入れるべきである。

```text
巨大データを参照する処理は、次を判定する。

1. データをサブカーネルへコピーしてよいか。
2. 各サブカーネルでローカルに再生成・再ロードできるか。
3. データをチャンク分割できるか。
4. 結果をメインへ戻す必要があるか。
5. 結果本体をファイル出力に逃がせるか。
```

## 5. メインカーネルをブロックするリスク

メインカーネルは、ノートブック評価、サブカーネル制御、共有変数・共有関数、結果集約、外部プロセス起動などの中心にいる。ここが詰まると、広範囲に影響する。

### 5.1 長時間の通常評価

Shift+Enter による通常評価は main link にキューイングされる。長時間評価が走ると、次の通常評価は待たされる。

これはフロントエンド全体を即座にロックするとは限らないが、カーネル評価を必要とする操作は詰まりやすくなる。

### 5.2 `RunProcess` による同期外部プロセス起動

危険例:

```wl
RunProcess[{"wolframscript", "-file", "task.wls"}]
```

`RunProcess` は外部プロセスが終了するまで戻らないため、呼び出し元のメインカーネル評価はブロックされる。

長時間処理では、次のように `StartProcess` を使う方がよい。

```wl
proc = StartProcess[{"wolframscript", "-file", "task.wls"}]
```

ただし、`StartProcess` でも stdout/stderr の読み取り、終了監視、ログ収集の設計を誤ると、別の形でメインカーネルに負荷をかける。

### 5.3 共有変数・共有関数による master callback 過多

危険例:

```wl
SetSharedVariable[progress, resultLog];

ParallelDo[
  progress++;
  AppendTo[resultLog, heavyResult[i]],
  {i, tasks}
]
```

サブカーネルから master kernel への callback が大量に発生し、メインカーネルが同期処理に忙殺される。

安全寄りの設計:

```wl
partialResults = ParallelMap[
  Function[chunk,
    local = computeChunk[chunk];
    file = "result-" <> ToString[$KernelID] <> ".mx";
    Export[file, local];
    <|"KernelID" -> $KernelID, "File" -> file|>
  ],
  chunks
];
```

## 6. フロントエンドをブロックする危険操作

フロントエンドとカーネルは WSTP で接続されており、通常評価用の main link とは別に、`Dynamic`, `Button`, パレット操作などで使われる preemptive link がある。

特に重要なのは、preemptive link 評価中はフロントエンドがロックされやすいことである。`Dynamic` や `Button` の中で重い計算を行うと、フロントエンド操作が固まる危険がある。

### 6.1 `Dynamic` / `Manipulate` 内の重い処理

危険例:

```wl
Dynamic[heavyComputation[x]]
```

または、

```wl
Manipulate[
  heavyComputation[x],
  {x, 0, 1}
]
```

スライダーや UI 更新のたびに重い評価が走り、フロントエンド応答を壊す。

安全寄り:

```wl
Dynamic[cachedResult, SynchronousUpdating -> False]
```

または、重い処理を明示ボタンで開始し、結果だけを `Dynamic` で表示する。

```wl
DynamicModule[{result = None, running = False},
 Column[{
   Button[
     "Run",
     running = True;
     result = heavyComputation[];
     running = False,
     Method -> "Queued"
   ],
   Dynamic[If[running, "Running...", result], SynchronousUpdating -> False]
 }]
]
```

### 6.2 `Button` / `ActionMenu` の preemptive 評価

危険例:

```wl
Button["Run heavy task", heavyComputation[]]
```

`Button` のデフォルトは preemptive 評価になりうるため、長時間処理では危険である。

安全寄り:

```wl
Button["Run heavy task", heavyComputation[], Method -> "Queued"]
```

ただし、`Method -> "Queued"` は main link に並ぶため、今度はメインカーネルの通常評価キューを占有しうる。本当に重い処理は `StartProcess`, `LocalSubmit`, `ParallelSubmit`, WolframScript, 外部 executor などに逃がすべきである。

### 6.3 blocking dialog

次のような dialog 系処理は、ユーザー応答まで評価を止める。

```wl
DialogInput[...]
ChoiceDialog[...]
InputString[...]
AuthenticationDialog[...]
```

危険例:

```wl
Button[
  "Ask",
  If[ChoiceDialog["Continue?"], heavyComputation[]]
]
```

preemptive な `Button` と blocking dialog が絡むと、フロントエンドが固まることがある。

安全寄り:

```wl
Button[
  "Ask",
  If[ChoiceDialog["Continue?"], heavyComputation[]],
  Method -> "Queued"
]
```

ただし、これでもメインカーネルはユーザー応答待ちでブロックされる。自動実行ワークフロー、サブカーネル、WolframScript、外部 executor では、blocking dialog は原則禁止にすべきである。

### 6.4 ノートブック操作

次の操作はフロントエンド依存であり、巨大ノートブックや大量書き込みでは危険である。

```wl
NotebookGet[EvaluationNotebook[]]
NotebookWrite[EvaluationNotebook[], expr]
NotebookPut[expr]
FrontEndExecute[expr]
FrontEndTokenExecute[...]
SelectionMove[...]
CurrentValue[$FrontEnd, ...]
```

危険例:

```wl
NotebookGet[EvaluationNotebook[]]
```

巨大ノートブックでは、ノートブック全体がカーネルへ転送される。

危険例:

```wl
Do[
  NotebookWrite[EvaluationNotebook[], Cell[ToString[i], "Print"]],
  {i, 100000}
]
```

これはフロントエンドへの大量書き込みであり、UI を非常に重くする。

安全寄りには、ログはノートブックへ逐次書かず、ファイルへ出す。

```wl
WriteString[logStream, ToString[event] <> "\n"]
```

また、ノートブックには最終要約だけを出す。

### 6.5 巨大出力・巨大グラフィックス

重い計算そのものより、結果をノートブックに表示する段階でフロントエンドが固まることがある。

危険例:

```wl
Range[10^8]
```

```wl
Table[Graphics[...], {10000}]
```

```wl
Dataset[hugeAssociation]
```

```wl
Print /@ Range[100000]
```

安全寄り:

```wl
res = heavyComputation[];
Export["result.mx", res];

<|
  "ByteCount" -> ByteCount[res],
  "Head" -> Head[res],
  "Preview" -> Short[res, 5],
  "File" -> "result.mx"
|>
```

## 7. WolframScript で CLI 経由に投入したタスクの影響

### 7.1 通常の CLI 起動は直接ブロックしない

外部の PowerShell やコマンドプロンプトから次のように起動する場合、通常は Mathematica ノートブックのメインカーネルとは別プロセスで動く。

```bat
wolframscript -file task.wls
```

```bat
wolframscript -code "heavyComputation[]"
```

この場合、通常は次のものは共有されない。

```text
メインカーネルの変数
メインカーネルの定義
サブカーネルのキュー
Notebook の Dynamic 評価
FrontEnd の preemptive link
```

したがって、WolframScript の計算が長時間走っているだけで、既存の Mathematica ノートブックの評価キューが直接止まることはない。

### 7.2 Mathematica から `RunProcess` で呼ぶとブロックする

危険例:

```wl
RunProcess[{"wolframscript", "-file", "task.wls"}]
```

これは WolframScript 自体がメインカーネルに侵入しているわけではない。しかし、メインカーネルが外部プロセスの終了待ちになるため、実質的にメインカーネル評価をブロックする。

長時間処理では、次の方がよい。

```wl
proc = StartProcess[{"wolframscript", "-file", "task.wls"}]
```

### 7.3 OS 資源競合

直接ブロックしなくても、同じ PC 上で動く以上、次は共有される。

```text
CPU
RAM
仮想メモリ / swap
ディスク I/O
GPU
ネットワーク
ファイルシステム
ライセンス・カーネル起動枠
```

WolframScript 側が大量のメモリを使い、OS が swap に入り始めると、Mathematica のフロントエンドもメインカーネルもまとめて重くなる。

### 7.4 WolframScript 内で `LaunchKernels[]` する場合

WolframScript 内で次のように書くと、WolframScript 側の WolframKernel が独自にサブカーネル群を起動する。

```wl
LaunchKernels[];
ParallelMap[f, data]
```

これは Mathematica ノートブック側のサブカーネルを使うのではない。ノートブック側で 8 サブカーネル、WolframScript 側で 8 サブカーネルを起動すると、合計で多数の WolframKernel 系プロセスが走る。CPU / RAM / ライセンス枠を圧迫する。

### 7.5 WolframScript 内でフロントエンド依存処理を使う場合

通常の WolframScript はフロントエンドに接続されていない。したがって、次のような処理は headless-safe ではない。

```wl
NotebookWrite[EvaluationNotebook[], ...]
FrontEndExecute[...]
CurrentValue[$FrontEnd, ...]
CreateDocument[...]
NotebookPrint[...]
```

`UsingFrontEnd[expr]` を使うと、スタンドアロンカーネルでも必要に応じてフロントエンドを起動して処理する。この場合は純粋な CLI タスクではなく、フロントエンド依存タスクとして分類すべきである。

### 7.6 同じファイル・設定を触る場合

WolframScript はメインカーネルと変数を共有しないが、ファイルシステムは共有する。次は干渉し得る。

```text
同じ .nb ファイルを書き換える
同じ .mx / .wxf / .wl / .json / .csv を読み書きする
同じログファイルに Append する
同じキャッシュディレクトリを更新する
同じ Paclet / init.m / 設定ファイルを変更する
```

一意の作業ディレクトリ、ロックファイル、atomic rename、ジョブ ID 付きファイル名などを使うべきである。

## 8. 危険操作分類

| 分類 | 危険操作 | 主なリスク | 推奨配置・対策 |
|---|---|---|---|
| `DataTransferRisk` | 巨大データの `DistributeDefinitions`、巨大結果の集約 | メモリ爆発、WSTP 転送過多 | チャンク分割、ローカル読み込み、ファイル出力 |
| `MainKernelBlocking` | 長時間通常評価、`RunProcess`, 同期 `ExternalEvaluate`, `WaitAll` | メインカーネル評価キュー停止 | `StartProcess`, WolframScript, 外部 executor |
| `MasterCallbackHeavy` | `SetSharedVariable`, `SetSharedFunction`, 高頻度 progress 更新 | サブカーネルが master kernel に殺到 | バッチ集約、間引き更新、ファイルログ |
| `FrontEndBlocking` | `Dynamic` 内の重い計算、preemptive `Button` | FE ロック、UI 応答低下 | `Method -> "Queued"`, 非同期化、結果キャッシュ |
| `DialogBlocking` | `DialogInput`, `ChoiceDialog`, `InputString`, `AuthenticationDialog` | ユーザー応答待ちで停止 | 自動処理では禁止 |
| `NotebookIOHeavy` | `NotebookGet`, 巨大 `NotebookWrite`, 大量 `Print` | FE-WSTP 転送、描画負荷 | ファイル出力、要約表示 |
| `HugeOutputRender` | 巨大リスト、巨大 `Dataset`, 大量画像・グラフ | 計算後に FE が固まる | `Short`, `Summary`, `Export` |
| `WolframScriptResourceContention` | CLI タスクの高 CPU / 高 RAM / 高 I/O | OS レベルで全体が重くなる | 並列度制限、優先度制御、メモリ上限 |
| `FileSystemConflictRisk` | 同じ `.nb`, `.mx`, log, cache を同時更新 | ファイル破損、競合 | ロック、一意ディレクトリ、atomic rename |
| `AbortRecoveryNeeded` | 並列計算、外部プロセス、長時間タスク | abort 後に子プロセスが残る | cleanup policy 必須 |

## 9. 実行先選択ルール案

### FE-1: UI 起点の長時間処理禁止

```text
Dynamic, Manipulate, Button, ActionMenu, EventHandler, Palette から起動される処理は、
推定実行時間が 1〜2 秒を超える場合、preemptive link で直接実行してはならない。
```

対策:

```text
Method -> "Queued"
非同期 task
StartProcess
WolframScript
外部 executor
```

### FE-2: blocking dialog の自動実行禁止

```text
DialogInput, Input, InputString, ChoiceDialog, AuthenticationDialog などの blocking dialog は、
自動ワークフロー、サブカーネル、WolframScript、外部 executor では禁止する。
```

必要な確認は、実行前にメイン FE 上で完了させる。

### FE-3: FE 依存操作の headless 実行禁止

```text
NotebookGet, NotebookWrite, NotebookPut, FrontEndExecute, FrontEndTokenExecute,
SelectionMove, CurrentValue などの FE 依存操作は、
WolframScript / headless / subkernel へ配置してはならない。
ただし UsingFrontEnd 明示時を除く。
```

### MK-1: master callback 頻度の見積もり

```text
SetSharedVariable / SetSharedFunction を含む並列処理は、
サブカーネルから master kernel への callback 頻度を見積もる。
高頻度ならサブカーネル実行不可、またはバッチ化を必須にする。
```

### MK-2: 巨大データ・巨大結果の集約禁止

```text
巨大データまたは巨大結果を master kernel に集約する ParallelEvaluate / ParallelMap は、
メモリ量と転送量を評価し、しきい値超過時はファイル出力方式に切り替える。
```

### MK-3: 同期外部呼び出しの制限

```text
RunProcess や同期 ExternalEvaluate など、終了待ちする外部呼び出しは、
短時間処理を除いてメインカーネル上で直接実行しない。
```

### WS-1: 通常の WolframScript は別プロセス

```text
外部 CLI から通常の wolframscript -file/-code で起動されるタスクは、
Mathematica メインカーネルとは別プロセスとして扱う。
したがって MainKernelBlockingRisk は原則 Low とする。
```

### WS-2: Mathematica から `RunProcess` で呼ぶ場合

```text
Mathematica メインカーネルから RunProcess で wolframscript を呼ぶ場合は、
呼び出し元評価が終了待ちになるため MainKernelBlockingRisk を High とする。
長時間処理では StartProcess または外部 executor を使う。
```

### WS-3: WolframScript 内の `LaunchKernels[]`

```text
wolframscript 内で LaunchKernels[] を使う場合は、
独立したサブカーネル群を起動するものとして扱い、
CPU/RAM/ライセンス/カーネル数の競合を評価する。
```

### WS-4: WolframScript 内の FE 依存処理

```text
wolframscript タスクに UsingFrontEnd, FrontEndExecute, NotebookWrite,
NotebookPrint, CreateDocument, CurrentValue[$FrontEnd,...] が含まれる場合は、
HeadlessSafe=False とし、FrontEndDependency=True とする。
```

### WS-5: ファイルシステム競合

```text
wolframscript タスクが既存 Notebook ファイル、共通ログ、共通 .mx/.wxf、
Paclet、init.m、設定ディレクトリを読み書きする場合は、
FileSystemConflictRisk を評価し、ロックファイルまたは一意な作業ディレクトリを必須にする。
```

### OUT-1: 巨大出力をノートブックへ直接返さない

```text
推定出力が巨大な処理は、ノートブックへ直接返さない。
結果本体はファイルへ保存し、ノートブックには Summary, Preview, ByteCount, FilePath のみ返す。
```

### ABORT-1: cleanup policy 必須

```text
ParallelEvaluate, ParallelSubmit, 外部プロセス, WolframScript を使う処理には
abort/cleanup 手順を必須化する。
```

例:

```wl
CheckAbort[
  result = ParallelEvaluate[expr],
  AbortKernels[];
  $Aborted
]
```

より一般には、次の cleanup 手順を設ける。

```text
1. main evaluation を止める。
2. subkernel queues を reset する。
3. remote kernels を abort する。
4. 外部プロセスを kill / cleanup する。
5. 中間ファイルの状態を incomplete として mark する。
```

## 10. タスクメタデータ案

実装上は、各タスクに次のようなメタデータを持たせると、実行先選択が安定する。

```wl
<|
  "RequiresFrontEnd" -> True | False,
  "UsesDynamic" -> True | False,
  "UsesDialog" -> True | False,
  "UsesNotebookIO" -> True | False,
  "UsesSharedVariable" -> True | False,
  "UsesSharedFunction" -> True | False,
  "UsesExternalProcess" -> True | False,
  "UsesWolframScript" -> True | False,
  "UsesLaunchKernels" -> True | False,
  "EstimatedInputBytes" -> n,
  "EstimatedOutputBytes" -> m,
  "EstimatedRuntimeSeconds" -> t,
  "CanRunHeadless" -> True | False,
  "CanRunInSubkernel" -> True | False,
  "CanRunInWolframScript" -> True | False,
  "FileSystemConflictRisk" -> "Low" | "Medium" | "High",
  "ResourceContentionRisk" -> "Low" | "Medium" | "High",
  "AbortCleanupRequired" -> True | False
|>
```

## 11. 実行先選択の簡易方針

```text
FrontEnd 操作が必要
    → メインカーネル。ただし長時間・巨大出力は禁止または非同期化。

FrontEnd 不要・巨大データあり
    → サブカーネルへコピーせず、WolframScript / 外部 executor / ローカルファイル読み込み。

共有変数・共有関数への高頻度アクセスあり
    → 並列化しない、またはバッチ化して通信頻度を落とす。

長時間外部プロセス
    → RunProcess ではなく StartProcess / WolframScript / 外部 executor。

巨大出力
    → ノートブック返却禁止。ファイル保存 + 要約返却。

CLI WolframScript
    → 通常はメインカーネルから隔離。ただし OS 資源、ファイル、ライセンス、FE 依存処理を評価する。
```

## 12. 参考情報

### Wolfram 公式ドキュメント

- Parallel Computing Overview / Introduction  
  <https://reference.wolfram.com/language/ParallelTools/tutorial/Introduction.html>

- Resource Sharing in Parallel Computing  
  <https://reference.wolfram.com/language/guide/ResourceSharingInParallelComputing.html>

- DistributeDefinitions  
  <https://reference.wolfram.com/language/ref/DistributeDefinitions.html>

- ParallelEvaluate  
  <https://reference.wolfram.com/language/ref/ParallelEvaluate.html>

- SetSharedVariable  
  <https://reference.wolfram.com/language/ref/SetSharedVariable.html>

- SetSharedFunction  
  <https://reference.wolfram.com/language/ref/SetSharedFunction.html>

- LaunchKernels  
  <https://reference.wolfram.com/language/ref/LaunchKernels.html>

- Advanced Dynamic Functionality  
  <https://reference.wolfram.com/language/tutorial/AdvancedDynamicFunctionality.html>

- SynchronousUpdating  
  <https://reference.wolfram.com/language/ref/SynchronousUpdating.html>

- Introduction to Control Objects  
  <https://reference.wolfram.com/language/tutorial/IntroductionToControlObjects.html>

- ActionMenu  
  <https://reference.wolfram.com/language/ref/ActionMenu.html>

- Creating Dialog Boxes  
  <https://reference.wolfram.com/language/tutorial/CreatingDialogBoxes.html>

- DialogInput  
  <https://reference.wolfram.com/language/ref/DialogInput.html>

- AuthenticationDialog  
  <https://reference.wolfram.com/language/ref/AuthenticationDialog.html>

- NotebookGet  
  <https://reference.wolfram.com/language/ref/NotebookGet.html>

- NotebookWrite  
  <https://reference.wolfram.com/language/ref/NotebookWrite.html>

- FrontEndExecute  
  <https://reference.wolfram.com/language/ref/FrontEndExecute.html>

- RunProcess  
  <https://reference.wolfram.com/language/ref/RunProcess.html>

- StartProcess  
  <https://reference.wolfram.com/language/ref/StartProcess.html>

- ExternalEvaluate  
  <https://reference.wolfram.com/language/ref/ExternalEvaluate.html>

- StartExternalSession  
  <https://reference.wolfram.com/language/ref/StartExternalSession.html>

- `$Notebooks`  
  <https://reference.wolfram.com/language/ref/$Notebooks.html>

- `$FrontEnd`  
  <https://reference.wolfram.com/language/ref/$FrontEnd.html>

- UsingFrontEnd  
  <https://reference.wolfram.com/language/ref/UsingFrontEnd.html>

- WSTPServer Introduction  
  <https://reference.wolfram.com/language/tutorial/IntroductionToWSTPServer.html>

- Failure Recovery, Tracing and Debugging  
  <https://reference.wolfram.com/language/ParallelTools/tutorial/FailureRecoveryTracingAndDebugging.html>

### Wolfram Support / Community / Mathematica StackExchange

- Wolfram Support: configuring kernels and parallel kernels  
  <https://support.wolfram.com/36293>

- Mathematica StackExchange: `SetSharedVariable` / `SetSharedFunction` and parallel performance  
  <https://mathematica.stackexchange.com/questions/138909/do-setsharedvariable-setsharedfunction-ruin-the-benefits-of-paralleltable>

- Mathematica StackExchange: `ChoiceDialog` from `Button` freezing front end  
  <https://mathematica.stackexchange.com/questions/5356/why-do-buttons-with-choicedialog-freeze-the-front-end>

- Wolfram Community: practical parallelization and communication overhead discussions  
  <https://community.wolfram.com/groups/-/m/t/1329497>

- Wolfram Community: large data / InterpolatingFunction / parallel computation discussion  
  <https://community.wolfram.com/groups/-/m/t/2607999>
