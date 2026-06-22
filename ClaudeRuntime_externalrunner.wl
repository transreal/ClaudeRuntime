(* ClaudeRuntime_externalrunner.wl -- External WolframScript runner / launcher (Phase 4.A)

   位置付け:
     ClaudeOrchestrator_external_executor_task_placement_spec_v7 の Phase 4 (runner) の
     プランビング核。ClaudeOrchestrator_workflow.wl の External executor フック
     ($ClaudeExternalJobLauncher / StatusReader / Killer) に実体を与える。

   本ファイルは2つの立場で使われる:
     (A) Orchestrator (親) 側: launcher / killer / job dir / manifest を提供。
         ClaudeWireExternalRunner[] で Workflow フックへ結線。
     (B) runner (子, 別 wolframscript プロセス) 側: ClaudeRunTaskFromManifest[jobDir]
         が manifest を読み handler を実行して status.json / output.wxf を書く。

   Phase 4.A スコープ:
     - wolframscript 解決 / durable job root / manifest / pid.json / 実 StartProcess 起動
     - runner entrypoint + handler registry + テスト用 "Echo" handler
     - status.json は atomic write (tmp -> rename)
   Phase 4.B (一部実装済み):
     - [済] 機密 input/output の実暗号化 (ConfidentialHandling=="EncryptedBundle")。
            SourceVault crypto (SourceVaultSealPayload/UnsealPayload) に委譲。鍵は
            NBAccess credential store に閉じる。cross-process 共有のため SystemCredential
            必須・fail-closed。子 run.wls は軽量 crypto 2 package を先にロードする。
     - [済] error.txt redaction (機密ジョブでは result 本文を吐かない)。
     - [残] ReferenceOnly の詳細運用・credential-ref 解決
     - [残] NBAccess 本体ロード + PolicySnapshot 適用 + NBCheck* I/O guard (cooperative enforcement)
     - [残] pid.txt ベースの cross-restart kill (image/JobID 同一性) と orphan recovery 本体
     - [残] stdout/stderr.log キャプチャ

   Load:
     Block[{$CharacterEncoding = "UTF-8"}, Get["ClaudeRuntime_externalrunner.wl"]]
*)

(* パッケージ自身の絶対パスを捕捉 (runner bootstrap が Get するため) *)
ClaudeRuntime`Private`$iExternalRunnerFile =
  If[StringQ[$InputFileName] && $InputFileName =!= "", $InputFileName, Missing[]];

BeginPackage["ClaudeRuntime`"];

ClaudeRunTaskFromManifest::usage =
  "ClaudeRunTaskFromManifest[jobDir] は runner (子プロセス) のエントリポイント。manifest.wl を読み、input.wxf を読み、Handler を実行し、output.wxf と status.json (Completed/Failed) を書く。";

ClaudeRegisterExternalTaskHandler::usage =
  "ClaudeRegisterExternalTaskHandler[name, fn, opts] は External task handler を登録する。fn は <|\"Manifest\"->m, \"Input\"->inputData|> を受け取り Association を返す。";

ClaudeResolveWolframScriptExecutable::usage =
  "ClaudeResolveWolframScriptExecutable[] は wolframscript 実行ファイルを解決する。優先順: $ClaudeWolframScriptExecutable > Environment[\"WOLFRAMSCRIPT\"] > $InstallationDirectory 近傍 > PATH 上の \"wolframscript\"。";

ClaudeExternalJobRoot::usage =
  "ClaudeExternalJobRoot[] は durable な job root ($ClaudeExternalJobRoot または $UserBaseDirectory/ClaudeRuntime/jobs) を返し、無ければ作成する。";

ClaudeExternalWolframScriptLauncher::usage =
  "ClaudeExternalWolframScriptLauncher[jobSpec] は job dir を作り manifest/input/run.wls を書き、wolframscript runner を StartProcess で起動して <|\"Status\"->\"Launched\", \"JobID\", \"JobDir\", \"PID\"|> を返す。$ClaudeExternalJobLauncher へ結線して使う。";

ClaudeExternalInProcessLauncher::usage =
  "ClaudeExternalInProcessLauncher[jobSpec] は job dir/manifest を準備し runner を現在のカーネルで同期実行する (別プロセスを起こさない)。テスト・単一ライセンス環境・短時間タスク用。long-running には使わない (main kernel をブロックする)。";

ClaudeExternalWolframScriptKiller::usage =
  "ClaudeExternalWolframScriptKiller[awaitMeta] は起動済み ProcessObject を同一性確認後に終了する。$ClaudeExternalJobKiller へ結線して使う。";

ClaudeWireExternalRunner::usage =
  "ClaudeWireExternalRunner[] は ClaudeOrchestrator`Workflow` の External executor フック ($ClaudeExternalJobLauncher / StatusReader / Killer) を本パッケージの実装へ結線する。";

ClaudeExternalJobRecover::usage =
  "ClaudeExternalJobRecover[opts] は job root を走査し、status が Running だが registry に無い孤児 job を回収する。opts \"Kill\"->True で pid.json 同一性確認後に kill、\"Mark\"->True で status を Expired に更新。返り値に回収結果。";

$ClaudeExternalProcessProbe::usage =
  "$ClaudeExternalProcessProbe は PID のプロセス情報を返す関数 (fn[pid] -> <|\"Alive\"->_, \"Executable\"->_|> | None)。Automatic は OS 問い合わせ (Windows: tasklist)。cross-restart kill の同一性確認に使う。テストで mock 注入可。";
$ClaudeExternalProcessKill::usage =
  "$ClaudeExternalProcessKill は PID を強制終了する関数 (fn[pid] -> Bool)。Automatic は OS kill (Windows: taskkill /F)。テストで mock 注入可。";

ClaudeLintExternalHandler::usage =
  "ClaudeLintExternalHandler[HoldComplete[body]] は handler 本体に raw I/O (Export/Import/URLRead/StartProcess/OpenWrite/DeleteFile/DialogInput/AuthenticationDialog 等) が直書きされていないか検査する。handler は NBChecked* / NBCheck* 経由で I/O すべき (v7 §13/§16)。<|\"Clean\"->_, \"Violations\"->{...}|>。";

$ClaudeBatchProcessorOverrides::usage =
  "$ClaudeBatchProcessorOverrides は batch handler (BulkFileProcessing/BulkLLMProcessing/MailFetch/SourceVaultIngest) の per-item processor を差し替える Association (handlerName -> Function[{item,idx,ctx}, <|\"Status\"->\"OK\"|\"Failed\",\"Result\"->_|>])。連結 (override が最優先)。";

$ClaudeLLMConnector::usage =
  "$ClaudeLLMConnector は BulkLLMProcessing が使う LLM 呼出関数 (fn[prompt])。Automatic は ClaudeCode`ClaudeQuerySync (ロード時) へ解決し、未ロード時は graceful fail。テストで mock 注入可。鍵は ClaudeQuerySync 側が NBGetAPIKey で扱う (rules/20)。";
$ClaudeSourceVaultIngestConnector::usage =
  "$ClaudeSourceVaultIngestConnector は SourceVaultIngest が使う取込関数 (fn[source])。Automatic は SourceVault`SourceVaultIngest へ解決。";
$ClaudeMailFetchConnector::usage =
  "$ClaudeMailFetchConnector は MailFetch が使う取得関数 (fn[mbox, period])。Automatic は SourceVault`SourceVaultMailEnsureLoaded へ解決。";
ClaudeWireExternalProviders::usage =
  "ClaudeWireExternalProviders[spec] は provider connector を結線する (spec キー: \"LLM\",\"SourceVaultIngest\",\"MailFetch\")。引数省略時は各 connector の現在の利用可否を返す。実 provider は claudecode.wl / SourceVault.wl ロード時に Automatic 経由で自動利用される。";

ClaudeActivateExternalExecutor::usage =
  "ClaudeActivateExternalExecutor[opts] は External executor を live 稼働させる: launcher/killer 結線 (ClaudeWireExternalRunner)、ClaudeExternalJobPollTick を共有 polling tick (ClaudeCode`ClaudeRegisterPollingTick) へ登録、完了 hook を設定し job 完了時に summary final action を FinalActionQueue へ enqueue。返り値は結線状況。";
ClaudeDeactivateExternalExecutor::usage =
  "ClaudeDeactivateExternalExecutor[] は poll tick 登録解除と完了 hook クリアを行う。";
$ClaudeExternalFinalActionEnqueue::usage =
  "$ClaudeExternalFinalActionEnqueue は完了 final action を enqueue する関数 (fn[action, accessSpec])。Automatic は ClaudeCode`ClaudeEnqueueFinalAction (ロード時)。テストで mock 注入可。";
$ClaudeExternalPollTickKey::usage =
  "$ClaudeExternalPollTickKey は共有 polling tick への登録 key (既定 \"external-job-poll\")。";

ClaudeExternalJobSummary::usage =
  "ClaudeExternalJobSummary[output, completion] は外部ジョブ出力の summary (Head/ByteCount/OutputRef/Preview) を返す。サイズが $ClaudeExternalInlineLimit 超なら Preview を省く (v7 §6/§10.2: 巨大出力を inline しない)。";

ClaudeExternalJobFinalAction::usage =
  "ClaudeExternalJobFinalAction[completion] は完了 payload の OutputRef を解決し、Notebook へ反映する final action (WriteNotebookCell, summary のみ) を構築して返す。本体は inline せず、反映は FinalActionQueue / 承認経由 (single committer)。<|\"Status\"->_, \"FinalAction\"->_|>。";

ClaudeExternalInlineAllowedQ::usage =
  "ClaudeExternalInlineAllowedQ[bytes] は出力を Notebook へ inline してよいサイズか ($ClaudeExternalInlineLimit 以下か) を返す。Unknown は安全側 False。";

$ClaudeExternalInlineLimit::usage =
  "$ClaudeExternalInlineLimit は Notebook へ inline できる出力 ByteCount の上限 (既定 64KB)。超過時は ref/summary のみ。";

$ClaudeWolframScriptExecutable::usage =
  "$ClaudeWolframScriptExecutable は wolframscript 実行ファイルの明示パス (未設定なら自動解決)。";

$ClaudeExternalJobRoot::usage =
  "$ClaudeExternalJobRoot は External job の durable root の明示パス (未設定なら $UserBaseDirectory/ClaudeRuntime/jobs)。";

Begin["`Private`"];

If[! ValueQ[$ClaudeWolframScriptExecutable], $ClaudeWolframScriptExecutable = Automatic];
If[! ValueQ[$ClaudeExternalJobRoot],         $ClaudeExternalJobRoot = Automatic];

(* 起動済み ProcessObject の registry (親プロセス内、jobId -> proc)。
   cross-restart では失われる (Phase 4.B で pid.txt taskkill)。 *)
If[! AssociationQ[$iExternalProcs], $iExternalProcs = <||>];

(* ─── wolframscript 解決 ─── *)
ClaudeResolveWolframScriptExecutable[] :=
  Module[{cands, exe},
    cands = {
      If[StringQ[$ClaudeWolframScriptExecutable], $ClaudeWolframScriptExecutable, Nothing],
      With[{e = Environment["WOLFRAMSCRIPT"]}, If[StringQ[e], e, Nothing]],
      FileNameJoin[{$InstallationDirectory, "wolframscript.exe"}],
      FileNameJoin[{$InstallationDirectory, "wolframscript"}]
    };
    exe = SelectFirst[cands, StringQ[#] && FileExistsQ[#] &, Missing[]];
    (* 見つからなければ PATH 上の bare 名に委ねる *)
    If[MissingQ[exe], "wolframscript", exe]
  ];

(* ─── durable job root ─── *)
ClaudeExternalJobRoot[] :=
  Module[{root},
    root = If[StringQ[$ClaudeExternalJobRoot], $ClaudeExternalJobRoot,
      FileNameJoin[{$UserBaseDirectory, "ClaudeRuntime", "jobs"}]];
    If[! DirectoryQ[root], Quiet @ CreateDirectory[root, CreateIntermediateDirectories -> True]];
    root
  ];

iGenJobId[] :=
  "job-" <> ToString[UnixTime[]] <> "-" <>
    IntegerString[RandomInteger[{16^^100000, 16^^FFFFFF}], 16];

(* forward-slash 化 (Windows path を script 文字列へ安全に埋め込む) *)
iFwd[p_String] := StringReplace[p, "\\" -> "/"];

(* atomic JSON write: tmp へ書いて rename *)
iAtomicWriteJSON[path_String, assoc_Association] :=
  Module[{tmp},
    tmp = path <> ".tmp";
    Quiet @ Export[tmp, assoc, "JSON"];
    Quiet @ If[FileExistsQ[path], DeleteFile[path]];
    Quiet @ RenameFile[tmp, path];
    path
  ];

iWriteStatus[jobDir_String, assoc_Association] :=
  iAtomicWriteJSON[FileNameJoin[{jobDir, "status.json"}], assoc];

iAppendProgress[jobDir_String, assoc_Association] :=
  Module[{f, line},
    f = FileNameJoin[{jobDir, "progress.jsonl"}];
    line = Quiet @ Check[ExportString[assoc, "JSON", "Compact" -> True], "{}"];
    Quiet @ Check[
      Module[{s = OpenAppend[f]}, WriteString[s, line <> "\n"]; Close[s]],
      Null]
  ];

(* ════════════════════════════════════════════════════════
   Phase 4.B: 機密 input/output の実暗号化 (SourceVault crypto 経由)
   - ConfidentialHandling=="EncryptedBundle" のジョブだけ暗号化する。
   - 暗号化は SourceVault`SourceVaultSealPayload / UnsealPayload に委譲し、
     鍵は NBAccess credential store に閉じる (鍵材料は runtime に出ない)。
   - cross-process では Memory backend は共有されないため SystemCredential を必須にする。
   - 機密ジョブで暗号化できない場合は fail-closed (平文を書かない)。
   ════════════════════════════════════════════════════════ *)

iConfidentialJobQ[manifest_Association] :=
  Lookup[manifest, "ConfidentialHandling", "ReferenceOnly"] === "EncryptedBundle";
iConfidentialJobQ[_] := False;

iSVCryptoReadyQ[] := TrueQ[Quiet @ Check[
  Length[DownValues[SourceVault`SourceVaultSealPayload]] > 0 &&
  Length[DownValues[SourceVault`SourceVaultUnsealPayload]] > 0, False]];

iSVBackend[] := Quiet @ Check[NBAccess`$NBCredentialBackend, "Memory"];

iEncryptedRecordQ[x_] :=
  TrueQ[Quiet @ Check[SourceVault`SourceVaultEncryptedRecordQ[x], False]];

(* 親側: 機密ジョブの暗号化前提を満たすか確認し、欠落鍵を bootstrap する。 *)
iSVPrepareConfidentialKeys[] := Which[
  ! iSVCryptoReadyQ[],
    <|"Status" -> "Unavailable", "Reason" -> "SourceVaultCryptoNotLoaded",
      "Hint" -> "Load NBAccess_crypto.wl + SourceVault_crypto.wl (or full SourceVault)."|>,
  iSVBackend[] =!= "SystemCredential",
    <|"Status" -> "Unavailable",
      "Reason" -> "ConfidentialEncryptionRequiresSystemCredential",
      "Hint" -> "Set NBAccess`$NBCredentialBackend = \"SystemCredential\" before confidential jobs."|>,
  True,
    (Quiet @ Check[SourceVault`SourceVaultInitializeEncryption[], $Failed];
     <|"Status" -> "Ready"|>)];

(* expr -> 封印 record (失敗時 $Failed)。store には残さない。 *)
iSealForJob[expr_] := Module[{r},
  r = Quiet @ Check[SourceVault`SourceVaultSealPayload[expr], $Failed];
  If[AssociationQ[r] && Lookup[r, "Status", ""] === "Stored", r["Record"], $Failed]];

(* 封印 record -> expr (失敗・改ざん時 $Failed; plaintext は返らない) *)
iUnsealFromJob[record_] := Module[{r},
  r = Quiet @ Check[SourceVault`SourceVaultUnsealPayload[record], $Failed];
  If[AssociationQ[r] && Lookup[r, "Status", ""] === "Ok", r["Payload"], $Failed]];

(* error.txt 用: 機密ジョブでは result 本文を吐かず redact する (log 漏洩防止) *)
iSafeErrorText[result_, manifest_Association] :=
  If[iConfidentialJobQ[manifest],
    "HandlerFailed (confidential job; details redacted)",
    ToString[result]];

(* ─── handler registry ─── *)
If[! AssociationQ[$iExtHandlers], $iExtHandlers = <||>];

ClaudeRegisterExternalTaskHandler[name_String, fn_, opts_:<||>] :=
  ($iExtHandlers[name] = <|"Fn" -> fn, "Options" -> opts|>; name);

(* テスト/疎通用の組込ハンドラ: 入力をそのまま結果に echo *)
ClaudeRegisterExternalTaskHandler["Echo",
  Function[ctx, <|"Status" -> "OK", "Result" -> Lookup[ctx, "Input", None]|>],
  <|"Backend" -> "WolframScript"|>];

(* Phase 4.B 疎通用: cooperative I/O guard (NBCheckedFileWrite) を通して書き込む。
   ctx["Input"]["Target"] への書込が AccessSpec scope 内なら成功、scope 外なら
   AccessSpecViolation で Failed。 *)
ClaudeRegisterExternalTaskHandler["GuardedWrite",
  Function[ctx,
    Module[{as, inp, target, r},
      as     = Lookup[ctx, "AccessSpec", <||>];
      inp    = Lookup[ctx, "Input", <||>];
      target = If[AssociationQ[inp] && KeyExistsQ[inp, "Target"],
                 inp["Target"],
                 FileNameJoin[{Lookup[ctx, "JobDir", "."], "guarded.txt"}]];
      If[Length[DownValues[NBAccess`NBCheckedFileWrite]] === 0,
        Return[<|"Status" -> "Failed", "Reason" -> "NBAccessNotLoaded"|>]];
      r = NBAccess`NBCheckedFileWrite[target, "guarded-data", as];
      If[Lookup[r, "Status", ""] === "OK",
        <|"Status" -> "OK", "Result" -> <|"Wrote" -> target|>|>,
        <|"Status" -> "Failed", "Reason" -> "AccessSpecViolation", "Detail" -> r|>]
    ]],
  <|"Backend" -> "WolframScript"|>];

(* ════════════════════════════════════════════════════════
   ApprovedHeldExpr handler (2026-06-12, ClaudeEval external dispatch)
   main 側で NBAccess 検証・(必要なら) ユーザー承認済みの held expr を
   子プロセスで実行する。対象は引数だけで完結する宣言的バッチ head
   (例: SourceVaultEagleSummarizeBatch)。head は AllowedHeads で再検証する
   (defense in depth)。設計: ドキュメント/ClaudeEval_external_dispatch_design.md
   ════════════════════════════════════════════════════════ *)

If[! IntegerQ[$ClaudeExternalHeldExprResultLimit],
  $ClaudeExternalHeldExprResultLimit = 1024*1024];

(* HoldComplete[h[...]] / HoldComplete[h] の head 名 (非評価で取得) *)
iHeldExprHeadName[held_HoldComplete] :=
  Replace[held, {
    HoldComplete[(h_Symbol)[___]] :> SymbolName[Unevaluated[h]],
    HoldComplete[h_Symbol]        :> SymbolName[Unevaluated[h]],
    _ :> $Failed}];
iHeldExprHeadName[_] := $Failed;

(* head に定義 (DownValues 等) があるか。Bootstrap 漏れの診断用。 *)
iHeldHeadDefinedQ[held_HoldComplete] :=
  TrueQ @ Replace[held, {
    HoldComplete[(h_Symbol)[___]] :>
      (Length[DownValues[h]] > 0 || Length[SubValues[h]] > 0 ||
       Length[OwnValues[h]] > 0),
    HoldComplete[h_Symbol] :> (Length[OwnValues[h]] > 0),
    _ :> False}];
iHeldHeadDefinedQ[_] := False;

(* binding 形 (place -> token | {token..}) から最初の "HeldExpr" 入り Payload を探す。
   Input が直接 payload 形 (<|"HeldExpr"->..|>) の場合にも対応。 *)
iFindHeldExprPayload[input_Association] :=
  Module[{tokens, payloads},
    tokens = Flatten[Map[Function[v, Which[
      AssociationQ[v], {v}, ListQ[v], v, True, {}]], Values[input]], 1];
    payloads = Map[Function[t,
      If[AssociationQ[t] && KeyExistsQ[t, "Payload"], t["Payload"], t]], tokens];
    payloads = Prepend[payloads, input];
    SelectFirst[payloads,
      AssociationQ[#] && MatchQ[Lookup[#, "HeldExpr", None], _HoldComplete] &,
      None]
  ];
iFindHeldExprPayload[_] := None;

ClaudeRegisterExternalTaskHandler["ApprovedHeldExpr",
  Function[ctx,
    Module[{manifest, payload, held, allowed, tc, headName, result, bytes},
      manifest = Lookup[ctx, "Manifest", <||>];
      payload  = iFindHeldExprPayload[Lookup[ctx, "Input", <||>]];
      If[payload === None,
        Return[<|"Status" -> "Failed", "Reason" -> "NoHeldExprInInput"|>]];
      held    = payload["HeldExpr"];
      allowed = Lookup[payload, "AllowedHeads", {}];
      tc      = Lookup[payload, "TimeConstraint",
                  Max[60, Lookup[manifest, "Timeout", 3600] - 60]];
      If[! NumericQ[tc] || tc <= 0, tc = 3600];
      headName = iHeldExprHeadName[held];
      If[! StringQ[headName] || ! ListQ[allowed] || ! MemberQ[allowed, headName],
        Return[<|"Status" -> "Failed",
          "Reason" -> "HeadNotAllowed:" <> ToString[headName]|>]];
      If[! iHeldHeadDefinedQ[held],
        Return[<|"Status" -> "Failed",
          "Reason" -> "HeadNotDefined:" <> headName <>
            " (BootstrapFiles のロード漏れ/失敗を確認)"|>]];
      result = Quiet @ Check[
        TimeConstrained[ReleaseHold[held], tc, $TimedOut], $Failed];
      Which[
        result === $TimedOut,
          <|"Status" -> "Failed",
            "Reason" -> "ExecutionTimedOut:" <> ToString[tc] <> "s"|>,
        result === $Failed,
          <|"Status" -> "Failed", "Reason" -> "ExecutionError"|>,
        True,
          bytes = Quiet @ Check[ByteCount[result], 0];
          If[IntegerQ[bytes] && bytes > $ClaudeExternalHeldExprResultLimit,
            (* 巨大結果は output.wxf 肥大防止のため要約に置換 (v7 §10.2) *)
            <|"Status" -> "OK", "Result" -> <|
              "Head" -> ToString[Head[result]], "ByteCount" -> bytes,
              "Short" -> Quiet @ Check[ToString[Short[result, 10]], "?"],
              "Truncated" -> True|>|>,
            <|"Status" -> "OK", "Result" -> result|>]
      ]
    ]],
  <|"Backend" -> "WolframScript"|>];

(* ─── handler lint (raw I/O 直書き検出) ─── *)
ClaudeLintExternalHandler[held_HoldComplete] :=
  Module[{heads, found},
    heads = {Export, Import, URLRead, URLExecute, URLFetch, StartProcess, Run,
             RunProcess, OpenWrite, OpenAppend, WriteString, DeleteFile,
             CopyFile, RenameFile, Put, Save,
             DialogInput, ChoiceDialog, Input, InputString, AuthenticationDialog};
    found = Select[heads, (! FreeQ[held, #]) &];
    <|"Clean" -> (found === {}), "Violations" -> (SymbolName /@ found)|>
  ];
ClaudeLintExternalHandler[_] := <|"Clean" -> False, "Violations" -> {"NotHeldComplete"}|>;

(* ════════════════════════════════════════════════════════
   Phase 5: checkpointable batch handler エンジン
   v7 §7.5/§9.3: checkpoint-aware retry。同一 JobDir で resume し、
   完了済み item は再処理しない (非冪等 task の二重実行を防ぐ)。
   per-item 処理は handler 種別ごとの processor (差し替え可能フック)。
   ════════════════════════════════════════════════════════ *)

If[! AssociationQ[$ClaudeBatchProcessorOverrides], $ClaudeBatchProcessorOverrides = <||>];

iCheckpointDir[jobDir_]  := FileNameJoin[{jobDir, "checkpoint"}];
iCheckpointFile[jobDir_] := FileNameJoin[{iCheckpointDir[jobDir], "state.wxf"}];
iCheckpointSave[jobDir_, state_] := (
  Quiet @ CreateDirectory[iCheckpointDir[jobDir], CreateIntermediateDirectories -> True];
  Quiet @ Export[iCheckpointFile[jobDir], state, "WXF"]);
iCheckpointLoad[jobDir_] :=
  If[FileExistsQ[iCheckpointFile[jobDir]],
    Quiet @ Check[Import[iCheckpointFile[jobDir], "WXF"], <||>], <||>];

(* batch の item 取得: ctx Input["Items"] (リスト) または ["ItemsRef"] (file, NBChecked) *)
iBatchItems[ctx_] :=
  Module[{inp, ref, as, rr},
    inp = Lookup[ctx, "Input", <||>];
    Which[
      AssociationQ[inp] && KeyExistsQ[inp, "Items"] && ListQ[inp["Items"]],
        inp["Items"],
      AssociationQ[inp] && KeyExistsQ[inp, "ItemsRef"],
        ref = inp["ItemsRef"]; as = Lookup[ctx, "AccessSpec", <||>];
        If[Length[DownValues[NBAccess`NBCheckedImport]] > 0,
          rr = NBAccess`NBCheckedImport[ref, "WXF", as];
          If[Lookup[rr, "Status", ""] === "OK" && ListQ[rr["Result"]],
            rr["Result"], $Failed],
          Quiet @ Check[Import[ref, "WXF"], $Failed]],
      True, $Failed
    ]
  ];

(* ─── 実 provider connector (seam: 注入可 / Automatic は既存 vetted 関数へ) ─── *)
If[! ValueQ[$ClaudeLLMConnector],                $ClaudeLLMConnector = Automatic];
If[! ValueQ[$ClaudeSourceVaultIngestConnector],  $ClaudeSourceVaultIngestConnector = Automatic];
If[! ValueQ[$ClaudeMailFetchConnector],          $ClaudeMailFetchConnector = Automatic];

(* Automatic は実関数 (full context) が定義済みなら採用、未ロードなら None。
   実 HTTP/IMAP/暗号は既存関数に委譲 (再発明しない・鍵は各関数が NBGetAPIKey で扱う)。 *)
iLLMConnector[] := Which[
  $ClaudeLLMConnector =!= Automatic, $ClaudeLLMConnector,
  Length[DownValues[ClaudeCode`ClaudeQuerySync]] > 0, ClaudeCode`ClaudeQuerySync,
  True, None];
iSVIngestConnector[] := Which[
  $ClaudeSourceVaultIngestConnector =!= Automatic, $ClaudeSourceVaultIngestConnector,
  Length[DownValues[SourceVault`SourceVaultIngest]] > 0, SourceVault`SourceVaultIngest,
  True, None];
iMailConnector[] := Which[
  $ClaudeMailFetchConnector =!= Automatic, $ClaudeMailFetchConnector,
  Length[DownValues[SourceVault`SourceVaultMailEnsureLoaded]] > 0,
    SourceVault`SourceVaultMailEnsureLoaded,
  True, None];

ClaudeWireExternalProviders[spec_Association:<||>] := (
  If[KeyExistsQ[spec, "LLM"],               $ClaudeLLMConnector = spec["LLM"]];
  If[KeyExistsQ[spec, "SourceVaultIngest"], $ClaudeSourceVaultIngestConnector = spec["SourceVaultIngest"]];
  If[KeyExistsQ[spec, "MailFetch"],         $ClaudeMailFetchConnector = spec["MailFetch"]];
  <|"LLM" -> (iLLMConnector[] =!= None),
    "SourceVaultIngest" -> (iSVIngestConnector[] =!= None),
    "MailFetch" -> (iMailConnector[] =!= None)|>);

(* 既定 processor。BulkFileProcessing は echo (純ファイル処理の雛形)。
   provider 系は connector へ委譲し、未利用時は graceful fail。 *)
iDefaultBatchProcessor["BulkFileProcessing"] :=
  Function[{item, idx, ctx},
    <|"Status" -> "OK",
      "Result" -> <|"Id" -> If[AssociationQ[item], Lookup[item, "Id", idx], idx],
                    "Processed" -> item|>|>];

iDefaultBatchProcessor["BulkLLMProcessing"] :=
  Function[{item, idx, ctx},
    Module[{conn, prompt, resp},
      conn = iLLMConnector[];
      If[conn === None,
        <|"Status" -> "Failed", "Reason" -> "LLMConnectorNotAvailable"|>,
        prompt = Which[
          AssociationQ[item] && KeyExistsQ[item, "Prompt"], item["Prompt"],
          AssociationQ[item] && KeyExistsQ[item, "Text"],   item["Text"],
          True, ToString[item]];
        resp = Quiet @ Check[conn[prompt], $Failed];
        If[resp === $Failed || MatchQ[resp, <|"Status" -> "Failed", ___|>],
          <|"Status" -> "Failed", "Reason" -> "LLMCallFailed"|>,
          <|"Status" -> "OK",
            "Result" -> <|"Id" -> If[AssociationQ[item], Lookup[item, "Id", idx], idx],
                          "Response" -> resp|>|>]]]];

iDefaultBatchProcessor["SourceVaultIngest"] :=
  Function[{item, idx, ctx},
    Module[{conn, src, r},
      conn = iSVIngestConnector[];
      If[conn === None,
        <|"Status" -> "Failed", "Reason" -> "SourceVaultIngestNotAvailable"|>,
        src = If[AssociationQ[item], Lookup[item, "Source", item], item];
        r = Quiet @ Check[conn[src], $Failed];
        If[r === $Failed,
          <|"Status" -> "Failed", "Reason" -> "IngestFailed"|>,
          <|"Status" -> "OK",
            "Result" -> <|"Id" -> If[AssociationQ[item], Lookup[item, "Id", idx], idx],
                          "Ingested" -> r|>|>]]]];

iDefaultBatchProcessor["MailFetch"] :=
  Function[{item, idx, ctx},
    Module[{conn, mbox, period, r},
      conn   = iMailConnector[];
      mbox   = Lookup[item, "Mbox", Lookup[item, "Mailbox", None]];
      period = Lookup[item, "Period", "Latest"];
      Which[
        conn === None,
          <|"Status" -> "Failed", "Reason" -> "MailConnectorNotAvailable"|>,
        ! StringQ[mbox],
          (* mbox 未指定で実メール取得を走らせない (fast-fail) *)
          <|"Status" -> "Failed", "Reason" -> "NoMailbox"|>,
        True,
          r = Quiet @ Check[conn[mbox, period], $Failed];
          If[r === $Failed,
            <|"Status" -> "Failed", "Reason" -> "MailFetchFailed"|>,
            <|"Status" -> "OK",
              "Result" -> <|"Mbox" -> mbox, "Period" -> period, "Fetched" -> r|>|>]]]];

iDefaultBatchProcessor[name_String] :=
  Function[{item, idx, ctx},
    <|"Status" -> "Failed", "Reason" -> "NoProcessor:" <> name|>];

iBatchProcessor[name_String] :=
  Lookup[$ClaudeBatchProcessorOverrides, name, iDefaultBatchProcessor[name]];

(* credential descriptor を解決 (secret は持ち回さない)。非致命: 失敗は記録のみ。 *)
iResolveBatchCredentials[ctx_] :=
  Module[{manifest, refs, as},
    manifest = Lookup[ctx, "Manifest", <||>];
    refs = Lookup[manifest, "CredentialRefs", {}];
    as   = Lookup[ctx, "AccessSpec", <||>];
    If[! ListQ[refs] || refs === {} ||
       Length[DownValues[NBAccess`NBResolveCredentialRef]] === 0,
      Return[<||>]];
    Association @ Map[
      Function[ref, ref -> NBAccess`NBResolveCredentialRef[ref, as]], refs]
  ];

iRunBatchHandler[ctx_, handlerName_String] :=
  Module[{items, proc, jobDir, cp, done, results, ctx2, r, item, n,
          failResult = None},
    jobDir = Lookup[ctx, "JobDir", "."];
    items  = iBatchItems[ctx];
    If[! ListQ[items],
      Return[<|"Status" -> "Failed", "Reason" -> "NoItemsOrUnreadable"|>]];
    n    = Length[items];
    proc = iBatchProcessor[handlerName];
    (* credential descriptor を ctx へ (handler/processor が NBGetAPIKey に使う) *)
    ctx2 = Append[ctx, "Credentials" -> iResolveBatchCredentials[ctx]];

    (* checkpoint から resume *)
    cp      = iCheckpointLoad[jobDir];
    done    = Lookup[cp, "Done", {}];
    results = Lookup[cp, "Results", <||>];

    (* 注: Return[] は Do 内では Module を抜けないため、flag + Break を使う *)
    Do[
      If[MemberQ[done, i], Continue[]];   (* 完了済みは再処理しない *)
      item = items[[i]];
      r = Quiet @ Check[proc[item, i, ctx2],
            <|"Status" -> "Failed", "Reason" -> "ProcessorException"|>];
      If[! AssociationQ[r] || Lookup[r, "Status", "OK"] === "Failed",
        iCheckpointSave[jobDir, <|"Done" -> done, "Results" -> results|>];
        iAppendProgress[jobDir, <|"Event" -> "ItemFailed", "Index" -> i,
          "At" -> UnixTime[]|>];
        failResult = <|"Status" -> "Failed",
          "Reason" -> "ItemFailed:" <> ToString[i] <> ":" <>
            ToString[Lookup[r, "Reason", ""]],
          "Processed" -> Length[done], "Total" -> n|>;
        Break[]];
      AppendTo[done, i];
      results[i] = Lookup[r, "Result", r];
      iCheckpointSave[jobDir, <|"Done" -> done, "Results" -> results|>];
      iAppendProgress[jobDir, <|"Event" -> "ItemDone", "Index" -> i,
        "Total" -> n, "At" -> UnixTime[]|>],
      {i, n}];

    If[failResult =!= None,
      failResult,
      <|"Status" -> "OK",
        "Result" -> <|"Count" -> n, "Items" -> Values[KeySort[results]]|>|>]
  ];

(* 4 種の batch handler を登録 (item 処理は processor フック差し替えで切替) *)
Scan[
  Function[nm,
    ClaudeRegisterExternalTaskHandler[nm,
      With[{name = nm}, Function[ctx, iRunBatchHandler[ctx, name]]],
      <|"Backend" -> "WolframScript", "Checkpointable" -> True|>]],
  {"BulkFileProcessing", "BulkLLMProcessing", "MailFetch", "SourceVaultIngest"}];

(* ════════════════════════════════════════════════════════
   Phase 6: final action 構築
   外部ジョブ完了 payload の OutputRef を解決し、Notebook へ反映する
   final action (WriteNotebookCell, summary のみ) を作る。本体は inline せず、
   反映は FinalActionQueue / 承認経由 (single committer)。v7 §6/§10.2/§15.6。
   ════════════════════════════════════════════════════════ *)

If[! IntegerQ[$ClaudeExternalInlineLimit], $ClaudeExternalInlineLimit = 64*1024];

ClaudeExternalInlineAllowedQ[b_Integer] := b <= $ClaudeExternalInlineLimit;
ClaudeExternalInlineAllowedQ[_] := False;   (* Unknown は安全側で inline しない *)

iAbsPathQ[p_String] :=
  StringMatchQ[p, (LetterCharacter ~~ ":") ~~ ___] ||
  StringStartsQ[p, "/"] || StringStartsQ[p, "\\"];
iAbsPathQ[_] := False;

ClaudeExternalJobSummary[output_, completion_Association] :=
  Module[{bytes, head, inlineOK},
    bytes = Quiet @ Check[ByteCount[output], "Unknown"];
    head  = Quiet @ Check[ToString[Head[output]], "?"];
    inlineOK = ClaudeExternalInlineAllowedQ[bytes];
    <|"JobID"          -> Lookup[completion, "JobID", "?"],
      "Status"         -> Lookup[completion, "Status", "Completed"],
      "Head"           -> head,
      "ByteCount"      -> bytes,
      "OutputRef"      -> Lookup[completion, "OutputRef", None],
      "SourceVaultRef" -> Lookup[completion, "SourceVaultRef", None],
      "Inlined"        -> inlineOK,
      "Preview"        -> If[inlineOK,
                            Quiet @ Check[ToString[Short[output, 5]], "?"],
                            Missing["TooLargeToInline"]]|>
  ];

iFormatExternalSummary[s_Association] :=
  StringRiffle[{
    "External job " <> ToString[Lookup[s, "JobID", "?"]] <>
      " : " <> ToString[Lookup[s, "Status", "?"]],
    "Head=" <> ToString[Lookup[s, "Head", "?"]] <>
      "  ByteCount=" <> ToString[Lookup[s, "ByteCount", "?"]],
    "OutputRef=" <> ToString[Lookup[s, "OutputRef", None]],
    If[TrueQ[Lookup[s, "Inlined", False]],
      "Preview: " <> ToString[Lookup[s, "Preview", ""]],
      "(出力が大きいため inline せず: ref/summary のみ)"]
  }, "\n"];

Options[ClaudeExternalJobFinalAction] = {"JobDir" -> None, "AccessSpec" -> <||>};

ClaudeExternalJobFinalAction[completion_Association, opts:OptionsPattern[]] :=
  Module[{ref, jobDir, as, path, output, summary, text},
    ref    = Lookup[completion, "OutputRef", None];
    jobDir = Lookup[completion, "JobDir", OptionValue["JobDir"]];
    as     = Lookup[completion, "AccessSpec", OptionValue["AccessSpec"]];
    If[! StringQ[ref],
      Return[<|"Status" -> "Failed", "Reason" -> "NoOutputRef"|>]];
    path = If[StringQ[jobDir] && ! iAbsPathQ[ref],
            FileNameJoin[{jobDir, ref}], ref];
    output = Which[
      AssociationQ[as] && as =!= <||> &&
        Length[DownValues[NBAccess`NBCheckedImport]] > 0,
        Module[{rr = NBAccess`NBCheckedImport[path, "WXF", as]},
          If[Lookup[rr, "Status", ""] === "OK", rr["Result"], $Failed]],
      True, Quiet @ Check[Import[path, "WXF"], $Failed]];
    (* 機密ジョブの output.wxf は封印 record。復号して本体を取り出す
       (改ざん・wrong key なら $Failed = OutputUnreadable に倒す)。 *)
    If[output =!= $Failed && iEncryptedRecordQ[output],
      output = iUnsealFromJob[output]];
    If[output === $Failed,
      Return[<|"Status" -> "Failed", "Reason" -> "OutputUnreadable", "Path" -> path|>]];
    summary = ClaudeExternalJobSummary[output, completion];
    text    = iFormatExternalSummary[summary];
    (* WriteNotebookCell action: NBAccess の final action 経由で承認・commit される。
       Cell には summary のみ。巨大本体は含めない。 *)
    Module[{fa},
      fa = <|
        "Action"           -> "WriteNotebookCell",
        "Cell"             -> Cell[text, "Text"],
        "Source"           -> "ExternalJob",
        "JobID"            -> Lookup[completion, "JobID", "?"],
        "RequiresFinalNode"-> True,
        "Summary"          -> summary|>;
      (* 2026-06-12: 発行元 notebook が分かる場合は summary をそこへ書く
         (iNBExecuteWriteNotebookCell が TargetNotebook を解決。無ければ CellPrint)。 *)
      If[MatchQ[Lookup[completion, "TargetNotebook", None], _NotebookObject],
        fa["TargetNotebook"] = completion["TargetNotebook"]];
      <|"Status" -> "OK", "FinalAction" -> fa|>]
  ];

(* ─── runner entrypoint (子プロセスで実行) ─── *)
ClaudeRunTaskFromManifest[jobDir_String] :=
  Module[{manifest, handlerName, reg, fn, inputData, inputFile, result,
          outFile, ok, accessSpec, snap, snapApplied, confJob, decIn,
          sealedOut, outputEncrypted = False},
    (* 1. manifest 読み込み *)
    manifest = Quiet @ Check[Get[FileNameJoin[{jobDir, "manifest.wl"}]], $Failed];
    If[! AssociationQ[manifest],
      iWriteStatus[jobDir, <|"Status" -> "Failed", "ErrorRef" -> "ManifestUnreadable"|>];
      Return[<|"Status" -> "Failed", "Reason" -> "ManifestUnreadable"|>]];

    (* 1b. AccessSpec を取り出し、PolicySnapshot があれば per-call 適用 (digest 検証)。
       NBAccess 未ロードなら検証はスキップ (Phase 4.A 互換)。AccessSpec は handler
       ctx へ渡し、handler は NBCheck* / NBChecked* を通して I/O する (cooperative)。 *)
    accessSpec = Lookup[manifest, "AccessSpec", <||>];
    snap = Lookup[accessSpec, "PolicySnapshot", Missing[]];
    If[AssociationQ[snap] &&
       Length[DownValues[NBAccess`NBApplyPolicySnapshot]] > 0,
      snapApplied = NBAccess`NBApplyPolicySnapshot[snap];
      If[! TrueQ[Lookup[snapApplied, "Valid", False]],
        iWriteStatus[jobDir, <|"Status" -> "Failed",
          "ErrorRef" -> "PolicySnapshotInvalid:" <>
            ToString[Lookup[snapApplied, "Reason", "?"]]|>];
        Return[<|"Status" -> "Failed", "Reason" -> "PolicySnapshotInvalid"|>]]];

    iWriteStatus[jobDir, <|"Status" -> "Running",
      "JobID" -> Lookup[manifest, "JobID", "?"]|>];
    iAppendProgress[jobDir, <|"Event" -> "Started", "At" -> UnixTime[]|>];

    (* 2. handler 解決 *)
    handlerName = Lookup[manifest, "Handler", Missing[]];
    reg = Lookup[$iExtHandlers, handlerName, None];
    If[! AssociationQ[reg],
      iWriteStatus[jobDir, <|"Status" -> "Failed",
        "ErrorRef" -> "UnknownHandler:" <> ToString[handlerName]|>];
      Return[<|"Status" -> "Failed", "Reason" -> "UnknownHandler"|>]];
    fn = reg["Fn"];

    (* 3. input 読み込み (input.wxf, 無ければ None)。封印 record なら復号する。 *)
    confJob = iConfidentialJobQ[manifest];
    inputFile = FileNameJoin[{jobDir, "input.wxf"}];
    inputData = If[FileExistsQ[inputFile],
      Quiet @ Check[Import[inputFile, "WXF"], None], None];
    If[iEncryptedRecordQ[inputData],
      decIn = iUnsealFromJob[inputData];
      If[decIn === $Failed,
        iWriteStatus[jobDir, <|"Status" -> "Failed",
          "JobID" -> Lookup[manifest, "JobID", "?"],
          "ErrorRef" -> "InputDecryptFailed"|>];
        iAppendProgress[jobDir, <|"Event" -> "Failed", "At" -> UnixTime[]|>];
        Return[<|"Status" -> "Failed", "Reason" -> "InputDecryptFailed"|>]];
      inputData = decIn];

    (* 4. handler 実行 (ctx に AccessSpec を渡す。handler は NBChecked* で I/O する) *)
    result = Quiet @ Check[
      fn[<|"Manifest" -> manifest, "Input" -> inputData, "JobDir" -> jobDir,
           "AccessSpec" -> accessSpec|>],
      $Failed];

    If[result === $Failed || ! AssociationQ[result] ||
       Lookup[result, "Status", "OK"] === "Failed",
      iWriteStatus[jobDir, <|"Status" -> "Failed",
        "JobID" -> Lookup[manifest, "JobID", "?"],
        "ErrorRef" -> "error.txt"|>];
      (* 機密ジョブでは result 本文を error.txt に吐かない (log 漏洩防止) *)
      Quiet @ Export[FileNameJoin[{jobDir, "error.txt"}],
        iSafeErrorText[result, manifest], "Text"];
      iAppendProgress[jobDir, <|"Event" -> "Failed", "At" -> UnixTime[]|>];
      Return[<|"Status" -> "Failed", "Reason" -> "HandlerFailed"|>]];

    (* 5. output 書き出し (output.wxf) + status Completed。
       機密ジョブは結果を封印してから書く。暗号化できなければ fail-closed
       (機密 output を平文で残さない)。 *)
    outFile = FileNameJoin[{jobDir, "output.wxf"}];
    If[confJob && ! iSVCryptoReadyQ[],
      iWriteStatus[jobDir, <|"Status" -> "Failed",
        "JobID" -> Lookup[manifest, "JobID", "?"],
        "ErrorRef" -> "OutputEncryptUnavailable"|>];
      iAppendProgress[jobDir, <|"Event" -> "Failed", "At" -> UnixTime[]|>];
      Return[<|"Status" -> "Failed", "Reason" -> "OutputEncryptUnavailable"|>]];
    sealedOut = If[confJob, iSealForJob[result], result];
    If[confJob && sealedOut === $Failed,
      iWriteStatus[jobDir, <|"Status" -> "Failed",
        "JobID" -> Lookup[manifest, "JobID", "?"],
        "ErrorRef" -> "OutputEncryptFailed"|>];
      iAppendProgress[jobDir, <|"Event" -> "Failed", "At" -> UnixTime[]|>];
      Return[<|"Status" -> "Failed", "Reason" -> "OutputEncryptFailed"|>]];
    outputEncrypted = confJob && iEncryptedRecordQ[sealedOut];
    ok = Quiet @ Check[Export[outFile, sealedOut, "WXF"]; True, False];
    iWriteStatus[jobDir, <|"Status" -> "Completed",
      "JobID" -> Lookup[manifest, "JobID", "?"],
      "OutputRef" -> "output.wxf",
      "OutputEncrypted" -> TrueQ[outputEncrypted]|>];
    iAppendProgress[jobDir, <|"Event" -> "Completed", "At" -> UnixTime[]|>];
    <|"Status" -> "Completed", "OutputRef" -> "output.wxf", "Wrote" -> ok,
      "OutputEncrypted" -> TrueQ[outputEncrypted]|>
  ];

(* ─── job 準備 (dir / input / manifest / run.wls) ─── *)
iPrepareExternalJob[jobSpec_Association] :=
  Module[{root, jobId, jobDir, handler, timeout, manifest, runnerFile,
          runWls, inputData, confidentialJob, inputEncrypted = False,
          sealed, prepKeys, cryptoBoot = "", resumeJob, oldManifest,
          bootFiles, bootBlock = ""},
    runnerFile = ClaudeRuntime`Private`$iExternalRunnerFile;
    If[! StringQ[runnerFile] || ! FileExistsQ[runnerFile],
      Return[<|"Status" -> "Failed", "Reason" -> "RunnerFileNotResolved"|>]];

    root   = ClaudeExternalJobRoot[];
    jobId  = Lookup[jobSpec, "JobID", iGenJobId[]];
    jobDir = FileNameJoin[{root, jobId}];
    Quiet @ CreateDirectory[jobDir, CreateIntermediateDirectories -> True];
    If[! DirectoryQ[jobDir],
      Return[<|"Status" -> "Failed", "Reason" -> "JobDirCreateFailed"|>]];

    (* Resume (retry) ジョブ: 既存 manifest を欠落 field の fallback に使う。
       (retry jobSpec は Binding / AccessSpec 等を持たない: workflow.wl iExternalRetry) *)
    resumeJob = TrueQ[Lookup[jobSpec, "Resume", False]];
    oldManifest = If[resumeJob,
      Quiet @ Check[Get[FileNameJoin[{jobDir, "manifest.wl"}]], <||>], <||>];
    If[! AssociationQ[oldManifest], oldManifest = <||>];

    handler = Lookup[jobSpec, "Handler",
      Lookup[oldManifest, "Handler", Missing[]]];
    timeout = Lookup[jobSpec, "Timeout",
      Lookup[oldManifest, "Timeout", 3600]];

    (* BootstrapFiles (2026-06-12): 子プロセスが handler 実行前にロードする
       パッケージ群。bare 名はパッケージディレクトリ (runner と同じ場所) 基準で
       絶対化する (例: ApprovedHeldExpr handler が SourceVault スタックを要する場合)。
       設計: ドキュメント/ClaudeEval_external_dispatch_design.md *)
    bootFiles = Lookup[jobSpec, "BootstrapFiles",
      Lookup[oldManifest, "BootstrapFiles", {}]];
    If[! ListQ[bootFiles], bootFiles = {}];
    bootFiles = Select[
      Map[Function[f, Which[
        ! StringQ[f], "",
        iAbsPathQ[f], f,
        True, FileNameJoin[{DirectoryName[runnerFile], f}]]], bootFiles],
      StringQ[#] && # =!= "" && FileExistsQ[#] &];

    (* input.wxf: jobSpec の "Input" を優先、無ければ Binding。
       ConfidentialHandling=="EncryptedBundle" のときは SourceVault crypto で実暗号化し、
       平文を job dir へ書かない (Phase 4.B)。非機密ジョブは従来どおり平文 WXF。 *)
    inputData = Lookup[jobSpec, "Input", Lookup[jobSpec, "Binding", <||>]];
    confidentialJob =
      Lookup[jobSpec, "ConfidentialHandling",
        Lookup[oldManifest, "ConfidentialHandling", "ReferenceOnly"]] ===
      "EncryptedBundle";
    Which[
      (* 2026-06-12 fix: Resume 時は既存 input.wxf を上書きしない。
         retry の jobSpec は Binding を持たないため、従来は input が <||> に
         潰れて checkpoint resume が入力を失っていた。 *)
      resumeJob && FileExistsQ[FileNameJoin[{jobDir, "input.wxf"}]],
        inputEncrypted = TrueQ[Lookup[oldManifest, "InputEncrypted", False]],
      confidentialJob,
        prepKeys = iSVPrepareConfidentialKeys[];
        If[Lookup[prepKeys, "Status", ""] =!= "Ready",
          Return[<|"Status" -> "Failed",
            "Reason" -> Lookup[prepKeys, "Reason", "ConfidentialEncryptionUnavailable"],
            "Hint" -> Lookup[prepKeys, "Hint", Missing["NotProvided"]]|>]];
        sealed = iSealForJob[inputData];
        If[sealed === $Failed,
          Return[<|"Status" -> "Failed", "Reason" -> "ConfidentialInputEncryptFailed"|>]];
        Quiet @ Export[FileNameJoin[{jobDir, "input.wxf"}], sealed, "WXF"];
        inputEncrypted = True,
      True,
        Quiet @ Export[FileNameJoin[{jobDir, "input.wxf"}], inputData, "WXF"]];

    (* manifest.wl (credential 本体 / 機密本文は入れない; AccessSpec / CredentialRefs
       は参照のみ。PolicySnapshot は AccessSpec 配下に含まれる) *)
    manifest = <|
      "JobID"      -> jobId,
      "WorkflowID" -> Lookup[jobSpec, "WorkflowID",
                        Lookup[oldManifest, "WorkflowID", None]],
      "AwaitId"    -> Lookup[jobSpec, "AwaitId",
                        Lookup[oldManifest, "AwaitId", None]],
      "Handler"    -> handler,
      "Backend"    -> Lookup[jobSpec, "Backend", "WolframScript"],
      "InputRef"   -> "input.wxf",
      "OutputRef"  -> "output.wxf",
      "StatusFile" -> "status.json",
      "Timeout"    -> timeout,
      "AccessSpec" -> Lookup[jobSpec, "AccessSpec",
                        Lookup[oldManifest, "AccessSpec", <||>]],
      "ConfidentialHandling" -> If[confidentialJob, "EncryptedBundle",
        Lookup[jobSpec, "ConfidentialHandling",
          Lookup[oldManifest, "ConfidentialHandling", "ReferenceOnly"]]],
      "InputEncrypted" -> inputEncrypted,
      "CredentialRefs" -> Lookup[jobSpec, "CredentialRefs",
                            Lookup[oldManifest, "CredentialRefs", {}]],
      "BootstrapFiles" -> bootFiles,
      "Attempt"    -> Lookup[jobSpec, "Attempt", 0],
      "CreatedAt"  -> Lookup[oldManifest, "CreatedAt", UnixTime[]]
    |>;
    Quiet @ Put[manifest, FileNameJoin[{jobDir, "manifest.wl"}]];

    (* run.wls bootstrap: runner package を Get して entrypoint を呼ぶ。
       機密ジョブでは、子プロセスが input/output を復号/暗号化できるよう
       軽量 crypto 2 package を先にロードし、backend を親と揃える。 *)
    cryptoBoot = If[confidentialJob,
      Module[{dir = DirectoryName[runnerFile], nbc, svc},
        nbc = FileNameJoin[{dir, "NBAccess_crypto.wl"}];
        svc = FileNameJoin[{dir, "SourceVault_crypto.wl"}];
        If[FileExistsQ[nbc] && FileExistsQ[svc],
          "Quiet @ Check[Get[\"" <> iFwd[nbc] <> "\"], Null];\n" <>
          "Quiet @ Check[Get[\"" <> iFwd[svc] <> "\"], Null];\n" <>
          "NBAccess`$NBCredentialBackend = \"SystemCredential\";\n",
          ""]],
      ""];
    (* BootstrapFiles を子で先ロード。claudecode.wl の Needs["NBAccess`","NBAccess.wl"]
       のような相対パス解決があるため、パッケージディレクトリへ SetDirectory して
       から Get する。crypto boot (backend 設定) は bootstrap の後 (上書き防止)。 *)
    bootBlock = If[bootFiles === {}, "",
      "SetDirectory[\"" <> iFwd[DirectoryName[runnerFile]] <> "\"];\n" <>
      StringJoin[Map[
        Function[f, "Quiet @ Check[Get[\"" <> iFwd[f] <> "\"], Null];\n"],
        bootFiles]]];
    runWls = FileNameJoin[{jobDir, "run.wls"}];
    Quiet @ Export[runWls,
      "Block[{$CharacterEncoding=\"UTF-8\"}, " <> bootBlock <> cryptoBoot <>
      "Get[\"" <> iFwd[runnerFile] <> "\"]];\n" <>
      "ClaudeRuntime`ClaudeRunTaskFromManifest[\"" <> iFwd[jobDir] <> "\"]\n",
      "Text"];

    <|"Status" -> "Prepared", "JobID" -> jobId, "JobDir" -> jobDir,
      "RunWls" -> runWls|>
  ];

(* ─── 実 launcher (親プロセス, StartProcess で別 wolframscript 起動) ─── *)
ClaudeExternalWolframScriptLauncher[jobSpec_Association] :=
  Module[{prep, jobId, jobDir, runWls, exe, proc, pid},
    prep = iPrepareExternalJob[jobSpec];
    If[Lookup[prep, "Status", ""] =!= "Prepared", Return[prep]];
    jobId = prep["JobID"]; jobDir = prep["JobDir"]; runWls = prep["RunWls"];

    exe = ClaudeResolveWolframScriptExecutable[];
    proc = Quiet @ Check[
      StartProcess[{exe, "-file", runWls},
        ProcessDirectory -> jobDir,
        ProcessEnvironment -> <|"CLAUDE_JOB_ID" -> jobId|>],
      $Failed];
    If[proc === $Failed || ! MatchQ[proc, _ProcessObject],
      iWriteStatus[jobDir, <|"Status" -> "Failed", "ErrorRef" -> "LaunchFailed"|>];
      Return[<|"Status" -> "Failed", "Reason" -> "StartProcessFailed"|>]];

    pid = Quiet @ Check[ProcessInformation[proc]["PID"], None];
    $iExternalProcs[jobId] = proc;

    iAtomicWriteJSON[FileNameJoin[{jobDir, "pid.json"}], <|
      "PID"        -> If[IntegerQ[pid], pid, -1],
      "Executable" -> "wolframscript",
      "JobID"      -> jobId,
      "StartedAt"  -> UnixTime[]
    |>];

    <|"Status" -> "Launched", "JobID" -> jobId, "JobDir" -> jobDir,
      "PID" -> If[IntegerQ[pid], pid, None]|>
  ];

(* ─── in-process launcher (テスト / 単一ライセンス環境 / 短時間タスク用) ───
   runner を現在のカーネルで同期実行する。別プロセスを起こさないため
   long-running には使わない (main kernel をブロックする)。job dir / manifest /
   status.json / output.wxf は実 launcher と同じ形で生成されるので、
   poller → 完了 → slot 返却の全チェーンを決定的に検証できる。 *)
ClaudeExternalInProcessLauncher[jobSpec_Association] :=
  Module[{prep, jobId, jobDir},
    prep = iPrepareExternalJob[jobSpec];
    If[Lookup[prep, "Status", ""] =!= "Prepared", Return[prep]];
    jobId = prep["JobID"]; jobDir = prep["JobDir"];
    ClaudeRunTaskFromManifest[jobDir];   (* 同期実行 -> status.json を書く *)
    <|"Status" -> "Launched", "JobID" -> jobId, "JobDir" -> jobDir,
      "PID" -> None, "InProcess" -> True|>
  ];

(* ─── プロセス probe / kill seam (cross-restart 同一性確認用) ─── *)
If[! ValueQ[$ClaudeExternalProcessProbe], $ClaudeExternalProcessProbe = Automatic];
If[! ValueQ[$ClaudeExternalProcessKill],  $ClaudeExternalProcessKill = Automatic];

(* 既定 probe: Windows tasklist で PID の生存と image 名を得る。 *)
iDefaultProcessProbe[pid_Integer] :=
  Module[{out, line},
    If[pid <= 0, Return[None]];
    out = Quiet @ Check[
      RunProcess[{"tasklist", "/FI", "PID eq " <> ToString[pid],
        "/FO", "CSV", "/NH"}], $Failed];
    If[! AssociationQ[out], Return[None]];
    line = First[StringSplit[Lookup[out, "StandardOutput", ""], "\n"], ""];
    If[! StringContainsQ[line, ToString[pid]],
      <|"Alive" -> False|>,
      <|"Alive" -> True,
        "Executable" -> StringTrim[First[StringSplit[line, ","], ""], "\""]|>]
  ];
iDefaultProcessProbe[_] := None;

(* 既定 kill: Windows taskkill /F。 *)
iDefaultProcessKill[pid_Integer] :=
  pid > 0 && TrueQ[Quiet @ Check[
    Lookup[RunProcess[{"taskkill", "/PID", ToString[pid], "/F"}], "ExitCode", 1] === 0,
    False]];
iDefaultProcessKill[_] := False;

iResolveProcessProbe[] := If[$ClaudeExternalProcessProbe === Automatic,
  iDefaultProcessProbe, $ClaudeExternalProcessProbe];
iResolveProcessKill[]  := If[$ClaudeExternalProcessKill === Automatic,
  iDefaultProcessKill, $ClaudeExternalProcessKill];

(* pid.json の PID が「生きている wolframscript」か検証 (PID 再利用での誤 kill 防止)。
   P0: alive + image=wolframscript。別の wolframscript への PID 再利用は
   image だけでは判別不能 (StartTime/CommandLine 照合は P1)。 *)
iVerifyJobProcessIdentity[pidJson_Association] :=
  Module[{pid, info},
    pid = Lookup[pidJson, "PID", -1];
    If[! IntegerQ[pid] || pid <= 0,
      Return[<|"Verified" -> False, "Reason" -> "NoPid"|>]];
    info = Quiet @ Check[iResolveProcessProbe[][pid], None];
    Which[
      ! AssociationQ[info] || ! TrueQ[Lookup[info, "Alive", False]],
        <|"Verified" -> False, "Reason" -> "NotAlive", "PID" -> pid|>,
      StringQ[Lookup[info, "Executable", ""]] &&
        StringContainsQ[ToLowerCase[info["Executable"]], "wolframscript"],
        <|"Verified" -> True, "PID" -> pid|>,
      True,
        <|"Verified" -> False, "Reason" -> "ImageMismatch", "PID" -> pid|>]
  ];
iVerifyJobProcessIdentity[_] := <|"Verified" -> False, "Reason" -> "NoPidJson"|>;

iReadPidJson[jobDir_] :=
  Module[{f = FileNameJoin[{jobDir, "pid.json"}]},
    If[FileExistsQ[f], Quiet @ Check[Import[f, "RawJSON"], <||>], <||>]];

(* ─── killer (same-session: ProcessObject / cross-restart: pid.json 同一性 kill) ─── *)
ClaudeExternalWolframScriptKiller[awaitMeta_Association] :=
  Module[{jobId, jobDir, proc, pidJson, ver, pid, killer},
    jobId  = Lookup[awaitMeta, "JobID", None];
    jobDir = Lookup[awaitMeta, "JobDir", None];
    proc   = Lookup[$iExternalProcs, jobId, None];
    Which[
      MatchQ[proc, _ProcessObject],
        If[Quiet @ Check[ProcessStatus[proc] === "Running", False],
          Quiet @ KillProcess[proc]];
        KeyDropFrom[$iExternalProcs, jobId];
        <|"Killed" -> True, "Via" -> "ProcessObject", "JobID" -> jobId|>,
      StringQ[jobDir],
        pidJson = iReadPidJson[jobDir];
        ver = iVerifyJobProcessIdentity[pidJson];
        If[TrueQ[Lookup[ver, "Verified", False]],
          pid = ver["PID"]; killer = iResolveProcessKill[];
          <|"Killed" -> TrueQ[Quiet @ Check[killer[pid], False]],
            "Via" -> "PidIdentity", "PID" -> pid, "JobID" -> jobId|>,
          (* 同一性不一致 -> 誤 kill 回避でスキップ *)
          <|"Killed" -> False, "Via" -> "SkippedIdentity",
            "Reason" -> Lookup[ver, "Reason", "?"], "JobID" -> jobId|>],
      True,
        <|"Killed" -> False, "Via" -> "NoTarget", "JobID" -> jobId|>]
  ];

(* ─── orphan recovery 本体 (検出 + identity kill + mark) ─── *)
Options[ClaudeExternalJobRecover] = {"Kill" -> True, "Mark" -> True};
ClaudeExternalJobRecover[opts:OptionsPattern[]] :=
  Module[{root, dirs, results = {}, doKill, doMark},
    doKill = TrueQ[OptionValue["Kill"]];
    doMark = TrueQ[OptionValue["Mark"]];
    root = ClaudeExternalJobRoot[];
    dirs = Quiet @ Check[FileNames["*", root], {}];
    Scan[
      Function[d,
        Module[{sf, st, jobId, killRes},
          sf = FileNameJoin[{d, "status.json"}];
          If[FileExistsQ[sf],
            st = Quiet @ Check[Import[sf, "RawJSON"], <||>];
            jobId = FileNameTake[d];
            If[AssociationQ[st] && Lookup[st, "Status", ""] === "Running" &&
               ! KeyExistsQ[$iExternalProcs, jobId],
              killRes = If[doKill,
                ClaudeExternalWolframScriptKiller[<|"JobID" -> jobId, "JobDir" -> d|>],
                <|"Killed" -> False, "Via" -> "NotRequested"|>];
              If[doMark,
                iWriteStatus[d, <|"Status" -> "Expired", "JobID" -> jobId,
                  "ErrorRef" -> "OrphanRecovered"|>]];
              AppendTo[results, <|"JobID" -> jobId, "JobDir" -> d,
                "Killed" -> TrueQ[Lookup[killRes, "Killed", False]],
                "KillVia" -> Lookup[killRes, "Via", "?"],
                "Marked" -> doMark|>]]]
        ]],
      Select[dirs, DirectoryQ]];
    <|"Recovered" -> results, "Count" -> Length[results]|>
  ];

(* ─── Workflow フックへ結線 ─── *)
ClaudeWireExternalRunner[] :=
  If[TrueQ[Quiet @ Check[
        ValueQ[ClaudeOrchestrator`Workflow`$ClaudeExternalJobLauncher] ||
        StringQ[ClaudeOrchestrator`Workflow`ClaudeExternalJobPollTick::usage], False]],
    ClaudeOrchestrator`Workflow`$ClaudeExternalJobLauncher     = ClaudeExternalWolframScriptLauncher;
    ClaudeOrchestrator`Workflow`$ClaudeExternalJobKiller       = ClaudeExternalWolframScriptKiller;
    (* StatusReader は既定 (JobDir/status.json 読み) で十分なので結線しない *)
    "Wired",
    "WorkflowNotLoaded"
  ];

(* ════════════════════════════════════════════════════════
   Live 統合: 共有 tick への poll 登録 + 完了 hook での final action enqueue
   (v7 §12.2)。独自 scheduler は作らず ClaudeCode`ClaudeRegisterPollingTick に
   相乗りする。Notebook 反映は ClaudeEnqueueFinalAction (承認/single committer)。
   ════════════════════════════════════════════════════════ *)

If[! ValueQ[$ClaudeExternalFinalActionEnqueue], $ClaudeExternalFinalActionEnqueue = Automatic];
If[! StringQ[$ClaudeExternalPollTickKey],       $ClaudeExternalPollTickKey = "external-job-poll"];

iFinalActionEnqueue[] := Which[
  $ClaudeExternalFinalActionEnqueue =!= Automatic, $ClaudeExternalFinalActionEnqueue,
  Length[DownValues[ClaudeCode`ClaudeEnqueueFinalAction]] > 0,
    ClaudeCode`ClaudeEnqueueFinalAction,
  True, None];

(* 反映用 accessSpec (FinalAction role)。NBAccess 未ロードなら最小限。 *)
iReflectAccessSpec[] :=
  If[Length[DownValues[NBAccess`NBMakeRuntimeAccessSpec]] > 0,
    NBAccess`NBMakeRuntimeAccessSpec[<|"PermissionMode" -> "WorkflowSafe"|>, "FinalAction"],
    <|"PermissionMode" -> "WorkflowSafe"|>];

(* workflow の完了 hook から呼ばれる: 完了 payload から summary final action を作り
   FinalActionQueue へ enqueue (承認経由)。本体は inline しない (ClaudeExternalJobFinalAction)。 *)
iExternalReflectCompletion[info_Association] :=
  Module[{awaitMeta, status, completion, built, enq},
    awaitMeta = Lookup[info, "AwaitMeta", <||>];
    status    = Lookup[info, "Status", <||>];
    completion = <|
      "Status"         -> "Completed",
      "JobID"          -> Lookup[awaitMeta, "JobID", "?"],
      "JobDir"         -> Lookup[awaitMeta, "JobDir", None],
      "OutputRef"      -> Lookup[status, "OutputRef", None],
      "SourceVaultRef" -> Lookup[status, "SourceVaultRef", None]|>;
    (* 2026-06-12: 投入元が NotifyNotebook を指定していれば summary の書込先にする
       (awaitMeta 経由 = 親メモリ内のみ。manifest / 子プロセスへは渡らない)。 *)
    If[MatchQ[Lookup[awaitMeta, "NotifyNotebook", None], _NotebookObject],
      completion["TargetNotebook"] = awaitMeta["NotifyNotebook"]];
    built = ClaudeExternalJobFinalAction[completion];
    If[Lookup[built, "Status", ""] =!= "OK",
      Return[<|"Reflected" -> False, "Reason" -> Lookup[built, "Reason", "BuildFailed"]|>]];
    enq = iFinalActionEnqueue[];
    If[enq === None,
      Return[<|"Reflected" -> False, "Reason" -> "NoEnqueueAvailable",
        "FinalAction" -> built["FinalAction"]|>]];
    Quiet @ Check[enq[built["FinalAction"], iReflectAccessSpec[]], Null];
    <|"Reflected" -> True, "JobID" -> completion["JobID"]|>
  ];

ClaudeActivateExternalExecutor[opts_Association:<||>] :=
  Module[{wired, pollReg = False},
    (* 1. launcher / killer 結線 *)
    wired = ClaudeWireExternalRunner[];
    (* 2. External / Subkernel poll tick を共有 tick へ登録 (独自 scheduler を作らない) *)
    If[TrueQ[Lookup[opts, "RegisterPoll", True]] &&
       Length[DownValues[ClaudeCode`ClaudeRegisterPollingTick]] > 0 &&
       Length[DownValues[ClaudeOrchestrator`Workflow`ClaudeExternalJobPollTick]] > 0,
      Quiet @ Check[
        ClaudeCode`ClaudeRegisterPollingTick[$ClaudeExternalPollTickKey,
          Function[Null, ClaudeOrchestrator`Workflow`ClaudeExternalJobPollTick[]]];
        If[Length[DownValues[ClaudeOrchestrator`Workflow`ClaudeSubkernelPollTick]] > 0,
          ClaudeCode`ClaudeRegisterPollingTick[$ClaudeExternalPollTickKey <> "-subkernel",
            Function[Null, ClaudeOrchestrator`Workflow`ClaudeSubkernelPollTick[]]]];
        pollReg = True, pollReg = False]];
    (* 3. 完了 hook 設定 (job 完了 -> summary final action -> FinalActionQueue) *)
    If[TrueQ[Lookup[opts, "ReflectToNotebook", True]] &&
       Length[OwnValues[ClaudeOrchestrator`Workflow`$ClaudeExternalCompletionHook]] >= 0,
      ClaudeOrchestrator`Workflow`$ClaudeExternalCompletionHook = iExternalReflectCompletion];
    <|"LauncherWired"  -> (wired === "Wired"),
      "PollRegistered" -> pollReg,
      "CompletionHook" -> (ClaudeOrchestrator`Workflow`$ClaudeExternalCompletionHook ===
                            iExternalReflectCompletion),
      "EnqueueAvailable" -> (iFinalActionEnqueue[] =!= None)|>
  ];

ClaudeDeactivateExternalExecutor[] := (
  If[Length[DownValues[ClaudeCode`ClaudeUnregisterPollingTick]] > 0,
    Quiet @ Check[ClaudeCode`ClaudeUnregisterPollingTick[$ClaudeExternalPollTickKey], Null];
    Quiet @ Check[ClaudeCode`ClaudeUnregisterPollingTick[$ClaudeExternalPollTickKey <> "-subkernel"], Null]];
  Quiet @ Check[
    ClaudeOrchestrator`Workflow`$ClaudeExternalCompletionHook = None, Null];
  <|"Deactivated" -> True|>);

End[];

EndPackage[];

Print[Style["ClaudeRuntime_externalrunner.wl (Phase 4.A) がロードされました。", Bold]];
Print["
  ClaudeRunTaskFromManifest[jobDir]      -> runner entrypoint (子プロセス)
  ClaudeRegisterExternalTaskHandler[..]  -> handler 登録 (組込: \"Echo\")
  ClaudeExternalWolframScriptLauncher    -> 実 wolframscript 起動 launcher
  ClaudeResolveWolframScriptExecutable[] -> wolframscript 解決
  ClaudeExternalJobRoot[]                 -> durable job root
  ClaudeWireExternalRunner[]             -> Workflow フックへ結線
"];
