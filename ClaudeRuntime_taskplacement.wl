(* ClaudeRuntime_taskplacement.wl -- Task placement classifier (Phase 1)

   位置付け:
     ClaudeOrchestrator_external_executor_task_placement_spec_v7_consolidated.md
     の Phase 1 (分類器・schema) を実装する Runtime 側 companion ファイル。

   責務 (runtime-orchestrator-boundary skill の DAG-IP):
     - 1 ターン内で閉じる純関数的な分類・正規化のみ。
     - workflow state / job registry / retry / concurrency 等の永続状態は持たない
       (それらは ClaudeOrchestrator の責務)。
     - NBAccess の Decision は安全性の正本。本分類器は助言的 (advisory) であり、
       最終 backend 決定は Orchestrator が行う。

   提供する公開シンボル (BeginPackage["ClaudeRuntime`"] で同 context に追加):
     ClaudeNormalizeTaskSpec[raw]              -> 正本 schema へ正規化した taskSpec
     ClaudeClassifyTask[taskSpec, context]     -> 内省・派生 metadata を埋めた classifiedTask
     ClaudeSelectExecutionBackend[ct, context] -> backend 推奨 (advisory)
     ClaudeBuildTaskAction[classifiedTask]     -> NBValidateAction 用の action association
     ClaudeTaskPlacementSchema[]               -> 正本 metadata schema (default template)
     $ClaudeTaskPlacementDataSizeLimits        -> 転送サイズ閾値
     $ClaudeTaskInspectionTimeLimit            -> held-expr 内省の時間上限 (秒)
     $ClaudeTransferSizeEstimateFactors        -> 転送サイズ概算の安全係数

   設計対応 (v7 §):
     §2.1/§2.5 正本 metadata schema
     §9.1      内省適用範囲 = held expr を持つ task のみ
     §9.2      内省コスト上限 (packed array は O(1) 概算 / 時間上限 / Unknown safe)
     §4.2-4.4  FrontEndBlockingRisk / UI 起点 / blocking dialog / FE 依存 headless 禁止
     §5.2      Subkernel 自動送信禁止条件 (transfer-safe / confidential / output size)
     §6.1      WolframScript 選択条件
     §4.3      backend 優先順位 (Decision > hard safety > ... > PreferredBackend > 推奨)

   Load:
     Block[{$CharacterEncoding = "UTF-8"}, Get["ClaudeRuntime_taskplacement.wl"]]
*)

BeginPackage["ClaudeRuntime`"];

ClaudeNormalizeTaskSpec::usage =
  If[$Language === "Japanese",
    "ClaudeNormalizeTaskSpec[raw] は raw Association を正本 metadata schema へ正規化した taskSpec を返す。\n未指定キーは安全側 default (Unknown 等) で補完する。",
    "ClaudeNormalizeTaskSpec[raw] normalizes a raw Association into the canonical task metadata schema, filling unspecified keys with safe defaults."];

ClaudeClassifyTask::usage =
  If[$Language === "Japanese",
    "ClaudeClassifyTask[taskSpec, context] は taskSpec を補助分類した classifiedTask を返す。\nheld expression を持つ task (Subkernel/MainKernel 候補) には dispatch 前の軽量内省を行い、\nReferencedSymbols / EstimatedTransferBytes / Uses* / FrontEndBlockingRisk 等を埋める。\n内省は $ClaudeTaskInspectionTimeLimit 秒以内、未確定は Unknown (安全側) に倒す。\ncontext 省略時は <||> を使う。",
    "ClaudeClassifyTask[taskSpec, context] returns a classifiedTask. For held-expression tasks (Subkernel/MainKernel candidates) it performs a lightweight pre-dispatch introspection, filling ReferencedSymbols / EstimatedTransferBytes / Uses* / FrontEndBlockingRisk etc. Introspection is bounded by $ClaudeTaskInspectionTimeLimit; unresolved values fall back to Unknown (safe side)."];

ClaudeSelectExecutionBackend::usage =
  If[$Language === "Japanese",
    "ClaudeSelectExecutionBackend[classifiedTask, context] は backend 推奨 (advisory) を返す。\n返り値: <|\"SelectedBackend\", \"ReasonClass\", \"Rejections\", \"Fallbacks\", \"RequiresApproval\", \"Notes\"|>。\n最終決定は Orchestrator が行う。NBAccess Decision (context または classifiedTask の \"Decision\") を最優先する。",
    "ClaudeSelectExecutionBackend[classifiedTask, context] returns an advisory backend recommendation. The final decision is the Orchestrator's; the NBAccess Decision takes top priority."];

ClaudeBuildTaskAction::usage =
  If[$Language === "Japanese",
    "ClaudeBuildTaskAction[classifiedTask] は NBValidateAction[action, accessSpec] に渡す action Association を組み立てる。\n本分類器は NBAccess を呼ばない (接続点の提供のみ)。検証は Orchestrator が行う。",
    "ClaudeBuildTaskAction[classifiedTask] builds the action Association for NBValidateAction[action, accessSpec]. This classifier does not call NBAccess; it only provides the connection artifact."];

ClaudeTaskPlacementSchema::usage =
  If[$Language === "Japanese",
    "ClaudeTaskPlacementSchema[] は正本 metadata schema の default template (Association) を返す。",
    "ClaudeTaskPlacementSchema[] returns the canonical metadata schema default template (Association)."];

$ClaudeTaskPlacementDataSizeLimits::usage =
  "$ClaudeTaskPlacementDataSizeLimits は転送サイズ閾値 (bytes) の Association。EstimatedTransferBytes / EstimatedMaterializationBytes に適用する。";

$ClaudeTaskInspectionTimeLimit::usage =
  "$ClaudeTaskInspectionTimeLimit は held-expr 内省の時間上限 (秒)。超過時は Unknown safe default に倒す。";

$ClaudeTransferSizeEstimateFactors::usage =
  "$ClaudeTransferSizeEstimateFactors は型別の転送サイズ概算安全係数の Association。";

Begin["`Private`"];

(* ════════════════════════════════════════════════════════
   設定値 (v7 §2.4 / §9.2 / §E.2)
   ════════════════════════════════════════════════════════ *)

If[! AssociationQ[$ClaudeTaskPlacementDataSizeLimits],
  $ClaudeTaskPlacementDataSizeLimits = <|
    "SubkernelAutoTransferBytes"      -> 10*1024^2,
    "SubkernelApprovalTransferBytes"  -> 100*1024^2,
    "WolframScriptInlineInputBytes"   -> 10*1024^2,
    "RequireReferenceAboveBytes"      -> 100*1024^2,
    "HardDenyValueTransferAboveBytes" -> 1024^3
  |>
];

If[! NumericQ[$ClaudeTaskInspectionTimeLimit],
  $ClaudeTaskInspectionTimeLimit = 0.5
];

If[! AssociationQ[$ClaudeTransferSizeEstimateFactors],
  $ClaudeTransferSizeEstimateFactors = <|
    "PackedArray"       -> 1.2,
    "SparseArray"       -> 1.5,
    "Image"             -> 1.5,
    "Graph"             -> 2.0,
    "Association"       -> 3.0,
    "Dataset"           -> 3.0,
    "GeneralExpression" -> 2.0
  |>
];

(* 宣言的 ExternalTask の TaskKind (held expr 内省の対象外: v7 §9.1) *)
$iTPDeclarativeKinds = {
  "MailFetch", "BulkFileProcessing", "BulkLLMProcessing",
  "SourceVaultIngest", "NetworkBatch", "LongRunningExternalIO",
  "CheckpointableBatch", "ExternalWolframScriptJob"
};

(* WolframScript を誘因する宣言的 kind *)
$iTPWolframScriptKinds = $iTPDeclarativeKinds;

(* ════════════════════════════════════════════════════════
   正本 metadata schema default template (v7 §2.1 + §2.5)
   ════════════════════════════════════════════════════════ *)

$iTPSchemaTemplate := <|
  (* --- 宣言・選択 --- *)
  "TaskKind"                     -> Missing["NotProvided"],
  "PlacementEffect"              -> Missing["NotProvided"],
  "DeclaredEffectClasses"        -> {},
  "NBAccessEffectClasses"        -> {},
  "Decision"                     -> Missing["NotValidated"],
  "ApprovalEligibility"          -> Missing["NotValidated"],
  "PreferredBackend"             -> Automatic,
  "SelectedBackend"              -> Missing["NotSelected"],
  (* --- サイズ・転送 --- *)
  "DataSize"                     -> "Unknown",
  "InputDataSize"                -> "Unknown",
  "EstimatedResidentBytes"       -> "Unknown",
  "EstimatedTransferBytes"       -> "Unknown",
  "EstimatedMaterializationBytes"-> "Unknown",
  "EstimatedOutputBytes"         -> "Unknown",
  "EstimatedRuntimeSeconds"      -> "Unknown",
  (* --- リスク --- *)
  "DataTransferRisk"             -> "Unknown",
  "MainKernelBlockingRisk"       -> "Unknown",
  "FrontEndBlockingRisk"         -> "Unknown",
  "FileSystemConflictRisk"       -> "Unknown",
  "ResourceContentionRisk"       -> "Unknown",
  "MasterCallbackRisk"           -> "Unknown",
  "AbortRecoveryRisk"            -> "Unknown",
  (* --- 値捕捉・転送可否 --- *)
  "ReferencesMainKernelSymbols"  -> "Unknown",
  "ReferencedSymbols"            -> {},
  "MainMemoryResident"           -> "Unknown",
  "RequiresVariableCapture"      -> "Unknown",
  "CanPassByReference"           -> "Unknown",
  "CanRecomputeInTarget"         -> "Unknown",
  "MaterializationRequired"      -> False,
  "MaterializationTarget"        -> "None",
  "TransferApproval"             -> "NotRequired",
  (* --- 並列・FE 依存 Uses フラグ --- *)
  "UsesDynamic"                  -> "Unknown",
  "UsesDialog"                   -> "Unknown",
  "UsesNotebookIO"               -> "Unknown",
  "UsesDistributeDefinitions"    -> "Unknown",
  "UsesSharedVariable"           -> "Unknown",
  "UsesSharedFunction"           -> "Unknown",
  "UsesRunProcess"               -> "Unknown",
  "UsesStartProcess"             -> "Unknown",
  "UsesLaunchKernels"            -> "Unknown",
  "WolframScriptLaunchesSubkernels" -> "Unknown",
  "UsesSharedFiles"              -> "Unknown",
  "RequiresFileLocks"            -> False,
  (* --- 並列メモリ見積り --- *)
  "EstimatedKernelCopies"        -> "Unknown",
  "AggregateWorkerResidentBytes" -> "Unknown",
  "EstimatedMasterCallbacks"     -> "Unknown",
  "RequestedWolframScriptKernels"-> "Unknown",
  (* --- headless / FE --- *)
  "RequiresFrontEnd"             -> "Unknown",
  "RequiresNotebookObject"       -> "Unknown",
  "HeadlessSafe"                 -> "Unknown",
  (* --- credential / 機密 --- *)
  "CredentialRefs"               -> {},
  "SecretRefs"                   -> {},
  "ConfidentialHandling"         -> Missing["NotProvided"],
  "ConfidentialSymbols"          -> {},
  (* --- retry / checkpoint --- *)
  "Idempotent"                   -> "Unknown",
  "Checkpointable"               -> "Unknown",
  "RetryPolicy"                  -> Missing["NotProvided"],
  "Attempt"                      -> 0,
  "CheckpointRef"                -> None,
  "ErrorRef"                     -> None,
  "FailureSummaryRef"            -> None,
  (* --- scope / cleanup --- *)
  "AllowedDirectories"           -> {},
  "AllowedNetworkTargets"        -> {},
  "AllowedExternalCommands"      -> {},
  "MayAccessFileSystem"          -> "None",
  "CleanupPolicy"                -> Missing["NotProvided"],
  "JobDirectoryPolicy"           -> Missing["NotProvided"],
  "AbortCleanupRequired"         -> False,
  (* --- held expr (内省用; 任意) --- *)
  "HeldExpr"                     -> Missing["NotProvided"],
  "InspectionStatus"             -> "NotInspected"
|>;

ClaudeTaskPlacementSchema[] := $iTPSchemaTemplate;

(* deprecated alias 解決 (v7 §2.2) *)
iTPResolveAliases[raw_Association] := Module[{r = raw},
  If[KeyExistsQ[r, "EstimatedInputBytes"] && ! KeyExistsQ[r, "EstimatedTransferBytes"],
    r["EstimatedTransferBytes"] = r["EstimatedInputBytes"]];
  If[KeyExistsQ[r, "TransferCost"] && ! KeyExistsQ[r, "DataTransferRisk"],
    r["DataTransferRisk"] = r["TransferCost"]];
  r
];

ClaudeNormalizeTaskSpec[raw_Association] :=
  Join[$iTPSchemaTemplate, iTPResolveAliases[raw]];
ClaudeNormalizeTaskSpec[raw_Association, ___] := ClaudeNormalizeTaskSpec[raw];
ClaudeNormalizeTaskSpec[_] := ClaudeNormalizeTaskSpec[<||>];

(* ════════════════════════════════════════════════════════
   サイズ概算 (v7 §9.2 / §E.2)
   ════════════════════════════════════════════════════════ *)

(* packed array は Dimensions から O(1) 概算。それ以外は短時間 ByteCount、
   超過・失敗時は "Unknown" を返す (安全側)。
   引数は HoldComplete[sym] 形式 (refSyms の要素)。本体で v = sym として値を
   1 回だけ取得する (OwnValue の読み出しであり再計算ではない)。 *)
iTPEstimateValueBytes[HoldComplete[expr_]] :=
  Module[{v, fac, est},
    v = expr;
    Which[
      Developer`PackedArrayQ[v],
        fac = $ClaudeTransferSizeEstimateFactors["PackedArray"];
        Ceiling[(Times @@ Dimensions[v]) * 8 * fac],
      Head[v] === SparseArray,
        est = TimeConstrained[ByteCount[v], 0.1, "Unknown"];
        If[IntegerQ[est],
          Ceiling[est * $ClaudeTransferSizeEstimateFactors["SparseArray"]],
          "Unknown"],
      MemberQ[{Image, Image3D}, Head[v]],
        est = TimeConstrained[ByteCount[v], 0.1, "Unknown"];
        If[IntegerQ[est], Ceiling[est * $ClaudeTransferSizeEstimateFactors["Image"]], "Unknown"],
      Head[v] === Graph,
        est = TimeConstrained[ByteCount[v], 0.1, "Unknown"];
        If[IntegerQ[est], Ceiling[est * $ClaudeTransferSizeEstimateFactors["Graph"]], "Unknown"],
      MemberQ[{Association, Dataset}, Head[v]],
        est = TimeConstrained[ByteCount[v], 0.1, "Unknown"];
        If[IntegerQ[est], Ceiling[est * $ClaudeTransferSizeEstimateFactors["Dataset"]], "Unknown"],
      True,
        est = TimeConstrained[ByteCount[v], 0.1, "Unknown"];
        If[IntegerQ[est],
          Ceiling[est * $ClaudeTransferSizeEstimateFactors["GeneralExpression"]],
          "Unknown"]
    ]
  ];

(* bytes 値群を合算。1 つでも "Unknown" があれば合計は "Unknown" (安全側)。 *)
iTPSumBytes[vals_List] :=
  If[MemberQ[vals, "Unknown"] || vals === {},
    If[vals === {}, 0, "Unknown"],
    Total[vals]
  ];

(* transfer bytes -> InputDataSize クラス (v7 §2.4 閾値) *)
iTPSizeClass["Unknown"] := "Unknown";
iTPSizeClass[b_Integer] := Module[{lim = $ClaudeTaskPlacementDataSizeLimits},
  Which[
    b <  lim["SubkernelAutoTransferBytes"],      "Small",
    b <  lim["RequireReferenceAboveBytes"],       "Medium",
    b <  lim["HardDenyValueTransferAboveBytes"],  "Large",
    True,                                          "Huge"
  ]
];
iTPSizeClass[_] := "Unknown";

iTPTransferRisk["Unknown"] := "Unknown";
iTPTransferRisk[b_Integer] := Switch[iTPSizeClass[b],
  "Small",  "Low",
  "Medium", "Medium",
  "Large",  "High",
  "Huge",   "Prohibitive",
  _,        "Unknown"
];
iTPTransferRisk[_] := "Unknown";

(* ════════════════════════════════════════════════════════
   held expr 内省 (v7 §9)
   ════════════════════════════════════════════════════════ *)

(* held expr 内の head 出現を構造的に判定 (評価しない)。 *)
iTPUsesAny[held_, heads_List] := AnyTrue[heads, (! FreeQ[held, #]) &];

$iTPDynamicHeads   = {Dynamic, Manipulate, Animate};
$iTPDialogHeads    = {DialogInput, ChoiceDialog, Input, InputString,
                      AuthenticationDialog, SystemDialogInput};
$iTPNotebookHeads  = {NotebookGet, NotebookWrite, NotebookPut, NotebookRead,
                      FrontEndExecute, FrontEndTokenExecute, SelectionMove,
                      CreateDocument, NotebookPrint, UsingFrontEnd, CurrentValue,
                      EvaluationNotebook, InputNotebook, SelectedNotebook};

(* held expr から内省結果 Association を返す。
   引数は既に評価済みの HoldComplete[...] (Part 抽出結果)。HoldComplete が
   内部式の評価を防ぐので、本関数自体に hold 属性は付けない。 *)
iTPIntrospectHeld[held_HoldComplete] :=
  Module[{rows, refRows, refNames, refHelds, byteEsts, transferBytes,
          usesDynamic, usesDialog, usesNB, usesDist, usesShV, usesShF,
          usesRun, usesStart, usesLaunch, headless, feRisk},

    (* 1. 自由シンボル抽出。各出現を
          {context, ownValueCount, symbolName, HoldComplete[sym]} で収集。
          RuleDelayed の RHS で Unevaluated を使い、シンボル値を評価しない
          (SymbolName/Context/OwnValues いずれも Unevaluated 経由)。 *)
    rows = DeleteDuplicates @ Cases[
      held,
      s_Symbol :> {Context[Unevaluated[s]],
                   Length[OwnValues[Unevaluated[s]]],
                   SymbolName[Unevaluated[s]],
                   HoldComplete[s]},
      {0, Infinity},
      Heads -> True
    ];

    (* 2. main kernel resident symbol = System` 以外 かつ OwnValue を持つもの。
          Table の iterator 等の局所変数は OwnValue を持たないので自然に除外される。 *)
    refRows  = Cases[rows, {ctx_String /; ctx =!= "System`", n_Integer /; n > 0, _, _}];
    refNames = refRows[[All, 3]];
    refHelds = refRows[[All, 4]];

    (* 3. 各 referenced symbol のサイズ概算 (refHelds 要素は HoldComplete[sym]) *)
    byteEsts = iTPEstimateValueBytes /@ refHelds;
    transferBytes = iTPSumBytes[byteEsts];

    (* 4. Uses* フラグ (構造判定) *)
    usesDynamic = iTPUsesAny[held, $iTPDynamicHeads];
    usesDialog  = iTPUsesAny[held, $iTPDialogHeads];
    usesNB      = iTPUsesAny[held, $iTPNotebookHeads];
    usesDist    = ! FreeQ[held, DistributeDefinitions];
    usesShV     = ! FreeQ[held, SetSharedVariable];
    usesShF     = ! FreeQ[held, SetSharedFunction];
    usesRun     = ! FreeQ[held, RunProcess];
    usesStart   = ! FreeQ[held, StartProcess];
    usesLaunch  = ! FreeQ[held, LaunchKernels];

    (* 5. headless / FE risk (v7 §4.2-4.4) *)
    headless = ! (usesNB || usesDialog);
    feRisk   = If[usesDialog || usesDynamic, "High", "Low"];

    <|
      "ReferencedSymbols"           -> refNames,
      "ReferencesMainKernelSymbols" -> (Length[refRows] > 0),
      "MainMemoryResident"          -> (Length[refRows] > 0),
      "RequiresVariableCapture"     -> (Length[refRows] > 0),
      "EstimatedTransferBytes"      -> transferBytes,
      "InputDataSize"               -> iTPSizeClass[transferBytes],
      "DataTransferRisk"            -> iTPTransferRisk[transferBytes],
      "UsesDynamic"                 -> usesDynamic,
      "UsesDialog"                  -> usesDialog,
      "UsesNotebookIO"              -> usesNB,
      "UsesDistributeDefinitions"   -> usesDist,
      "UsesSharedVariable"          -> usesShV,
      "UsesSharedFunction"          -> usesShF,
      "UsesRunProcess"              -> usesRun,
      "UsesStartProcess"            -> usesStart,
      "UsesLaunchKernels"           -> usesLaunch,
      "MasterCallbackRisk"          -> If[usesShV || usesShF, "High", "Low"],
      "RequiresFrontEnd"            -> (usesNB || usesDialog),
      "RequiresNotebookObject"      -> usesNB,
      "HeadlessSafe"                -> headless,
      "FrontEndBlockingRisk"        -> feRisk,
      "InspectionStatus"            -> "Inspected"
    |>
  ];
iTPIntrospectHeld[_] := <|"InspectionStatus" -> "NoHeldExpr"|>;

(* この task は held expr 内省の対象か (v7 §9.1) *)
iTPIntrospectableQ[ts_Association] := Module[{kind, held, pref},
  kind = ts["TaskKind"];
  held = ts["HeldExpr"];
  pref = ts["PreferredBackend"];
  And[
    MatchQ[held, _HoldComplete],
    ! MemberQ[$iTPDeclarativeKinds, kind],
    MatchQ[pref, Automatic | "SubkernelAsync" | "MainKernelAsync"] ||
      MissingQ[kind] || ! MemberQ[$iTPDeclarativeKinds, kind]
  ]
];

(* ════════════════════════════════════════════════════════
   ClaudeClassifyTask (v7 §3 step 2-3)
   ════════════════════════════════════════════════════════ *)

ClaudeClassifyTask[rawSpec_Association, context_Association] :=
  Module[{ts, introspected},
    ts = ClaudeNormalizeTaskSpec[rawSpec];
    (* ConfidentialSymbols は context からも取り込む *)
    If[KeyExistsQ[context, "ConfidentialSymbols"] && ts["ConfidentialSymbols"] === {},
      ts["ConfidentialSymbols"] = context["ConfidentialSymbols"]];

    If[iTPIntrospectableQ[ts],
      (* 内省を時間上限付きで実行。超過・失敗時は Unknown safe default を維持。 *)
      introspected = TimeConstrained[
        iTPIntrospectHeld[ts["HeldExpr"]],
        $ClaudeTaskInspectionTimeLimit,
        <|"InspectionStatus" -> "InspectionTimedOut"|>
      ];
      ts = Join[ts, introspected],
      (* 宣言的 task: 内省しない。InputRef/scope 宣言を正とする。 *)
      ts["InspectionStatus"] = "DeclarativeNoIntrospection"
    ];
    ts
  ];
ClaudeClassifyTask[rawSpec_Association] := ClaudeClassifyTask[rawSpec, <||>];

(* ════════════════════════════════════════════════════════
   Subkernel 自動送信禁止条件 (v7 §5.2) + Unknown safe default (§9.2)
   ════════════════════════════════════════════════════════ *)

(* True / "Unknown" を「危険側」とみなすヘルパ (Unknown safe default) *)
iTPTrueOrUnknown[v_] := TrueQ[v] || v === "Unknown";

iTPSubkernelRejections[ct_Association] := Module[{r = {}, lim, tb, conf, refs},
  lim = $ClaudeTaskPlacementDataSizeLimits;
  tb  = ct["EstimatedTransferBytes"];
  conf = ct["ConfidentialSymbols"];
  refs = ct["ReferencedSymbols"];

  If[iTPTrueOrUnknown[ct["ReferencesMainKernelSymbols"]] && refs =!= {},
    AppendTo[r, "ReferencesMainKernelSymbols"]];
  If[MemberQ[{"Large", "Huge"}, ct["InputDataSize"]],
    AppendTo[r, "InputDataSizeLargeOrHuge"]];
  If[IntegerQ[tb] && tb > lim["SubkernelAutoTransferBytes"],
    AppendTo[r, "TransferBytesOverAutoLimit"]];
  If[MemberQ[{"High", "Prohibitive", "Unknown"}, ct["DataTransferRisk"]] &&
     refs =!= {},
    AppendTo[r, "DataTransferRisk"]];
  If[ct["CanPassByReference"] === False,
    AppendTo[r, "CannotPassByReference"]];
  If[MemberQ[{"Large", "Huge"}, ct["EstimatedOutputBytes"]] ||
     (IntegerQ[ct["EstimatedOutputBytes"]] &&
      ct["EstimatedOutputBytes"] > lim["RequireReferenceAboveBytes"]),
    AppendTo[r, "OutputBytesLargeOrHuge"]];
  If[refs =!= {} && conf =!= {} && Intersection[refs, conf] =!= {},
    AppendTo[r, "ConfidentialSymbolCapture"]];
  If[TrueQ[ct["UsesSharedVariable"]] || TrueQ[ct["UsesSharedFunction"]],
    If[ct["MasterCallbackRisk"] === "High",
      AppendTo[r, "HighMasterCallback"]]];
  If[TrueQ[ct["UsesDistributeDefinitions"]] &&
     IntegerQ[ct["AggregateWorkerResidentBytes"]] &&
     ct["AggregateWorkerResidentBytes"] > lim["HardDenyValueTransferAboveBytes"],
    AppendTo[r, "DistributeDefinitionsAggregateOverLimit"]];
  (* FE 依存・dialog は subkernel 不可 (v7 §4.4) *)
  If[iTPTrueOrUnknown[ct["UsesNotebookIO"]] || TrueQ[ct["RequiresFrontEnd"]] ||
     TrueQ[ct["RequiresNotebookObject"]],
    AppendTo[r, "FrontEndDependent"]];
  If[TrueQ[ct["UsesDialog"]],
    AppendTo[r, "BlockingDialog"]];
  DeleteDuplicates[r]
];

(* WolframScript への headless 不可条件 (v7 §4.4) *)
iTPWolframScriptRejections[ct_Association] := Module[{r = {}},
  If[ct["HeadlessSafe"] === False ||
     TrueQ[ct["UsesNotebookIO"]] || TrueQ[ct["RequiresFrontEnd"]] ||
     TrueQ[ct["RequiresNotebookObject"]],
    AppendTo[r, "NotHeadlessSafe"]];
  If[TrueQ[ct["UsesDialog"]],
    AppendTo[r, "BlockingDialog"]];
  (* main-memory symbol を直接参照 かつ materialize 計画なし -> 値渡し不可 (v7 §6.1) *)
  If[ct["ReferencesMainKernelSymbols"] === True &&
     ct["MaterializationRequired"] =!= True &&
     ct["MaterializationTarget"] === "None",
    AppendTo[r, "MainMemorySymbolWithoutMaterialization"]];
  DeleteDuplicates[r]
];

(* WolframScript を誘因する条件 (v7 §6.1) *)
iTPWolframScriptPreferredQ[ct_Association] := Or[
  MemberQ[$iTPWolframScriptKinds, ct["TaskKind"]],
  ct["DataSize"] === "Large" || ct["DataSize"] === "Huge",
  ct["EstimatedRuntimeSeconds"] === "Long",
  (NumericQ[ct["EstimatedRuntimeSeconds"]] && ct["EstimatedRuntimeSeconds"] > 30),
  TrueQ[ct["Checkpointable"]]
];

(* ════════════════════════════════════════════════════════
   ClaudeSelectExecutionBackend (v7 §4.3 優先順位; advisory)
   ════════════════════════════════════════════════════════ *)

ClaudeSelectExecutionBackend[ct0_Association, context_Association] :=
  Module[{ct, decision, subRej, wsRej, pref, notes = {},
          uiTriggered, recommend, reason},
    ct = ct0;
    decision = Lookup[context, "Decision", ct["Decision"]];
    pref = ct["PreferredBackend"];
    uiTriggered = TrueQ[Lookup[context, "UITriggered", False]];

    (* (1) NBAccess Decision 最優先 *)
    If[decision === "Deny",
      Return[<|"SelectedBackend" -> "Deny", "ReasonClass" -> "NBAccessDeny",
        "Rejections" -> {}, "Fallbacks" -> {}, "RequiresApproval" -> False,
        "Notes" -> notes|>]];
    If[decision === "RepairNeeded",
      Return[<|"SelectedBackend" -> "RepairNeeded", "ReasonClass" -> "NBAccessRepairNeeded",
        "Rejections" -> {}, "Fallbacks" -> {}, "RequiresApproval" -> False,
        "Notes" -> notes|>]];

    subRej = iTPSubkernelRejections[ct];
    wsRej  = iTPWolframScriptRejections[ct];

    (* (2) hard safety: FE / Notebook mutation / dialog *)
    If[TrueQ[ct["RequiresNotebookObject"]] || TrueQ[ct["UsesNotebookIO"]] ||
       MemberQ[ct["NBAccessEffectClasses"], "NotebookMutation"] ||
       MemberQ[ct["NBAccessEffectClasses"], "DesktopAction"] ||
       MemberQ[ct["NBAccessEffectClasses"], "FrontEndAction"],
      Return[<|"SelectedBackend" -> "FinalActionQueue",
        "ReasonClass" -> "FrontEndOrNotebookRequired",
        "Rejections" -> DeleteDuplicates[Join[subRej, wsRej]],
        "Fallbacks" -> {"MainKernelAsync"},
        "RequiresApproval" -> (decision === "NeedsApproval"),
        "Notes" -> notes|>]];

    (* (3) blocking dialog: dispatch 前に main FE で解決 (v7 §4.3) *)
    If[TrueQ[ct["UsesDialog"]],
      AppendTo[notes, "RequiresPreDispatchDialogResolution"];
      Return[<|"SelectedBackend" -> "MainKernelAsync",
        "ReasonClass" -> "BlockingDialogMustResolveOnMainFE",
        "Rejections" -> DeleteDuplicates[Join[subRej, wsRej]],
        "Fallbacks" -> {"FinalActionQueue"},
        "RequiresApproval" -> True, "Notes" -> notes|>]];

    (* (4) UI 起点 + 長時間 -> preemptive 直接実行禁止 (v7 §4.2) *)
    If[uiTriggered &&
       (ct["EstimatedRuntimeSeconds"] === "Long" ||
        (NumericQ[ct["EstimatedRuntimeSeconds"]] && ct["EstimatedRuntimeSeconds"] > 2) ||
        ct["FrontEndBlockingRisk"] === "High"),
      AppendTo[notes, "UITriggeredLongRunningMustDispatchAsync"]];

    (* (5) 宣言的 external / WolframScript 誘因 *)
    If[iTPWolframScriptPreferredQ[ct],
      If[wsRej === {},
        recommend = "WolframScriptProcess"; reason = "BatchOrExternalOrLong",
        (* WolframScript 不可なら FE 系へ退避 *)
        recommend = "FinalActionQueue"; reason = "WolframScriptRejected";
        AppendTo[notes, "WolframScriptRejected:" <> StringRiffle[wsRej, ","]]];
      Return[iTPFinishRecommendation[recommend, reason, ct, pref, subRej, wsRej,
        decision, notes]]];

    (* (6) Subkernel 候補 *)
    If[subRej === {} &&
       MatchQ[ct["HeadlessSafe"], True | "Unknown"] &&
       ! TrueQ[ct["RequiresFrontEnd"]],
      recommend = "SubkernelAsync"; reason = "SerializableTransferSafeComputation";
      Return[iTPFinishRecommendation[recommend, reason, ct, pref, subRej, wsRej,
        decision, notes]]];

    (* (7) 既定: MainKernelAsync *)
    AppendTo[notes, "DefaultMainKernel:" <> StringRiffle[subRej, ","]];
    iTPFinishRecommendation["MainKernelAsync", "DefaultMainKernelTask", ct, pref,
      subRej, wsRej, decision, notes]
  ];
ClaudeSelectExecutionBackend[ct_Association] :=
  ClaudeSelectExecutionBackend[ct, <||>];

(* PreferredBackend は希望 (v7 §4.3 優先順位 5)。
   推奨と一致すれば採用。食い違う場合、希望が安全側に却下されないなら尊重、
   却下されるなら推奨を採り rejection を記録する。 *)
iTPFinishRecommendation[recommend_, reason_, ct_, pref_, subRej_, wsRej_,
    decision_, notes0_] :=
  Module[{notes = notes0, sel = recommend, rc = reason, prefRejected},
    If[MatchQ[pref, "MainKernelAsync" | "SubkernelAsync" |
                    "WolframScriptProcess" | "FinalActionQueue"] &&
       pref =!= recommend,
      prefRejected = Switch[pref,
        "SubkernelAsync",       subRej =!= {},
        "WolframScriptProcess", wsRej =!= {},
        _,                      False];
      If[prefRejected,
        AppendTo[notes, "PreferredBackendRejected:" <> pref],
        (* 希望が安全側で却下されない -> 尊重 *)
        sel = pref; rc = "PreferredBackendHonored"]
    ];
    <|"SelectedBackend" -> sel, "ReasonClass" -> rc,
      "Rejections" -> <|"Subkernel" -> subRej, "WolframScript" -> wsRej|>,
      "Fallbacks" -> DeleteCases[
        {"MainKernelAsync", "FinalActionQueue"}, sel],
      "RequiresApproval" -> (decision === "NeedsApproval"),
      "Notes" -> notes|>
  ];

(* ════════════════════════════════════════════════════════
   ClaudeBuildTaskAction (v7 §5.1; NBValidateAction 接続点)
   ════════════════════════════════════════════════════════ *)

ClaudeBuildTaskAction[ct_Association] := <|
  "Action"               -> "ExternalTask",
  "TaskKind"             -> ct["TaskKind"],
  "PlacementEffect"      -> ct["PlacementEffect"],
  "DeclaredEffectClasses"-> ct["DeclaredEffectClasses"],
  "Target"               -> <|
    "NetworkTargets" -> ct["AllowedNetworkTargets"],
    "Directories"    -> ct["AllowedDirectories"]
  |>,
  "RequestedBackend"     -> Replace[ct["SelectedBackend"],
                              Except[_String] :> ct["PreferredBackend"]]
|>;

End[];

EndPackage[];

Print[Style["ClaudeRuntime_taskplacement.wl (Phase 1 classifier) がロードされました。", Bold]];
Print["
  ClaudeNormalizeTaskSpec[raw]              -> 正本 schema へ正規化
  ClaudeClassifyTask[spec, ctx]             -> held-expr 内省 + 派生 metadata
  ClaudeSelectExecutionBackend[ct, ctx]     -> backend 推奨 (advisory)
  ClaudeBuildTaskAction[ct]                 -> NBValidateAction 用 action
  ClaudeTaskPlacementSchema[]               -> 正本 schema template
"];
