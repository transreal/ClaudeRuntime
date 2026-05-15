# ClaudeEval / ClaudeUpdatePackage の実行モデルとリトライ機構  
## 方針説明・詳細仕様・実装順

## 1. 文書の目的

この文書は、既存の `NBAccess.wl` / `claudecode.wl` の設計思想を維持したまま、今後追加する

- `ClaudeRuntime.wl`
- `ClaudeTestKit.wl`

をどのように積み上げるか、また

- `ClaudeEval`
- `ClaudeUpdatePackage`

の違いをどう仕様化するか、さらに
- 包括的かつ堅固なリトライ機構

をどう設計するかを整理したものである。

本仕様の最重要点は、**claw-code 的な agent runtime をそのまま移植するのではなく、既存の安全モデルを壊さずに proposal loop / transaction loop を導入すること**にある。

---

## 2. 基本方針

### 2.1 最重要原則

この系では以下を絶対条件とする。

1. **機密データの実体は NBAccess だけが扱う。**
2. **外部 LLM は資源へ直接アクセスしない。**
3. **LLM は必ず Mathematica 式を生成し、その式は実行前に検証される。**
4. **実行可能な式の surface は公開された安全 API に限定する。**
5. **Notebook / FrontEnd / token / confidential 実体への直接アクセスは runtime に持ち込まない。**
6. **LLM へ渡す context も、失敗時の retry packet も、必ず NBAccess による redaction を通す。**

### 2.2 既存設計を壊さない位置づけ

新しい構成は次のように整理する。

- **NBAccess.wl**  
  security kernel / data kernel  
  confidential、access level、token、Notebook 実体、redaction、audit を管轄する。

- **claudecode.wl**  
  Notebook UI / orchestration  
  `ClaudeEval`、`ContinueEval`、`ClaudeUpdatePackage`、approval UI、Notebook との橋渡しを管轄する。

- **ClaudeRuntime.wl**  
  proposal loop / transaction loop の進行管理  
  ただし安全性判断そのものは持たない。

- **ClaudeTestKit.wl**  
  runtime と security contract の両方を検証する包括的テスト基盤。

---

## 3. 依存関係と責務分担

依存方向は次のように保つ。

```text
NBAccess.wl
   ↑
   │  (public safe API only)
   │
claudecode.wl  ─────→ ClaudeRuntime.wl
   ↑                    ↑
   │                    │
   └──── ClaudeTestKit.wl ────(mock provider / mock adapter / NBAccess test fixture)
```

### 3.1 NBAccess の責務

NBAccess は以下を担当する。

- privacy level を持つデータの保持とアクセス制御
- Notebook / cell / session の実体アクセス
- token / secret の管理
- access-level 付き API
- context の redaction
- held expression の静的検証
- 実行前後の access check
- audit 記録
- retry 用 failure packet の安全化

### 3.2 claudecode の責務

claudecode は以下を担当する。

- `ClaudeEval`
- `ContinueEval`
- `ClaudeUpdatePackage`
- Notebook UI
- palette
- approval dialog
- runtime adapter の具体実装
- Notebook と runtime の橋渡し
- 実行履歴表示

### 3.3 ClaudeRuntime の責務

ClaudeRuntime は以下だけを担当する。

- provider への問い合わせ
- proposal の受理
- validation / execution / retry の状態遷移
- turn state / transaction state の保持
- checkpoint 管理
- trace の構造化
- retry decision

**安全判定自体は NBAccess が行う**。ClaudeRuntime は「進行管理」に徹する。

### 3.4 ClaudeTestKit の責務

ClaudeTestKit は以下を担当する。

- MockProvider
- MockAdapter
- scenario runner
- golden trace normalization
- security regression test 補助
- no-leak assertion
- validation-denied assertion
- package update transaction の再現試験補助

---

## 4. この系における “tool” の捉え方

一般的な agent runtime では tool registry が中心になるが、この系では少し事情が違う。

この系では LLM が直接 tool を呼ぶのではなく、**Hold された Mathematica 式**を提案する。  
したがって、実質的な “tool surface” は次の 2 つの集合で定義される。

1. **NBAccess が公開する安全 head**
2. **claudecode が公開する高級操作 head**

したがって、当面の中核は独立した tool registry よりも、**Allowed Expression Surface** を明文化することである。

例として、将来的に許可対象となる安全 API の方向性は次のようなものになる。

```wl
NBReadCell[ref_, AccessLevel -> ...]
NBWriteCell[ref_, expr_, AccessLevel -> ...]
NBGetSessionSlice[sessionRef_, spec_, AccessLevel -> ...]
NBRedactedSummary[ref_, AccessLevel -> ...]
ClaudeComposeNotebookReply[...]
ClaudeInsertGeneratedCells[...]
```

LLM が生成可能なのは、このような許可された head を持つ `HoldComplete[...]` の式に限定する。

---

## 5. ClaudeRuntime の基本モデル

### 5.1 実行モデル

この系の turn loop は、通常の tool loop ではなく、**expression-proposal loop** である。

1. claudecode が `NBAccess` に安全な context packet を作らせる
2. ClaudeRuntime が provider に問い合わせる
3. provider は `HoldComplete[...]` を含む proposal を返す
4. claudecode adapter が `NBAccess` に validation を依頼する
5. validation 結果に応じて allow / deny / approval / rewrite を分岐する
6. allow なら `NBAccess` が実行する
7. 実行結果は redacted summary へ変換される
8. 必要なら次の proposal を要求する

### 5.2 核となるデータ構造

#### ClaudeContextPacket

LLM に渡してよい安全な context。

```wl
<|
  "VisibleContext" -> ...,
  "OpaqueRefs" -> {...},
  "PolicyDigest" -> ...,
  "AllowedHeads" -> {...},
  "SessionSummary" -> ...,
  "AccessEnvelope" -> ...
|>
```

#### ClaudeProposal

LLM が返す未実行の提案。

```wl
<|
  "HeldExpr" -> HoldComplete[ ... ],
  "Intent" -> "ReadAndSummarize",
  "Commentary" -> "...",
  "ModelUsage" -> <|...|>
|>
```

#### ClaudeValidationResult

NBAccess が返す validation 結果。

```wl
<|
  "Status" -> "Allowed" | "Denied" | "NeedsApproval" | "RewriteSuggested",
  "SanitizedHeldExpr" -> HoldComplete[ ... ],
  "RequiredReadLevel" -> ...,
  "RequiredWriteLevel" -> ...,
  "EffectClasses" -> {...},
  "ReferencedObjects" -> {...},
  "Violations" -> {...},
  "RedactionWarnings" -> {...}
|>
```

#### ClaudeExecutionResult

NBAccess 経由で実行した結果。

```wl
<|
  "Status" -> "Success" | "Failure",
  "ResultRef" -> ...,
  "VisibleResult" -> ...,
  "AuditRecord" -> ...,
  "EffectsPerformed" -> {...}
|>
```

#### ClaudeTurnState

runtime の内部状態。

```wl
<|
  "TurnId" -> ...,
  "ConversationState" -> ...,
  "LastContextPacket" -> ...,
  "Events" -> {...},
  "Status" -> "Running" | "Done" | "AwaitingApproval" | "Failed"
|>
```

### 5.3 ClaudeRuntime の公開 API

最小セットとしては次を想定する。

```wl
CreateClaudeRuntime[provider_, adapter_, opts___]
ClaudeRunTurn[runtime_, userIntent_, opts___]
ClaudeContinueTurn[runtime_, continuationInput_, opts___]
ClaudeRuntimeState[runtime_]
ClaudeTurnTrace[runtime_]
```

### 5.4 adapter の役割

`ClaudeRuntime` 自体は Notebook や secret を知らない。  
外界への接続は adapter を通して行う。

```wl
<|
  "BuildContextPacket" -> f1,
  "ValidateHeldExpr"   -> f2,
  "ExecuteHeldExpr"    -> f3,
  "SummarizeForModel"  -> f4,
  "PersistEvent"       -> f5,
  "RequestApproval"    -> f6
|>
```

この adapter を `claudecode.wl` が生成し、その内部で `NBAccess` を呼ぶ。

---

## 6. ClaudeEval と ClaudeUpdatePackage の違い

### 6.1 結論

両者は同じ ClaudeRuntime を使うが、**同じコマンドではない**。  
差は次のように整理する。

- **ClaudeEval**  
  対話的・即時反映型の proposal runtime

- **ClaudeUpdatePackage**  
  検証ゲート付き・コミット遅延型の transaction runtime

### 6.2 ClaudeEval の性格

ClaudeEval は、その場の notebook 文脈に対して

- 読み取り
- 要約
- notebook 挿入
- 軽い変換
- セッション継続

を行うための汎用 runtime である。

特徴:

- 即時性重視
- 副作用は比較的軽い
- 成功した式はその場で実行される
- retry は proposal 側中心で、実行済み副作用後の自動再実行は抑制する

### 6.3 ClaudeUpdatePackage の性格

ClaudeUpdatePackage は package 更新専用のワークフローであり、理想的には次の流れを取る。

1. package snapshot
2. proposal
3. shadow workspace への適用
4. static check
5. reload check
6. test 実行
7. commit 判定
8. 本番反映

特徴:

- transaction 的
- shadow workspace 前提
- commit 前に必ず検証ゲートを通す
- retry は checkpoint rollback 中心
- reload / test failure を repair proposal に変換できる

### 6.4 profile の違い

同じ ClaudeRuntime を使いつつ差を出すには、RunProfile を分けるのがよい。

- `"EvalProfile"`
- `"UpdatePackageProfile"`

profile によって少なくとも次が変わる。

- allowed expression surface
- access policy
- approval 要件
- trace 形式
- retry policy
- 成功条件

---

## 7. ClaudeEval の詳細仕様

### 7.1 目的

- notebook 文脈に基づく通常対話
- セル変換
- 要約
- 整形
- 安全な notebook 書き戻し

### 7.2 基本フェーズ

1. Prepare  
   `NBMakeContextPacket` により安全な context を生成

2. Propose  
   LLM が held expression を返す

3. Inspect  
   `NBInferExprRequirements`

4. Decide  
   `NBValidateHeldExpr`

5. Execute  
   allow のときのみ `NBExecuteHeldExpr`

6. Repackage  
   `NBRedactExecutionResult`

7. Continue  
   必要なら次 proposal

### 7.3 EvalProfile で許すもの

- notebook / session の安全な読み取り
- notebook への限定的挿入
- formatting
- text / code cell 生成
- 安全 API による局所変換

### 7.4 EvalProfile で避けるもの

- ファイルシステムへの広範な書き込み
- package source の本格更新
- commit / rollback
- token / secret 実体への接触
- unrestricted external process

### 7.5 ClaudeEval の retry 原則

ClaudeEval の retry は提案段階中心にする。

許可する retry:

- transport retry
- format retry
- validation-repair retry

原則として避ける retry:

- 実行済み副作用後の自動再実行
- approval が必要な式の自動実行
- confidential 関連 violation 後の継続

---

## 8. ClaudeUpdatePackage の詳細仕様

### 8.1 目的

- package 更新
- 安全な差分適用
- reload 検証
- test 通過
- commit / rollback

### 8.2 基本フェーズ

1. Snapshot  
   対象 package と関連ファイルのスナップショット取得

2. Proposal  
   更新式 / patch 式の提案

3. Validate proposal  
   head / access / effect / leak risk の確認

4. Apply to shadow  
   shadow workspace へ適用

5. Static checks  
   package structure / syntax / symbol consistency

6. Reload checks  
   isolated kernel での `Get`

7. Tests  
   session-local `test.wl` と常設テストの実行

8. Decide  
   commit / repair retry / full replan

9. Commit  
   本番反映

### 8.3 UpdatePackageProfile で許すもの

- package file の安全な読み取り
- patch / replacement
- shadow workspace 生成
- isolated reload
- test 実行
- commit / rollback

### 8.4 UpdatePackageProfile で重要な原則

- **本番ファイルは commit まで触らない**
- **shadow workspace で検証してから本番反映する**
- **reload failure / test failure は repair proposal に変換できる**
- **retry は checkpoint rollback を前提にする**

---

## 9. リトライ機構の基本設計

### 9.1 リトライ設計の原則

堅固な retry を実現するには、一律の再試行ではなく、**失敗分類ベースの retry** にする必要がある。

重要原則:

1. retry は failure class に応じて分岐する
2. retry してよいものだけ retry する
3. 権限昇格を自動 retry で行わない
4. retry に使う失敗情報も redaction を通す
5. security violation は即停止する
6. UpdatePackage では checkpoint rollback を前提とする

### 9.2 失敗分類

#### A. Transport / Provider Transient

例:
- timeout
- rate limit
- 一時的 API error
- CLI 呼び出し失敗

対応:
- 同じ入力で再試行
- backoff あり

#### B. Model Format Failure

例:
- `HoldComplete` でない
- 式が壊れている
- 必須構造がない
- delimiter 不備

対応:
- 出力制約を強めて再提案
- 副作用前なので安全

#### C. Validation Denial

例:
- 禁止 head
- access level 不足
- confidential 再流出のおそれ
- 許可外副作用

対応:
- deny 理由を redacted して返す
- 権限を自動拡張しない
- 別案を再提案させる

#### D. Execution Transient

例:
- notebook lock
- temp file conflict
- FE の一時的不整合
- lock 競合

対応:
- idempotent と判定できる場合のみ再実行

#### E. Transactional Failure

主に UpdatePackage 用。

例:
- patch 適用失敗
- reload error
- test failure
- merge failure
- commit 前検証失敗

対応:
- checkpoint へ戻す
- failure packet を作る
- repair proposal を要求する

#### F. Security Violation

例:
- 秘匿実体が trace / prompt に出そう
- token 実体への接触
- confidential dereference 不正

対応:
- 即停止
- 自動 retry しない

---

## 10. ClaudeEval のリトライ仕様

ClaudeEval では aggressive な retry は避ける。

### 10.1 provider retry

- transport / provider transient 用
- 最大 2〜3 回
- exponential backoff

### 10.2 format retry

- 壊れた出力形式の再提案
- 制約を強める
  - `HoldComplete` で返す
  - 許可 head のみ使う
  - 1 式だけ返す

### 10.3 validation-repair retry

- deny 理由を redacted form で返す
- 同じ intent を許可 head だけで達成させる
- 最大 1〜2 回

### 10.4 原則 retry しないもの

- 実行済み副作用後の再実行
- approval 必須の式
- confidential 関連 violation

---

## 11. ClaudeUpdatePackage のリトライ仕様

### 11.1 基本姿勢

UpdatePackage は commit まで本番反映を遅延できるため、ClaudeEval より強い retry を許容できる。

### 11.2 必須要素

#### shadow workspace

- package 更新はまず shadow copy に適用する
- 本番 `.wl` は commit まで変更しない

#### checkpoint

少なくとも次の checkpoint を持つ。

- `C0`: original snapshot
- `C1`: prompt/context fixed
- `C2`: proposal accepted
- `C3`: patch applied to shadow
- `C4`: static validation passed
- `C5`: reload passed
- `C6`: tests passed
- `C7`: committed

#### failure packet

失敗時に provider へ返す情報は自由文ではなく構造化する。

```wl
<|
  "Stage" -> "Reload",
  "FailureType" -> "ReloadError",
  "Messages" -> {...},
  "ChangedSymbols" -> {...},
  "PatchSummary" -> ...,
  "TestSummary" -> ...,
  "RetryConstraints" -> {...}
|>
```

この packet も NBAccess の redaction を通す。

### 11.3 UpdatePackage の retry 段階

#### 段階 1: transport retry

- API / CLI 一時失敗
- 同じ request を再送

#### 段階 2: proposal retry

- 出力形式や patch 形式の問題
- 制約を強めて再提案

#### 段階 3: repair retry

- reload error
- test failure
- patch conflict

対応:
- checkpoint へ戻す
- failure packet を作る
- repair proposal を要求
- shadow で再検証する

#### 段階 4: full replan

- 局所修復で直らない場合
- failed repairs の要約を与え、一から組み直させる
- 多くても 1 回まで

---

## 12. RetryPolicy を明示オブジェクトにする

retry を分散した if 文で書かず、明示的な policy object として扱う。

例:

```wl
<|
  "TransportRetryMax" -> 3,
  "FormatRetryMax" -> 2,
  "ValidationRepairMax" -> 2,
  "ReloadRepairMax" -> 2,
  "TestRepairMax" -> 2,
  "FullReplanMax" -> 1,
  "BackoffSeconds" -> {2, 5, 15},
  "RetryOn" -> {
    "TransportTransient",
    "ModelFormatError",
    "ReloadError",
    "TestFailure",
    "PatchApplyConflict"
  },
  "NeverRetryOn" -> {
    "SecurityViolation",
    "AccessEscalationRequired",
    "ConfidentialLeakRisk"
  }
|>
```

`ClaudeEval` と `ClaudeUpdatePackage` は、この値が異なる profile として実装する。

---

## 13. NBAccess に追加すべき API

この設計を支えるため、NBAccess には少なくとも次の公開 API を追加する。

### 13.1 context packet 生成

```wl
NBMakeContextPacket[nb_, accessSpec_, opts___]
```

### 13.2 式の要求推論

```wl
NBInferExprRequirements[heldExpr_, accessSpec_, opts___]
```

### 13.3 式の検証

```wl
NBValidateHeldExpr[heldExpr_, accessSpec_, opts___]
```

### 13.4 式の実行

```wl
NBExecuteHeldExpr[heldExpr_, accessSpec_, opts___]
```

### 13.5 実行結果の redaction

```wl
NBRedactExecutionResult[result_, accessSpec_, opts___]
```

### 13.6 retry packet の安全化

```wl
NBMakeRetryPacket[failureAssoc_, accessSpec_, opts___]
```

### 13.7 audit

```wl
NBAuditAppend[eventAssoc_]
NBAuditRead[spec___]
```

---

## 14. claudecode に追加すべき API

### 14.1 runtime adapter 生成

```wl
ClaudeBuildRuntimeAdapter[nb_, opts___]
```

### 14.2 runtime 起動

```wl
ClaudeStartRuntime[nb_, providerSpec_, opts___]
```

### 14.3 proposal approval UI

```wl
ClaudeApproveProposalDialog[validationResult_, opts___]
```

### 14.4 package update transaction 起動

```wl
ClaudeStartPackageUpdate[packageSpec_, opts___]
```

### 14.5 package update trace 表示

```wl
ClaudeRenderUpdateTrace[trace_, opts___]
```

---

## 15. ClaudeRuntime に追加すべき API

### 15.1 基本 API

```wl
CreateClaudeRuntime[provider_, adapter_, opts___]
ClaudeRunTurn[runtime_, userIntent_, opts___]
ClaudeContinueTurn[runtime_, continuationInput_, opts___]
ClaudeRuntimeState[runtime_]
ClaudeTurnTrace[runtime_]
```

### 15.2 retry / failure 分類 API

```wl
ClaudeClassifyFailure[failure_, opts___]
ClaudeShouldRetryQ[failureClass_, retryPolicy_, state_, opts___]
ClaudeBuildRetryRequest[state_, failurePacket_, opts___]
ClaudeRollbackToCheckpoint[runtime_, checkpoint_, opts___]
```

### 15.3 package update 用 API

```wl
ClaudeRunUpdateTransaction[runtime_, updateSpec_, opts___]
ClaudeUpdateTransactionState[runtime_]
ClaudeUpdateTrace[runtime_]
```

---

## 16. ClaudeTestKit の詳細仕様

### 16.1 ClaudeTestKit の目的

- runtime 単体試験
- security contract 試験
- retry / repair 試験
- package update transaction 試験
- no-leak regression

### 16.2 必要な構成要素

#### CreateMockProvider

```wl
CreateMockProvider[script_]
```

#### CreateMockAdapter

```wl
CreateMockAdapter[spec_]
```

#### CreateNBAccessTestFixture

NBAccess の実公開 API を使う安全 fixture。

```wl
CreateNBAccessTestFixture[opts___]
```

#### RunClaudeScenario

```wl
RunClaudeScenario[scenarioAssoc_]
```

#### NormalizeClaudeTrace

```wl
NormalizeClaudeTrace[trace_]
```

#### AssertNoSecretLeak

```wl
AssertNoSecretLeak[trace_, opts___]
```

#### AssertValidationDenied

```wl
AssertValidationDenied[result_, opts___]
```

### 16.3 重要なテスト分類

#### runtime tests
- text only turn
- single proposal
- multiple proposal continuation
- retry decision
- approval waiting

#### security contract tests
- confidential value が prompt に出ない
- forbidden head が deny される
- access 不足が正しく判定される
- audit に秘密の実体が残らない
- retry packet に秘密の実体が出ない

#### update transaction tests
- shadow apply
- reload failure repair
- test failure repair
- rollback correctness
- full replan への遷移

---

## 17. `ClaudeUpdatePackage` の `test.wl` の位置づけ

既存の session-local `test.wl` は今後も有用である。  
ただし役割は明確に分ける。

### 17.1 残すべき役割

- その更新セッションの最小確認
- 修正した機能に対する局所回帰
- 常設 regression へ昇格する候補

### 17.2 常設テストとの関係

ClaudeUpdatePackage の test phase では、次の順で使う。

1. session-local `test.wl`
2. package 固有の Regression
3. 共通 Contract tests
4. 必要に応じて broader Integration tests

この順により、局所性と包括性を両立する。

---

## 18. 実装順

実装順は、既存の安全モデルを崩さず、かつ早い段階でテスト可能にすることを優先して決める。

### Phase 1: 仕様固定と境界定義

最初に実装する前に、次を文書化して固定する。

1. `Allowed Expression Surface`
2. `ClaudeContextPacket` の形式
3. `ClaudeValidationResult` / `ClaudeExecutionResult` の形式
4. failure class の分類
5. `RetryPolicy` の形式
6. EvalProfile / UpdatePackageProfile の差

**理由:**  
ここが曖昧なまま実装すると、NBAccess / claudecode / Runtime の責務が混ざるため。

### Phase 2: NBAccess の最小拡張

次に NBAccess に最小限の公開 API を足す。

優先順位:

1. `NBMakeContextPacket`
2. `NBInferExprRequirements`
3. `NBValidateHeldExpr`
4. `NBExecuteHeldExpr`
5. `NBRedactExecutionResult`

可能なら同時に:

6. `NBMakeRetryPacket`
7. `NBAuditAppend`

**理由:**  
runtime を作る前に、安全 kernel 側の境界 API を確立する必要がある。

### Phase 3: ClaudeRuntime の最小骨格

次に runtime を最小構成で作る。

優先順位:

1. `CreateClaudeRuntime`
2. `ClaudeRunTurn`
3. `ClaudeContinueTurn`
4. `ClaudeRuntimeState`
5. `ClaudeTurnTrace`

この段階ではまず **ClaudeEval 相当の proposal loop のみ** を実装する。

**理由:**  
transaction runtime より先に、最小の expression-proposal loop を安定させる方が容易である。

### Phase 4: ClaudeTestKit の導入

runtime 骨格ができたら、すぐに test kit を入れる。

優先順位:

1. `CreateMockProvider`
2. `CreateMockAdapter`
3. `RunClaudeScenario`
4. `NormalizeClaudeTrace`
5. `AssertNoSecretLeak`
6. `AssertValidationDenied`

**理由:**  
runtime と security contract を早期から回帰試験できるようにするため。

### Phase 5: claudecode と ClaudeRuntime の接続

次に claudecode 側に adapter と UI を足す。

優先順位:

1. `ClaudeBuildRuntimeAdapter`
2. `ClaudeStartRuntime`
3. `ClaudeApproveProposalDialog`
4. `ClaudeEval` を runtime 経由へ段階的に移行

**理由:**  
runtime 単体が動いてから Notebook UI に接続した方が問題の切り分けがしやすい。

### Phase 6: ClaudeEval の retry 実装

次に ClaudeEval へ軽量 retry を入れる。

優先順位:

1. transport retry
2. format retry
3. validation-repair retry

この段階では、実行済み副作用後の aggressive retry は入れない。

**理由:**  
Eval は即時副作用があるため、まず安全な範囲の retry に限定すべきである。

### Phase 7: ClaudeUpdatePackage の transaction 化

ここから package update workflow を本格化する。

優先順位:

1. snapshot
2. shadow workspace
3. static check
4. reload check
5. test phase
6. commit / rollback

この段階で、今の簡易 retry は `"ReloadRepair"` 相当の一段として再定義する。

**理由:**  
既存の `ContinueUpdate` 的挙動を捨てずに、transaction retry engine へ自然に昇格させるため。

### Phase 8: UpdatePackage の包括的 retry 実装

優先順位:

1. failure class 分類
2. checkpoint 管理
3. repair retry
4. test failure retry
5. full replan

**理由:**  
shadow / reload / tests が揃わないと、transaction retry は正しく設計できないため。

### Phase 9: 常設テスト体系の整備

最後にテスト体系を固定化する。

ディレクトリ例:

```text
Tests/
  RunTests.wl
  Unit/
  Contract/
  Integration/
  Golden/
  Regression/
  Smoke/
```

併せて、session-local `test.wl` から常設 Regression へ昇格する運用を決める。

**理由:**  
設計と runtime が安定してからテスト資産を整理した方が、無駄な書き換えが少ない。

---

## 19. 実装優先順位の要約

### 最優先

1. NBAccess の公開安全 API
2. ClaudeRuntime の最小 proposal loop
3. ClaudeTestKit の mock / no-leak / deny assertion

### 次点

4. claudecode adapter と ClaudeEval 接続
5. ClaudeEval の retry
6. UpdatePackage の shadow workspace 化

### その次

7. UpdatePackage の checkpoint / repair retry
8. full replan
9. regression / golden / smoke の整備

---

## 20. まとめ

この仕様では、

- **NBAccess = security kernel**
- **claudecode = Notebook orchestrator**
- **ClaudeRuntime = proposal / transaction の進行管理**
- **ClaudeTestKit = runtime + security regression harness**

という役割分担を保つ。

また、

- **ClaudeEval は対話的 proposal runtime**
- **ClaudeUpdatePackage は transaction runtime**

として明確に分ける。

そして retry は一律再試行ではなく、

- 失敗分類
- redacted retry packet
- retry policy
- UpdatePackage では checkpoint rollback

に基づいて設計する。

この方針により、既存の confidential / access-control / Notebook 中心設計を崩さずに、より包括的で堅固な runtime と test 基盤を追加できる。
