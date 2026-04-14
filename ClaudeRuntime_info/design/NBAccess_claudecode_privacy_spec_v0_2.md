# NBAccess / claudecode / ClaudeRuntime 向け  
# プライバシー・アクセス制御・実行制御仕様案 v0.2

## 1. 文書の目的

本仕様は、既存の `NBAccess.wl` / `claudecode.wl` の設計思想を維持したまま、次を統合して整理することを目的とする。

1. このシステムの日常的な使い方の概要
2. `ClaudeEval` と `ClaudeUpdatePackage` の実行モデル
3. 従来の「再帰回数制限」を、より精密な runtime budget / retry policy に置き換える方針
4. 次のステップとしての **半順序ラベル** によるプライバシー制御拡張
5. 数値スコア `[0,1]` と半順序ラベルの役割分担

本仕様は、既存のプライバシー・アクセス制御仕様案 v0.1 の二層モデル
（`BasePrivacyScore` と `PolicyLabel`）を継承しつつ、  
今後追加する `ClaudeRuntime.wl` / `ClaudeTestKit.wl` と整合する形へ更新するものである。

---

## 2. 設計の中心思想

### 2.1 最重要原則

この系では、以下を不変条件とする。

1. **機密データの実体は NBAccess だけが扱う。**
2. **外部 LLM は資源へ直接アクセスしない。**
3. **LLM は必ず Mathematica 式を生成し、その式は実行前に検証される。**
4. **実行可能な式の surface は、NBAccess / claudecode が公開する安全 API に限定する。**
5. **Notebook / Session / TaggingRules / Credential / API key / audit state は NBAccess 専管とする。**
6. **ClaudeRuntime は進行管理のみを行い、安全判定そのものは NBAccess に委ねる。**
7. **プライバシー制御は将来的に半順序ラベルを主体系とし、数値スコアは補助体系として残す。**

### 2.2 二層モデルの継承と強化

既存 v0.1 仕様案では、各データに

- `BasePrivacyScore`
- `PolicyLabel`

の二層を持たせる方針が示されている。  
本仕様でもこれを継承するが、位置づけを次のように明確化する。

- **PolicyLabel / DefinitionLabel / ContainerLabel**  
  → **authoritative** な policy 系。最終的な flow / declassify / release 判定の主体系
- **BasePrivacyScore / ContainerRisk / EffectiveRiskScore**  
  → **advisory** な risk 系。routing / approval / audit / screening の補助体系

---

## 3. 想定される日常的な使い方の概要

このシステムの日常運用では、基本的に

- **普段の notebook 作業は `ClaudeEval`**
- **package の永続的変更は `ClaudeUpdatePackage`**

の二本立てになる。

### 3.1 ClaudeEval の日常的な用途

`ClaudeEval` は、主に notebook 上の現在文脈を対象にした、対話的・即時反映型の実行である。

典型的な用途:

- 選択セルの要約
- 技術文の翻訳・整形
- notebook 上のコード草案の整理
- session history を踏まえた続きの提案
- notebook セルへの安全な書き戻し

#### 例

- 「この節を3行で要約して」
- 「選択セルを学会発表向けの英語に直して」
- 「ここまでの議論を踏まえて次の実装ステップを書いて」
- 「このコードを補助関数に分けて notebook 上で整理して」

ここでは、LLM は notebook や session を直接読まず、  
NBAccess が作った安全な context packet を受け取り、  
その context に対する `HoldComplete[...]` の Mathematica 式を提案する。

### 3.2 ClaudeUpdatePackage の日常的な用途

`ClaudeUpdatePackage` は、package 更新専用の transaction workflow である。

典型的な用途:

- `.wl` ファイルの関数修正
- 公開関数 / 内部関数の分離
- バグ修正
- package 単位のリファクタリング
- `test.wl` の更新
- reload / test を通したうえでの commit

#### 例

- 「`NBValidateHeldExpr` に禁止 head 判定を追加して」
- 「`ClaudeBuildRuntimeAdapter` を追加し、それを検証する `test.wl` も更新して」
- 「`NBAccess` の privacy label 関係 API を分離して package を整理して」

ここでは、更新は最初から本番ファイルに書かず、  
必ず shadow workspace に適用し、reload / tests を通過してから commit する。

### 3.3 基本的な使い分け

#### `ClaudeEval` を使う場面

- 要約
- 翻訳
- セル整形
- notebook 内の対話的作業
- 実装前の草案整理

#### `ClaudeUpdatePackage` を使う場面

- `.wl` の更新
- 関数追加・修正・削除
- テスト追加
- package レベルの安全な反映
- 継続的な保守作業

---

## 4. システム構成と責務分担

依存関係の原則は次のとおり。

```text
NBAccess.wl
   ↑
   │  (public safe API only)
   │
claudecode.wl  ─────→ ClaudeRuntime.wl
   ↑                    ↑
   │                    │
   └──── ClaudeTestKit.wl ────(mock provider / mock adapter / NBAccess fixture)
```

### 4.1 NBAccess の責務

NBAccess は security kernel / data kernel であり、次を担当する。

- confidential data の保持
- notebook / cell / session / TaggingRules / credential 実体アクセス
- access-level / policy-label 付き API
- redaction
- held expression の静的検証
- 実行前後の access check
- declassify / release
- audit state
- retry packet の安全化

### 4.2 claudecode の責務

claudecode は notebook orchestrator であり、次を担当する。

- `ClaudeEval`
- `ContinueEval`
- `ClaudeUpdatePackage`
- Notebook UI
- palette
- approval dialog
- runtime adapter の実装
- Notebook と runtime の橋渡し
- trace の notebook 表示

### 4.3 ClaudeRuntime の責務

ClaudeRuntime は proposal / transaction の進行管理であり、次を担当する。

- provider への問い合わせ
- proposal の受理
- validation / execution / retry の状態遷移
- step / retry / checkpoint の budget 管理
- event trace
- transaction state

**安全判定そのものは NBAccess が行う。**

### 4.4 ClaudeTestKit の責務

ClaudeTestKit は runtime と security contract の包括的テスト基盤であり、次を担当する。

- MockProvider
- MockAdapter
- scenario runner
- golden normalization
- no-leak assertion
- validation-denied assertion
- label algebra tests
- authorization contract tests
- update transaction regression tests

---

## 5. 実行モデル

### 5.1 この系では「tool loop」ではなく「expression-proposal loop」を採用する

一般的な agent runtime が tool call を中心にするのに対し、この系では LLM は直接資源を触らず、  
**Hold された Mathematica 式**を提案する。

流れは次のとおり。

1. claudecode が `NBAccess` に安全な context packet を作らせる
2. ClaudeRuntime が provider に問い合わせる
3. provider は `HoldComplete[...]` を含む proposal を返す
4. claudecode adapter が `NBAccess` に validation を依頼する
5. validation 結果に応じて allow / deny / approval / rewrite を分岐する
6. allow のときだけ `NBAccess` が式を実行する
7. 実行結果は redacted / summarized された形で返る
8. 必要なら継続 proposal を求める

### 5.2 ClaudeEval の実行モデル

`ClaudeEval` は対話的・即時反映型であり、主眼は

- 読み取り
- 要約
- notebook 挿入
- formatting
- 対話継続

にある。

### 5.3 ClaudeUpdatePackage の実行モデル

`ClaudeUpdatePackage` は transaction 型であり、主眼は

- snapshot
- proposal
- shadow apply
- static check
- reload check
- test phase
- commit / rollback

にある。

---

## 6. 再帰の考え方のアップデート

### 6.1 従来の「再帰回数制限」の問題

従来の `ClaudeEval` では、再帰呼び出し回数を制限することで、

- 無限ループ防止
- エラー時の再試行上限
- multi-step 実行の打ち切り

を一括で制御していた。

しかしこれは、次の異なる事象を同一カウントで扱ってしまう。

- proposal の継続
- format 修復
- validation repair
- transport retry
- reload error repair
- test failure repair

### 6.2 新しい考え方

新設計では、再帰は「自己呼び出しの深さ」ではなく、  
**状態遷移と予算の消費**として表現する。

すなわち、再帰回数制限は次の予算に分解される。

- `MaxTotalSteps`
- `MaxProposalIterations`
- `MaxTransportRetries`
- `MaxFormatRetries`
- `MaxValidationRepairs`
- `MaxExecutionRetries`
- `MaxReloadRepairs`
- `MaxTestRepairs`
- `MaxPatchApplyRetries`
- `MaxFullReplans`

### 6.3 ClaudeEval における再帰の意味

`ClaudeEval` では、「再帰」は主として

- proposal 継続
- format retry
- validation repair

を意味する。

ここでは、実行済み副作用後の自動再実行は原則として抑制する。

### 6.4 ClaudeUpdatePackage における再帰の意味

`ClaudeUpdatePackage` では、「再帰」は主として

- reload repair
- test repair
- patch apply retry
- full replan

を意味する。

こちらは shadow workspace と checkpoint を持つため、  
ClaudeEval よりも強い retry を許容できる。

### 6.5 approval 待ちは再帰ではない

`NeedsApproval` は failure ではなく停止状態である。  
したがって、approval 待ちは通常の retry budget を消費しない。

---

## 7. RetryPolicy と RuntimeState の具体像

### 7.1 RetryPolicy

RetryPolicy は静的設定であり、「どの retry をどこまで許すか」を表す。

例:

```wl
<|
  "Profile" -> "Eval" | "UpdatePackage",
  "Limits" -> <|
    "MaxTotalSteps" -> 6,
    "MaxProposalIterations" -> 3,
    "MaxTransportRetries" -> 2,
    "MaxFormatRetries" -> 2,
    "MaxValidationRepairs" -> 1,
    "MaxExecutionRetries" -> 0,
    "MaxReloadRepairs" -> 0,
    "MaxTestRepairs" -> 0,
    "MaxPatchApplyRetries" -> 0,
    "MaxFullReplans" -> 0
  |>,
  "Backoff" -> <| ... |>,
  "ClassificationRules" -> <| ... |>,
  "CheckpointPolicy" -> <| ... |>,
  "ApprovalPolicy" -> <| ... |>,
  "Accounting" -> <| ... |>
|>
```

### 7.2 RuntimeState

RuntimeState は動的状態であり、「今どこまで進み、何を何回使ったか」を表す。

例:

```wl
<|
  "RuntimeId" -> "...",
  "Profile" -> "Eval" | "UpdatePackage",
  "Status" -> "Initialized" | "Running" | "AwaitingApproval" | "Retrying" | "Done" | "Failed",
  "CurrentPhase" -> ...,
  "RetryPolicy" -> <| ... |>,
  "BudgetsUsed" -> <| ... |>,
  "LastContextPacket" -> ...,
  "LastProposal" -> ...,
  "LastValidationResult" -> ...,
  "LastExecutionResult" -> ...,
  "LastFailure" -> ...,
  "FailureHistory" -> {...},
  "EventTrace" -> {...},
  "CheckpointStack" -> {...},
  "PendingApproval" -> ...,
  "ConversationState" -> <||>,
  "TransactionState" -> <||>,
  "Metadata" -> <||>
|>
```

### 7.3 旧「再帰回数制限」との互換

移行期には、旧来の `MaxRecursiveCalls` を残してもよいが、  
これは内部的には `MaxTotalSteps` のような最終安全弁として再解釈する。

---

## 8. 失敗分類

retry を堅固にするには、失敗を分類しなければならない。

### 8.1 主要 failure class

- `TransportTransient`
- `ProviderRateLimit`
- `ProviderTimeout`
- `ModelFormatError`
- `ValidationRepairable`
- `ForbiddenHead`
- `AccessEscalationRequired`
- `ConfidentialLeakRisk`
- `PolicyFlowViolation`
- `ActsForInsufficient`
- `ReleasePolicyMissing`
- `DeclassifyRequired`
- `ExecutionTransient`
- `ExecutionNonIdempotentFailure`
- `PatchApplyConflict`
- `ReloadError`
- `TestFailure`
- `SecurityViolation`
- `ExplicitDeny`
- `UnknownFailure`

### 8.2 failure class と retry の関係

#### retry 可能なもの

- Transport / provider transient
- format error
- validation repairable
- reload error
- test failure
- patch apply conflict

#### retry してはいけないもの

- security violation
- confidential leak risk
- acts-for 不足
- forbidden head
- explicit deny
- 不適切な declassify 要求

---

## 9. プライバシー制御の現状と次のステップ

### 9.1 現状

現状では、privacy / access control は主に `[0,1]` の数値スコアで運用されている。

これは次の利点を持つ。

- 実装が簡単
- しきい値が分かりやすい
- コードレビューしやすい
- 「クラウドに出してよいか」の境界を一目で追える

特に、**クラウド LLM とプライベート LLM の境界を `0.5` に置く**のは、  
運用上たいへん見通しがよい。

### 9.2 次のステップ

ただし、最終的な access 可否を数値スコアだけで決めると、次の問題がある。

- 「誰に流してよいか」が表現しづらい
- declassify の概念が弱い
- container / environment / acts-for を厳密に扱いにくい
- confidential function の execution と definition の区別が弱い

そこで次のステップとして、**半順序ラベル**を主体系として導入する。

---

## 10. 半順序ラベル導入の基本方針

### 10.1 基本方針

今後の仕様では、privacy 制御を次の二層で運用する。

#### 主体系
半順序ラベル

- `PolicyLabel`
- `ContainerLabel`
- `DefinitionLabel`
- `EffectiveLabel`

#### 副体系
数値スコア

- `BasePrivacyScore`
- `ContainerRisk`
- `EffectiveRiskScore`

### 10.2 役割分担

#### 半順序ラベルが決めるもの

- 誰に flow してよいか
- declassify が必要か
- notebook に出してよいか
- external sink へ送ってよいか
- module / principal / acts-for が十分か

#### 数値スコアが決めるもの

- cloud LLM / private LLM / local only の routing
- approval の要否
- audit の重み
- screening の強度
- risk 可視化
- suspicious access の早期発見

### 10.3 重要な原則

**「score < 0.5 だからクラウドへ出してよい」ではない。**  
正しくは:

**半順序ラベル上 cloud sink へ flow 可能で、かつ EffectiveRiskScore も cloud threshold 未満なら、クラウドへ出せる。**

---

## 11. 半順序ラベルのモデル

### 11.1 Principal / ActsFor

アクセス主体を principal とし、委任関係を `ActsFor` で表す。

例:

- 人間ユーザ
- ロール
- グループ
- module
- system principal

### 11.2 Label

最低限、confidentiality 中心の DLM 風 reader policy から始める。

```wl
Label[<|
  "ReaderPolicies" -> <|
    owner1 -> {readerA, readerB, ...},
    owner2 -> {readerC, ...}
  |>,
  "Categories" -> {"Grades", "MethodIP", ...}
|>]
```

### 11.3 半順序

ラベル間には半順序 `⪯` を入れる。

```wl
NBLabelLEQ[l1_, l2_]
```

意味としては、`l1` の情報が `l2` の sink / environment へ flow してよいかを判定する基礎関係である。

### 11.4 Join

複数入力に依存する出力のラベルは join で求める。

```wl
NBLabelJoin[l1_, l2_]
```

これは「両方の制約を満たす」方向、すなわちより restrictive 側へ寄せる。

---

## 12. EffectiveLabel と flow 判定

### 12.1 EffectiveLabel

実際の判定には、オブジェクト単体のラベルだけでなく、container / sink / environment を考慮した effective label を使う。

概念的には:

```wl
NBEffectiveLabel[obj_, req_] :=
  NBLabelJoin[
    obj["PolicyLabel"],
    obj["ContainerLabel"],
    SinkLabel[req["Sink"]],
    EnvironmentLabel[req["Environment"]]
  ]
```

### 12.2 flow 判定

```wl
NBCanFlowToQ[srcLabel_, dstLabel_, req_]
```

これが permit の主判定になる。

### 12.3 declassify 判定

```wl
NBCanDeclassifyQ[srcLabel_, dstLabel_, req_]
```

通常関数はラベルを下げてはならず、  
ラベル低下は `Declassify` または `ReleasePolicy` 付き `GuardedApply` のみ許可する。

---

## 13. 数値スコアの新しい位置づけ

### 13.1 数値スコアは advisory に格下げする

スコアは今後も残すが、主用途は次の 2 つに絞る。

1. **routing**
2. **risk visibility**

### 13.2 cloud / private / local の routing

例として次の閾値を標準化する。

- `EffectiveRiskScore < 0.5`  
  → cloud LLM 候補
- `0.5 <= EffectiveRiskScore < 0.8`  
  → private LLM 候補
- `0.8 <= EffectiveRiskScore`  
  → local only / release 後のみ

ただし routing の前提条件として、policy gate が通っていなければならない。

### 13.3 この設計の利点

- コードレビューしやすい
- cloud 境界が一目で分かる
- 「不穏なアクセス」を見つけやすい
- ラベルの複雑さを人間向けに視認化できる

---

## 14. AccessDecision と RouteDecision

### 14.1 AccessDecision

NBAccess は runtime に対して、ラベル内部構造を返さず、構造化された判定結果を返す。

```wl
<|
  "Decision" -> "Permit" | "Deny" | "Screen" | "RequireApproval",
  "ReasonClass" -> "PolicyFlowViolation" | "ScoreTooHigh" |
                   "ReleasePolicyMissing" | "DeclassifyRequired" |
                   "ActsForInsufficient" | "EnvironmentDenied",
  "RequiredAction" -> "None" | "RepairProposal" | "HumanApproval" | "Declassify",
  "SanitizedExpr" -> HoldComplete[...],
  "VisibleExplanation" -> "...",
  "AuditPatch" -> <| ... |>
|>
```

### 14.2 RouteDecision

NBAccess または adapter は、permit 済みオブジェクトに対して routing 判定も返す。

```wl
<|
  "Route" -> "CloudLLM" | "PrivateLLM" | "LocalOnly" | "Denied",
  "EffectiveRiskScore" -> 0.63,
  "Thresholds" -> <|
    "Cloud" -> 0.5,
    "Private" -> 0.8
  |>,
  "Reason" -> "RiskAboveCloudThreshold",
  "PolicySummary" -> <| ... |>
|>
```

---

## 15. ClaudeRuntime と半順序ラベルの整合

### 15.1 Runtime は label を知らない

ClaudeRuntime は次を計算しない。

- label の内部構造
- acts-for
- label join
- label order
- declassify 正当性

これらはすべて NBAccess が担う。

### 15.2 Runtime が見るもの

Runtime が見るのは、

- `Decision`
- `ReasonClass`
- `RequiredAction`
- `VisibleExplanation`
- `RouteDecision`

だけである。

### 15.3 Runtime 側の failure class 追加

半順序ラベル導入後、Runtime 側では次の failure class を扱う。

- `PolicyFlowViolation`
- `ActsForInsufficient`
- `ReleasePolicyMissing`
- `DeclassifyRequired`
- `LabelInferenceFailed`

ただし、これらの意味解釈は runtime ではなく NBAccess が決める。

---

## 16. NBAccess 公開 API のアップデート案

### 16.1 label algebra

```wl
NBLabelQ[label_]
NBLabelBottom[]
NBLabelTop[]

NBLabelJoin[l1_, l2_]
NBLabelMeet[l1_, l2_]              (* 必要になったら *)
NBLabelLEQ[l1_, l2_]

NBRegisterPrincipal[name_, opts___]
NBGrantActsFor[p_, q_]
NBActsForQ[p_, q_]
```

### 16.2 policy / flow / release

```wl
NBEffectiveLabel[obj_, req_]
NBCanFlowToQ[srcLabel_, dstLabel_, req_]
NBCanDeclassifyQ[srcLabel_, dstLabel_, req_]
NBReleaseResult[result_, req_, opts___]
NBMakeRetryPacket[failureAssoc_, accessSpec_, opts___]
```

### 16.3 existing public surface の更新

```wl
NBMakeContextPacket[nb_, accessSpec_, opts___]
NBInferExprRequirements[heldExpr_, accessSpec_, opts___]
NBValidateHeldExpr[heldExpr_, accessSpec_, opts___]
NBExecuteHeldExpr[heldExpr_, accessSpec_, opts___]
NBRedactExecutionResult[result_, accessSpec_, opts___]
NBAuthorize[obj_, req_]
```

### 16.4 function security

```wl
NBRegisterFunctionSecurity[sym_Symbol, spec_Association]
NBFunctionDefinitionLabel[f_]
NBFunctionExecPolicy[f_]
NBFunctionReleasePolicy[f_]
GuardedApply[req_, f_, args___]
Declassify[obj_, req_, releaseSpec_]
```

---

## 17. ClaudeTestKit の拡張

半順序ラベル導入後、ClaudeTestKit には次の 3 層のテストが必要になる。

### 17.1 Label algebra tests

- `NBLabelJoin`
- `NBLabelLEQ`
- `NBActsForQ`
- `NBCanFlowToQ`
- `NBCanDeclassifyQ`

### 17.2 Authorization contract tests

- 同じ score でも label が違えば deny になる
- score が低くても declassify が無ければ deny になる
- release policy があると coarse result は permit される
- sink / environment label が厳しくなると deny される
- failure packet に confidential 実体が出ない

### 17.3 Runtime integration tests

- `PolicyFlowViolation` から repair proposal へ遷移する
- `ReleasePolicyMissing` は retry せず abort する
- `NeedsApproval` は budget 消費なしで停止する
- UpdatePackage の failure packet が label-aware に redaction される

---

## 18. 実装順

実装順は、安全モデルを崩さず、段階的移行しやすいことを優先する。

### Phase 1: 仕様固定

まず以下を文書で固定する。

1. Allowed Expression Surface
2. `ClaudeContextPacket`
3. `ClaudeValidationResult`
4. `ClaudeExecutionResult`
5. failure class
6. `RetryPolicy`
7. `RuntimeState`
8. label algebra の最小 API
9. score の advisory 化
10. cloud/private/local routing の閾値

### Phase 2: NBAccess の label algebra 導入

優先順位:

1. `NBRegisterPrincipal`
2. `NBGrantActsFor`
3. `NBActsForQ`
4. `NBLabelJoin`
5. `NBLabelLEQ`
6. `NBCanFlowToQ`

この段階では `AccessLevel` 数値はまだ残してよい。

### Phase 3: NBAuthorize の分離

`NBAuthorize` を内部的に

- `PolicyGate`
- `ScoreGate`
- `EnvironmentGate`

へ分離し、返り値を `AccessDecision` にする。

### Phase 4: validation / execution / release の label-aware 化

優先順位:

1. `NBInferExprRequirements`
2. `NBValidateHeldExpr`
3. `NBExecuteHeldExpr`
4. `NBReleaseResult`
5. `GuardedApply`
6. `Declassify`

### Phase 5: ClaudeRuntime の最小骨格

優先順位:

1. `CreateClaudeRuntime`
2. `ClaudeRunTurn`
3. `ClaudeContinueTurn`
4. `ClaudeRuntimeState`
5. `ClaudeTurnTrace`

まずは `ClaudeEval` 相当の proposal loop のみ実装する。

### Phase 6: ClaudeTestKit の導入

優先順位:

1. `CreateMockProvider`
2. `CreateMockAdapter`
3. `RunClaudeScenario`
4. `NormalizeClaudeTrace`
5. `AssertNoSecretLeak`
6. label algebra / authorization contract tests

### Phase 7: claudecode と runtime の接続

優先順位:

1. `ClaudeBuildRuntimeAdapter`
2. `ClaudeStartRuntime`
3. `ClaudeApproveProposalDialog`
4. `ClaudeEval` を runtime 経由へ段階的移行

### Phase 8: ClaudeEval の retry 更新

優先順位:

1. transport retry
2. format retry
3. validation repair
4. approval 待ちの budget 非消費化

### Phase 9: ClaudeUpdatePackage の transaction 化

優先順位:

1. snapshot
2. shadow workspace
3. static check
4. reload check
5. test phase
6. commit / rollback

### Phase 10: UpdatePackage の repair retry 強化

優先順位:

1. checkpoint 管理
2. reload repair
3. test repair
4. patch apply retry
5. full replan

### Phase 11: score の advisory 化の完了

最後に、数値 access level に依存した permit 判定を徐々に縮退させる。  
score は routing / audit / approval / visibility に主用途を移す。

---

## 19. まとめ

この仕様アップデートの要点は次の 4 つである。

1. **日常運用では `ClaudeEval` と `ClaudeUpdatePackage` を明確に使い分ける。**
2. **従来の「再帰回数制限」は、state machine と retry budget に分解して扱う。**
3. **プライバシー制御は、半順序ラベルを主体系、数値スコアを副体系とする二層モデルへ移行する。**
4. **ClaudeRuntime は進行管理に徹し、ラベル semi-lattice や acts-for の知識は NBAccess に閉じ込める。**

この方針により、

- notebook 中心の柔軟な日常利用
- confidential / credential / session に対する厳格なアクセス境界
- cloud/private/local の見通しのよい routing
- 将来的な richer policy model への拡張

を同時に実現できる。
