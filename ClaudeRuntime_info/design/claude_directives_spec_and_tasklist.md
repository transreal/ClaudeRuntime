# CLAUDE.md / rules / skills 導入仕様 & 実装タスクリスト
## 対象
- `claudecode(36).wl`
- `ClaudeRuntime(2).wl`
- `ClaudeOrchestrator.wl`
- `ClaudeTestKit(2).wl`
- `NBAccess(29).wl`

---

## 1. 目的

このシステムに、Claude Code / Claw Code の流儀を参考にしつつ、

- `.claude/CLAUDE.md`
- `.claude/rules/*.md`
- `.claude/skills/<skill-name>/SKILL.md`

を導入する。

要件は次の2つである。

1. **ファイル形式・ディレクトリ構造は Claude Code 互換**
2. **大規模 LLM / 小規模 LLM / マルチエージェント実行に応じて、注入方法だけを可変にする**

---

## 2. 基本方針

### 2.1 at-rest と in-memory を分ける

#### at-rest
ファイルシステム上の形式は完全互換とする。

- `.claude/CLAUDE.md`
- `.claude/rules/*.md`
- `.claude/skills/<name>/SKILL.md`

#### in-memory
実行時には task / role / model size / token budget に応じて、読み込んだ directive 群を可変投影する。

モードは次を持つ。

- `Full`
- `Summary`
- `Index`
- `Lazy`
- `None`

### 2.2 役割分担

- **claudecode**  
  directive の読込・解決・投影の中心
- **ClaudeRuntime**  
  directive を packet として運ぶだけ
- **ClaudeOrchestrator**  
  role / task ごとの選別と worker 配布
- **NBAccess**  
  rules 由来の hard policy を受け取る受け口
- **ClaudeTestKit**  
  directive 機構の deterministic test

---

## 3. 現状コードから見た前提

### 3.1 既にあるもの
`claudecode(36).wl` には、すでに以下の足場がある。

- `.claude/CLAUDE.md`, `.claude/rules/`, `.claude/skills/` を作業ディレクトリへコピーする仕組み
- `CLAUDE.md` の探索・読込
- prompt 先頭への `CLAUDE.md` 注入
- directive の一覧・更新・同期系関数

つまり、**ファイル互換の土台は既にある**。

### 3.2 まだ足りないもの
不足しているのは主に以下。

1. rules / skills の first-class 化
2. 小規模 LLM 向けの圧縮投影
3. Orchestrator の role / task ごとの選別
4. TestKit での directive fixture / scenario test
5. rules 由来 policy の NBAccess 反映

---

## 4. 互換仕様

### 4.1 ディレクトリ構造
次を正規構造とする。

```text
.claude/
  CLAUDE.md
  rules/
    00-autoeval-prohibited.md
    40-no-secret-exfiltration.md
  skills/
    wolfram-general/
      SKILL.md
    notebook-style/
      SKILL.md
    slide-authoring/
      SKILL.md
```

### 4.2 CLAUDE.md
役割:

- プロジェクト全体の方針
- rules / skills の入口
- 大枠の行動指針
- 共通コンテキスト

### 4.3 rules
役割:

- 破ってはいけない制約
- 実行・秘密保持・autoeval 禁止などの hard / semi-hard rule
- skills より優先される

形式:

- Markdown
- 1ファイル1規則群
- 数字 prefix を許容

### 4.4 SKILL.md
役割:

- 具体的手順
- 実例
- role / task に応じた実践知
- prompt として展開可能な知識パッケージ

許容形式:

- Markdown 本文
- frontmatter を許容
- 最低限 `name`, `description`
- できれば `tags`, `tools`, `when_to_use`, `model_hint`, `token_hint`

---

## 5. 新設する中核概念

### 5.1 DirectiveRepository
ファイルシステム上の `.claude` 群を探索・読込・キャッシュしたもの。

### 5.2 DirectiveBundle
「今回の task / role / model に対して使う directive 群」。

例:

```wl
<|
  "ClaudeMD" -> "...",
  "ActiveRules" -> {...},
  "ActiveSkills" -> {...},
  "ProjectionMode" -> "Summary",
  "TokenBudget" -> 2500
|>
```

### 5.3 PromptProjection
DirectiveBundle を prompt 向け文字列へ変換する層。

---

## 6. 重要原則

### 6.1 rules は always-on、skills は selection
- rules は原則として常時有効
- skills は role / task / budget に応じて選択

### 6.2 NBAccess は最上位 safety
優先順位は次。

1. NBAccess の hard safety
2. Orchestrator の capability / deny heads
3. directive rules
4. CLAUDE.md
5. selected skills

### 6.3 worker へ全文を配らない
マルチエージェント時、worker には全文を無差別に配布しない。  
role / task に応じて絞り込み、必要なら summary / index / lazy に落とす。

---

## 7. model size ごとの可変構造

### 7.1 Large LLM
推奨:

- `CLAUDE.md` 全文
- rules 全文
- relevant skill 全文または長要約

既定モード:
- `Full`
- `Summary`

### 7.2 Small LLM
推奨:

- `CLAUDE.md` は短要約
- rules は 1 行 rule 化
- skills は
  - `name`
  - `description`
  - `when_to_use`
  - 最重要手順 3〜5 行
 だけに圧縮

既定モード:
- `Index`
- `Lazy`

### 7.3 自動選択
`ModelSpec` または推定 context window で mode を決める。

擬似コード:

```wl
If[estimatedContextWindow >= 64000,
  mode = "Full",
  If[estimatedContextWindow >= 16000,
    mode = "Summary",
    mode = "Index"
  ]
]
```

---

## 8. 実装仕様

## 8.1 claudecode.wl
責務:
- `.claude` 探索
- repository 読込
- bundle 解決
- prompt 投影
- 単一エージェント向け BuildContext への注入

### 追加関数
- `ClaudeLoadDirectiveRepository[root_]`
- `ClaudeFindDirectiveRoots[startDir_]`
- `ClaudeInvalidateDirectiveCache[]`
- `ClaudeResolveDirectiveBundle[task_, opts___]`
- `ClaudeProjectDirectives[bundle_, opts___]`
- `ClaudeSelectSkills[repo_, task_, opts___]`
- `ClaudeSummarizeDirective[item_, opts___]`
- `ClaudeDirectiveTokenEstimate[item_]`

### BuildContext への追加
`ClaudeBuildRuntimeAdapter` の `"BuildContext"` が返す packet に追加:

```wl
"DirectiveBundle" -> bundle,
"DirectivePrompt" -> projectedText,
"DirectiveMeta" -> <|
  "Mode" -> mode,
  "Budget" -> budget,
  "SelectedSkillNames" -> {...},
  "SelectedRuleNames" -> {...}
|>
```

### QueryProvider への追加
prompt 組立時に `DirectivePrompt` を system prompt または prefix block として挿入する。

---

## 8.2 ClaudeRuntime.wl
責務:
- directive を知識として持たない
- `BuildContext` から来た `DirectiveBundle` / `DirectivePrompt` を運ぶ

### 追加してよいもの
- trace に
  - `DirectiveMode`
  - `DirectiveBudget`
  - `SelectedSkills`
  を残す

### 追加しないもの
- `.claude` 探索
- rules / skills パース
- skill 選択
- directive 圧縮

---

## 8.3 ClaudeOrchestrator.wl
責務:
- task / role / worker ごとの directive 再投影
- selected skills / rules の role-aware な選別

### 追加関数
- `ClaudeResolveDirectiveBundleForTask[repo_, taskSpec_, role_, opts___]`
- `ClaudeProjectDirectivesForRole[bundle_, role_, modelSpec_, budget_]`
- `ClaudeSelectSkillsForTask[repo_, taskSpec_, depArtifacts_, opts___]`

### role ごとの原則

#### Explore
- rules は比較的厚め
- 読み取り系 / 探索系 skill 優先
- output schema と矛盾しない軽量指示

#### Plan
- `CLAUDE.md` 要約
- 構成設計系 skill
- 絶対禁止 rules

#### Draft
- topic 特化 skill
- notebook / slide / style skill
- token budget は強めに制限

#### Verify
- rules を最も厚く
- 検証 skill を優先

#### Commit
- notebook mutation rules
- autoeval 禁止
- commit 専用 skill

### worker BuildContext に追加
```wl
"DirectiveBundle" -> roleBundle,
"DirectivePrompt" -> projectedText,
"SelectedSkills" -> {...},
"SelectedRules" -> {...}
```

---

## 8.4 NBAccess.wl
責務:
- filesystem 上の `.claude` を読みに行かない
- bundle 化された rules を受けて hard policy へ反映する

### 追加してよい関数
- `NBDirectiveDerivedPolicy[bundle_]`
- `NBDirectiveWarnings[bundle_, heldExpr_]`

### 例
- `autoeval-prohibited` rule があれば autoevaluate 関連を deny
- `no-secret-exfiltration` rule があれば secret 関連 head を強化 deny

---

## 8.5 ClaudeTestKit.wl
責務:
- directive 投影・選別・small/large モード切替を deterministic に試験

### 追加関数
- `CreateMockDirectiveRepository[data_]`
- `CreateMockDirectiveBundle[data_]`
- `CreateMockSkillSelection[data_]`
- `RunDirectiveScenario[scenario_]`

### 代表シナリオ
1. `Full` mode で全文注入
2. `Summary` mode で要約注入
3. `Index` mode で skill 名一覧だけ注入
4. `Lazy` mode で follow-up 展開
5. Explore role では commit skill を選ばない
6. Commit role では notebook mutation rule が必須
7. Small LLM mode では token budget 超過時に圧縮投影へ切替

---

## 9. skill 選択アルゴリズム

### 9.1 手がかり
- user instruction
- `TaskSpec["Goal"]`
- `TaskSpec["Role"]`
- notebook context
- dependency artifacts
- rules
- model budget

### 9.2 最低限の scoring
- skill 名が task goal に部分一致: `+5`
- role とタグが一致: `+4`
- instruction と skill 本文の語一致: `+3`
- output schema との関連: `+2`

### 9.3 将来拡張
- embedding ベース再ランキング
- summary cache
- usage history ベース再ランキング

---

## 10. 導入順序

### Stage 1: 単一エージェント対応
- DirectiveRepository 実装
- `.claude/CLAUDE.md`, `.claude/rules/*.md`, `.claude/skills/*/SKILL.md` 読込
- BuildContext に DirectiveBundle 追加
- `Full / Summary / Index` 投影実装
- skill 選択の簡易版

### Stage 2: Orchestrator 対応
- role 別 directive projection
- task ごとの skill 選択
- worker / reducer / committer 別 bundle

### Stage 3: TestKit 対応
- directive fixture
- projection test
- role selection test
- small / large model test

### Stage 4: Lazy 展開
- index だけ渡す
- follow-up turn で skill 展開
- token budget 超過時に再投影

---

# 実装タスクリスト

## A. claudecode 実装タスク

### A-1. Repository 読込
- [ ] `.claude/CLAUDE.md` 読込関数を一般化する
- [ ] `.claude/rules/*.md` を列挙・読込する
- [ ] `.claude/skills/*/SKILL.md` を列挙・読込する
- [ ] SKILL.md frontmatter パーサを実装する
- [ ] directive cache を作る
- [ ] cache invalidation API を実装する

### A-2. Bundle 解決
- [ ] `ClaudeResolveDirectiveBundle` を実装する
- [ ] selected rules / selected skills を保持する Association 形式を定義する
- [ ] `DirectiveMeta` 形式を定義する

### A-3. Projection
- [ ] `ClaudeProjectDirectives[..., "Full"]`
- [ ] `ClaudeProjectDirectives[..., "Summary"]`
- [ ] `ClaudeProjectDirectives[..., "Index"]`
- [ ] `DirectiveTokenEstimate` を実装する
- [ ] budget 超過時の mode downgrade を実装する

### A-4. BuildContext 統合
- [ ] `ClaudeBuildRuntimeAdapter["BuildContext"]` に `DirectiveBundle` を追加
- [ ] `DirectivePrompt` を packet に追加
- [ ] `DirectiveMeta` を packet に追加

### A-5. QueryProvider 統合
- [ ] system prompt 組立に `DirectivePrompt` を挿入
- [ ] `UseClaudeMD` / `Rules` / `Skills` / `DirectiveMode` オプションを追加
- [ ] large / small model 自動切替を実装

---

## B. ClaudeRuntime 実装タスク

- [ ] `DirectiveBundle` を runtime packet の一部としてそのまま運べることを確認
- [ ] EventTrace に `DirectiveMode` を記録する
- [ ] EventTrace に `SelectedSkills` / `SelectedRules` を記録する
- [ ] directive 未設定時でも runtime がそのまま動くことを確認

---

## C. ClaudeOrchestrator 実装タスク

### C-1. role-aware bundle
- [ ] `ClaudeResolveDirectiveBundleForTask` を実装
- [ ] `ClaudeProjectDirectivesForRole` を実装
- [ ] `ClaudeSelectSkillsForTask` を実装

### C-2. role policy
- [ ] Explore role の既定選別規則
- [ ] Plan role の既定選別規則
- [ ] Draft role の既定選別規則
- [ ] Verify role の既定選別規則
- [ ] Commit role の既定選別規則

### C-3. worker packet 統合
- [ ] worker BuildContext に `DirectiveBundle` を追加
- [ ] `SelectedSkills` / `SelectedRules` を worker に渡す
- [ ] worker へ全文を配らない budget 制御を入れる

---

## D. NBAccess 実装タスク

- [ ] `NBDirectiveDerivedPolicy` を実装
- [ ] `NBDirectiveWarnings` を実装
- [ ] bundle 由来 rule を hard safety に重ねるインターフェースを作る
- [ ] `autoeval-prohibited` の例を実装
- [ ] `no-secret-exfiltration` の例を実装

---

## E. ClaudeTestKit 実装タスク

### E-1. fixture
- [ ] `CreateMockDirectiveRepository`
- [ ] `CreateMockDirectiveBundle`
- [ ] `CreateMockSkillSelection`

### E-2. scenario runner
- [ ] `RunDirectiveScenario` を実装
- [ ] projection mode テストを追加
- [ ] role selection テストを追加
- [ ] small / large model mode テストを追加

### E-3. assertion
- [ ] `AssertDirectiveModeUsed`
- [ ] `AssertSelectedSkills`
- [ ] `AssertSelectedRules`
- [ ] `AssertDirectiveBudgetRespected`
- [ ] `AssertLazyExpansionTriggered`

---

## F. サンプル directives 作成タスク

- [ ] `.claude/CLAUDE.md` サンプル
- [ ] `.claude/rules/00-autoeval-prohibited.md`
- [ ] `.claude/rules/40-no-secret-exfiltration.md`
- [ ] `.claude/skills/wolfram-general/SKILL.md`
- [ ] `.claude/skills/notebook-style/SKILL.md`
- [ ] `.claude/skills/slide-authoring/SKILL.md`
- [ ] `.claude/skills/orchestrator-worker/SKILL.md`

---

## G. 導入後の確認項目

- [ ] 単一エージェント `ClaudeEval` で CLAUDE.md / rules / skills が反映される
- [ ] Explore / Draft / Verify / Commit で選ばれる skills が変わる
- [ ] small model では `Index` または `Lazy` に落ちる
- [ ] large model では `Full` または `Summary` が使われる
- [ ] rules が skill より優先される
- [ ] NBAccess hard safety が markdown rules より優先される
- [ ] directive なしでも後方互換で動く

---

## 11. 最小マイルストーン

### Milestone 1
- `.claude/CLAUDE.md/rules/skills` をすべて読める
- `BuildContext` に `DirectiveBundle` を載せる
- `Full / Summary / Index` が動く

### Milestone 2
- Orchestrator が role ごとに selected skills を切り替える
- small / large model で mode 自動切替

### Milestone 3
- TestKit の directive scenario が通る
- rules -> NBAccess policy 反映の代表例が動く

### Milestone 4
- `Lazy` 展開
- usage history / embedding を使った skill 再ランキング

---

## 12. 結論

この導入は、現在の設計と整合的である。

- `claudecode` に filesystem / projection を置く
- `ClaudeRuntime` は抽象のままにする
- `ClaudeOrchestrator` で role-aware に再投影する
- `NBAccess` は hard safety を維持する
- `ClaudeTestKit` で deterministic に検証する

最重要の設計原則は次の2つ。

1. **ファイル形式は Claude Code 互換のまま保持する**
2. **prompt 注入の仕方だけを model size / role / task に応じて可変にする**
