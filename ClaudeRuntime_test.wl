(* ClaudeRuntime_test.wl -- ClaudeRuntime / ClaudeTestKit テスト
   
   claudecode.wl 非依存で動作するよう、LLMGraph インフラの
   最小スタブを提供してからテストを実行する。
   
   実行: Block[{$CharacterEncoding = "UTF-8"}, Get["ClaudeRuntime_test.wl"]]
*)

(* ════════════════════════════════════════════════════════
   0. テスト基盤
   ════════════════════════════════════════════════════════ *)

$testResults = {};
$testCount = 0;
$testPassed = 0;
$testFailed = 0;

iAssert[name_String, expr_] :=
  Module[{result},
    $testCount++;
    result = Quiet @ Check[expr, $Failed];
    If[TrueQ[result],
      $testPassed++;
      AppendTo[$testResults, <|"Name" -> name, "Passed" -> True|>],
      $testFailed++;
      AppendTo[$testResults, <|"Name" -> name, "Passed" -> False,
        "Got" -> result|>];
      Print[Style["  \[Cross] " <> name <> ": ", Red],
        ToString[Short[result, 3]]]
    ]
  ];

iAssertEqual[name_String, got_, expected_] :=
  Module[{},
    $testCount++;
    If[got === expected,
      $testPassed++;
      AppendTo[$testResults, <|"Name" -> name, "Passed" -> True|>],
      $testFailed++;
      AppendTo[$testResults, <|"Name" -> name, "Passed" -> False,
        "Got" -> got, "Expected" -> expected|>];
      Print[Style["  \[Cross] " <> name, Red]];
      Print["    got:      ", Short[got, 3]];
      Print["    expected: ", Short[expected, 3]]
    ]
  ];

iPrintSection[title_String] :=
  Print[Style["\n\[FilledSquare] " <> title, Bold]];

(* iTest: iAssert と同じインターフェースの別名。
   Phase 14 以降の新テストで使用。 *)
iTest[name_String, expr_] := iAssert[name, expr];

(* ════════════════════════════════════════════════════════
   1. LLMGraph 最小スタブ (ClaudeCode` パッケージ非依存化)
   
   ClaudeRuntime.wl は ClaudeCode`iLLMGraphNode 等を
   明示コンテキストで呼ぶので、同コンテキストに直接定義する。
   SyncProvider 前提で全ノードを同期即時実行する。
   ════════════════════════════════════════════════════════ *)

ClaudeCode`iLLMGraphNode[id_String, type_String, category_String,
    deps_List, handler_] :=
  <|"id" -> id, "type" -> type, "category" -> category,
    "dependsOn" -> deps, "status" -> "pending",
    "handler" -> handler, "result" -> None,
    "runState" -> None, "error" -> None|>;

If[!AssociationQ[ClaudeCode`$iStubDAGJobs],
  ClaudeCode`$iStubDAGJobs = <||>];

ClaudeCode`LLMGraphDAGCreate[spec_Association] :=
  Module[{jobId, nodes, onComplete, job,
          changed = True, n, deps, allDepsDone, result},
    jobId = "stub-dag-" <> ToString[RandomInteger[99999]];
    nodes      = spec["nodes"];
    onComplete = Lookup[spec, "onComplete", None];
    job = spec;
    If[TrueQ[$stubDebug],
      Print["  [stub] DAG start: ", Keys[nodes]]];
    (* 依存順にトポロジカル実行 *)
    While[changed,
      changed = False;
      Do[
        n = nodes[nid];
        If[Lookup[n, "status", ""] =!= "pending", Continue[]];
        deps = Lookup[n, "dependsOn", {}];
        allDepsDone = AllTrue[deps,
          Module[{depNode, ds},
            depNode = Lookup[nodes, #, <||>];
            ds = Lookup[depNode, "status", ""];
            ds === "done" || (TrueQ[Lookup[n, "tolerateFailure", False]] &&
                              ds === "failed")] &];
        If[!allDepsDone,
          If[TrueQ[$stubDebug],
            Print["  [stub] ", nid, " skip (deps not ready)"]];
          Continue[]];
        If[TrueQ[$stubDebug],
          Print["  [stub] ", nid, " executing..."]];
        result = Check[
          n["handler"][<|"nodes" -> nodes, "nb" -> $Failed,
            "context" -> Lookup[spec, "context", <||>]|>],
          $Failed];
        If[TrueQ[$stubDebug],
          Print["  [stub] ", nid, " result: ",
            Which[result === $Failed, "$Failed",
                  result === None, "None",
                  AssociationQ[result], "<|" <> StringRiffle[Keys[result], ","] <> "|>",
                  True, Short[result, 2]]]];
        If[result === $Failed || result === None,
          n["status"] = "failed";
          n["error"]  = "Handler returned " <> ToString[Head[result]],
          n["status"] = "done";
          n["result"] = result];
        nodes[nid] = n;
        changed = True,
        {nid, Keys[nodes]}]];
    job["nodes"] = nodes;
    ClaudeCode`$iStubDAGJobs[jobId] = job;
    If[TrueQ[$stubDebug],
      Print["  [stub] DAG complete: ",
        AssociationMap[Lookup[nodes[#], "status", "?"] &, Keys[nodes]]]];
    If[onComplete =!= None, Quiet[onComplete[job]]];
    jobId
  ];

ClaudeCode`LLMGraphDAGCancel[jobId_String] :=
  (ClaudeCode`$iStubDAGJobs = KeyDrop[ClaudeCode`$iStubDAGJobs, jobId];
   jobId);

(* RunScheduledTask stub は不要: ClaudeRuntime が直接呼び出しに変更済み *)

(* ════════════════════════════════════════════════════════
   2. パッケージロード
   ════════════════════════════════════════════════════════ *)

Print[Style["\n══ ClaudeRuntime / ClaudeTestKit テスト開始 ══", Bold, Blue]];

(* 3ファイルが同一ディレクトリにある前提 *)
$iTestDir = Which[
  StringQ[$InputFileName] && FileExistsQ[$InputFileName],
    DirectoryName[$InputFileName],
  True,
    Quiet @ Check[NotebookDirectory[], Directory[]]
];

Print["  テストディレクトリ: ", $iTestDir];

Block[{$CharacterEncoding = "UTF-8"},
  Module[{f1, f2},
    f1 = FileNameJoin[{$iTestDir, "ClaudeRuntime.wl"}];
    f2 = FileNameJoin[{$iTestDir, "ClaudeTestKit.wl"}];
    If[!FileExistsQ[f1], Print[Style["ERROR: " <> f1 <> " が見つかりません", Red]]; Abort[]];
    If[!FileExistsQ[f2], Print[Style["ERROR: " <> f2 <> " が見つかりません", Red]]; Abort[]];
    Get[f1];
    Get[f2];
  ];
];

(* ロード検証 *)
If[!AssociationQ[ClaudeRuntime`ClaudeRetryPolicy["Eval"]],
  Print[Style["ERROR: ClaudeRuntime がロードされていません", Red]]; Abort[]];
If[!AssociationQ[ClaudeTestKit`CreateMockProvider[{"x"}]],
  Print[Style["ERROR: ClaudeTestKit.CreateMockProvider がロードされていません", Red]]; Abort[]];
Module[{testAdapter = ClaudeTestKit`CreateMockAdapter[]},
  If[!AssociationQ[testAdapter],
    Print[Style["ERROR: CreateMockAdapter[] が Association を返しません: ", Red],
      Short[testAdapter, 2]]; Abort[],
    Print[Style["  CreateMockAdapter OK (keys: " <>
      StringRiffle[Keys[testAdapter], ", "] <> ")", Darker[Green]]]]];
Print[Style["  パッケージロード OK", Darker[Green]]];
Print["  ClaudeRuntime version: ",
  If[StringQ[ClaudeRuntime`$ClaudeRuntimeVersion],
    ClaudeRuntime`$ClaudeRuntimeVersion, "UNKNOWN (古いファイル!)"]];
Print["  ClaudeTestKit version: ",
  If[StringQ[ClaudeTestKit`$ClaudeTestKitVersion],
    ClaudeTestKit`$ClaudeTestKitVersion, "UNKNOWN (古いファイル!)"]];

(* ════════════════════════════════════════════════════════
   2.5 ミニマル診断テスト
   ════════════════════════════════════════════════════════ *)

iPrintSection["ミニマル診断テスト"];

(* $stubDebug = True;  確認済みにつき無効化 *)

Module[{adapter, rid, st, jobId},
  Print["  [diag] CreateMockAdapter..."];
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[{
      "Hello! How are you? I can't parse this."}]];
  Print["  [diag] adapter AssociationQ: ", AssociationQ[adapter]];
  Print["  [diag] adapter keys: ",
    If[AssociationQ[adapter], Keys[adapter], Head[adapter]]];
  
  Print["  [diag] CreateClaudeRuntime..."];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter];
  Print["  [diag] rid: ", rid, " StringQ: ", StringQ[rid]];
  
  If[StringQ[rid],
    st = ClaudeRuntime`ClaudeRuntimeState[rid];
    Print["  [diag] initial status: ", st["Status"]];
    
    Print["  [diag] ClaudeRunTurn..."];
    jobId = ClaudeRuntime`ClaudeRunTurn[rid, "test",
      "Notebook" -> $Failed];
    Print["  [diag] jobId: ", Short[jobId, 2],
      " StringQ: ", StringQ[jobId]];
    
    st = ClaudeRuntime`ClaudeRuntimeState[rid];
    Print["  [diag] final status: ", st["Status"]];
    Print["  [diag] TurnCount: ", st["TurnCount"]];
    Print["  [diag] EventTrace length: ", Length[st["EventTrace"]]];
    If[Length[st["EventTrace"]] > 0,
      Print["  [diag] events: ",
        Lookup[#, "Type", "?"] & /@ st["EventTrace"]]],
    Print["  [diag] rid is not a String, cannot continue"]
  ];
];

(* ════════════════════════════════════════════════════════
   3. ClaudeRuntime 単体テスト
   ════════════════════════════════════════════════════════ *)

$stubDebug = False;

iPrintSection["ClaudeRuntime 単体テスト"];

(* ── 3.1 RetryPolicy ── *)
Module[{ep, up},
  ep = ClaudeRuntime`ClaudeRetryPolicy["Eval"];
  up = ClaudeRuntime`ClaudeRetryPolicy["UpdatePackage"];
  iAssertEqual["RetryPolicy Eval Profile",
    ep["Profile"], "Eval"];
  iAssertEqual["RetryPolicy UpdatePackage Profile",
    up["Profile"], "UpdatePackage"];
  iAssert["Eval MaxTotalSteps = 8",
    ep["Limits"]["MaxTotalSteps"] === 8];
  iAssert["UpdatePackage MaxTotalSteps = 20",
    up["Limits"]["MaxTotalSteps"] === 20];
  iAssert["UpdatePackage has more generous limits",
    up["Limits"]["MaxReloadRepairs"] > ep["Limits"]["MaxReloadRepairs"]];
];

(* ── 3.2 Failure classification ── *)
Module[{},
  iAssertEqual["Classify timeout",
    ClaudeRuntime`ClaudeClassifyFailure["Connection timeout"]["Class"],
    "TransportTransient"];
  iAssert["Timeout is retryable",
    TrueQ[ClaudeRuntime`ClaudeClassifyFailure["timeout"]["Retryable"]]];
  iAssertEqual["Classify forbidden",
    ClaudeRuntime`ClaudeClassifyFailure["Forbidden head"]["Class"],
    "ForbiddenHead"];
  iAssert["Forbidden is fatal",
    TrueQ[ClaudeRuntime`ClaudeClassifyFailure["Forbidden"]["Fatal"]]];
  iAssertEqual["Classify rate limit",
    ClaudeRuntime`ClaudeClassifyFailure["429 rate limit"]["Class"],
    "ProviderRateLimit"];
  iAssertEqual["Classify confidential leak",
    ClaudeRuntime`ClaudeClassifyFailure["confidential data leak"]["Class"],
    "ConfidentialLeakRisk"];
  iAssertEqual["Classify unknown",
    ClaudeRuntime`ClaudeClassifyFailure["something weird"]["Class"],
    "UnknownFailure"];
  (* Association form *)
  iAssertEqual["Classify assoc ForbiddenHead",
    ClaudeRuntime`ClaudeClassifyFailure[
      <|"ReasonClass" -> "ForbiddenHead"|>]["Class"],
    "ForbiddenHead"];
];

(* ── 3.3 CreateClaudeRuntime ── *)
Module[{badAdapter, goodAdapter, rid},
  badAdapter = <|"BuildContext" -> Identity|>;
  iAssertEqual["Bad adapter returns $Failed",
    ClaudeRuntime`CreateClaudeRuntime[badAdapter], $Failed];

  goodAdapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[{"hello"}]];
  rid = ClaudeRuntime`CreateClaudeRuntime[goodAdapter];
  iAssert["Good adapter returns runtimeId",
    StringQ[rid] && StringStartsQ[rid, "rt-"]];

  Module[{st = ClaudeRuntime`ClaudeRuntimeState[rid]},
    iAssertEqual["Initial status", st["Status"], "Initialized"];
    iAssertEqual["Initial TurnCount", st["TurnCount"], 0];
    iAssert["EventTrace has Created event",
      Length[st["EventTrace"]] >= 1 &&
      st["EventTrace"][[1]]["Type"] === "Created"];
  ];
];

(* ── 3.4 ClaudeRunTurn: Permit (simple) ── *)
Module[{adapter, rid, jobId, st, trace},
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[{
      "```mathematica\nPrint[\"hello\"]\n```"
    }],
    "ExecutionResults" -> {Null}
  ];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Say hello",
    "Notebook" -> $Failed];

  iAssert["RunTurn returns jobId string",
    StringQ[jobId]];

  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  iAssertEqual["Permit: final status Done", st["Status"], "Done"];
  iAssertEqual["Permit: TurnCount = 1", st["TurnCount"], 1];

  trace = ClaudeRuntime`ClaudeTurnTrace[rid];
  iAssert["Permit: trace has ContextBuilt",
    AnyTrue[trace, #["Type"] === "ContextBuilt" &]];
  iAssert["Permit: trace has ProviderQueried",
    AnyTrue[trace, #["Type"] === "ProviderQueried" &]];
  iAssert["Permit: trace has ProposalParsed",
    AnyTrue[trace, #["Type"] === "ProposalParsed" &]];
  iAssert["Permit: trace has ValidationComplete",
    AnyTrue[trace, #["Type"] === "ValidationComplete" &]];
  iAssert["Permit: trace has ResultRedacted",
    AnyTrue[trace, #["Type"] === "ResultRedacted" &]];
  iAssert["Permit: trace has TurnComplete",
    AnyTrue[trace, #["Type"] === "TurnComplete" &]];
];

(* ── 3.5 ClaudeRunTurn: Deny (forbidden head) → AwaitingApproval ──
   Phase 25b: Deny は即時失敗ではなく AwaitingApproval (DenyOverride) に遷移。
   ユーザーが「中止」すると Failed になる。 *)
Module[{adapter, rid, jobId, st, trace},
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[{
      "```mathematica\nDeleteFile[\"x.txt\"]\n```"
    }]
  ];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "delete file",
    "Notebook" -> $Failed];

  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  iAssertEqual["Deny: status AwaitingApproval (Phase 25b)",
    st["Status"], "AwaitingApproval"];
  iAssert["Deny: PendingApproval has DenyOverride",
    AssociationQ[st["PendingApproval"]] &&
    TrueQ[Lookup[st["PendingApproval"], "DenyOverride", False]]];
  iAssert["Deny: trace has AwaitingApproval with DenyOverride",
    AnyTrue[ClaudeRuntime`ClaudeTurnTrace[rid],
      (Lookup[#, "Type", ""] === "AwaitingApproval" &&
       TrueQ[Lookup[#, "DenyOverride", False]]) &]];

  (* ユーザーが中止 → Failed *)
  ClaudeRuntime`ClaudeDenyProposal[rid];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  iAssertEqual["Deny+UserDeny: final status Failed",
    st["Status"], "Failed"];
  iAssertEqual["Deny+UserDeny: ReasonClass UserDenied",
    Lookup[st["LastFailure"], "ReasonClass", ""], "UserDenied"];
];

(* ── 3.6 ClaudeRunTurn: NeedsApproval ── *)
Module[{adapter, rid, jobId, st},
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[{
      "```mathematica\nNBCellWriteCode[nb, 1, \"x\"]\n```"
    }]
  ];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "write code",
    "Notebook" -> $Failed];

  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  iAssertEqual["Approval: status AwaitingApproval",
    st["Status"], "AwaitingApproval"];
  iAssert["Approval: PendingApproval is set",
    AssociationQ[st["PendingApproval"]]];

  (* Deny the proposal *)
  ClaudeRuntime`ClaudeDenyProposal[rid];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  iAssertEqual["After deny: status Failed", st["Status"], "Failed"];
];

(* ── 3.7 ClaudeRunTurn: NeedsApproval → Approve ── *)
Module[{adapter, rid, jobId, st},
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[{
      "```mathematica\nNBCellWriteCode[nb, 2, \"y=1\"]\n```"
    }],
    "ExecutionResults" -> {Null}
  ];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "write code",
    "Notebook" -> $Failed];

  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  iAssertEqual["Approve: initially AwaitingApproval",
    st["Status"], "AwaitingApproval"];

  ClaudeRuntime`ClaudeApproveProposal[rid];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  iAssertEqual["Approve: after approval Done", st["Status"], "Done"];
  iAssert["Approve: trace has ApprovalGranted",
    AnyTrue[ClaudeRuntime`ClaudeTurnTrace[rid],
      #["Type"] === "ApprovalGranted" &]];
];

(* ── 3.8 ClaudeRunTurn: TextOnly ── *)
Module[{adapter, rid, jobId, st, trace},
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[{
      "The answer is 42!"
    }]
  ];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "what is 6*7",
    "Notebook" -> $Failed];

  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  iAssertEqual["TextOnly: status Done", st["Status"], "Done"];
  iAssert["TextOnly: trace has TextOnlyResponse",
    AnyTrue[ClaudeRuntime`ClaudeTurnTrace[rid],
      #["Type"] === "TextOnlyResponse" &]];
];

(* ── 3.9 Budget exhaustion ── *)
Module[{adapter, rid, jobId, st},
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[
      Table["```mathematica\nPrint[" <> ToString[i] <> "]\n```", {i, 10}]
    ],
    "ExecutionResults" -> Table[Null, 10],
    "MaxContinuations" -> 99  (* adapter は常に continuation 要求 *)
  ];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter, "Profile" -> "Eval"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "loop test",
    "Notebook" -> $Failed];

  (* Eval プロファイルでは MaxProposalIterations = 4 なので
     budget 消費後に Done で停止するはず *)
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  iAssert["Budget: TurnCount <= MaxProposalIterations + 1",
    st["TurnCount"] <= 5];
  iAssert["Budget: BudgetsUsed MaxTotalSteps > 0",
    st["BudgetsUsed"]["MaxTotalSteps"] > 0];
];

(* ── 3.10 Cancel ── *)
Module[{adapter, rid, st},
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[{"hello"}]];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter];
  ClaudeRuntime`ClaudeRuntimeCancel[rid];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  iAssertEqual["Cancel: status Failed", st["Status"], "Failed"];
  iAssert["Cancel: trace has Cancelled",
    AnyTrue[ClaudeRuntime`ClaudeTurnTrace[rid],
      #["Type"] === "Cancelled" &]];
];

(* ── 3.11 RuntimeNotFound ── *)
Module[{result},
  result = ClaudeRuntime`ClaudeRuntimeState["nonexistent"];
  iAssert["RuntimeNotFound returns Missing",
    MatchQ[result, _Missing]];
];

(* ── 3.12 NormalizeClaudeTrace ── *)
Module[{trace, normalized},
  trace = {
    <|"Type" -> "Created", "Timestamp" -> 123456.789,
      "RuntimeId" -> "rt-12345"|>,
    <|"Type" -> "TurnStarted", "Timestamp" -> 123457.0,
      "JobId" -> "stub-dag-99999"|>
  };
  normalized = ClaudeTestKit`NormalizeClaudeTrace[trace];
  iAssert["Normalize: Timestamp removed",
    !KeyExistsQ[normalized[[1]], "Timestamp"]];
  iAssert["Normalize: RuntimeId anonymized",
    !AnyTrue[normalized, 
      StringQ[Lookup[#, "RuntimeId", None]] && 
      StringStartsQ[Lookup[#, "RuntimeId", ""], "rt-"] &]];
];

(* ════════════════════════════════════════════════════════
   4. ClaudeTestKit 単体テスト
   ════════════════════════════════════════════════════════ *)

iPrintSection["ClaudeTestKit 単体テスト"];

(* ── 4.1 MockProvider ── *)
Module[{mp, r1, r2, r3},
  mp = ClaudeTestKit`CreateMockProvider[{"aaa", "bbb"}];
  r1 = mp["Query"][<||>, <||>];
  r2 = mp["Query"][<||>, <||>];
  r3 = mp["Query"][<||>, <||>];
  iAssertEqual["MockProvider 1st response", r1["response"], "aaa"];
  iAssertEqual["MockProvider 2nd response", r2["response"], "bbb"];
  iAssert["MockProvider exhausted", StringQ[r3["response"]]];
  iAssertEqual["MockProvider count", mp["ResponseCount"][], 3];
  mp["Reset"][];
  iAssertEqual["MockProvider reset", mp["ResponseCount"][], 0];
];

(* ── 4.2 MockAdapter ParseProposal ── *)
Module[{ma, p1, p2, p3},
  ma = ClaudeTestKit`CreateMockAdapter[];
  p1 = ma["ParseProposal"]["The answer is 42!"];
  iAssert["Parse text-only: HasProposal=False",
    !TrueQ[p1["HasProposal"]]];

  p2 = ma["ParseProposal"]["```mathematica\nPrint[1]\n```"];
  iAssert["Parse code block: HasProposal=True",
    TrueQ[p2["HasProposal"]]];
  iAssert["Parse code block: HeldExpr is HoldComplete",
    MatchQ[p2["HeldExpr"], HoldComplete[_]]];

  p3 = ma["ParseProposal"]["Print[1]"];
  iAssert["Parse bare expr: HasProposal=False (no ```mathematica block)",
    !TrueQ[p3["HasProposal"]]];
];

(* ── 4.3 MockAdapter ValidateProposal ── *)
Module[{ma, vPermit, vDeny, vApproval, vRepair},
  ma = ClaudeTestKit`CreateMockAdapter[];
  vPermit = ma["ValidateProposal"][
    <|"HeldExpr" -> HoldComplete[Print["hi"]]|>, <||>];
  iAssertEqual["Validate Print: Permit",
    vPermit["Decision"], "Permit"];

  vDeny = ma["ValidateProposal"][
    <|"HeldExpr" -> HoldComplete[DeleteFile["x"]]|>, <||>];
  iAssertEqual["Validate DeleteFile: Deny",
    vDeny["Decision"], "Deny"];

  vApproval = ma["ValidateProposal"][
    <|"HeldExpr" -> HoldComplete[NBCellWriteCode[nb, 1, "x"]]|>, <||>];
  iAssertEqual["Validate NBCellWriteCode: NeedsApproval",
    vApproval["Decision"], "NeedsApproval"];

  vRepair = ma["ValidateProposal"][
    <|"HeldExpr" -> HoldComplete[SomeUnknownFunction[]]|>, <||>];
  iAssertEqual["Validate unknown head: RepairNeeded",
    vRepair["Decision"], "RepairNeeded"];
];

(* ── 4.4 MockAdapter RedactResult with secrets ── *)
Module[{ma, redacted},
  ma = ClaudeTestKit`CreateMockAdapter[
    "Secrets" -> {"my-api-key-xyz"}];
  redacted = ma["RedactResult"][
    <|"Success" -> True, "RawResult" -> "data contains my-api-key-xyz here"|>,
    <||>];
  iAssert["Redact: secret is replaced",
    StringContainsQ[redacted["RedactedResult"], "[REDACTED]"]];
  iAssert["Redact: secret not present",
    !StringContainsQ[redacted["RedactedResult"], "my-api-key-xyz"]];
];

(* ── 4.5 Assertion functions ── *)
Module[{trace},
  trace = {
    <|"Type" -> "ContextBuilt", "Timestamp" -> 1|>,
    <|"Type" -> "ProviderQueried", "Timestamp" -> 2|>,
    <|"Type" -> "FatalFailure", "Detail" -> "ForbiddenHead", "Timestamp" -> 3|>,
    <|"Type" -> "StatusChange", "Status" -> "Failed", "Timestamp" -> 4|>
  };
  iAssert["AssertNoSecretLeak: no secrets",
    TrueQ[ClaudeTestKit`AssertNoSecretLeak[trace, {"password123"}]]];
  iAssert["AssertValidationDenied: finds denial",
    TrueQ[ClaudeTestKit`AssertValidationDenied[trace]]];
  iAssert["AssertOutcome: Failed",
    TrueQ[ClaudeTestKit`AssertOutcome[trace, "Failed"]]];
  iAssert["AssertEventSequence: partial match",
    TrueQ[ClaudeTestKit`AssertEventSequence[trace,
      {"ContextBuilt", "ProviderQueried"}]]];
  iAssert["AssertEventSequence: no match",
    !TrueQ[ClaudeTestKit`AssertEventSequence[trace,
      {"TurnComplete", "Done"}]]];
];

(* ════════════════════════════════════════════════════════
   5. ClaudeTestKit 組み込みシナリオ実行
   ════════════════════════════════════════════════════════ *)

iPrintSection["ClaudeTestKit 組み込みシナリオ"];

Module[{scenarios, scenarioNames, result},
  scenarios = ClaudeTestKit`$ClaudeTestScenarios;
  scenarioNames = Keys[scenarios];
  iAssert["Built-in scenarios exist",
    Length[scenarioNames] >= 5];

  Do[
    result = ClaudeTestKit`RunClaudeScenario[scenarios[sName]];
    iAssert["Scenario " <> sName <> ": completed",
      AssociationQ[result] && KeyExistsQ[result, "Status"]];
    iAssert["Scenario " <> sName <> ": all assertions passed",
      TrueQ[result["AllPassed"]]];
    If[!TrueQ[result["AllPassed"]],
      Print["    Failed assertions for ", sName, ":"];
      Do[
        If[!TrueQ[result["AssertionResults"][aName]["Passed"]],
          Print["      ", aName, ": ",
            result["AssertionResults"][aName]["Detail"]]],
        {aName, Keys[result["AssertionResults"]]}]],
    {sName, scenarioNames}
  ];
];

(* ════════════════════════════════════════════════════════
   6. 統合テスト: 複合シナリオ
   ════════════════════════════════════════════════════════ *)

iPrintSection["統合テスト"];

(* ── 6.1 Approval → approve → continuation ── *)
Module[{adapter, rid, jobId, st},
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[{
      "```mathematica\nNBCellWriteCode[nb, 1, \"a=1\"]\n```",
      "```mathematica\nPrint[\"done\"]\n```"
    }],
    "ExecutionResults" -> {Null, Null},
    "MaxContinuations" -> 1
  ];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "write and print",
    "Notebook" -> $Failed];

  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  iAssertEqual["Approval+Cont: initially AwaitingApproval",
    st["Status"], "AwaitingApproval"];

  (* 承認すると execute → continuation → 2nd turn → Done *)
  ClaudeRuntime`ClaudeApproveProposal[rid];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  (* 2nd turn は Print で Permit → Done *)
  iAssert["Approval+Cont: final status Done or has multiple turns",
    st["Status"] === "Done" || st["TurnCount"] >= 2];
];

(* ── 6.2 RepairNeeded で budget 消費後に Failed ──
   NBAccess ロード済みの場合、Runtime 直接チェックは MyCustomFunc を
   Permit にするため、adapter フォールバックを使うよう NBAccess リストを
   一時的に退避する。 *)
Module[{adapter, rid, jobId, st, trace,
        savedDeny, savedApproval},
  savedDeny = Quiet[NBAccess`$NBDenyHeads];
  savedApproval = Quiet[NBAccess`$NBApprovalHeads];
  Quiet[NBAccess`$NBDenyHeads =.];
  Quiet[NBAccess`$NBApprovalHeads =.];
  
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[{
      "```mathematica\nMyCustomFunc[1, 2, 3]\n```",
      "```mathematica\nMyCustomFunc[4, 5, 6]\n```",
      "```mathematica\nMyCustomFunc[7, 8, 9]\n```",
      "```mathematica\nMyCustomFunc[10, 11, 12]\n```",
      "```mathematica\nMyCustomFunc[13, 14, 15]\n```"
    }]
  ];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter, "Profile" -> "Eval"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "call custom func",
    "Notebook" -> $Failed];

  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  iAssertEqual["Repair exhaust: final status Failed",
    st["Status"], "Failed"];
  iAssert["Repair exhaust: ValidationRepairs consumed",
    st["BudgetsUsed"]["MaxValidationRepairs"] >= 1 ||
    AnyTrue[ClaudeRuntime`ClaudeTurnTrace[rid],
      #["Type"] === "ValidationRepairAttempt" &]];
  
  (* NBAccess リストを復元 *)
  If[ListQ[savedDeny], NBAccess`$NBDenyHeads = savedDeny];
  If[ListQ[savedApproval], NBAccess`$NBApprovalHeads = savedApproval];
];

(* ── 6.3 UpdatePackage プロファイルで limits が異なることの確認 ── *)
Module[{adapter, rid, st},
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[{"hello"}]];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter,
    "Profile" -> "UpdatePackage"];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  iAssertEqual["UpdatePackage profile applied",
    st["Profile"], "UpdatePackage"];
  iAssertEqual["UpdatePackage MaxTotalSteps = 20",
    st["RetryPolicy"]["Limits"]["MaxTotalSteps"], 20];
  iAssertEqual["UpdatePackage MaxReloadRepairs = 3",
    st["RetryPolicy"]["Limits"]["MaxReloadRepairs"], 3];
];

(* ════════════════════════════════════════════════════════
   7. Phase 7 テスト: NBAccess Runtime Integration API
   
   NBAccess.wl が同ディレクトリにある場合のみ実行。
   なければスキップ。
   ════════════════════════════════════════════════════════ *)

Module[{nbAccessPath, phase7Available = False},
  nbAccessPath = FileNameJoin[{DirectoryName[$InputFileName], "NBAccess.wl"}];
  If[FileExistsQ[nbAccessPath],
    Quiet @ Block[{$CharacterEncoding = "UTF-8"}, Get[nbAccessPath]];
    phase7Available = True;
    Print[Style["\n  NBAccess.wl ロード済み → Phase 7 テスト実行", Darker[Green]]],
    Print[Style["\n  NBAccess.wl が見つからない → Phase 7 テスト SKIP", Orange]]];
  
  If[phase7Available,
    
    iPrintSection["Phase 7: $NBAllowedHeads / $NBDenyHeads / $NBApprovalHeads"];
    
    iAssert["AllowedHeads contains NBCellRead",
      MemberQ[NBAccess`$NBAllowedHeads, "NBCellRead"]];
    iAssert["DenyHeads contains DeleteFile",
      MemberQ[NBAccess`$NBDenyHeads, "DeleteFile"]];
    iAssert["ApprovalHeads contains NBCellWriteCode",
      MemberQ[NBAccess`$NBApprovalHeads, "NBCellWriteCode"]];
    iAssert["AllowedHeads contains CompoundExpression",
      MemberQ[NBAccess`$NBAllowedHeads, "CompoundExpression"]];
    
    iPrintSection["Phase 7: NBValidateHeldExpr"];
    
    Module[{spec = <|"AccessLevel" -> 0.5|>, r},
      (* Permit: allowed head *)
      r = NBAccess`NBValidateHeldExpr[
        HoldComplete[Print["hello"]], spec];
      iAssertEqual["Validate Print -> Permit", r["Decision"], "Permit"];
      
      (* Deny: forbidden head *)
      r = NBAccess`NBValidateHeldExpr[
        HoldComplete[DeleteFile["x.txt"]], spec];
      iAssertEqual["Validate DeleteFile -> Deny", r["Decision"], "Deny"];
      iAssertEqual["Validate DeleteFile reason", r["ReasonClass"], "ForbiddenHead"];
      
      (* NeedsApproval: approval head *)
      r = NBAccess`NBValidateHeldExpr[
        HoldComplete[NBCellWriteCode[nb, 1, "x=1"]], spec];
      iAssertEqual["Validate NBCellWriteCode -> NeedsApproval",
        r["Decision"], "NeedsApproval"];
      
      (* RepairNeeded: unknown head *)
      r = NBAccess`NBValidateHeldExpr[
        HoldComplete[SomeRandomFunction[42]], spec];
      iAssertEqual["Validate unknown head -> RepairNeeded",
        r["Decision"], "RepairNeeded"];
      
      (* TextOnly のケースは式そのものなので Deny にすべき: 不正な形式 *)
      r = NBAccess`NBValidateHeldExpr["not a held expr", spec];
      iAssertEqual["Validate non-HoldComplete -> Deny",
        r["Decision"], "Deny"];
      
      (* CompoundExpression *)
      r = NBAccess`NBValidateHeldExpr[
        HoldComplete[CompoundExpression[Print["a"], Print["b"]]], spec];
      iAssertEqual["Validate CompoundExpression of allowed -> Permit",
        r["Decision"], "Permit"];
      
      (* 混合: allowed + deny *)
      r = NBAccess`NBValidateHeldExpr[
        HoldComplete[Module[{}, DeleteFile["x"]]], spec];
      iAssertEqual["Validate Module with DeleteFile -> Deny",
        r["Decision"], "Deny"];
      
      (* 混合: allowed + approval *)
      r = NBAccess`NBValidateHeldExpr[
        HoldComplete[Module[{}, NBCellWriteCode[nb, 1, "y=2"]]], spec];
      iAssertEqual["Validate Module with NBCellWriteCode -> NeedsApproval",
        r["Decision"], "NeedsApproval"];
      
      (* confidential leak *)
      Module[{confSpec = <|"AccessLevel" -> 0.5,
          "ConfidentialSymbols" -> {"$SecretAPIKey"}|>},
        r = NBAccess`NBValidateHeldExpr[
          HoldComplete[Print[$SecretAPIKey]], confSpec];
        iAssertEqual["Validate confidential symbol -> Deny",
          r["Decision"], "Deny"];
        iAssertEqual["Validate confidential reason",
          r["ReasonClass"], "ConfidentialLeakRisk"];
      ];
    ];
    
    iPrintSection["Phase 7: NBExecuteHeldExpr"];
    
    Module[{spec = <|"AccessLevel" -> 0.5|>, r},
      (* 成功 *)
      r = NBAccess`NBExecuteHeldExpr[
        HoldComplete[2 + 3], spec];
      iAssert["Execute 2+3 success", TrueQ[r["Success"]]];
      iAssertEqual["Execute 2+3 result", r["RawResult"], 5];
      
      (* 不正入力 *)
      r = NBAccess`NBExecuteHeldExpr["not held", spec];
      iAssert["Execute non-HoldComplete fails", !TrueQ[r["Success"]]];
      
      (* タイムアウト *)
      r = NBAccess`NBExecuteHeldExpr[
        HoldComplete[Pause[5]], spec, "TimeConstraint" -> 0.1];
      iAssert["Execute timeout", !TrueQ[r["Success"]]];
      iAssert["Execute timeout msg",
        StringContainsQ[r["Error"], "timed out"]];
    ];
    
    iPrintSection["Phase 7: NBRedactExecutionResult"];
    
    Module[{spec, r},
      spec = <|"AccessLevel" -> 0.5, "Secrets" -> {"sk-abc123"}|>;
      r = NBAccess`NBRedactExecutionResult[
        <|"Success" -> True, "RawResult" -> "The key is sk-abc123",
          "Error" -> None|>, spec];
      iAssert["Redact removes secret",
        !StringContainsQ[r["RedactedResult"], "sk-abc123"]];
      iAssert["Redact has REDACTED marker",
        StringContainsQ[r["RedactedResult"], "[REDACTED]"]];
      
      (* 秘密なし *)
      r = NBAccess`NBRedactExecutionResult[
        <|"Success" -> True, "RawResult" -> "safe text",
          "Error" -> None|>, <|"AccessLevel" -> 0.5|>];
      iAssert["Redact safe text unchanged",
        StringContainsQ[r["RedactedResult"], "safe text"]];
    ];
    
    iPrintSection["Phase 7: NBMakeContextPacket"];
    
    Module[{spec = <|"AccessLevel" -> 0.5|>, r},
      (* notebook なしの場合 *)
      r = NBAccess`NBMakeContextPacket[$Failed, spec];
      iAssert["ContextPacket invalid nb",
        !TrueQ[r["NotebookValid"]]];
      iAssertEqual["ContextPacket invalid nb cells", r["Cells"], {}];
    ];
    
    iPrintSection["Phase 7: 統合テスト (Adapter + Runtime + NBAccess)"];
    
    (* claudecode.wl をロード (Phase 12 で adapter 統合済み) *)
    Module[{codePath},
      codePath = FileNameJoin[{DirectoryName[$InputFileName],
        "claudecode.wl"}];
      If[FileExistsQ[codePath],
        Quiet @ Block[{$CharacterEncoding = "UTF-8"}, Get[codePath]];
        Print[Style["  claudecode.wl ロード済み (adapter 統合)", Darker[Green]]];
        (* Phase 21 diagnostic: check if ClaudeBuildRuntimeAdapter is properly defined *)
        Print["  [diag-load] $Context after Get: ", $Context];
        Print["  [diag-load] ClaudeBuildRuntimeAdapter Names: ",
          Length[Names["ClaudeCode`ClaudeBuildRuntimeAdapter"]]];
        Print["  [diag-load] DownValues count: ",
          Length[DownValues[ClaudeCode`ClaudeBuildRuntimeAdapter]]];
        Print["  [diag-load] Options: ",
          Short[Options[ClaudeCode`ClaudeBuildRuntimeAdapter], 2]];
        Print["  [diag-load] EndPackage ran: ",
          !MemberQ[$ContextPath, "ClaudeCode`Private`"]];
        Module[{testAdapter},
          testAdapter = Quiet @ Check[
            ClaudeCode`ClaudeBuildRuntimeAdapter[$Failed, "SyncProvider" -> True],
            "FAILED"];
          Print["  [diag-load] test call result type: ", Head[testAdapter]];
          If[AssociationQ[testAdapter],
            Print["  [diag-load] test call keys: ", Keys[testAdapter]],
            Print["  [diag-load] test call value: ", Short[testAdapter, 2]]]],
        Print[Style["  claudecode.wl なし → 統合テスト SKIP", Orange]]]];
    
    (* Phase 16c: claudecode.wl ロード後に同期 DAG スタブを再適用。
       理由: 実際の LLMGraphDAGCreate は非同期 (ScheduledTask 駆動)。
       テスト実行中は ScheduledTask が動かないため、
       同期スタブでないとテストが完了しない。
       これは adapter 統合の正しさをテストするもので、
       DAG の非同期動作自体のテストではない。
       
       重要: テスト完了後に実体を復元するため、ここで保存する。 *)
    $iSavedDAGCreateDV = DownValues[ClaudeCode`LLMGraphDAGCreate];
    $iSavedDAGCancelDV = DownValues[ClaudeCode`LLMGraphDAGCancel];
    Print[Style["  実体 LLMGraphDAGCreate を保存済み (テスト後に復元予定)",
      Italic, Gray]];
    Module[{stubImpl},
      stubImpl = Function[{spec},
        Module[{jobId, nodes, onComplete, job,
                changed = True, n, deps, allDepsDone, result},
          jobId = "stub-dag-" <> ToString[RandomInteger[99999]];
          nodes      = spec["nodes"];
          onComplete = Lookup[spec, "onComplete", None];
          job = spec;
          While[changed,
            changed = False;
            Do[
              n = nodes[nid];
              If[Lookup[n, "status", ""] =!= "pending", Continue[]];
              deps = Lookup[n, "dependsOn", {}];
              allDepsDone = AllTrue[deps,
                Module[{depNode, ds},
                  depNode = Lookup[nodes, #, <||>];
                  ds = Lookup[depNode, "status", ""];
                  ds === "done" || (TrueQ[Lookup[n, "tolerateFailure", False]] &&
                                    ds === "failed")] &];
              If[!allDepsDone, Continue[]];
              result = Quiet @ Check[n["handler"][
                <|"nodes" -> nodes, "nb" -> $Failed,
                  "context" -> Lookup[spec, "context", <||>]|>],
                $Failed];
              If[result === $Failed || result === None,
                n["status"] = "failed";
                n["error"]  = "Handler returned " <> ToString[Head[result]],
                n["status"] = "done";
                n["result"] = result];
              nodes[nid] = n;
              changed = True,
              {nid, Keys[nodes]}]];
          job["nodes"] = nodes;
          If[onComplete =!= None, Quiet[onComplete[job]]];
          jobId]];
      (* 実際の LLMGraphDAGCreate を同期スタブで上書き *)
      Unprotect[ClaudeCode`LLMGraphDAGCreate];
      ClaudeCode`LLMGraphDAGCreate[spec_Association] := stubImpl[spec];
      Print[Style["  同期 DAG スタブ再適用済み (テスト用)", Italic, Gray]]
    ];    
    If[Length[Names["ClaudeCode`ClaudeBuildRuntimeAdapter"]] > 0,
      
      (* テスト: adapter + mock provider → Permit → Done *)
      Module[{mockProv, adapter, rid, jobId, st, tr},
        mockProv = ClaudeTestKit`CreateMockProvider[{
          "```mathematica\nPrint[\"hello from adapter\"]\n```"
        }];
        adapter = ClaudeCode`ClaudeBuildRuntimeAdapter[$Failed,
          "SyncProvider" -> True,
          "Provider" -> mockProv,
          "MaxContinuations" -> 0];
        iAssert["Adapter has all keys",
          AllTrue[{"BuildContext", "QueryProvider", "ParseProposal",
            "ValidateProposal", "ExecuteProposal", "RedactResult",
            "ShouldContinue"}, KeyExistsQ[adapter, #] &]];
        
        rid = ClaudeRuntime`CreateClaudeRuntime[adapter, "Profile" -> "Eval"];
        iAssert["Adapter runtime created", StringQ[rid]];
        
        jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Say hello", "Notebook" -> $Failed];
        st = ClaudeRuntime`ClaudeRuntimeState[rid];
        tr = ClaudeRuntime`ClaudeTurnTrace[rid];
        iAssertEqual["Adapter Permit -> Done", st["Status"], "Done"];
        iAssert["Adapter trace has ResultRedacted",
          AnyTrue[tr, Lookup[#, "Type", ""] === "ResultRedacted" &]];
      ];
      
      (* テスト: adapter + deny head → AwaitingApproval (Phase 25b DenyOverride) *)
      Module[{mockProv, adapter, rid, jobId, st},
        mockProv = ClaudeTestKit`CreateMockProvider[{
          "```mathematica\nDeleteFile[\"danger.txt\"]\n```"
        }];
        adapter = ClaudeCode`ClaudeBuildRuntimeAdapter[$Failed,
          "SyncProvider" -> True,
          "Provider" -> mockProv];
        rid = ClaudeRuntime`CreateClaudeRuntime[adapter];
        jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Delete file", "Notebook" -> $Failed];
        st = ClaudeRuntime`ClaudeRuntimeState[rid];
        iAssertEqual["Adapter Deny -> AwaitingApproval",
          st["Status"], "AwaitingApproval"];
        iAssert["Adapter Deny has DenyOverride",
          TrueQ[Lookup[
            Lookup[st, "PendingApproval", <||>],
            "DenyOverride", False]]];
      ];
      
      (* テスト: adapter + approval head → AwaitingApproval *)
      Module[{mockProv, adapter, rid, jobId, st, tr},
        mockProv = ClaudeTestKit`CreateMockProvider[{
          "```mathematica\nNBCellWriteCode[nb, 1, \"x=42\"]\n```"
        }];
        adapter = ClaudeCode`ClaudeBuildRuntimeAdapter[$Failed,
          "SyncProvider" -> True,
          "Provider" -> mockProv];
        (* Diagnostic: check $NBApprovalHeads *)
        Print["  [diag-approval] $NBApprovalHeads type: ",
          Head[NBAccess`$NBApprovalHeads]];
        Print["  [diag-approval] $NBApprovalHeads length: ",
          If[ListQ[NBAccess`$NBApprovalHeads],
            Length[NBAccess`$NBApprovalHeads], "NOT A LIST"]];
        Print["  [diag-approval] NBCellWriteCode in ApprovalHeads: ",
          MemberQ[NBAccess`$NBApprovalHeads, "NBCellWriteCode"]];
        Print["  [diag-approval] $NBDenyHeads length: ",
          If[ListQ[NBAccess`$NBDenyHeads],
            Length[NBAccess`$NBDenyHeads], "NOT A LIST"]];
        (* Test ParseProposal *)
        Module[{parsed, heldExpr, heads},
          parsed = adapter["ParseProposal"][
            "```mathematica\nNBCellWriteCode[nb, 1, \"x=42\"]\n```"];
          Print["  [diag-approval] parsed HasProposal: ",
            Lookup[parsed, "HasProposal", "?"]];
          heldExpr = Lookup[parsed, "HeldExpr", None];
          Print["  [diag-approval] HeldExpr: ", Short[heldExpr, 2]];
          If[MatchQ[heldExpr, HoldComplete[_]],
            heads = Cases[heldExpr,
              s_Symbol[___] :> SymbolName[Unevaluated[s]],
              {1, Infinity}];
            Print["  [diag-approval] extracted heads: ", heads]];
          (* Test ValidateProposal directly *)
          Module[{valResult},
            valResult = adapter["ValidateProposal"][parsed, <||>];
            Print["  [diag-approval] ValidateProposal result: ",
              Short[valResult, 3]]]];
        rid = ClaudeRuntime`CreateClaudeRuntime[adapter];
        jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Write code", "Notebook" -> $Failed];
        st = ClaudeRuntime`ClaudeRuntimeState[rid];
        tr = ClaudeRuntime`ClaudeTurnTrace[rid];
        Print["  [diag-approval] final status: ", st["Status"]];
        Print["  [diag-approval] events: ",
          Map[Lookup[#, "Type", "?"] &, tr]];
        iAssertEqual["Adapter Approval -> AwaitingApproval",
          st["Status"], "AwaitingApproval"];
      ];
      
      (* テスト: secret redaction 統合 *)
      Module[{mockProv, adapter, rid, jobId, st, tr, trStr},
        mockProv = ClaudeTestKit`CreateMockProvider[{
          "```mathematica\nToString[\"my-secret-key-999\"]\n```"
        }];
        adapter = ClaudeCode`ClaudeBuildRuntimeAdapter[$Failed,
          "SyncProvider" -> True,
          "Provider" -> mockProv,
          "Secrets" -> {"my-secret-key-999"},
          "MaxContinuations" -> 0];
        rid = ClaudeRuntime`CreateClaudeRuntime[adapter];
        jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Show key", "Notebook" -> $Failed];
        tr = ClaudeRuntime`ClaudeTurnTrace[rid];
        trStr = ToString[tr, InputForm];
        iAssert["Adapter no secret in trace",
          !StringContainsQ[trStr, "my-secret-key-999"]];
      ];
      
      (* テスト: ClaudeStartRuntime ショートカット *)
      Module[{mockProv, result, st},
        mockProv = ClaudeTestKit`CreateMockProvider[{
          "```mathematica\nPrint[\"quick start\"]\n```"
        }];
        result = ClaudeCode`ClaudeStartRuntime[$Failed, "Quick test",
          "SyncProvider" -> True,
          "Provider" -> mockProv,
          "MaxContinuations" -> 0];
        iAssert["StartRuntime returns RuntimeId",
          StringQ[result["RuntimeId"]]];
        st = ClaudeRuntime`ClaudeRuntimeState[result["RuntimeId"]];
        iAssertEqual["StartRuntime -> Done", st["Status"], "Done"];
      ];
    ];
  ];
];

(* ════════════════════════════════════════════════════════
   Phase 7 後: LLMGraph スタブ再インストール
   
   Phase 7 が claudecode.wl をロードした場合、
   ClaudeCode`LLMGraphDAGCreate が非同期 (ポーリングタスク) 版に
   上書きされる。以降のテストは同期実行を前提としているため、
   スタブを再インストールして元に戻す。
   ════════════════════════════════════════════════════════ *)

If[Length[Names["ClaudeCode`ClaudeBuildRuntimeAdapter"]] > 0,
  Print[Style["\n  claudecode.wl ロード済み \[Rule] LLMGraph スタブ再インストール",
    Darker[Orange]]];
  ClaudeCode`LLMGraphDAGCreate[spec_Association] :=
    Module[{jobId, nodes, onComplete, job,
            changed = True, n, deps, allDepsDone, result},
      jobId = "stub-dag-" <> ToString[RandomInteger[99999]];
      nodes      = spec["nodes"];
      onComplete = Lookup[spec, "onComplete", None];
      job = spec;
      While[changed,
        changed = False;
        Do[
          n = nodes[nid];
          If[Lookup[n, "status", ""] =!= "pending", Continue[]];
          deps = Lookup[n, "dependsOn", {}];
          allDepsDone = AllTrue[deps,
            Module[{depNode, ds},
              depNode = Lookup[nodes, #, <||>];
              ds = Lookup[depNode, "status", ""];
              ds === "done" || (TrueQ[Lookup[n, "tolerateFailure", False]] &&
                                ds === "failed")] &];
          If[!allDepsDone, Continue[]];
          result = Check[
            n["handler"][<|"nodes" -> nodes, "nb" -> $Failed,
              "context" -> Lookup[spec, "context", <||>]|>],
            $Failed];
          If[result === $Failed || result === None,
            n["status"] = "failed";
            n["error"]  = "Handler returned " <> ToString[Head[result]],
            n["status"] = "done";
            n["result"] = result];
          nodes[nid] = n;
          changed = True,
          {nid, Keys[nodes]}]];
      job["nodes"] = nodes;
      If[onComplete =!= None, Quiet[onComplete[job]]];
      jobId
    ];
  ClaudeCode`LLMGraphDAGCancel[jobId_String] := jobId;
];

(* ════════════════════════════════════════════════════════
   8. Phase 8 テスト: Transport Retry / Format Retry / ClaudeEvalViaRuntime
   ════════════════════════════════════════════════════════ *)

iPrintSection["Phase 8: Transport Retry"];

(* FailingMockProvider: 最初の N 回は $Failed を返し、その後は正常応答 *)
iCreateFailingProvider[failCount_Integer, successResponse_String] :=
  Module[{callIdx = 0},
    <|
      "Type" -> "FailingMockProvider",
      "Query" -> Function[{contextPacket, convState},
        callIdx++;
        If[callIdx <= failCount,
          $Failed,
          <|"response" -> successResponse|>
        ]
      ],
      "CallCount" -> Function[{}, callIdx],
      "Reset" -> Function[{}, callIdx = 0]
    |>
  ];

(* Transport retry: 1回失敗→2回目成功 *)
Module[{failProv, adapter, rid, jobId, st, tr},
  failProv = iCreateFailingProvider[1,
    "```mathematica\nPrint[\"recovered\"]\n```"];
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> failProv];
  (* SyncProvider は MockAdapter が設定済み *)
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter, "Profile" -> "Eval"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Test retry", "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  tr = ClaudeRuntime`ClaudeTurnTrace[rid];
  iAssertEqual["TransportRetry 1fail -> Done", st["Status"], "Done"];
  iAssert["TransportRetry event in trace",
    AnyTrue[tr, Lookup[#, "Type", ""] === "TransportRetry" &]];
  iAssert["TransportRetry provider called twice",
    failProv["CallCount"][] >= 2];
];

(* Transport retry: 全て失敗→Failed *)
Module[{failProv, adapter, rid, jobId, st, tr},
  failProv = iCreateFailingProvider[10,
    "```mathematica\nPrint[\"never\"]\n```"];
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> failProv];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter, "Profile" -> "Eval"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Test exhaust", "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  tr = ClaudeRuntime`ClaudeTurnTrace[rid];
  iAssertEqual["TransportRetry exhaust -> Failed/Done",
    MemberQ[{"Failed", "Done"}, st["Status"]], True];
  iAssert["TransportRetry exhausted event",
    AnyTrue[tr, Lookup[#, "Type", ""] === "TransportRetryExhausted" &]];
];

(* Transport retry: Fatal エラーはリトライしない *)
Module[{adapter, rid, jobId, st, tr},
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> <|
      "Type" -> "FatalProvider",
      "Query" -> Function[{contextPacket, convState},
        <|"response" -> "", "Error" -> "forbidden access denied"|>
      ]|>];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter, "Profile" -> "Eval"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Fatal test", "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  iAssertEqual["FatalTransport -> Failed", st["Status"], "Failed"];
];

iPrintSection["Phase 8: Format Retry"];

(* Format retry: 不正フォーマット→repair turn→正常応答 *)
Module[{mockProv, adapter, rid, jobId, st, tr},
  mockProv = ClaudeTestKit`CreateMockProvider[{
    "Here is my answer without code block!",  (* 不正フォーマット *)
    "```mathematica\nPrint[\"fixed\"]\n```"    (* repair 後の正常応答 *)
  }];
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> mockProv,
    "MaxContinuations" -> 1];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter, "Profile" -> "Eval"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Format test", "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  tr = ClaudeRuntime`ClaudeTurnTrace[rid];
  (* TextOnly 応答として Done になるか、repair で continuation するかはアーキテクチャ依存 *)
  iAssert["FormatRetry completes",
    MemberQ[{"Done", "Failed"}, st["Status"]]];
];

iPrintSection["Phase 8: ClaudeEvalViaRuntime"];

If[Length[Names["ClaudeCode`ClaudeBuildRuntimeAdapter"]] > 0,
  (* ClaudeEvalViaRuntime with mock provider *)
  Module[{mockProv, result},
    mockProv = ClaudeTestKit`CreateMockProvider[{
      "```mathematica\n2 + 3\n```"
    }];
    result = ClaudeCode`ClaudeEvalViaRuntime["Compute 2+3",
      "SyncProvider" -> True,
      "Provider" -> mockProv,
      "MaxContinuations" -> 0,
      "Notebook" -> $Failed];
    iAssert["EvalViaRuntime returns Association",
      AssociationQ[result]];
    iAssertEqual["EvalViaRuntime -> Done",
      result["Status"], "Done"];
    iAssert["EvalViaRuntime has RuntimeId",
      StringQ[result["RuntimeId"]]];
    iAssert["EvalViaRuntime TurnCount >= 1",
      result["TurnCount"] >= 1];
  ];
  
  (* ClaudeEvalViaRuntime with deny *)
  Module[{mockProv, result},
    mockProv = ClaudeTestKit`CreateMockProvider[{
      "```mathematica\nDeleteFile[\"x\"]\n```"
    }];
    result = ClaudeCode`ClaudeEvalViaRuntime["Delete file",
      "SyncProvider" -> True,
      "Provider" -> mockProv,
      "Notebook" -> $Failed];
    iAssertEqual["EvalViaRuntime deny -> AwaitingApproval (Phase 25b)",
      result["Status"], "AwaitingApproval"];
  ];
];

(* ════════════════════════════════════════════════════════
   9. Phase 9 テスト: Transaction パイプライン
   ════════════════════════════════════════════════════════ *)

iPrintSection["Phase 9: Transaction パイプライン (UpdatePackage)"];

(* ── 9.1 Transaction 正常パス: 全ステップ成功 → Done ── *)
Module[{mockProv, adapter, rid, jobId, st, tr},
  mockProv = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\nPrint[\"patch applied\"]\n```"
  }];
  adapter = ClaudeTestKit`CreateMockTransactionAdapter[
    "Provider" -> mockProv];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter,
    "Profile" -> "UpdatePackage"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Add Print function",
    "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  tr = ClaudeRuntime`ClaudeTurnTrace[rid];
  
  iAssertEqual["Tx success: status Done", st["Status"], "Done"];
  iAssert["Tx success: SnapshotCreated in trace",
    AnyTrue[tr, Lookup[#, "Type", ""] === "SnapshotCreated" &]];
  iAssert["Tx success: ShadowApplied in trace",
    AnyTrue[tr, Lookup[#, "Type", ""] === "ShadowApplied" &]];
  iAssert["Tx success: StaticCheckPassed in trace",
    AnyTrue[tr, Lookup[#, "Type", ""] === "StaticCheckPassed" &]];
  iAssert["Tx success: ReloadCheckPassed in trace",
    AnyTrue[tr, Lookup[#, "Type", ""] === "ReloadCheckPassed" &]];
  iAssert["Tx success: TestsPassed in trace",
    AnyTrue[tr, Lookup[#, "Type", ""] === "TestsPassed" &]];
  iAssert["Tx success: TransactionCommitted in trace",
    AnyTrue[tr, Lookup[#, "Type", ""] === "TransactionCommitted" &]];
  iAssert["Tx success: event sequence correct",
    ClaudeTestKit`AssertEventSequence[tr,
      {"SnapshotCreated", "ShadowApplied", "StaticCheckPassed",
       "ReloadCheckPassed", "TestsPassed", "TransactionCommitted",
       "TurnComplete"}]];
  iAssert["Tx success: TransactionState has Committed",
    st["TransactionState"]["Phase"] === "Committed"];
];

(* ── 9.2 Transaction: ShadowApply 失敗 → rollback + repair ── *)
Module[{mockProv, adapter, rid, jobId, st, tr},
  mockProv = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\nPrint[\"bad patch\"]\n```",
    "```mathematica\nPrint[\"fixed patch\"]\n```"
  }];
  adapter = ClaudeTestKit`CreateMockTransactionAdapter[
    "Provider" -> mockProv,
    "FailAtPhase" -> "ShadowApply",
    "FailCount" -> 1,
    "MaxContinuations" -> 1];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter,
    "Profile" -> "UpdatePackage"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Apply patch",
    "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  tr = ClaudeRuntime`ClaudeTurnTrace[rid];
  
  iAssert["Tx ShadowFail: ShadowApplyFailed in trace",
    AnyTrue[tr, Lookup[#, "Type", ""] === "ShadowApplyFailed" &]];
  iAssert["Tx ShadowFail: RolledBack in trace",
    AnyTrue[tr, Lookup[#, "Type", ""] === "RolledBack" &]];
  (* repair turn が起動し、2回目は成功するはず *)
  iAssert["Tx ShadowFail: eventually Done or multiple turns",
    st["Status"] === "Done" || st["TurnCount"] >= 2];
];

(* ── 9.3 Transaction: ReloadCheck 失敗 → rollback + repair ── *)
Module[{mockProv, adapter, rid, jobId, st, tr},
  mockProv = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\nPrint[\"reload fail\"]\n```",
    "```mathematica\nPrint[\"reload fix\"]\n```"
  }];
  adapter = ClaudeTestKit`CreateMockTransactionAdapter[
    "Provider" -> mockProv,
    "FailAtPhase" -> "ReloadCheck",
    "FailCount" -> 1,
    "MaxContinuations" -> 1];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter,
    "Profile" -> "UpdatePackage"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Apply with reload error",
    "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  tr = ClaudeRuntime`ClaudeTurnTrace[rid];
  
  iAssert["Tx ReloadFail: ReloadCheckFailed in trace",
    AnyTrue[tr, Lookup[#, "Type", ""] === "ReloadCheckFailed" &]];
  iAssert["Tx ReloadFail: RolledBack in trace",
    AnyTrue[tr, Lookup[#, "Type", ""] === "RolledBack" &]];
  iAssert["Tx ReloadFail: repair attempted",
    st["TurnCount"] >= 2 || st["Status"] === "Done"];
];

(* ── 9.4 Transaction: TestPhase 失敗 → rollback + repair ── *)
Module[{mockProv, adapter, rid, jobId, st, tr},
  mockProv = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\nPrint[\"test fail\"]\n```",
    "```mathematica\nPrint[\"test fix\"]\n```"
  }];
  adapter = ClaudeTestKit`CreateMockTransactionAdapter[
    "Provider" -> mockProv,
    "FailAtPhase" -> "TestPhase",
    "FailCount" -> 1,
    "MaxContinuations" -> 1];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter,
    "Profile" -> "UpdatePackage"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Apply with test failure",
    "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  tr = ClaudeRuntime`ClaudeTurnTrace[rid];
  
  iAssert["Tx TestFail: TestsFailed in trace",
    AnyTrue[tr, Lookup[#, "Type", ""] === "TestsFailed" &]];
  iAssert["Tx TestFail: RolledBack in trace",
    AnyTrue[tr, Lookup[#, "Type", ""] === "RolledBack" &]];
  iAssert["Tx TestFail: repair attempted",
    st["TurnCount"] >= 2 || st["Status"] === "Done"];
];

(* ── 9.5 Transaction: ReloadCheck 失敗 × budget 消尽 → Failed ── *)
Module[{mockProv, adapter, rid, jobId, st, tr},
  mockProv = ClaudeTestKit`CreateMockProvider[
    Table["```mathematica\nPrint[\"always fails\"]\n```", 10]
  ];
  adapter = ClaudeTestKit`CreateMockTransactionAdapter[
    "Provider" -> mockProv,
    "FailAtPhase" -> "ReloadCheck",
    "FailCount" -> 99,  (* 常に失敗 *)
    "MaxContinuations" -> 5];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter,
    "Profile" -> "UpdatePackage"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Always fail reload",
    "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  tr = ClaudeRuntime`ClaudeTurnTrace[rid];
  
  iAssertEqual["Tx ReloadExhaust: status Failed",
    st["Status"], "Failed"];
  iAssert["Tx ReloadExhaust: MaxReloadRepairs consumed",
    st["BudgetsUsed"]["MaxReloadRepairs"] >= 1];
];

(* ── 9.6 Transaction: TestPhase 失敗 × budget 消尽 → Failed ── *)
Module[{mockProv, adapter, rid, jobId, st, tr},
  mockProv = ClaudeTestKit`CreateMockProvider[
    Table["```mathematica\nPrint[\"tests never pass\"]\n```", 10]
  ];
  adapter = ClaudeTestKit`CreateMockTransactionAdapter[
    "Provider" -> mockProv,
    "FailAtPhase" -> "TestPhase",
    "FailCount" -> 99,
    "MaxContinuations" -> 5];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter,
    "Profile" -> "UpdatePackage"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Always fail tests",
    "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  
  iAssertEqual["Tx TestExhaust: status Failed",
    st["Status"], "Failed"];
  iAssert["Tx TestExhaust: MaxTestRepairs consumed",
    st["BudgetsUsed"]["MaxTestRepairs"] >= 1];
];

(* ── 9.7 Transaction: Snapshot 失敗 → 即座に Fatal ── *)
Module[{mockProv, adapter, rid, jobId, st, tr},
  mockProv = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\nPrint[\"snap fail\"]\n```"
  }];
  adapter = ClaudeTestKit`CreateMockTransactionAdapter[
    "Provider" -> mockProv,
    "FailAtPhase" -> "Snapshot",
    "FailCount" -> 99];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter,
    "Profile" -> "UpdatePackage"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Snapshot fails",
    "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  tr = ClaudeRuntime`ClaudeTurnTrace[rid];
  
  iAssertEqual["Tx SnapshotFail: status Failed",
    st["Status"], "Failed"];
  iAssert["Tx SnapshotFail: SnapshotFailed in trace",
    AnyTrue[tr, Lookup[#, "Type", ""] === "SnapshotFailed" &]];
];

(* ── 9.8 Transaction: Deny head → AwaitingApproval (Phase 25b DenyOverride) ── *)
Module[{mockProv, adapter, rid, jobId, st},
  mockProv = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\nDeleteFile[\"x\"]\n```"
  }];
  adapter = ClaudeTestKit`CreateMockTransactionAdapter[
    "Provider" -> mockProv];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter,
    "Profile" -> "UpdatePackage"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Deny in tx",
    "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  
  iAssertEqual["Tx Deny: status AwaitingApproval (Phase 25b)",
    st["Status"], "AwaitingApproval"];
  iAssert["Tx Deny: DenyOverride flag set",
    TrueQ[Lookup[
      Lookup[st, "PendingApproval", <||>],
      "DenyOverride", False]]];
];

(* ── 9.9 Transaction: Eval プロファイルでは transaction 不使用 ── *)
Module[{mockProv, adapter, rid, jobId, st, tr},
  mockProv = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\nPrint[\"eval mode\"]\n```"
  }];
  adapter = ClaudeTestKit`CreateMockTransactionAdapter[
    "Provider" -> mockProv];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter,
    "Profile" -> "Eval"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Eval test",
    "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  tr = ClaudeRuntime`ClaudeTurnTrace[rid];
  
  iAssertEqual["Tx EvalProfile: status Done", st["Status"], "Done"];
  (* Eval モードでは transaction イベントなし *)
  iAssert["Tx EvalProfile: no SnapshotCreated",
    !AnyTrue[tr, Lookup[#, "Type", ""] === "SnapshotCreated" &]];
];

(* ── 9.10 Transaction: budget 管理の確認 ── *)
Module[{adapter, rid, st},
  adapter = ClaudeTestKit`CreateMockTransactionAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[{"hello"}]];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter,
    "Profile" -> "UpdatePackage"];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  
  iAssertEqual["Tx Budget: MaxReloadRepairs = 3",
    st["RetryPolicy"]["Limits"]["MaxReloadRepairs"], 3];
  iAssertEqual["Tx Budget: MaxTestRepairs = 3",
    st["RetryPolicy"]["Limits"]["MaxTestRepairs"], 3];
  iAssertEqual["Tx Budget: MaxPatchApplyRetries = 2",
    st["RetryPolicy"]["Limits"]["MaxPatchApplyRetries"], 2];
  iAssertEqual["Tx Budget: MaxFullReplans = 1",
    st["RetryPolicy"]["Limits"]["MaxFullReplans"], 1];
];

(* ── 9.11 ClaudeUpdatePackageViaRuntime (adapter 統合) ── *)
If[Length[Names["ClaudeCode`ClaudeBuildRuntimeAdapter"]] > 0,
  iPrintSection["Phase 9: ClaudeUpdatePackageViaRuntime 統合"];
  
  Module[{mockProv, result},
    mockProv = ClaudeTestKit`CreateMockProvider[{
      "```mathematica\nPrint[\"via runtime\"]\n```"
    }];
    (* 実 adapter テストには実ファイルが必要なのでここでは
       ClaudeStartRuntime で UpdatePackage プロファイルを使うテストのみ *)
    result = ClaudeCode`ClaudeStartRuntime[$Failed,
      "Update package test",
      "SyncProvider" -> True,
      "Provider" -> mockProv,
      "MaxContinuations" -> 0,
      "Profile" -> "UpdatePackage"];
    iAssert["UpdatePkgViaRuntime: returns RuntimeId",
      StringQ[result["RuntimeId"]]];
    (* Eval adapter なので transaction なし → Done *)
    Module[{st = ClaudeRuntime`ClaudeRuntimeState[result["RuntimeId"]]},
      iAssertEqual["UpdatePkgViaRuntime: profile is UpdatePackage",
        st["Profile"], "UpdatePackage"]];
  ];
];

(* ════════════════════════════════════════════════════════
   10. Phase 10 テスト: Repair Retry 強化
   ════════════════════════════════════════════════════════ *)

iPrintSection["Phase 10: Repair Retry 強化"];

(* ── 10.1 Checkpoint events in successful transaction ── *)
Module[{mockProv, adapter, rid, jobId, st, tr},
  mockProv = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\nPrint[\"chk\"]\n```"
  }];
  adapter = ClaudeTestKit`CreateMockTransactionAdapter[
    "Provider" -> mockProv];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter,
    "Profile" -> "UpdatePackage"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Checkpoint test",
    "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  tr = ClaudeRuntime`ClaudeTurnTrace[rid];
  
  iAssertEqual["P10 checkpoint: Done", st["Status"], "Done"];
  iAssert["P10 checkpoint: CheckpointSaved events exist",
    Count[tr, _?(Lookup[#, "Type", ""] === "CheckpointSaved" &)] >= 4];
  iAssert["P10 checkpoint: Snapshot checkpoint",
    AnyTrue[tr, Lookup[#, "Type", ""] === "CheckpointSaved" &&
      Lookup[#, "Phase", ""] === "Snapshot" &]];
  iAssert["P10 checkpoint: ShadowApply checkpoint",
    AnyTrue[tr, Lookup[#, "Type", ""] === "CheckpointSaved" &&
      Lookup[#, "Phase", ""] === "ShadowApply" &]];
  iAssert["P10 checkpoint: CheckpointStack non-empty",
    Length[Lookup[st, "CheckpointStack", {}]] >= 4];
];

(* ── 10.2 Structured repair info on ShadowApply failure ── *)
Module[{mockProv, adapter, rid, jobId, st, contInput},
  mockProv = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\nPrint[\"fail\"]\n```",
    "```mathematica\nPrint[\"fix\"]\n```"
  }];
  adapter = ClaudeTestKit`CreateMockTransactionAdapter[
    "Provider" -> mockProv,
    "FailAtPhase" -> "ShadowApply",
    "FailCount" -> 1,
    "MaxContinuations" -> 1];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter,
    "Profile" -> "UpdatePackage"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Structured repair",
    "Notebook" -> $Failed];
  
  (* 1回目失敗後、ContinuationInput に構造化 repair info が入るはず *)
  (* ただし iOnTurnComplete で即座に次ターンが起動されるので
     最終状態を確認 *)
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  iAssert["P10 structured: eventually completes",
    MemberQ[{"Done", "Failed"}, st["Status"]]];
  iAssert["P10 structured: multiple turns",
    st["TurnCount"] >= 2];
];

(* ── 10.3 Per-phase failure count tracking ── *)
Module[{mockProv, adapter, rid, jobId, st},
  mockProv = ClaudeTestKit`CreateMockProvider[
    Table["```mathematica\nPrint[\"r\"]\n```", 10]];
  adapter = ClaudeTestKit`CreateMockTransactionAdapter[
    "Provider" -> mockProv,
    "FailAtPhase" -> "ReloadCheck",
    "FailCount" -> 99,
    "MaxContinuations" -> 5];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter,
    "Profile" -> "UpdatePackage"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Phase failure count",
    "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  
  iAssertEqual["P10 phaseCount: Failed", st["Status"], "Failed"];
  iAssert["P10 phaseCount: ReloadCheck failures tracked",
    Lookup[
      Lookup[st["TransactionState"], "PhaseFailureCounts", <||>],
      "ReloadCheck", 0] >= 1];
];

(* ── 10.4 Full replan escalation ── *)
Module[{mockProv, adapter, rid, jobId, st, tr},
  mockProv = ClaudeTestKit`CreateMockProvider[
    Table["```mathematica\nPrint[\"rp\"]\n```", 20]];
  adapter = ClaudeTestKit`CreateMockTransactionAdapter[
    "Provider" -> mockProv,
    "FailAtPhase" -> "TestPhase",
    "FailCount" -> 99,
    "MaxContinuations" -> 10];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter,
    "Profile" -> "UpdatePackage"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Full replan test",
    "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  tr = ClaudeRuntime`ClaudeTurnTrace[rid];
  
  iAssertEqual["P10 replan: Failed", st["Status"], "Failed"];
  (* TestRepairs(3) 消尽後に FullReplanAttempt が発生するはず *)
  iAssert["P10 replan: FullReplanAttempt in trace",
    AnyTrue[tr, Lookup[#, "Type", ""] === "FullReplanAttempt" &]];
  iAssert["P10 replan: MaxFullReplans consumed",
    st["BudgetsUsed"]["MaxFullReplans"] >= 1];
];

(* ── 10.5 FailureCount in trace events ── *)
Module[{mockProv, adapter, rid, jobId, st, tr, failEvents},
  mockProv = ClaudeTestKit`CreateMockProvider[
    Table["```mathematica\nPrint[\"fc\"]\n```", 10]];
  adapter = ClaudeTestKit`CreateMockTransactionAdapter[
    "Provider" -> mockProv,
    "FailAtPhase" -> "ReloadCheck",
    "FailCount" -> 2,
    "MaxContinuations" -> 5];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter,
    "Profile" -> "UpdatePackage"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "FailureCount tracking",
    "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  tr = ClaudeRuntime`ClaudeTurnTrace[rid];
  
  failEvents = Select[tr,
    Lookup[#, "Type", ""] === "ReloadCheckFailed" &];
  iAssert["P10 failCount: ReloadCheckFailed events have FailureCount",
    Length[failEvents] >= 1 &&
    IntegerQ[Lookup[First[failEvents], "FailureCount", None]]];
];

(* ── 10.6 Repair on success after failure ── *)
Module[{mockProv, adapter, rid, jobId, st, tr},
  mockProv = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\nPrint[\"t1\"]\n```",
    "```mathematica\nPrint[\"t2\"]\n```"
  }];
  adapter = ClaudeTestKit`CreateMockTransactionAdapter[
    "Provider" -> mockProv,
    "FailAtPhase" -> "TestPhase",
    "FailCount" -> 1,
    "MaxContinuations" -> 1];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter,
    "Profile" -> "UpdatePackage"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Repair then succeed",
    "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  tr = ClaudeRuntime`ClaudeTurnTrace[rid];
  
  iAssert["P10 repair succeed: TestsFailed then TestsPassed",
    AnyTrue[tr, Lookup[#, "Type", ""] === "TestsFailed" &] &&
    AnyTrue[tr, Lookup[#, "Type", ""] === "TestsPassed" &]];
  iAssertEqual["P10 repair succeed: Done", st["Status"], "Done"];
];

(* ════════════════════════════════════════════════════════
   11. Phase 11 テスト: Score Advisory 化
   ════════════════════════════════════════════════════════ *)

iPrintSection["Phase 11: Score Advisory 化"];

(* Phase 11 テストは NBAccess が利用可能な場合のみ実行 *)
If[Length[Names["NBAccess`NBRouteDecision"]] > 0,

  (* ── 11.1 NBRouteDecision: cloud score ── *)
  Module[{rd},
    rd = NBAccess`NBRouteDecision[0.3];
    iAssert["P11 route cloud: returns Association",
      AssociationQ[rd]];
    iAssertEqual["P11 route cloud: Route=CloudLLM",
      rd["Route"], "CloudLLM"];
    iAssertEqual["P11 route cloud: score=0.3",
      rd["EffectiveRiskScore"], 0.3];
    iAssert["P11 route cloud: has Thresholds",
      AssociationQ[rd["Thresholds"]]];
  ];

  (* ── 11.2 NBRouteDecision: private score ── *)
  Module[{rd},
    rd = NBAccess`NBRouteDecision[0.6];
    iAssertEqual["P11 route private: Route=PrivateLLM",
      rd["Route"], "PrivateLLM"];
  ];

  (* ── 11.3 NBRouteDecision: local score ── *)
  Module[{rd},
    rd = NBAccess`NBRouteDecision[0.9];
    iAssertEqual["P11 route local: Route=LocalOnly",
      rd["Route"], "LocalOnly"];
  ];

  (* ── 11.4 NBRouteDecision: boundary 0.5 ── *)
  Module[{rd},
    rd = NBAccess`NBRouteDecision[0.5];
    iAssertEqual["P11 route boundary 0.5: PrivateLLM",
      rd["Route"], "PrivateLLM"];
  ];

  (* ── 11.5 NBRouteDecision: boundary 0.8 ── *)
  Module[{rd},
    rd = NBAccess`NBRouteDecision[0.8];
    iAssertEqual["P11 route boundary 0.8: LocalOnly",
      rd["Route"], "LocalOnly"];
  ];

  (* ── 11.6 NBRouteDecision from accessSpec ── *)
  Module[{rd},
    rd = NBAccess`NBRouteDecision[<|"AccessLevel" -> 0.2|>];
    iAssertEqual["P11 route from spec: CloudLLM",
      rd["Route"], "CloudLLM"];
  ];

  (* ── 11.7 $NBRoutingThresholds is configurable ── *)
  Module[{rd, oldTh},
    oldTh = NBAccess`$NBRoutingThresholds;
    NBAccess`$NBRoutingThresholds = <|"Cloud" -> 0.3, "Private" -> 0.6|>;
    rd = NBAccess`NBRouteDecision[0.4];
    iAssertEqual["P11 custom thresholds: PrivateLLM at 0.4",
      rd["Route"], "PrivateLLM"];
    rd = NBAccess`NBRouteDecision[0.2];
    iAssertEqual["P11 custom thresholds: CloudLLM at 0.2",
      rd["Route"], "CloudLLM"];
    NBAccess`$NBRoutingThresholds = oldTh; (* restore *)
  ];

  (* ── 11.8 NBValidateHeldExpr includes RouteAdvice ── *)
  Module[{spec = <|"AccessLevel" -> 0.3|>, r},
    r = NBAccess`NBValidateHeldExpr[
      HoldComplete[Print["test"]], spec];
    iAssertEqual["P11 validate RouteAdvice: Permit",
      r["Decision"], "Permit"];
    iAssert["P11 validate RouteAdvice: has RouteAdvice key",
      KeyExistsQ[r, "RouteAdvice"]];
    iAssert["P11 validate RouteAdvice: is Association",
      AssociationQ[r["RouteAdvice"]]];
    iAssertEqual["P11 validate RouteAdvice: CloudLLM for 0.3",
      r["RouteAdvice"]["Route"], "CloudLLM"];
  ];

  (* ── 11.9 RouteAdvice is advisory: score doesn't affect permit/deny ── *)
  Module[{specLow = <|"AccessLevel" -> 0.1|>,
          specHigh = <|"AccessLevel" -> 0.9|>, r1, r2},
    r1 = NBAccess`NBValidateHeldExpr[
      HoldComplete[Print["a"]], specLow];
    r2 = NBAccess`NBValidateHeldExpr[
      HoldComplete[Print["b"]], specHigh];
    iAssertEqual["P11 advisory: low score Permit",
      r1["Decision"], "Permit"];
    iAssertEqual["P11 advisory: high score also Permit",
      r2["Decision"], "Permit"];
    iAssertEqual["P11 advisory: low score route CloudLLM",
      r1["RouteAdvice"]["Route"], "CloudLLM"];
    iAssertEqual["P11 advisory: high score route LocalOnly",
      r2["RouteAdvice"]["Route"], "LocalOnly"];
  ];

  (* ── 11.10 RouteAdvice in runtime trace ── *)
  If[Length[Names["ClaudeCode`ClaudeBuildRuntimeAdapter"]] > 0,
    Module[{mockProv, adapter, rid, jobId, st, tr, valEvent},
      mockProv = ClaudeTestKit`CreateMockProvider[{
        "```mathematica\nPrint[\"route test\"]\n```"
      }];
      adapter = ClaudeCode`ClaudeBuildRuntimeAdapter[$Failed,
        "SyncProvider" -> True,
        "Provider" -> mockProv,
        "AccessLevel" -> 0.3,
        "MaxContinuations" -> 0];
      rid = ClaudeRuntime`CreateClaudeRuntime[adapter, "Profile" -> "Eval"];
      jobId = ClaudeRuntime`ClaudeRunTurn[rid, "Route trace test",
        "Notebook" -> $Failed];
      tr = ClaudeRuntime`ClaudeTurnTrace[rid];
      valEvent = SelectFirst[tr,
        Lookup[#, "Type", ""] === "ValidationComplete" &, <||>];
      iAssert["P11 trace: ValidationComplete has RouteAdvice",
        AssociationQ[Lookup[valEvent, "RouteAdvice", None]]];
      iAssertEqual["P11 trace: RouteAdvice is CloudLLM",
        Lookup[Lookup[valEvent, "RouteAdvice", <||>], "Route", "?"],
        "CloudLLM"];
    ]],

  Print[Style["  NBRouteDecision not found → Phase 11 SKIP", Orange]]
];

(* ════════════════════════════════════════════════════════
   12. Phase 12 テスト: claudecode.wl への adapter 統合
   ════════════════════════════════════════════════════════ *)

iPrintSection["Phase 12: Runtime Adapter Integration"];

(* Phase 12 テストは ClaudeCode` が利用可能な場合のみ *)
If[Length[Names["ClaudeCode`ClaudeBuildRuntimeAdapter"]] > 0,

  (* ── 12.1 ClaudeBuildRuntimeAdapter 構築 ── *)
  Module[{adapter},
    adapter = ClaudeCode`ClaudeBuildRuntimeAdapter[$Failed,
      "AccessLevel" -> 0.3, "Secrets" -> {"sec1"},
      "MaxContinuations" -> 2, "SyncProvider" -> True];
    iAssert["P12 adapter: is Association",
      AssociationQ[adapter]];
    iAssert["P12 adapter: has BuildContext",
      KeyExistsQ[adapter, "BuildContext"]];
    iAssert["P12 adapter: has QueryProvider",
      KeyExistsQ[adapter, "QueryProvider"]];
    iAssert["P12 adapter: has ParseProposal",
      KeyExistsQ[adapter, "ParseProposal"]];
    iAssert["P12 adapter: has ValidateProposal",
      KeyExistsQ[adapter, "ValidateProposal"]];
    iAssert["P12 adapter: has ExecuteProposal",
      KeyExistsQ[adapter, "ExecuteProposal"]];
    iAssert["P12 adapter: has RedactResult",
      KeyExistsQ[adapter, "RedactResult"]];
    iAssert["P12 adapter: has ShouldContinue",
      KeyExistsQ[adapter, "ShouldContinue"]];
    iAssertEqual["P12 adapter: SyncProvider",
      adapter["SyncProvider"], True];
  ];

  (* ── 12.2 ParseProposal: code block extraction ── *)
  Module[{adapter, parse, r1, r2},
    adapter = ClaudeCode`ClaudeBuildRuntimeAdapter[$Failed];
    parse = adapter["ParseProposal"];
    
    r1 = parse["Here is the answer:\n```mathematica\nPrint[\"hello\"]\n```\nDone."];
    iAssert["P12 parse: HasProposal for code block",
      r1["HasProposal"] === True];
    iAssert["P12 parse: HeldExpr is HoldComplete",
      MatchQ[r1["HeldExpr"], HoldComplete[_]]];
    iAssertEqual["P12 parse: RawCode",
      r1["RawCode"], "Print[\"hello\"]"];
    
    r2 = parse["Just a text answer, no code."];
    iAssertEqual["P12 parse: no code -> HasProposal False",
      r2["HasProposal"], False];
    
    (* Association 入力の防御テスト *)
    Module[{r3},
      r3 = parse[<|"response" -> "```mathematica\n1+1\n```"|>];
      iAssert["P12 parse: Association input -> HasProposal True",
        r3["HasProposal"] === True]];
  ];

  (* ── 12.3 $ClaudeRoutingProviders 初期化 ── *)
  iAssert["P12 routing providers: is Association",
    AssociationQ[ClaudeCode`$ClaudeRoutingProviders]];
  iAssert["P12 routing providers: has CloudLLM",
    KeyExistsQ[ClaudeCode`$ClaudeRoutingProviders, "CloudLLM"]];
  iAssert["P12 routing providers: has PrivateLLM",
    KeyExistsQ[ClaudeCode`$ClaudeRoutingProviders, "PrivateLLM"]];
  iAssert["P12 routing providers: has LocalOnly",
    KeyExistsQ[ClaudeCode`$ClaudeRoutingProviders, "LocalOnly"]];

  (* ── 12.4 Adapter + MockProvider で runtime 統合テスト ── *)
  If[Length[Names["ClaudeRuntime`CreateClaudeRuntime"]] > 0 &&
     Length[Names["ClaudeTestKit`CreateMockProvider"]] > 0,
    Module[{mockProv, adapter, runtimeId, st},
      mockProv = ClaudeTestKit`CreateMockProvider[{
        <|"response" -> "The answer is 42."|>}];
      adapter = ClaudeCode`ClaudeBuildRuntimeAdapter[$Failed,
        "Provider" -> mockProv, "SyncProvider" -> True];
      runtimeId = ClaudeRuntime`CreateClaudeRuntime[adapter,
        "Profile" -> "Eval"];
      iAssert["P12 runtime integration: runtimeId is String",
        StringQ[runtimeId]];
      
      ClaudeRuntime`ClaudeRunTurn[runtimeId, "What is 6*7?"];
      Module[{waited = 0},
        While[waited < 10,
          st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
          If[MemberQ[{"Done", "Failed", "AwaitingApproval"}, st["Status"]],
            Break[]];
          Pause[0.3]; waited += 0.3]];
      st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
      iAssert["P12 runtime integration: status is Done",
        st["Status"] === "Done"];
    ],
    Print[Style["  ClaudeRuntime/ClaudeTestKit not loaded → P12 runtime integration SKIP", Orange]]
  ];

  (* ── 12.5 Adapter + MockProvider で NeedsApproval フロー ── *)
  If[Length[Names["ClaudeRuntime`CreateClaudeRuntime"]] > 0 &&
     Length[Names["ClaudeTestKit`CreateMockProvider"]] > 0 &&
     Length[Names["NBAccess`NBValidateHeldExpr"]] > 0,
    Module[{mockProv, adapter, runtimeId, st},
      mockProv = ClaudeTestKit`CreateMockProvider[{
        <|"response" -> "```mathematica\nNBCellWriteCode[1, \"test\"]\n```"|>}];
      adapter = ClaudeCode`ClaudeBuildRuntimeAdapter[$Failed,
        "Provider" -> mockProv, "SyncProvider" -> True,
        "AccessLevel" -> 0.3];
      runtimeId = ClaudeRuntime`CreateClaudeRuntime[adapter,
        "Profile" -> "Eval"];
      ClaudeRuntime`ClaudeRunTurn[runtimeId, "Write test code"];
      Module[{waited = 0},
        While[waited < 10,
          st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
          If[MemberQ[{"Done", "Failed", "AwaitingApproval"}, st["Status"]],
            Break[]];
          Pause[0.3]; waited += 0.3]];
      st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
      (* NeedsApproval が返されるか TextOnly/Done になるかは 
         NBValidateHeldExpr の判定次第 *)
      iAssert["P12 approval flow: terminal or awaiting",
        MemberQ[{"Done", "Failed", "AwaitingApproval"}, st["Status"]]];
    ],
    Print[Style["  NBAccess/Runtime not loaded → P12 approval flow SKIP", Orange]]
  ];

  (* ── 12.6 Routing provider selection logic ── *)
  Module[{origProviders},
    origProviders = ClaudeCode`$ClaudeRoutingProviders;
    Block[{ClaudeCode`$ClaudeRoutingProviders = <|
        "CloudLLM"   -> Automatic,
        "PrivateLLM" -> {"lmstudio", "test-model", "http://localhost:1234"},
        "LocalOnly"  -> Function[{p}, "local-response: " <> StringTake[p, UpTo[20]]]
      |>},
      (* CloudLLM -> Automatic は ClaudeQueryBg を呼ぶ (ここではテストしない) *)
      (* LocalOnly -> Function をテスト *)
      Module[{result},
        result = ClaudeCode`Private`iAdapterSelectProvider[
          "test prompt", <|"Route" -> "LocalOnly"|>, False];
        iAssert["P12 routing LocalOnly: Function provider called",
          StringQ[result] && StringContainsQ[result, "local-response"]];
      ];
    ];
  ];,

  Print[Style["  ClaudeCode`ClaudeBuildRuntimeAdapter not found → Phase 12 SKIP", Orange]]
];

(* ════════════════════════════════════════════════════════
   12b. Phase 13: $UseClaudeRuntime flag テスト
   ════════════════════════════════════════════════════════ *)

iPrintSection["Phase 13: $UseClaudeRuntime flag"];

If[Length[Names["ClaudeCode`$UseClaudeRuntime"]] > 0,

(* テスト: $UseClaudeRuntime のデフォルト値 *)
iAssert["P13 $UseClaudeRuntime is True (ClaudeRuntime loaded)",
  TrueQ[ClaudeCode`$UseClaudeRuntime]];

(* テスト: iClaudeEvalViaRuntimeBridge の存在確認 *)
iAssert["P13 iClaudeEvalViaRuntimeBridge defined",
  Length[DownValues[ClaudeCode`Private`iClaudeEvalViaRuntimeBridge]] > 0];

(* テスト: runtime bridge が mock provider で動作する *)
Module[{mockProv, mockAdapter, runtimeId, jobId, st, tr,
        maxWait = 10, waited = 0},
  mockProv = ClaudeTestKit`CreateMockProvider[{
    "The answer is 42."}];
  mockAdapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> mockProv, "MaxContinuations" -> 0];
  
  runtimeId = ClaudeRuntime`CreateClaudeRuntime[mockAdapter, "Profile" -> "Eval"];
  iAssert["P13 bridge: runtime created", StringQ[runtimeId]];
  
  jobId = ClaudeRuntime`ClaudeRunTurn[runtimeId, "What is 6*7?",
    "Notebook" -> $Failed];
  
  While[waited < maxWait,
    st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
    If[MemberQ[{"Done", "Failed"}, st["Status"]], Break[]];
    Pause[0.1]; waited += 0.1];
  
  st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
  tr = ClaudeRuntime`ClaudeTurnTrace[runtimeId];
  
  iAssertEqual["P13 bridge: text-only Done", st["Status"], "Done"];
  iAssert["P13 bridge: TextOnly in trace",
    AnyTrue[tr, Lookup[#, "Type", ""] === "TextOnlyResponse" &]];
];

(* テスト: runtime bridge - 式提案 → 実行 → 完了 *)
Module[{mockProv, mockAdapter, runtimeId, jobId, st, tr,
        maxWait = 10, waited = 0},
  mockProv = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\nToString[1 + 1]\n```"}];
  mockAdapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> mockProv,
    "ExecutionResults" -> {"2"},
    "MaxContinuations" -> 0];
  
  runtimeId = ClaudeRuntime`CreateClaudeRuntime[mockAdapter, "Profile" -> "Eval"];
  jobId = ClaudeRuntime`ClaudeRunTurn[runtimeId, "Compute 1+1",
    "Notebook" -> $Failed];
  
  While[waited < maxWait,
    st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
    If[MemberQ[{"Done", "Failed"}, st["Status"]], Break[]];
    Pause[0.1]; waited += 0.1];
  
  st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
  tr = ClaudeRuntime`ClaudeTurnTrace[runtimeId];
  
  iAssertEqual["P13 bridge exec: Done", st["Status"], "Done"];
  iAssert["P13 bridge exec: ResultRedacted",
    AnyTrue[tr, Lookup[#, "Type", ""] === "ResultRedacted" &]];
];

(* テスト: ParseProposal パターン緩和 *)
iPrintSection["Phase 13: ParseProposal pattern relaxation"];

Module[{mockProv, mockAdapter, runtimeId, st, tr,
        maxWait = 10, waited = 0},
  mockProv = ClaudeTestKit`CreateMockProvider[{
    "Here is the code:\n```Mathematica\nToString[42]\n```\nDone."}];
  mockAdapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> mockProv,
    "ExecutionResults" -> {"42"},
    "MaxContinuations" -> 0];
  
  runtimeId = ClaudeRuntime`CreateClaudeRuntime[mockAdapter, "Profile" -> "Eval"];
  ClaudeRuntime`ClaudeRunTurn[runtimeId, "test", "Notebook" -> $Failed];
  While[waited < maxWait,
    st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
    If[MemberQ[{"Done", "Failed"}, st["Status"]], Break[]];
    Pause[0.1]; waited += 0.1];
  st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
  iAssertEqual["P13 parse Capital-M: completes", st["Status"], "Done"];
];

(* テスト: ContinueEval bridge 存在確認 *)
iAssert["P13 iContinueEvalViaRuntimeBridge defined",
  Length[DownValues[ClaudeCode`Private`iContinueEvalViaRuntimeBridge]] > 0];

(* テスト: $iSessionRuntimeIds 初期化 *)
iAssert["P13 $iSessionRuntimeIds is Association",
  AssociationQ[ClaudeCode`Private`$iSessionRuntimeIds]];

, (* else: claudecode.wl 未ロード *)
  Print[Style["  claudecode.wl 未ロード → Phase 13 SKIP", Orange]]
];

(* ════════════════════════════════════════════════════════
   14. Phase 14: Iterative Agent Loop テスト
   ════════════════════════════════════════════════════════ *)

Print[Style["\n── Phase 14: Iterative Agent Loop ──", Bold]];

(* 14.1: ConversationState Messages 蓄積テスト *)
Module[{provider, adapter, rid, st},
  provider = ClaudeTestKit`CreateMockProvider[{
    "Turn 1 result:\n```mathematica\nPrint[\"hello\"]\n```",
    "The task is complete. No more actions needed."
  }];
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> provider,
    "AllowedHeads" -> {"Print", "ToString"},
    "MaxContinuations" -> 1];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter];
  ClaudeRuntime`ClaudeRunTurn[rid, "test iterative"];
  Pause[0.5];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  iTest["Phase14: ConversationState has Messages",
    KeyExistsQ[st["ConversationState"], "Messages"]];
  iTest["Phase14: Messages is a List",
    ListQ[st["ConversationState"]["Messages"]]];
  iTest["Phase14: At least 1 turn recorded",
    Length[st["ConversationState"]["Messages"]] >= 1];
  iTest["Phase14: OriginalTask preserved",
    KeyExistsQ[st["ConversationState"], "OriginalTask"]];
];

(* 14.2: Multi-turn continuation with result feedback *)
Module[{provider, adapter, rid, st, msgs},
  provider = ClaudeTestKit`CreateMockProvider[{
    "Reading cells:\n```mathematica\nNBCellRead[nb, 1]\n```",
    "Got result. Now:\n```mathematica\nPrint[\"done\"]\n```",
    "All done, no more actions."
  }];
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> provider,
    "AllowedHeads" -> {"NBCellRead", "Print", "ToString"},
    "MaxContinuations" -> 2];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter];
  ClaudeRunTurn[rid, "multi-turn test"];
  Pause[1.5];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  msgs = Lookup[st["ConversationState"], "Messages", {}];
  iTest["Phase14: Multi-turn: >= 2 messages recorded",
    Length[msgs] >= 2];
  iTest["Phase14: Multi-turn: first turn has ProposedCode",
    StringQ[Lookup[First[msgs, <||>], "ProposedCode", None]]];
];

(* 14.3: ContinuationInput is structured *)
Module[{provider, adapter, rid, st, contInput},
  provider = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\nPrint[42]\n```",
    "done."
  }];
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> provider,
    "AllowedHeads" -> {"Print"},
    "MaxContinuations" -> 1];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter];
  ClaudeRunTurn[rid, "structured continuation"];
  Pause[0.5];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  (* After execution, ContinuationInput should be structured if continuing *)
  iTest["Phase14: Final status is Done or has structured state",
    MemberQ[{"Done", "Failed"}, st["Status"]]];
];

(* ════════════════════════════════════════════════════════
   15. Phase 14: Label Algebra テスト
   ════════════════════════════════════════════════════════ *)

Print[Style["\n── Phase 14: Label Algebra ──", Bold]];

(* 15.1: NBLabelQ *)
iTest["LabelAlgebra: NBLabelQ[Bottom] = True",
  NBAccess`NBLabelQ[NBAccess`NBLabelBottom[]]];
iTest["LabelAlgebra: NBLabelQ[Top] = True",
  NBAccess`NBLabelQ[NBAccess`NBLabelTop[]]];
iTest["LabelAlgebra: NBLabelQ[\"invalid\"] = False",
  !NBAccess`NBLabelQ["invalid"]];

(* 15.2: NBLabelLEQ *)
iTest["LabelAlgebra: Bottom LEQ Top",
  NBAccess`NBLabelLEQ[NBAccess`NBLabelBottom[], NBAccess`NBLabelTop[]]];
iTest["LabelAlgebra: Bottom LEQ Bottom",
  NBAccess`NBLabelLEQ[NBAccess`NBLabelBottom[], NBAccess`NBLabelBottom[]]];

(* 15.3: NBLabelJoin *)
Module[{l1, l2, joined},
  l1 = <|"ReaderPolicies" -> <|"alice" -> {"bob", "carol"}|>,
    "Categories" -> {"Grades"}|>;
  l2 = <|"ReaderPolicies" -> <|"alice" -> {"bob", "dave"}|>,
    "Categories" -> {"MethodIP"}|>;
  joined = NBAccess`NBLabelJoin[l1, l2];
  iTest["LabelAlgebra: Join intersection of readers",
    Lookup[joined["ReaderPolicies"], "alice", {}] === {"bob"}];
  iTest["LabelAlgebra: Join union of categories",
    Sort[joined["Categories"]] === {"Grades", "MethodIP"}];
];

(* 15.4: Principal / ActsFor *)
NBAccess`NBRegisterPrincipal["userA", "Type" -> "User"];
NBAccess`NBRegisterPrincipal["roleAdmin", "Type" -> "Role"];
NBAccess`NBGrantActsFor["userA", "roleAdmin"];
iTest["LabelAlgebra: ActsFor self",
  NBAccess`NBActsForQ["userA", "userA"]];
iTest["LabelAlgebra: ActsFor delegated",
  NBAccess`NBActsForQ["userA", "roleAdmin"]];
iTest["LabelAlgebra: ActsFor not reverse",
  !NBAccess`NBActsForQ["roleAdmin", "userA"]];

(* 15.5: NBCanFlowToQ *)
Module[{public, restricted},
  public = NBAccess`NBLabelBottom[];
  restricted = <|"ReaderPolicies" -> <|"alice" -> {"bob"}|>,
    "Categories" -> {}|>;
  iTest["LabelAlgebra: Public can flow to restricted",
    NBAccess`NBCanFlowToQ[public, restricted]];
];

(* ════════════════════════════════════════════════════════
   16. Phase 14: NBInferExprRequirements テスト
   ════════════════════════════════════════════════════════ *)

Print[Style["\n── Phase 14: NBInferExprRequirements ──", Bold]];

Module[{req},
  req = NBAccess`NBInferExprRequirements[
    HoldComplete[NBAccess`NBCellRead[nb, 3]],
    <|"AccessLevel" -> 0.5|>];
  iTest["InferExpr: returns Association",
    AssociationQ[req]];
  iTest["InferExpr: has ReadHeads",
    KeyExistsQ[req, "ReadHeads"]];
  iTest["InferExpr: HasSideEffects = False for read",
    !TrueQ[req["HasSideEffects"]]];
];

Module[{req},
  req = NBAccess`NBInferExprRequirements[
    HoldComplete[NBAccess`NBCellWriteCode[nb, 3, "x"]],
    <|"AccessLevel" -> 0.5|>];
  iTest["InferExpr: HasSideEffects = True for write",
    TrueQ[req["HasSideEffects"]]];
];

(* ════════════════════════════════════════════════════════
   17. Phase 14: NBReleaseResult / NBMakeRetryPacket テスト
   ════════════════════════════════════════════════════════ *)

Print[Style["\n── Phase 14: NBReleaseResult / NBMakeRetryPacket ──", Bold]];

Module[{result, released},
  result = <|"Success" -> True, "RawResult" -> "test output", "Error" -> None|>;
  released = NBAccess`NBReleaseResult[result,
    <|"AccessLevel" -> 0.3|>, "Sink" -> "CloudLLM"];
  iTest["ReleaseResult: low risk releases to cloud",
    TrueQ[released["Released"]]];
];

Module[{result, released},
  result = <|"Success" -> True, "RawResult" -> "secret data", "Error" -> None|>;
  released = NBAccess`NBReleaseResult[result,
    <|"AccessLevel" -> 0.9|>, "Sink" -> "CloudLLM"];
  iTest["ReleaseResult: high risk blocked from cloud",
    !TrueQ[released["Released"]]];
];

Module[{packet},
  packet = NBAccess`NBMakeRetryPacket[
    <|"ReasonClass" -> "ForbiddenHead",
      "VisibleExplanation" -> "DeleteFile is forbidden, secret=mykey123",
      "Decision" -> "Deny"|>,
    <|"AccessLevel" -> 0.5, "Secrets" -> {"mykey123"}|>];
  iTest["RetryPacket: secrets redacted",
    !StringContainsQ[packet["VisibleExplanation"], "mykey123"]];
  iTest["RetryPacket: has ReasonClass",
    packet["ReasonClass"] === "ForbiddenHead"];
];

(* ════════════════════════════════════════════════════════
   18. Phase 15: NBAuthorize / PolicyGate / ScoreGate / EnvironmentGate
   ════════════════════════════════════════════════════════ *)

Print[Style["\n── Phase 15: NBAuthorize 分離テスト ──", Bold]];

(* ── PolicyGate テスト ── *)
Module[{obj, req, result},
  (* ラベルなし → Pass *)
  obj = <|"PolicyLabel" -> NBAccess`NBLabelBottom[],
          "ContainerLabel" -> NBAccess`NBLabelBottom[]|>;
  req = <|"SinkLabel" -> NBAccess`NBLabelBottom[]|>;
  result = NBAccess`NBPolicyGate[obj, req];
  iTest["PolicyGate: bottom→bottom = Pass",
    result["Decision"] === "Pass"];
];

Module[{obj, req, result},
  (* restricted label → bottom sink = Deny (flow violation) *)
  obj = <|"PolicyLabel" ->
    <|"ReaderPolicies" -> <|"Alice" -> {"Bob"}|>, "Categories" -> {}|>,
    "ContainerLabel" -> NBAccess`NBLabelBottom[]|>;
  req = <|"SinkLabel" ->
    <|"ReaderPolicies" -> <|"Alice" -> {"Charlie"}|>, "Categories" -> {}|>|>;
  result = NBAccess`NBPolicyGate[obj, req];
  iTest["PolicyGate: incompatible readers = Deny",
    result["Decision"] === "Deny"];
  iTest["PolicyGate: reason = PolicyFlowViolation",
    result["Reason"] === "PolicyFlowViolation"];
];

Module[{obj, req, result},
  (* ラベルなし（未設定） → Pass（後方互換） *)
  obj = <||>;
  req = <||>;
  result = NBAccess`NBPolicyGate[obj, req];
  iTest["PolicyGate: no labels configured = Pass",
    result["Decision"] === "Pass"];
];

Module[{obj, req, result},
  (* declassify 可能なケース *)
  NBAccess`NBRegisterPrincipal["Admin2"];
  NBAccess`NBRegisterPrincipal["Alice2"];
  NBAccess`NBGrantActsFor["Admin2", "Alice2"];
  obj = <|"PolicyLabel" ->
    <|"ReaderPolicies" -> <|"Alice2" -> {"Bob2"}|>, "Categories" -> {}|>,
    "ContainerLabel" -> NBAccess`NBLabelBottom[]|>;
  req = <|"SinkLabel" ->
    <|"ReaderPolicies" -> <|"Alice2" -> {"Charlie2"}|>, "Categories" -> {}|>,
    "Principal" -> "Admin2"|>;
  result = NBAccess`NBPolicyGate[obj, req];
  iTest["PolicyGate: Admin acts-for Alice = RequireApproval (declassify)",
    result["Decision"] === "RequireApproval"];
];

(* ── ScoreGate テスト ── *)
Module[{obj, req, result},
  obj = <|"AccessLevel" -> 0.3|>;
  req = <|"Sink" -> "CloudLLM"|>;
  result = NBAccess`NBScoreGate[obj, req];
  iTest["ScoreGate: low score + CloudLLM = Pass",
    result["Decision"] === "Pass"];
];

Module[{obj, req, result},
  obj = <|"AccessLevel" -> 0.7|>;
  req = <|"Sink" -> "CloudLLM"|>;
  result = NBAccess`NBScoreGate[obj, req];
  iTest["ScoreGate: high score + CloudLLM = Screen",
    result["Decision"] === "Screen"];
];

Module[{obj, req, result},
  obj = <|"AccessLevel" -> 0.9|>;
  req = <|"Sink" -> "PrivateLLM"|>;
  result = NBAccess`NBScoreGate[obj, req];
  iTest["ScoreGate: very high score + PrivateLLM = Screen",
    result["Decision"] === "Screen"];
];

(* ── EnvironmentGate テスト ── *)
Module[{obj, req, result},
  obj = <||>;
  req = <|"Environment" -> "Notebook", "Sink" -> "CloudLLM"|>;
  result = NBAccess`NBEnvironmentGate[obj, req];
  iTest["EnvironmentGate: default = Pass",
    result["Decision"] === "Pass"];
];

Module[{obj, req, result},
  obj = <|"AllowedSinks" -> {"LocalOnly"}|>;
  req = <|"Sink" -> "CloudLLM"|>;
  result = NBAccess`NBEnvironmentGate[obj, req];
  iTest["EnvironmentGate: CloudLLM not in AllowedSinks = Deny",
    result["Decision"] === "Deny"];
];

(* ── NBAuthorize 統合テスト ── *)
Module[{obj, req, result},
  obj = <|"PolicyLabel" -> NBAccess`NBLabelBottom[],
          "AccessLevel" -> 0.3|>;
  req = <|"SinkLabel" -> NBAccess`NBLabelBottom[],
          "Sink" -> "CloudLLM"|>;
  result = NBAccess`NBAuthorize[obj, req];
  iTest["NBAuthorize: all pass = Permit",
    result["Decision"] === "Permit"];
  iTest["NBAuthorize: has GateResults",
    AssociationQ[result["GateResults"]]];
  iTest["NBAuthorize: GateResults has 3 gates",
    Length[result["GateResults"]] === 3];
];

Module[{obj, req, result},
  (* Score gate screens but policy passes → Screen *)
  obj = <|"PolicyLabel" -> NBAccess`NBLabelBottom[],
          "AccessLevel" -> 0.7|>;
  req = <|"SinkLabel" -> NBAccess`NBLabelBottom[],
          "Sink" -> "CloudLLM"|>;
  result = NBAccess`NBAuthorize[obj, req];
  iTest["NBAuthorize: score Screen + policy Pass = Screen",
    result["Decision"] === "Screen"];
];

Module[{obj, req, result},
  (* Policy Deny overrides score Pass *)
  obj = <|"PolicyLabel" ->
    <|"ReaderPolicies" -> <|"*" -> {}|>, "Categories" -> {"TopSecret"}|>,
    "AccessLevel" -> 0.1|>;
  req = <|"SinkLabel" -> NBAccess`NBLabelBottom[],
          "Sink" -> "CloudLLM"|>;
  result = NBAccess`NBAuthorize[obj, req];
  iTest["NBAuthorize: policy Deny overrides low score",
    result["Decision"] === "Deny"];
];

(* ════════════════════════════════════════════════════════
   19. Phase 15: label-aware validation テスト
   ════════════════════════════════════════════════════════ *)

Print[Style["\n── Phase 15: label-aware validation テスト ──", Bold]];

Module[{result},
  (* label なし accessSpec → 従来通り Permit *)
  result = NBAccess`NBValidateHeldExpr[
    HoldComplete[Print["hello"]],
    <|"AccessLevel" -> 0.5|>];
  iTest["LabelValidation: no label = Permit (backward compat)",
    result["Decision"] === "Permit"];
];

Module[{result},
  (* PolicyLabel + SinkLabel 設定、flow OK *)
  result = NBAccess`NBValidateHeldExpr[
    HoldComplete[Print["hello"]],
    <|"AccessLevel" -> 0.3,
      "PolicyLabel" -> NBAccess`NBLabelBottom[],
      "SinkLabel" -> NBAccess`NBLabelBottom[],
      "Sink" -> "CloudLLM"|>];
  iTest["LabelValidation: bottom→bottom with label = Permit",
    result["Decision"] === "Permit"];
];

Module[{result},
  (* PolicyLabel が top、sink が bottom → flow violation → Deny *)
  result = NBAccess`NBValidateHeldExpr[
    HoldComplete[Print["hello"]],
    <|"AccessLevel" -> 0.1,
      "PolicyLabel" -> NBAccess`NBLabelTop[],
      "SinkLabel" -> NBAccess`NBLabelBottom[],
      "Sink" -> "CloudLLM"|>];
  iTest["LabelValidation: top→bottom = Deny (PolicyFlowViolation)",
    result["Decision"] === "Deny"];
  iTest["LabelValidation: reason = PolicyFlowViolation",
    result["ReasonClass"] === "PolicyFlowViolation"];
];

Module[{result},
  (* 同じ score でも label が違えば deny — authorization contract test *)
  result = NBAccess`NBValidateHeldExpr[
    HoldComplete[ToString[42]],
    <|"AccessLevel" -> 0.1,
      "PolicyLabel" ->
        <|"ReaderPolicies" -> <|"Owner" -> {"Alice"}|>, "Categories" -> {}|>,
      "SinkLabel" ->
        <|"ReaderPolicies" -> <|"Owner" -> {"Bob"}|>, "Categories" -> {}|>,
      "Sink" -> "CloudLLM"|>];
  iTest["AuthContract: same score, different label = Deny",
    result["Decision"] === "Deny"];
];

Module[{result},
  (* LabelCheck -> False で明示的にスキップ *)
  result = NBAccess`NBValidateHeldExpr[
    HoldComplete[Print["hello"]],
    <|"AccessLevel" -> 0.1,
      "PolicyLabel" -> NBAccess`NBLabelTop[],
      "SinkLabel" -> NBAccess`NBLabelBottom[]|>,
    "LabelCheck" -> False];
  iTest["LabelValidation: LabelCheck->False skips label check",
    result["Decision"] === "Permit"];
];

(* ════════════════════════════════════════════════════════
   20. Phase 15: ShouldContinue [DONE] マーカーテスト
   ════════════════════════════════════════════════════════ *)

Print[Style["\n── Phase 15: ShouldContinue [DONE] マーカーテスト ──", Bold]];

Module[{provider, adapter, runtimeId, st},
  (* LLM が [DONE] マーカー付きテキスト応答を返す → TextOnly → 即 Done *)
  provider = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\nPrint[\"step1\"]\n```\nFirst step done.",
    "Task is complete. [DONE]"
  }];
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> provider,
    "AllowedHeads" -> {"Print", "ToString"},
    "MaxContinuations" -> 5];
  runtimeId = ClaudeRuntime`CreateClaudeRuntime[adapter];
  ClaudeRuntime`ClaudeRunTurn[runtimeId, "test done marker"];
  st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
  iTest["[DONE] marker: TextOnly = immediate Done",
    st["Status"] === "Done"];
  iTest["[DONE] marker: TurnCount = 2",
    st["TurnCount"] === 2];
];

(* ════════════════════════════════════════════════════════
   21. Phase 15: TotalCellCount テスト
   ════════════════════════════════════════════════════════ *)

Print[Style["\n── Phase 15: TotalCellCount テスト ──", Bold]];

Module[{packet},
  (* nb=$Failed → TotalCellCount = 0 *)
  packet = NBAccess`NBMakeContextPacket[$Failed,
    <|"AccessLevel" -> 0.5|>];
  iTest["TotalCellCount: invalid notebook = 0",
    Lookup[packet, "TotalCellCount", -1] === 0];
];

Module[{packet},
  (* nb=None → TotalCellCount = 0 *)
  packet = NBAccess`NBMakeContextPacket[None,
    <|"AccessLevel" -> 0.5|>];
  iTest["TotalCellCount: None notebook = 0",
    Lookup[packet, "TotalCellCount", -1] === 0];
];

(* ════════════════════════════════════════════════════════
   22. Phase 15: Messages に TextResponse 蓄積テスト
   ════════════════════════════════════════════════════════ *)

Print[Style["\n── Phase 15: Messages TextResponse 蓄積テスト ──", Bold]];

Module[{provider, adapter, runtimeId, st, msgs},
  provider = ClaudeTestKit`CreateMockProvider[{
    "Let me check.\n```mathematica\nPrint[\"hello\"]\n```",
    "All done."
  }];
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> provider,
    "AllowedHeads" -> {"Print"},
    "MaxContinuations" -> 2];
  runtimeId = ClaudeRuntime`CreateClaudeRuntime[adapter];
  ClaudeRuntime`ClaudeRunTurn[runtimeId, "test text response"];
  st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
  msgs = Lookup[st["ConversationState"], "Messages", {}];
  iTest["TextResponse: Messages have TextResponse field",
    Length[msgs] > 0 && KeyExistsQ[First[msgs], "TextResponse"]];
  iTest["TextResponse: first turn has non-empty TextResponse",
    StringQ[msgs[[1]]["TextResponse"]] &&
    StringLength[msgs[[1]]["TextResponse"]] > 0];
];

(* ════════════════════════════════════════════════════════
   23. Phase 16: ContinueEval continuation テスト
   ════════════════════════════════════════════════════════ *)

Print[Style["\n── Phase 16: ContinueEval continuation テスト ──", Bold]];

(* 3 ターンの反復ループ: コード → コード → テキスト完了 *)
Module[{provider, adapter, runtimeId, st, msgs, turnCount},
  provider = ClaudeTestKit`CreateMockProvider[{
    "Step 1: read cells\n```mathematica\nPrint[\"reading\"]\n```",
    "Step 2: process\n```mathematica\nPrint[\"processing\"]\n```",
    "All done, summary here. [DONE]"
  }];
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> provider,
    "AllowedHeads" -> {"Print", "ToString"},
    "MaxContinuations" -> 5];
  runtimeId = ClaudeRuntime`CreateClaudeRuntime[adapter];
  ClaudeRuntime`ClaudeRunTurn[runtimeId, "multi-step task"];
  st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
  
  iTest["Continuation: 3-turn loop completes as Done",
    st["Status"] === "Done"];
  iTest["Continuation: TurnCount = 3",
    st["TurnCount"] === 3];
  
  msgs = Lookup[st["ConversationState"], "Messages", {}];
  iTest["Continuation: Messages has 3 entries",
    Length[msgs] === 3];
  iTest["Continuation: first turn has ProposedCode",
    StringQ[msgs[[1]]["ProposedCode"]]];
  iTest["Continuation: last turn is TextOnly (no code)",
    msgs[[3]]["ExecutionResult"] === None];
];

(* ContinuationInput の構造化確認 *)
Module[{provider, adapter, runtimeId, st, msgs},
  provider = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\nPrint[\"step1\"]\n```",
    "```mathematica\nPrint[\"step2\"]\n```",
    "Done. [DONE]"
  }];
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> provider,
    "AllowedHeads" -> {"Print"},
    "MaxContinuations" -> 5];
  runtimeId = ClaudeRuntime`CreateClaudeRuntime[adapter];
  ClaudeRuntime`ClaudeRunTurn[runtimeId, "original task"];
  st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
  
  iTest["ContinuationInput: OriginalTask preserved across turns",
    Lookup[st["ConversationState"], "OriginalTask", ""] === "original task"];
];

(* ════════════════════════════════════════════════════════
   24. Phase 16: NeedsApproval フローテスト
   ════════════════════════════════════════════════════════ *)

Print[Style["\n── Phase 16: NeedsApproval フローテスト ──", Bold]];

(* NeedsApproval → Approve → 実行継続 *)
Module[{provider, adapter, runtimeId, st, approveResult},
  provider = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\nNBCellWriteCode[nb, 1, \"new code\"]\n```",
    "Write complete. [DONE]"
  }];
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> provider,
    "AllowedHeads" -> {"Print", "ToString"},
    "ApprovalHeads" -> {"NBCellWriteCode"},
    "MaxContinuations" -> 3];
  runtimeId = ClaudeRuntime`CreateClaudeRuntime[adapter];
  ClaudeRuntime`ClaudeRunTurn[runtimeId, "write to cell"];
  st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
  
  iTest["NeedsApproval: status = AwaitingApproval",
    st["Status"] === "AwaitingApproval"];
  iTest["NeedsApproval: PendingApproval has Proposal",
    AssociationQ[st["PendingApproval"]] &&
    KeyExistsQ[st["PendingApproval"], "Proposal"]];
  
  (* 承認 *)
  approveResult = ClaudeRuntime`ClaudeApproveProposal[runtimeId];
  st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
  
  iTest["NeedsApproval: after approve, status = Done",
    st["Status"] === "Done"];
  iTest["NeedsApproval: PendingApproval cleared after approve",
    st["PendingApproval"] === None];
];

(* NeedsApproval → Deny → Failed *)
Module[{provider, adapter, runtimeId, st, denyResult},
  provider = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\nNBCellWriteCode[nb, 1, \"danger\"]\n```"
  }];
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> provider,
    "AllowedHeads" -> {"Print"},
    "ApprovalHeads" -> {"NBCellWriteCode"},
    "MaxContinuations" -> 0];
  runtimeId = ClaudeRuntime`CreateClaudeRuntime[adapter];
  ClaudeRuntime`ClaudeRunTurn[runtimeId, "risky write"];
  st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
  
  iTest["DenyProposal: status = AwaitingApproval before deny",
    st["Status"] === "AwaitingApproval"];
  
  denyResult = ClaudeRuntime`ClaudeDenyProposal[runtimeId];
  st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
  
  iTest["DenyProposal: status = Failed after deny",
    st["Status"] === "Failed"];
  iTest["DenyProposal: LastFailure has UserDenied",
    AssociationQ[st["LastFailure"]] &&
    st["LastFailure"]["ReasonClass"] === "UserDenied"];
];

(* ════════════════════════════════════════════════════════
   25. Phase 16: Set/SetDelayed 文脈チェックテスト
   ════════════════════════════════════════════════════════ *)

Print[Style["\n── Phase 16: Set/SetDelayed 文脈チェックテスト ──", Bold]];

(* Module 内の Set は Permit *)
Module[{result},
  result = NBAccess`NBValidateHeldExpr[
    HoldComplete[Module[{x = 0}, x = x + 1; x]],
    <|"AccessLevel" -> 0.5|>];
  iTest["Set context: Module-local Set = Permit",
    result["Decision"] === "Permit"];
];

(* With 内の Set は Permit *)
Module[{result},
  result = NBAccess`NBValidateHeldExpr[
    HoldComplete[With[{n = 10}, Module[{acc = 0}, Do[acc = acc + i, {i, n}]; acc]]],
    <|"AccessLevel" -> 0.5|>];
  iTest["Set context: With+Module nested Set = Permit",
    result["Decision"] === "Permit"];
];

(* Block 内の Set は Permit *)
Module[{result},
  result = NBAccess`NBValidateHeldExpr[
    HoldComplete[Block[{x}, x = 42; x]],
    <|"AccessLevel" -> 0.5|>];
  iTest["Set context: Block-local Set = Permit",
    result["Decision"] === "Permit"];
];

(* Function body 内の Set は Permit *)
Module[{result},
  result = NBAccess`NBValidateHeldExpr[
    HoldComplete[Function[{x}, Module[{y = x}, y = y + 1; y]]],
    <|"AccessLevel" -> 0.5|>];
  iTest["Set context: Function+Module Set = Permit",
    result["Decision"] === "Permit"];
];

(* グローバルスコープの Set は NeedsApproval *)
Module[{result},
  result = NBAccess`NBValidateHeldExpr[
    HoldComplete[x = 42],
    <|"AccessLevel" -> 0.5|>];
  iTest["Set context: global Set = NeedsApproval",
    result["Decision"] === "NeedsApproval"];
];

(* グローバルスコープの SetDelayed は NeedsApproval *)
Module[{result},
  result = NBAccess`NBValidateHeldExpr[
    HoldComplete[f[x_] := x^2],
    <|"AccessLevel" -> 0.5|>];
  iTest["Set context: global SetDelayed = NeedsApproval",
    result["Decision"] === "NeedsApproval"];
];

(* CompoundExpression でグローバル Set を含む場合 *)
Module[{result},
  result = NBAccess`NBValidateHeldExpr[
    HoldComplete[CompoundExpression[y = 10, Print[y]]],
    <|"AccessLevel" -> 0.5|>];
  iTest["Set context: global Set in CompoundExpression = NeedsApproval",
    result["Decision"] === "NeedsApproval"];
];

(* Set なし (純粋な読み取り式) は従来通り Permit *)
Module[{result},
  result = NBAccess`NBValidateHeldExpr[
    HoldComplete[Print[1 + 1]],
    <|"AccessLevel" -> 0.5|>];
  iTest["Set context: no Set at all = Permit",
    result["Decision"] === "Permit"];
];

(* ════════════════════════════════════════════════════════
   26. Phase 16: カテゴリ構造テスト
   ════════════════════════════════════════════════════════ *)

Print[Style["\n── Phase 16: カテゴリ構造テスト ──", Bold]];

If[Length[Names["NBAccess`$NBAllowedHeadsByCategory"]] > 0,
(* NBAccess がロード済みの場合のみ実行 *)

(* $NBAllowedHeadsByCategory が存在すること *)
iTest["Category: $NBAllowedHeadsByCategory is Association",
  AssociationQ[NBAccess`$NBAllowedHeadsByCategory]];

(* 全カテゴリが非空であること *)
iTest["Category: all categories non-empty",
  AllTrue[Values[NBAccess`$NBAllowedHeadsByCategory],
    ListQ[#] && Length[#] > 0 &]];

(* $NBAllowedHeads が $NBAllowedHeadsByCategory から導出されること *)
Module[{flatHeads},
  NBAccess`Private`iRecomputeAllowedHeads[];
  flatHeads = Flatten[Values[NBAccess`$NBAllowedHeadsByCategory]];
  iTest["Category: $NBAllowedHeads = Flatten[Values[ByCategory]]",
    Sort[NBAccess`$NBAllowedHeads] === Sort[flatHeads]];
];

(* NBDisableCategory でカテゴリを無効化 *)
Module[{before, after},
  before = Length[NBAccess`$NBAllowedHeads];
  NBAccess`NBDisableCategory["Formatting"];
  NBAccess`Private`iRecomputeAllowedHeads[];
  after = Length[NBAccess`$NBAllowedHeads];
  iTest["Category: disabling Formatting reduces head count",
    after < before];
  (* 復元 *)
  NBAccess`NBEnableCategory["Formatting"];
  NBAccess`Private`iRecomputeAllowedHeads[];
];

(* Formatting 無効化時に Style が unknown head になること *)
Module[{result},
  NBAccess`NBDisableCategory["Formatting"];
  NBAccess`Private`iRecomputeAllowedHeads[];
  result = NBAccess`NBValidateHeldExpr[
    HoldComplete[Style["hello", Bold]],
    <|"AccessLevel" -> 0.5|>];
  iTest["Category: disabled Formatting → Style = RepairNeeded",
    result["Decision"] === "RepairNeeded"];
  (* 復元 *)
  NBAccess`NBEnableCategory["Formatting"];
  NBAccess`Private`iRecomputeAllowedHeads[];
];

(* 復元後は Style が Permit に戻ること *)
Module[{result},
  result = NBAccess`NBValidateHeldExpr[
    HoldComplete[Style["hello", Bold]],
    <|"AccessLevel" -> 0.5|>];
  iTest["Category: re-enabled Formatting → Style = Permit",
    result["Decision"] === "Permit"];
];

, (* Else: NBAccess 未ロード *)
Print[Style["  NBAccess 未ロード → Category テスト SKIP", Orange]]
]; (* End If NBAccess loaded *)

(* ════════════════════════════════════════════════════════
   27. Phase 16: ConversationState 圧縮テスト
   ════════════════════════════════════════════════════════ *)

Print[Style["\n── Phase 16: ConversationState 圧縮テスト ──", Bold]];

(* iCompactConversationHistory: 上限以下なら変更なし *)
Module[{msgs, result},
  msgs = Table[<|"Turn" -> i, "ProposedCode" -> "code" <> ToString[i],
    "ExecutionResult" -> <|"Summary" -> "res" <> ToString[i]|>,
    "Timestamp" -> i|>, {i, 5}];
  result = ClaudeRuntime`Private`iCompactConversationHistory[msgs, 3, 20];
  iTest["Compact: under limit → no change",
    Length[result] === 5 && !AnyTrue[result, TrueQ[Lookup[#, "Compacted", False]] &]];
];

(* iCompactConversationHistory: 上限超過で古いターンが圧縮される *)
Module[{msgs, result, compactedCount},
  msgs = Table[<|"Turn" -> i, "ProposedCode" -> "code" <> ToString[i],
    "ExecutionResult" -> <|"Summary" -> "res" <> ToString[i]|>,
    "TextResponse" -> "text" <> ToString[i],
    "Timestamp" -> i|>, {i, 25}];
  result = ClaudeRuntime`Private`iCompactConversationHistory[msgs, 5, 20];
  compactedCount = Count[result, _?(TrueQ[Lookup[#, "Compacted", False]] &)];
  iTest["Compact: over limit → compacted entries exist",
    compactedCount > 0];
  iTest["Compact: total length <= maxTotal",
    Length[result] <= 20];
  iTest["Compact: last 5 are not compacted",
    !AnyTrue[result[[-5 ;; ]], TrueQ[Lookup[#, "Compacted", False]] &]];
];

(* iMakeTurnSummary: コードと結果の要約生成 *)
Module[{msg, summary},
  msg = <|"Turn" -> 1,
    "ProposedCode" -> "NBCellRead[nb, 3]",
    "ExecutionResult" -> <|"Summary" -> "Cell 3 content: hello"|>,
    "TextResponse" -> "Let me read cell 3."|>;
  summary = ClaudeRuntime`Private`iMakeTurnSummary[msg];
  iTest["TurnSummary: contains code snippet",
    StringContainsQ[summary, "NBCellRead"]];
  iTest["TurnSummary: contains result snippet",
    StringContainsQ[summary, "Cell 3"]];
];

(* 圧縮済みメッセージは再圧縮されない *)
Module[{msgs, result},
  msgs = {
    <|"Turn" -> 1, "Summary" -> "old compacted", "Compacted" -> True, "Timestamp" -> 1|>,
    <|"Turn" -> 2, "ProposedCode" -> "Print[1]",
      "ExecutionResult" -> <|"Summary" -> "Null"|>, "Timestamp" -> 2|>,
    <|"Turn" -> 3, "ProposedCode" -> "Print[2]",
      "ExecutionResult" -> <|"Summary" -> "Null"|>, "Timestamp" -> 3|>
  };
  result = ClaudeRuntime`Private`iCompactConversationHistory[msgs, 2, 3];
  iTest["Compact: already-compacted msg preserved",
    TrueQ[result[[1]]["Compacted"]] &&
    result[[1]]["Summary"] === "old compacted"];
];

(* 実行時統合テスト: 多ターン runtime で圧縮が発動 *)
Module[{provider, adapter, runtimeId, st, msgs, responses},
  (* $MaxConversationMessages を小さく設定してテスト *)
  Block[{ClaudeRuntime`Private`$MaxConversationMessages = 5,
         ClaudeRuntime`Private`$MaxDetailedMessages = 2},
    responses = Table[
      "```mathematica\nPrint[\"turn" <> ToString[i] <> "\"]\n```",
      {i, 7}];
    AppendTo[responses, "All done. [DONE]"];
    provider = ClaudeTestKit`CreateMockProvider[responses];
    adapter = ClaudeTestKit`CreateMockAdapter[
      "Provider" -> provider,
      "AllowedHeads" -> {"Print"},
      "MaxContinuations" -> 10];
    runtimeId = ClaudeRuntime`CreateClaudeRuntime[adapter];
    (* MaxProposalIterations を十分に確保し、7ターン分の continuation を許可 *)
    ClaudeRuntime`Private`$iClaudeRuntimes[runtimeId][
      "RetryPolicy"]["Limits"]["MaxProposalIterations"] = 10;
    ClaudeRuntime`Private`$iClaudeRuntimes[runtimeId][
      "RetryPolicy"]["Limits"]["MaxTotalSteps"] = 20;
    ClaudeRuntime`ClaudeRunTurn[runtimeId, "long task"];
    st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
    msgs = Lookup[st["ConversationState"], "Messages", {}];
    iTest["Compact integration: Messages length <= limit",
      Length[msgs] <= 5];
    iTest["Compact integration: some messages are compacted",
      AnyTrue[msgs, TrueQ[Lookup[#, "Compacted", False]] &]];
  ];
];

(* ════════════════════════════════════════════════════════
   Phase 20: マルチターン表示データ構造テスト
   
   iRuntimeDisplayResult の全ターン表示が依存する
   ConversationState["Messages"] の構造を検証。
   ════════════════════════════════════════════════════════ *)

iPrintSection["Phase 20: Multi-turn display data"];

(* 2ターン: コード実行 + テキスト完了 → Messages に両方記録 *)
Module[{provider, adapter, runtimeId, st, msgs},
  provider = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\nv = 2 * v\n```",
    "vの値を二倍にしました。 [DONE]"
  }];
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> provider,
    "AllowedHeads" -> {"Set", "Times"},
    "MaxContinuations" -> 3];
  runtimeId = ClaudeRuntime`CreateClaudeRuntime[adapter];
  ClaudeRuntime`ClaudeRunTurn[runtimeId, "vを二倍にして"];
  st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
  msgs = Lookup[st["ConversationState"], "Messages", {}];
  
  iTest["MultiTurn display: 2 messages recorded",
    Length[msgs] === 2];
  
  iTest["MultiTurn display: Turn 1 has ProposedCode",
    StringQ[Lookup[msgs[[1]], "ProposedCode", None]] &&
    StringContainsQ[msgs[[1]]["ProposedCode"], "v"]];
  
  iTest["MultiTurn display: Turn 1 has ExecutionResult",
    AssociationQ[Lookup[msgs[[1]], "ExecutionResult", None]]];
  
  iTest["MultiTurn display: Turn 2 has TextResponse",
    StringQ[Lookup[msgs[[2]], "TextResponse", None]]];
];

(* 3ターン: 2回コード実行 + テキスト完了 *)
Module[{provider, adapter, runtimeId, msgs},
  provider = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\nx = 1\n```",
    "```mathematica\ny = x + 1\n```",
    "計算完了。 [DONE]"
  }];
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> provider,
    "AllowedHeads" -> {"Set", "Plus"},
    "MaxContinuations" -> 5];
  runtimeId = ClaudeRuntime`CreateClaudeRuntime[adapter];
  ClaudeRuntime`ClaudeRunTurn[runtimeId, "xとyを計算して"];
  msgs = ClaudeRuntime`ClaudeGetConversationMessages[runtimeId];
  
  iTest["3-turn: 3 messages recorded",
    Length[msgs] === 3];
  
  iTest["3-turn: intermediate turns (1,2) have ProposedCode",
    AllTrue[msgs[[1 ;; 2]], StringQ[Lookup[#, "ProposedCode", None]] &]];
  
  iTest["3-turn: final turn is TextOnly",
    !StringQ[Lookup[msgs[[3]], "ProposedCode", None]] ||
    Lookup[msgs[[3]], "ProposedCode", None] === None];
  
  iTest["3-turn: ClaudeGetConversationMessages returns same as state",
    Length[msgs] ===
    Length[Lookup[
      ClaudeRuntime`ClaudeRuntimeState[runtimeId]["ConversationState"],
      "Messages", {}]]];
];

(* iMakeTurnSummary がコードと結果の両方を含む要約を生成 *)
Module[{msg, summary},
  msg = <|"Turn" -> 1,
    "ProposedCode" -> "v = 2 * v",
    "ExecutionResult" -> <|"Summary" -> "Result: 42"|>,
    "TextResponse" -> None|>;
  summary = ClaudeRuntime`Private`iMakeTurnSummary[msg];
  iTest["iMakeTurnSummary includes code",
    StringContainsQ[summary, "Code:"]];
  iTest["iMakeTurnSummary includes result",
    StringContainsQ[summary, "Result:"]];
];

(* ════════════════════════════════════════════════════════
   Phase 20: Function Security API テスト
   ════════════════════════════════════════════════════════ *)

iPrintSection["Phase 20: Function security API"];

(* テスト用関数 *)
testSecureFunc[x_] := x * 2;
testDeniedFunc[x_] := x + 100;

(* 登録テスト *)
Module[{spec, result},
  spec = <|
    "DefinitionLabel" -> <|"ReaderPolicies" -> <|"owner1" -> {"reader1"}|>,
      "Categories" -> {"MethodIP"}|>,
    "ExecPolicy" -> "Guarded",
    "ReleasePolicy" -> <|"RequiredFields" -> {"Justification"}|>|>;
  result = NBAccess`NBRegisterFunctionSecurity[testSecureFunc, spec];
  iTest["RegisterFunctionSecurity returns entry",
    AssociationQ[result] && result["ExecPolicy"] === "Guarded"];
  
  NBAccess`NBRegisterFunctionSecurity[testDeniedFunc,
    <|"ExecPolicy" -> "Denied"|>];
];

(* DefinitionLabel / ExecPolicy / ReleasePolicy 照会 *)
iTest["FunctionDefinitionLabel returns registered label",
  NBAccess`NBLabelQ[NBAccess`NBFunctionDefinitionLabel[testSecureFunc]]];

iTest["FunctionExecPolicy returns Guarded",
  NBAccess`NBFunctionExecPolicy[testSecureFunc] === "Guarded"];

iTest["FunctionReleasePolicy has RequiredFields",
  KeyExistsQ[NBAccess`NBFunctionReleasePolicy[testSecureFunc],
    "RequiredFields"]];

iTest["Unregistered function returns Open",
  NBAccess`NBFunctionExecPolicy[Print] === "Open"];

(* GuardedApply テスト *)

(* Denied → 即拒否 *)
Module[{result},
  result = NBAccess`GuardedApply[<||>, testDeniedFunc, 5];
  iTest["GuardedApply Denied: Success=False",
    !TrueQ[result["Success"]]];
  iTest["GuardedApply Denied: error mentions Denied",
    StringContainsQ[result["Error"], "Denied"]];
];

(* Open → 通常実行 *)
Module[{result},
  result = NBAccess`GuardedApply[<||>, Print, "test"];
  iTest["GuardedApply Open: Success=True",
    TrueQ[result["Success"]]];
];

(* Guarded + flow OK → 実行 *)
Module[{result, principal = "admin"},
  (* principal に acts-for を付与 *)
  NBAccess`NBRegisterPrincipal["admin"];
  NBAccess`NBRegisterPrincipal["owner1"];
  NBAccess`NBGrantActsFor["admin", "owner1"];
  result = NBAccess`GuardedApply[
    <|"Principal" -> principal,
      "SinkLabel" -> NBAccess`NBLabelBottom[]|>,
    testSecureFunc, 21];
  iTest["GuardedApply Guarded flow OK: result=42",
    TrueQ[result["Success"]] && result["Result"] === 42];
];

(* Declassify テスト *)
Module[{obj, req, result},
  obj = <|
    "ResultLabel" -> <|"ReaderPolicies" -> <|"owner1" -> {"reader1"}|>,
      "Categories" -> {}|>,
    "ReleasePolicy" -> <|"RequiredFields" -> {"Justification"}|>|>;
  req = <|"Principal" -> "admin"|>;
  
  (* RequiredFields 不足 → 失敗 *)
  result = NBAccess`Declassify[obj, req, <|
    "TargetLabel" -> NBAccess`NBLabelBottom[]|>];
  iTest["Declassify missing RequiredFields: fails",
    !TrueQ[result["Success"]] &&
    StringContainsQ[result["Error"], "Justification"]];
  
  (* RequiredFields 充足 → 成功 *)
  result = NBAccess`Declassify[obj, req, <|
    "TargetLabel" -> NBAccess`NBLabelBottom[],
    "Justification" -> "Approved for publication"|>];
  iTest["Declassify with RequiredFields: succeeds",
    TrueQ[result["Success"]]];
];

(* ════════════════════════════════════════════════════════
   Phase 21: ToolLoop テスト
   ════════════════════════════════════════════════════════ *)

Module[{adapter, rid, st, toolCallResponse, toolFinalResponse,
        turnCount = 0},
  Print[Style["\n── Phase 21: ToolLoop テスト ──", Bold]];
  
  (* ── ツールコール応答を返す MockProvider ── *)
  toolCallResponse = "I need to search for that information.\n\n" <>
    "<tool_call name=\"web_search\" id=\"tc-001\">\n" <>
    "{\"query\": \"Mathematica latest version 2026\"}\n" <>
    "</tool_call>";
  
  toolFinalResponse = "Based on the search results, " <>
    "the latest version is Mathematica 14.2. [DONE]";
  
  adapter = <|
    "SyncProvider" -> True,
    "BuildContext" -> Function[{input, convState},
      <|"Input" -> input, "Cells" -> {},
        "AccessSpec" -> <|"AccessLevel" -> 0.5|>,
        "AvailableTools" -> {}|>],
    "QueryProvider" -> Function[{contextPacket, convState},
      turnCount++;
      If[turnCount === 1,
        <|"response" -> toolCallResponse|>,
        <|"response" -> toolFinalResponse|>]],
    "ParseProposal" -> Function[{rawResponse},
      Module[{toolCallMatches, toolCalls, resp = rawResponse},
        If[AssociationQ[resp], resp = Lookup[resp, "response", ""]];
        If[!StringQ[resp], resp = ToString[resp]];
        toolCallMatches = StringCases[resp,
          RegularExpression[
            "(?s)<tool_call\\s+name=\"([^\"]+)\"(?:\\s+id=\"([^\"]*)\")?\\s*>\\s*([\\s\\S]*?)\\s*</tool_call>"
          ] :> {"$1", "$2", "$3"}];
        If[Length[toolCallMatches] > 0,
          <|"HasToolUse" -> True, "HasProposal" -> False,
            "ToolCalls" -> Map[
              <|"Name" -> #[[1]], "Id" -> #[[2]],
                "Input" -> <|"raw" -> #[[3]]|>|> &,
              toolCallMatches],
            "TextResponse" -> resp, "HeldExpr" -> None|>,
          <|"HasToolUse" -> False, "HasProposal" -> False,
            "TextResponse" -> resp, "HeldExpr" -> None|>]]],
    "ValidateProposal" -> Function[{proposal, contextPacket},
      <|"Decision" -> "Permit"|>],
    "ExecuteProposal" -> Function[{proposal, validationResult},
      <|"Success" -> True, "RawResult" -> "ok"|>],
    "RedactResult" -> Function[{execResult, contextPacket},
      <|"RedactedResult" -> "ok", "Summary" -> "ok"|>],
    "ShouldContinue" -> Function[{redactedResult, convState, turnCnt},
      !StringContainsQ[
        Lookup[Last @ Lookup[convState, "Messages", {<||>}],
          "TextResponse", ""], "[DONE]"]],
    "ExecuteTools" -> Function[{toolCallsList, contextPacket},
      Map[<|"ToolName" -> Lookup[#, "Name", "?"],
            "ToolId" -> Lookup[#, "Id", ""],
            "Success" -> True,
            "Result" -> "Mathematica 14.2 released March 2026",
            "Summary" -> "Found version info"|> &,
        toolCallsList]]
  |>;
  
  (* ── テスト 1: ToolUse ParseProposal 検出 ── *)
  Module[{parsed},
    parsed = adapter["ParseProposal"][toolCallResponse];
    iTest["ToolLoop: ParseProposal detects tool_call",
      TrueQ[Lookup[parsed, "HasToolUse", False]]];
    iTest["ToolLoop: ParseProposal extracts tool name",
      Length[Lookup[parsed, "ToolCalls", {}]] === 1 &&
      Lookup[First @ Lookup[parsed, "ToolCalls", {}], "Name", ""] === "web_search"];
  ];
  
  (* ── テスト 2: ToolUse テキストのみ応答は HasToolUse=False ── *)
  Module[{parsed},
    parsed = adapter["ParseProposal"][toolFinalResponse];
    iTest["ToolLoop: text-only response HasToolUse=False",
      !TrueQ[Lookup[parsed, "HasToolUse", False]]];
  ];
  
  (* ── テスト 3: ExecuteTools 呼び出し ── *)
  Module[{results},
    results = adapter["ExecuteTools"][
      {<|"Name" -> "web_search", "Id" -> "tc-001",
         "Input" -> <|"query" -> "test"|>|>},
      <|"AccessSpec" -> <|"AccessLevel" -> 0.5|>|>];
    iTest["ToolLoop: ExecuteTools returns results",
      ListQ[results] && Length[results] === 1 &&
      TrueQ[Lookup[First[results], "Success", False]]];
  ];
  
  (* ── テスト 4: Runtime ToolUse フロー (sync) ── *)
  turnCount = 0;
  rid = Quiet @ Check[
    ClaudeRuntime`CreateClaudeRuntime[adapter, "Profile" -> "Eval"],
    (Print["  [diag-P21] CreateClaudeRuntime failed"]; $Failed)];
  iTest["ToolLoop: CreateClaudeRuntime succeeds",
    StringQ[rid]];
  
  If[StringQ[rid],
    (* sync モードで DAG を起動 — onComplete が同期的に結果を処理 *)
    Module[{jobId},
      jobId = Quiet @ Check[
        ClaudeRuntime`ClaudeRunTurn[rid,
          "What is the latest Mathematica version?"],
        (Print["  [diag-P21] ClaudeRunTurn failed: ",
          Short[$MessageList, 3]]; $Failed)];
      iTest["ToolLoop: ClaudeRunTurn returns jobId",
        StringQ[jobId]];
      Print["  [diag-P21] jobId=", Short[jobId, 2],
        " turnCount=", turnCount];
    ];
    
    (* DAG 完了後の状態確認 *)
    st = ClaudeRuntime`ClaudeRuntimeState[rid];
    Print["  [diag-P21] status=", Lookup[st, "Status", "?"],
      " TurnCount=", Lookup[st, "TurnCount", "?"],
      " budgets=", Lookup[st, "BudgetsUsed", <||>]];
    iTest["ToolLoop: runtime reaches Done after tool loop",
      Lookup[st, "Status", "?"] === "Done"];
    
    (* ── テスト 5: 会話履歴にツールターンが記録 ── *)
    Module[{msgs},
      msgs = ClaudeRuntime`ClaudeGetConversationMessages[rid];
      Print["  [diag-P21] msgs count=", Length[msgs],
        " types=", Map[Lookup[#, "Type", Lookup[#, "Turn", "?"]] &,
          msgs]];
      iTest["ToolLoop: conversation has multiple turns",
        Length[msgs] >= 1];
      If[Length[msgs] >= 1,
        iTest["ToolLoop: tool turn recorded in messages",
          AnyTrue[msgs,
            (Lookup[#, "Type", ""] === "ToolUse" ||
             ListQ[Lookup[#, "ToolCalls", None]]) &]],
        iTest["ToolLoop: tool turn recorded (skipped)", True]];
    ];
    
    (* ── テスト 6: MaxToolIterations budget ── *)
    Module[{budgets},
      budgets = Lookup[st, "BudgetsUsed", <||>];
      iTest["ToolLoop: MaxToolIterations budget consumed",
        Lookup[budgets, "MaxToolIterations", 0] >= 1];
    ];
    
    (* ── テスト 7: EventTrace にツールイベント ── *)
    Module[{trace},
      trace = ClaudeRuntime`ClaudeTurnTrace[rid];
      Print["  [diag-P21] trace events=",
        Map[Lookup[#, "Type", "?"] &, trace]];
      iTest["ToolLoop: EventTrace contains tool events",
        AnyTrue[trace,
          StringContainsQ[Lookup[#, "Type", ""],
            "Tool" | "tool"] &]];
    ],
    (* rid が失敗した場合 *)
    Print["  [diag-P21] Skipping runtime tests (CreateClaudeRuntime failed)"];
    iTest["ToolLoop: ClaudeRunTurn returns jobId", False];
    iTest["ToolLoop: runtime reaches Done after tool loop", False];
    iTest["ToolLoop: conversation has multiple turns", False];
    iTest["ToolLoop: tool turn recorded in messages", False];
    iTest["ToolLoop: MaxToolIterations budget consumed", False];
    iTest["ToolLoop: EventTrace contains tool events", False];
  ];
];

(* ── テスト: 複数ツールコールのパース ── *)
Module[{parsed, multiToolResponse},
  Print[Style["\n── Phase 21: 複数ツールコール パーステスト ──", Bold]];
  
  multiToolResponse = "Let me search and evaluate.\n\n" <>
    "<tool_call name=\"web_search\" id=\"s1\">\n{\"query\": \"test1\"}\n</tool_call>\n\n" <>
    "<tool_call name=\"mathematica_eval\" id=\"m1\">\n{\"code\": \"1+1\"}\n</tool_call>";
  
  (* Use a simple parse that mirrors the adapter logic *)
  Module[{toolCallMatches},
    toolCallMatches = StringCases[multiToolResponse,
      RegularExpression[
        "(?s)<tool_call\\s+name=\"([^\"]+)\"(?:\\s+id=\"([^\"]*)\")?\\s*>\\s*([\\s\\S]*?)\\s*</tool_call>"
      ] :> {"$1", "$2", "$3"}];
    iTest["MultiTool: detects 2 tool calls",
      Length[toolCallMatches] === 2];
    If[Length[toolCallMatches] >= 2,
      iTest["MultiTool: first tool is web_search",
        toolCallMatches[[1, 1]] === "web_search"];
      iTest["MultiTool: second tool is mathematica_eval",
        toolCallMatches[[2, 1]] === "mathematica_eval"],
      iTest["MultiTool: (skipped)", True];
      iTest["MultiTool: (skipped)", True]];
  ];
];

(* ── テスト: MaxToolIterations budget 枯渇 ── *)
Module[{adapter2, rid2, st2, callCount = 0},
  Print[Style["\n── Phase 21: ToolLoop budget 枯渇テスト ──", Bold]];
  
  adapter2 = <|
    "SyncProvider" -> True,
    "BuildContext" -> Function[{input, convState},
      <|"Input" -> input, "Cells" -> {},
        "AccessSpec" -> <|"AccessLevel" -> 0.5|>|>],
    "QueryProvider" -> Function[{contextPacket, convState},
      callCount++;
      (* 常にツールコールを返す → budget 切れまでループ *)
      <|"response" -> "<tool_call name=\"web_search\" id=\"loop-" <>
        ToString[callCount] <> "\">\n{\"query\": \"infinite\"}\n</tool_call>"|>],
    "ParseProposal" -> Function[{rawResponse},
      Module[{resp = rawResponse, matches},
        If[AssociationQ[resp], resp = Lookup[resp, "response", ""]];
        If[!StringQ[resp], resp = ToString[resp]];
        matches = StringCases[resp,
          RegularExpression[
            "(?s)<tool_call\\s+name=\"([^\"]+)\"(?:\\s+id=\"([^\"]*)\")?\\s*>\\s*([\\s\\S]*?)\\s*</tool_call>"
          ] :> {"$1", "$2", "$3"}];
        If[Length[matches] > 0,
          <|"HasToolUse" -> True, "HasProposal" -> False,
            "ToolCalls" -> Map[
              <|"Name" -> #[[1]], "Id" -> #[[2]],
                "Input" -> <|"raw" -> #[[3]]|>|> &,
              matches],
            "TextResponse" -> resp, "HeldExpr" -> None|>,
          <|"HasToolUse" -> False, "HasProposal" -> False,
            "TextResponse" -> resp, "HeldExpr" -> None|>]]],
    "ValidateProposal" -> Function[{p, c}, <|"Decision" -> "Permit"|>],
    "ExecuteProposal" -> Function[{p, v},
      <|"Success" -> True, "RawResult" -> "ok"|>],
    "RedactResult" -> Function[{e, c},
      <|"RedactedResult" -> "ok", "Summary" -> "ok"|>],
    "ShouldContinue" -> Function[{r, c, t}, True],
    "ExecuteTools" -> Function[{calls, ctx},
      Map[<|"ToolName" -> Lookup[#, "Name", "?"],
            "Success" -> True,
            "Result" -> "result"|> &, calls]]
  |>;
  
  rid2 = ClaudeRuntime`CreateClaudeRuntime[adapter2, "Profile" -> "Eval"];
  ClaudeRuntime`ClaudeRunTurn[rid2, "infinite loop test"];
  st2 = ClaudeRuntime`ClaudeRuntimeState[rid2];
  
  iTest["ToolLoop budget: terminates (not infinite)",
    MemberQ[{"Done", "Failed"}, Lookup[st2, "Status", "?"]]];
  iTest["ToolLoop budget: MaxToolIterations exhausted",
    Lookup[Lookup[st2, "BudgetsUsed", <||>],
      "MaxToolIterations", 0] >= 6];
];

(* ════════════════════════════════════════════════════════
   Phase 24: エコー抑制 / 表示パターンテスト
   
   result2.nb から特定された問題を再現するテスト。
   最終ターンが [DONE] + コードブロック + 先行コード実行がある場合、
   冗長な再実行を防止する。
   ════════════════════════════════════════════════════════ *)

iPrintSection["Phase 24: Echo suppression"];

(* テスト24-1: 計算タスク — Phase 24 プロンプト改善後の期待動作
   Turn 1: ```mathematica\n1 + 1\n``` → 実行 → 2
   Turn 2: "結果は 2 です。 [DONE]" → テキストのみ完了（エコーなし） *)
Module[{provider, adapter, runtimeId, st, msgs, lastMsg},
  provider = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\n1 + 1\n```",
    "\:7d50\:679c\:306f 2 \:3067\:3059\:3002 [DONE]"
  }];
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> provider,
    "AllowedHeads" -> {"Plus", "Times", "Print"},
    "MaxContinuations" -> 1];
  runtimeId = ClaudeRuntime`CreateClaudeRuntime[adapter];
  ClaudeRuntime`ClaudeRunTurn[runtimeId, "1+1\:306f\:ff1f"];
  st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
  msgs = Lookup[st["ConversationState"], "Messages", {}];
  
  iTest["P24 echo: status is Done",
    st["Status"] === "Done"];
  iTest["P24 echo: 2 turns recorded",
    Length[msgs] >= 2];
  (* Turn 1 のコードが "1 + 1" であること *)
  iTest["P24 echo: Turn 1 proposed code is computation",
    StringQ[Lookup[msgs[[1]], "ProposedCode", None]] &&
    StringContainsQ[Lookup[msgs[[1]], "ProposedCode", ""], "1"]];
  (* Turn 2 が [DONE] を含むこと *)
  lastMsg = Last[msgs];
  iTest["P24 echo: final turn has DONE",
    StringQ[Lookup[lastMsg, "TextResponse", ""]] &&
    StringContainsQ[Lookup[lastMsg, "TextResponse", ""], "[DONE]"]];
];

(* テスト24-2: format repair 後の説明タスク
   Turn 1: TextOnly（コードなし） → repair 発動
   Turn 2: コードブロック付き応答 → 正常表示
   注: MaxContinuations=0 で repair 後の不要な continuation を防止。
   MockAdapter の ShouldContinue は [DONE] を検出しないため。 *)
Module[{provider, adapter, runtimeId, st, msgs, trace},
  provider = ClaudeTestKit`CreateMockProvider[{
    "\:96e2\:6563\:6570\:5b66\:306e\:4e3b\:8981\:30c8\:30d4\:30c3\:30af\:3092\:89e3\:8aac\:3057\:307e\:3059\:3002",
    "```mathematica\nColumn[{Style[\"\:96e2\:6563\:6570\:5b66\", Bold, 20]}]\n```\n\n[DONE]"
  }];
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> provider,
    "AllowedHeads" -> {"Column", "Style", "Row", "Grid", "Plot"},
    "MaxContinuations" -> 0];
  runtimeId = ClaudeRuntime`CreateClaudeRuntime[adapter];
  ClaudeRuntime`ClaudeRunTurn[runtimeId, "\:96e2\:6563\:6570\:5b66\:3092\:89e3\:8aac\:3057\:3066"];
  st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
  trace = ClaudeRuntime`ClaudeTurnTrace[runtimeId];
  
  iTest["P24 repair: status is Done",
    st["Status"] === "Done"];
  (* TextOnlyRepair イベントが発生したこと *)
  iTest["P24 repair: TextOnlyRepair event exists",
    AnyTrue[trace, Lookup[#, "Type", ""] === "TextOnlyRepair" &]];
  (* 最終的にコードが提案されたこと *)
  msgs = Lookup[st["ConversationState"], "Messages", {}];
  iTest["P24 repair: final msg has ProposedCode",
    Length[msgs] > 0 &&
    StringQ[Lookup[Last[msgs], "ProposedCode", None]]];
];

(* テスト24-3: Continuation で TextOnly + [DONE] が正当な完了
   Turn 1: コード実行
   Turn 2: [DONE] テキストのみ（エコーなし） → isAfterDaemon パターン *)
Module[{provider, adapter, runtimeId, st, msgs, lastMsg},
  provider = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\nListPlot[Table[{n, Fibonacci[n]}, {n, 20}]]\n```",
    "\:30d5\:30a3\:30dc\:30ca\:30c3\:30c1\:6570\:5217\:3092\:53ef\:8996\:5316\:3057\:307e\:3057\:305f\:3002 [DONE]"
  }];
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> provider,
    "AllowedHeads" -> {"ListPlot", "Table", "Fibonacci"},
    "MaxContinuations" -> 3];
  runtimeId = ClaudeRuntime`CreateClaudeRuntime[adapter];
  ClaudeRuntime`ClaudeRunTurn[runtimeId, "\:30d5\:30a3\:30dc\:30ca\:30c3\:30c1\:3092\:53ef\:8996\:5316\:3057\:3066"];
  st = ClaudeRuntime`ClaudeRuntimeState[runtimeId];
  msgs = Lookup[st["ConversationState"], "Messages", {}];
  
  iTest["P24 afterDaemon: status is Done",
    st["Status"] === "Done"];
  iTest["P24 afterDaemon: 2 turns",
    Length[msgs] >= 2];
  (* Turn 1 はコード、Turn 2 は TextOnly *)
  iTest["P24 afterDaemon: Turn 1 has code",
    StringQ[Lookup[msgs[[1]], "ProposedCode", None]]];
  lastMsg = Last[msgs];
  iTest["P24 afterDaemon: Turn 2 is TextOnly",
    !StringQ[Lookup[lastMsg, "ProposedCode", None]]];
  iTest["P24 afterDaemon: Turn 2 has DONE",
    StringContainsQ[Lookup[lastMsg, "TextResponse", ""], "[DONE]"]];
];

(* テスト24-4, 24-5: claudecode.wl がロード済みの場合のみ実行 *)
If[Length[Names["ClaudeCode`Private`iAdapterBuildPrompt"]] > 0,

(* テスト24-4: iAdapterBuildPrompt の REMINDER がターンタイプに応じて変化
   初回ターン: コード必須リマインダー
   Continuation ターン: [DONE] テキストのみ許可リマインダー *)
Module[{adapter, prompt1, prompt2, contextPacket, convState},
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[{"dummy"}],
    "AllowedHeads" -> {"Print"},
    "MaxContinuations" -> 1];
  
  (* 初回ターン *)
  contextPacket = <|"Input" -> "test task", "Cells" -> {},
    "TotalCellCount" -> 0|>;
  convState = <|"Messages" -> {}|>;
  prompt1 = ClaudeCode`Private`iAdapterBuildPrompt[contextPacket, convState];
  
  iTest["P24 prompt: first turn has MUST include code blocks",
    StringContainsQ[prompt1, "MUST include ```mathematica"]];
  iTest["P24 prompt: first turn rejects text-only",
    StringContainsQ[prompt1, "NOT acceptable"]];
  
  (* Continuation ターン *)
  contextPacket = <|
    "Input" -> <|"Type" -> "Continuation",
      "OriginalTask" -> "test task"|>,
    "Cells" -> {}, "TotalCellCount" -> 0|>;
  convState = <|"Messages" -> {<|"Turn" -> 1, "ProposedCode" -> "1+1"|>}|>;
  prompt2 = ClaudeCode`Private`iAdapterBuildPrompt[contextPacket, convState];
  
  iTest["P24 prompt: continuation allows text-only DONE",
    StringContainsQ[prompt2, "respond with text only"]];
  iTest["P24 prompt: continuation warns against echo",
    StringContainsQ[prompt2, "Do NOT echo"]];
];

(* テスト24-5: RESPONSE FORMAT にエコー禁止例が含まれること *)
Module[{adapter, prompt, contextPacket, convState},
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[{"dummy"}],
    "AllowedHeads" -> {"Print"},
    "MaxContinuations" -> 1];
  contextPacket = <|"Input" -> "calculate", "Cells" -> {},
    "TotalCellCount" -> 0|>;
  convState = <|"Messages" -> {}|>;
  prompt = ClaudeCode`Private`iAdapterBuildPrompt[contextPacket, convState];
  
  iTest["P24 prompt: has echo prohibition example",
    StringContainsQ[prompt, "do NOT echo the result"]];
  iTest["P24 prompt: has Turn 2 CORRECT example",
    StringContainsQ[prompt, "CORRECT"]];
  iTest["P24 prompt: has Turn 2 WRONG example",
    StringContainsQ[prompt, "WRONG"]];
];

, (* Else: claudecode.wl 未ロード *)
Print[Style["  claudecode.wl 未ロード → P24 prompt テスト SKIP", Orange]]
]; (* End If claudecode loaded *)

(* ════════════════════════════════════════════════════════
   Phase 25: 非同期 Runtime + リッチ WindowStatusArea + sync チェイン最適化
   ════════════════════════════════════════════════════════ *)
Print[Style["\n=== Phase 25: Async Runtime & WindowStatusArea ===", Bold]];

(* ── テスト 25-1: SyncProvider -> False で adapter 構築 ── *)
If[ValueQ[ClaudeCode`ClaudeBuildRuntimeAdapter] &&
   Head[ClaudeCode`ClaudeBuildRuntimeAdapter] =!= ClaudeCode`ClaudeBuildRuntimeAdapter,
Module[{adapter},
  adapter = ClaudeCode`ClaudeBuildRuntimeAdapter[$Failed,
    "SyncProvider" -> False,
    "AccessLevel"  -> 0.5];
  iTest["P25 adapter: SyncProvider=False stored in adapter",
    AssociationQ[adapter] &&
    Lookup[adapter, "SyncProvider", True] === False];
  iTest["P25 adapter: QueryProviderAsync exists",
    AssociationQ[adapter] &&
    Lookup[adapter, "QueryProviderAsync", None] =!= None];
  iTest["P25 adapter: QueryProvider exists (sync fallback)",
    AssociationQ[adapter] &&
    Lookup[adapter, "QueryProvider", None] =!= None];
],
Print[Style["  ClaudeBuildRuntimeAdapter 未定義 → P25-1 SKIP", Orange]]
];

(* ── テスト 25-2: ClaudeRunTurn の DAG ノード構成 (async mode) ── *)
Module[{adapter, runtimeId, rt, mockProv},
  mockProv = ClaudeTestKit`CreateMockProvider[{
    "```mathematica\n1 + 1\n```"}];
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> mockProv,
    "AllowedHeads" -> {"Plus"},
    "MaxContinuations" -> 0];
  (* SyncProvider=False を設定 *)
  adapter["SyncProvider"] = False;
  (* QueryProviderAsync を追加 *)
  adapter["QueryProviderAsync"] = Function[{cp, cs},
    <|"proc" -> None, "outFile" -> "dummy.txt",
      "batFile" -> "dummy.bat", "promptFile" -> "dummy.txt",
      "startTime" -> AbsoluteTime[]|>];
  
  runtimeId = ClaudeRuntime`CreateClaudeRuntime[adapter,
    "Profile" -> "Eval"];
  rt = ClaudeRuntime`Private`$iClaudeRuntimes[runtimeId];
  
  iTest["P25 async DAG: runtime created",
    StringQ[runtimeId] && AssociationQ[rt]];
  iTest["P25 async DAG: SyncProvider is False in adapter",
    TrueQ[Lookup[Lookup[rt, "Adapter", <||>], "SyncProvider", True] === False]];
];

(* ── テスト 25-3: $ClaudeWorkingDirectory 使用 (iClaudeTempDir 修正) ── *)
(* QueryProviderAsync のパスが $ClaudeWorkingDirectory を使うことを検証 *)
If[ValueQ[ClaudeCode`ClaudeBuildRuntimeAdapter] &&
   Head[ClaudeCode`ClaudeBuildRuntimeAdapter] =!= ClaudeCode`ClaudeBuildRuntimeAdapter,
Module[{adapter, asyncFn, result},
  adapter = ClaudeCode`ClaudeBuildRuntimeAdapter[$Failed,
    "SyncProvider" -> False,
    "AccessLevel"  -> 0.5];
  asyncFn = Lookup[adapter, "QueryProviderAsync", None];
  iTest["P25 tempdir: QueryProviderAsync is a Function",
    MatchQ[asyncFn, _Function]];
  (* Note: 実際の実行は CLI が必要なため関数の存在のみ検証 *)
],
Print[Style["  ClaudeBuildRuntimeAdapter 未定義 → P25-3 SKIP", Orange]]
];

(* ── テスト 25-4: sync チェイン最適化のロジック検証 ── *)
(* 依存チェイン A → B → C で A が done のとき、
   B と C が同一 tick で実行されることを疑似検証 *)
Module[{nodes, job, eligibleIds, executed = {}},
  nodes = <|
    "A" -> <|"id" -> "A", "type" -> "sync", "status" -> "done",
      "category" -> "sync", "dependsOn" -> {}, "result" -> "ok"|>,
    "B" -> <|"id" -> "B", "type" -> "sync", "status" -> "pending",
      "category" -> "sync", "dependsOn" -> {"A"},
      "handler" -> Function[{j}, AppendTo[executed, "B"]; <|"ok" -> True|>]|>,
    "C" -> <|"id" -> "C", "type" -> "sync", "status" -> "pending",
      "category" -> "sync", "dependsOn" -> {"B"},
      "handler" -> Function[{j}, AppendTo[executed, "C"]; <|"ok" -> True|>]|>
  |>;
  
  (* Phase 25 のロジック: sync 完了後に再チェック *)
  Module[{anyLaunched = True, iter = 0},
    While[anyLaunched && iter < 5,
      anyLaunched = False;
      iter++;
      eligibleIds = Select[Keys[nodes],
        Lookup[nodes[#], "status", ""] === "pending" &&
        AllTrue[Lookup[nodes[#], "dependsOn", {}],
          Lookup[Lookup[nodes, #, <||>], "status", ""] === "done" &] &];
      Do[
        Module[{n = nodes[eid], result},
          result = n["handler"][<||>];
          n["status"] = "done";
          n["result"] = result;
          nodes[eid] = n;
          anyLaunched = True],
        {eid, eligibleIds}]
    ]];
  
  iTest["P25 sync chain: both B and C executed",
    executed === {"B", "C"}];
  iTest["P25 sync chain: all nodes done",
    AllTrue[Values[nodes], Lookup[#, "status", ""] === "done" &]];
];

(* ── テスト 25-5: Runtime DAG context 検出 ── *)
Module[{context1, context2},
  context1 = <|"runtimeId" -> "rt-123", "turnCount" -> 1|>;
  context2 = <|"detailLevel" -> "Summary"|>;
  
  iTest["P25 runtime DAG detect: runtimeId present",
    StringQ[Lookup[context1, "runtimeId", None]]];
  iTest["P25 runtime DAG detect: no runtimeId",
    !StringQ[Lookup[context2, "runtimeId", None]]];
];

(* ── テスト 25-6: iClaudeEvalViaRuntimeBridge が SyncProvider=False を使用 ── *)
If[ValueQ[ClaudeCode`ClaudeStartRuntime] &&
   Head[ClaudeCode`ClaudeStartRuntime] =!= ClaudeCode`ClaudeStartRuntime,
Module[{opts},
  opts = Options[ClaudeCode`ClaudeStartRuntime];
  iTest["P25 bridge: ClaudeStartRuntime has SyncProvider option",
    MemberQ[Keys[opts], "SyncProvider"]];
  (* デフォルトは True (各呼び出し元が明示的に False を渡す) *)
  iTest["P25 bridge: default SyncProvider is True",
    Lookup[opts, "SyncProvider", None] === True];
],
Print[Style["  ClaudeStartRuntime 未定義 → P25-6 SKIP", Orange]]
];

(* ── テスト 25-7: バージョン確認 ── *)
iTest["P26 version: phase26",
  StringQ[ClaudeRuntime`$ClaudeRuntimeVersion] &&
  StringContainsQ[ClaudeRuntime`$ClaudeRuntimeVersion, "phase26"]];

(* ════════════════════════════════════════════════════════
   Phase 26: adapter ValidateProposal フォールバック
   
   NBAccess 未ロード時に adapter["ValidateProposal"] が呼ばれることを検証。
   Phase 25b で Runtime が NBAccess リストを直接参照するようになったが、
   NBAccess 未ロード環境 (テスト/外部利用) で adapter が無視される
   バグを修正した。
   ════════════════════════════════════════════════════════ *)
Print[Style["\n=== Phase 26: Adapter ValidateProposal Fallback ===", Bold]];

(* ── テスト 26-1: NBAccess 未ロード時に MockAdapter の Deny が機能する ── *)
Module[{adapter, rid, jobId, st, savedDeny, savedApproval},
  (* NBAccess リストを一時的に未定義にする *)
  savedDeny = Quiet[NBAccess`$NBDenyHeads];
  savedApproval = Quiet[NBAccess`$NBApprovalHeads];
  Quiet[NBAccess`$NBDenyHeads =.];
  Quiet[NBAccess`$NBApprovalHeads =.];
  
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[{
      "```mathematica\nDeleteFile[\"test\"]\n```"}],
    "DenyHeads" -> {"DeleteFile"}];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "deny test",
    "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  
  iTest["P26 fallback: Deny detected without NBAccess",
    st["Status"] === "AwaitingApproval"];
  iTest["P26 fallback: DenyOverride set",
    TrueQ[Lookup[
      Lookup[st, "PendingApproval", <||>],
      "DenyOverride", False]]];
  
  (* リストを復元 *)
  If[ListQ[savedDeny], NBAccess`$NBDenyHeads = savedDeny];
  If[ListQ[savedApproval], NBAccess`$NBApprovalHeads = savedApproval];
];

(* ── テスト 26-2: NBAccess 未ロード時に MockAdapter の NeedsApproval が機能する ── *)
Module[{adapter, rid, jobId, st, savedDeny, savedApproval},
  savedDeny = Quiet[NBAccess`$NBDenyHeads];
  savedApproval = Quiet[NBAccess`$NBApprovalHeads];
  Quiet[NBAccess`$NBDenyHeads =.];
  Quiet[NBAccess`$NBApprovalHeads =.];
  
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[{
      "```mathematica\nNBCellWriteCode[nb, 1, \"x\"]\n```"}],
    "ApprovalHeads" -> {"NBCellWriteCode"}];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "approval test",
    "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  
  iTest["P26 fallback: NeedsApproval detected without NBAccess",
    st["Status"] === "AwaitingApproval"];
  iTest["P26 fallback: NeedsApproval has no DenyOverride",
    !TrueQ[Lookup[
      Lookup[st, "PendingApproval", <||>],
      "DenyOverride", False]]];
  
  If[ListQ[savedDeny], NBAccess`$NBDenyHeads = savedDeny];
  If[ListQ[savedApproval], NBAccess`$NBApprovalHeads = savedApproval];
];

(* ── テスト 26-3: NBAccess 未ロード時に MockAdapter の RepairNeeded が機能する ── *)
Module[{adapter, rid, jobId, st, tr, savedDeny, savedApproval},
  savedDeny = Quiet[NBAccess`$NBDenyHeads];
  savedApproval = Quiet[NBAccess`$NBApprovalHeads];
  Quiet[NBAccess`$NBDenyHeads =.];
  Quiet[NBAccess`$NBApprovalHeads =.];
  
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[{
      "```mathematica\nUnknownFunc[42]\n```",
      "```mathematica\nUnknownFunc[43]\n```",
      "```mathematica\nUnknownFunc[44]\n```",
      "```mathematica\nUnknownFunc[45]\n```",
      "```mathematica\nUnknownFunc[46]\n```"}],
    "AllowedHeads" -> {"Print"}];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter, "Profile" -> "Eval"];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "repair test",
    "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  tr = ClaudeRuntime`ClaudeTurnTrace[rid];
  
  iTest["P26 fallback: RepairNeeded leads to Failed after budget",
    st["Status"] === "Failed"];
  iTest["P26 fallback: ValidationRepairAttempt in trace",
    AnyTrue[tr, Lookup[#, "Type", ""] === "ValidationRepairAttempt" &]];
  
  If[ListQ[savedDeny], NBAccess`$NBDenyHeads = savedDeny];
  If[ListQ[savedApproval], NBAccess`$NBApprovalHeads = savedApproval];
];

(* ── テスト 26-4: NBAccess ロード済み時は Runtime 直接チェックが優先 ── *)
If[ListQ[Quiet[NBAccess`$NBDenyHeads]],
Module[{adapter, rid, jobId, st},
  (* MockAdapter は DeleteFile を許可するが、NBAccess は拒否 *)
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[{
      "```mathematica\nDeleteFile[\"test\"]\n```"}],
    "AllowedHeads" -> {"DeleteFile"},  (* adapter は許可 *)
    "DenyHeads" -> {}];               (* adapter は拒否しない *)
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "nbaccess deny test",
    "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  
  iTest["P26 direct: NBAccess Deny overrides adapter Permit",
    st["Status"] === "AwaitingApproval"];
],
Print[Style["  NBAccess 未ロード → P26-4 SKIP", Orange]]
];

(* ── テスト 26-5: iDetectsContextOverwrite 関数テスト ── *)
Print[Style["\n── Phase 26: Core Context Overwrite Detection ──", Bold]];

iTest["P26 overwrite: detect ClaudeCode` assignment",
  ClaudeRuntime`Private`iDetectsContextOverwrite[
    "ClaudeCode`LLMGraphDAGCreate[spec_Association] := stubImpl[spec]"]];

iTest["P26 overwrite: detect NBAccess` assignment",
  ClaudeRuntime`Private`iDetectsContextOverwrite[
    "NBAccess`$NBDenyHeads = {\"DeleteFile\"}"]];

iTest["P26 overwrite: detect DownValues override",
  ClaudeRuntime`Private`iDetectsContextOverwrite[
    "DownValues[ClaudeCode`LLMGraphDAGCreate] = saved"]];

iTest["P26 overwrite: detect Unprotect",
  ClaudeRuntime`Private`iDetectsContextOverwrite[
    "Unprotect[ClaudeCode`LLMGraphDAGCreate]"]];

iTest["P26 overwrite: detect ClaudeRuntime` assignment",
  ClaudeRuntime`Private`iDetectsContextOverwrite[
    "ClaudeRuntime`Private`$iClaudeRuntimes = <||>"]];

iTest["P26 overwrite: detect ClaudeRuntime` Private assignment",
  ClaudeRuntime`Private`iDetectsContextOverwrite[
    "ClaudeRuntime`Private`$iClaudeRuntimes = <||>"]];

iTest["P26 overwrite: normal code not detected",
  !ClaudeRuntime`Private`iDetectsContextOverwrite[
    "Print[\"hello\"]"]];

iTest["P26 overwrite: function CALL not detected (not overwrite)",
  !ClaudeRuntime`Private`iDetectsContextOverwrite[
    "ClaudeCode`ClaudeEval[\"test\"]"]];

iTest["P26 overwrite: local Set not detected",
  !ClaudeRuntime`Private`iDetectsContextOverwrite[
    "Module[{x}, x = 42; Print[x]]"]];

iTest["P26 overwrite: bare symbol reference not detected",
  !ClaudeRuntime`Private`iDetectsContextOverwrite[
    "Print[ClaudeCode`$UseClaudeRuntime]"]];

(* ── テスト 26-6: Runtime 検証でコンテキスト上書きが NeedsApproval になる ── *)
Module[{adapter, rid, jobId, st},
  adapter = ClaudeTestKit`CreateMockAdapter[
    "Provider" -> ClaudeTestKit`CreateMockProvider[{
      "```mathematica\nClaudeCode`LLMGraphDAGCreate[s_] := s\n```"}],
    "AllowedHeads" -> {"SetDelayed"}];
  rid = ClaudeRuntime`CreateClaudeRuntime[adapter];
  jobId = ClaudeRuntime`ClaudeRunTurn[rid, "overwrite test",
    "Notebook" -> $Failed];
  st = ClaudeRuntime`ClaudeRuntimeState[rid];
  
  iTest["P26 overwrite runtime: NeedsApproval for context overwrite",
    st["Status"] === "AwaitingApproval"];
  iTest["P26 overwrite runtime: ReasonClass is CoreContextOverwrite",
    AssociationQ[st["PendingApproval"]] &&
    Lookup[
      Lookup[st["PendingApproval"], "ValidationResult", <||>],
      "ReasonClass", ""] === "CoreContextOverwrite"];
];

Print[Style["\n══ テスト結果サマリ ══", Bold, Blue]];
Print["  Total:  ", $testCount];
Print["  Passed: ", Style[$testPassed, Darker[Green]]];
Print["  Failed: ", Style[$testFailed, If[$testFailed > 0, Red, Darker[Green]]]];

If[$testFailed > 0,
  Print[Style["\n  失敗テスト一覧:", Red]];
  Do[
    If[!TrueQ[r["Passed"]],
      Print["    \[Cross] ", r["Name"]]],
    {r, $testResults}]];

If[$testFailed === 0,
  Print[Style["\n  \[Checkmark] ALL TESTS PASSED", Bold, Darker[Green]]]];

(* ════════════════════════════════════════════════════════
   テスト後クリーンアップ: LLMGraphDAGCreate 実体の復元
   
   テスト中は同期スタブで上書きしているため、
   テスト後に ClaudeEval が動作するよう実体を復元する。
   ════════════════════════════════════════════════════════ *)

If[ListQ[$iSavedDAGCreateDV] && Length[$iSavedDAGCreateDV] > 0,
  Quiet[Unprotect[ClaudeCode`LLMGraphDAGCreate]];
  DownValues[ClaudeCode`LLMGraphDAGCreate] = $iSavedDAGCreateDV;
  Quiet[Unprotect[ClaudeCode`LLMGraphDAGCancel]];
  DownValues[ClaudeCode`LLMGraphDAGCancel] = $iSavedDAGCancelDV;
  (* Integrity チェックのスナップショットもリセット:
     次回 ClaudeEval 時に復元後の状態で新しいベースラインを取得 *)
  ClaudeCode`Private`$iCoreIntegritySnapshot = None;
  Print[Style["\n  実体 LLMGraphDAGCreate/Cancel を復元しました。",
    Italic, Darker[Green]]];
  Print["    ClaudeEval はテスト後も正常に動作します。"],
  Print[Style["\n  claudecode.wl 未ロード: LLMGraph 復元不要", Italic, Gray]]
];