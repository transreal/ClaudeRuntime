(* ::Package:: *)

(* ClaudeRuntime_externalrunner.wl -- External WolframScript runner / launcher (Phase 4.A)

   \:4f4d\:7f6e\:4ed8\:3051:
     ClaudeOrchestrator_external_executor_task_placement_spec_v7 \:306e Phase 4 (runner) \:306e
     \:30d7\:30e9\:30f3\:30d3\:30f3\:30b0\:6838\:3002ClaudeOrchestrator_workflow.wl \:306e External executor \:30d5\:30c3\:30af
     ($ClaudeExternalJobLauncher / StatusReader / Killer) \:306b\:5b9f\:4f53\:3092\:4e0e\:3048\:308b\:3002

   \:672c\:30d5\:30a1\:30a4\:30eb\:306f2\:3064\:306e\:7acb\:5834\:3067\:4f7f\:308f\:308c\:308b:
     (A) Orchestrator (\:89aa) \:5074: launcher / killer / job dir / manifest \:3092\:63d0\:4f9b\:3002
         ClaudeWireExternalRunner[] \:3067 Workflow \:30d5\:30c3\:30af\:3078\:7d50\:7dda\:3002
     (B) runner (\:5b50, \:5225 wolframscript \:30d7\:30ed\:30bb\:30b9) \:5074: ClaudeRunTaskFromManifest[jobDir]
         \:304c manifest \:3092\:8aad\:307f handler \:3092\:5b9f\:884c\:3057\:3066 status.json / output.wxf \:3092\:66f8\:304f\:3002

   Phase 4.A \:30b9\:30b3\:30fc\:30d7:
     - wolframscript \:89e3\:6c7a / durable job root / manifest / pid.json / \:5b9f StartProcess \:8d77\:52d5
     - runner entrypoint + handler registry + \:30c6\:30b9\:30c8\:7528 "Echo" handler
     - status.json \:306f atomic write (tmp -> rename)
   Phase 4.B (\:4e00\:90e8\:5b9f\:88c5\:6e08\:307f):
     - [\:6e08] \:6a5f\:5bc6 input/output \:306e\:5b9f\:6697\:53f7\:5316 (ConfidentialHandling=="EncryptedBundle")\:3002
            SourceVault crypto (SourceVaultSealPayload/UnsealPayload) \:306b\:59d4\:8b72\:3002\:9375\:306f
            NBAccess credential store \:306b\:9589\:3058\:308b\:3002cross-process \:5171\:6709\:306e\:305f\:3081 SystemCredential
            \:5fc5\:9808\:30fbfail-closed\:3002\:5b50 run.wls \:306f\:8efd\:91cf crypto 2 package \:3092\:5148\:306b\:30ed\:30fc\:30c9\:3059\:308b\:3002
     - [\:6e08] error.txt redaction (\:6a5f\:5bc6\:30b8\:30e7\:30d6\:3067\:306f result \:672c\:6587\:3092\:5410\:304b\:306a\:3044)\:3002
     - [\:6b8b] ReferenceOnly \:306e\:8a73\:7d30\:904b\:7528\:30fbcredential-ref \:89e3\:6c7a
     - [\:6b8b] NBAccess \:672c\:4f53\:30ed\:30fc\:30c9 + PolicySnapshot \:9069\:7528 + NBCheck* I/O guard (cooperative enforcement)
     - [\:6b8b] pid.txt \:30d9\:30fc\:30b9\:306e cross-restart kill (image/JobID \:540c\:4e00\:6027) \:3068 orphan recovery \:672c\:4f53
     - [\:6b8b] stdout/stderr.log \:30ad\:30e3\:30d7\:30c1\:30e3

   Load:
     Block[{$CharacterEncoding = "UTF-8"}, Get["ClaudeRuntime_externalrunner.wl"]]
*)

(* \:30d1\:30c3\:30b1\:30fc\:30b8\:81ea\:8eab\:306e\:7d76\:5bfe\:30d1\:30b9\:3092\:6355\:6349 (runner bootstrap \:304c Get \:3059\:308b\:305f\:3081) *)
ClaudeRuntime`Private`$iExternalRunnerFile =
  If[StringQ[$InputFileName] && $InputFileName =!= "", $InputFileName, Missing[]];

BeginPackage["ClaudeRuntime`"];

ClaudeRunTaskFromManifest::usage =
  "ClaudeRunTaskFromManifest[jobDir] \:306f runner (\:5b50\:30d7\:30ed\:30bb\:30b9) \:306e\:30a8\:30f3\:30c8\:30ea\:30dd\:30a4\:30f3\:30c8\:3002manifest.wl \:3092\:8aad\:307f\:3001input.wxf \:3092\:8aad\:307f\:3001Handler \:3092\:5b9f\:884c\:3057\:3001output.wxf \:3068 status.json (Completed/Failed) \:3092\:66f8\:304f\:3002";

ClaudeRegisterExternalTaskHandler::usage =
  "ClaudeRegisterExternalTaskHandler[name, fn, opts] \:306f External task handler \:3092\:767b\:9332\:3059\:308b\:3002fn \:306f <|\"Manifest\"->m, \"Input\"->inputData|> \:3092\:53d7\:3051\:53d6\:308a Association \:3092\:8fd4\:3059\:3002";

ClaudeResolveWolframScriptExecutable::usage =
  "ClaudeResolveWolframScriptExecutable[] \:306f wolframscript \:5b9f\:884c\:30d5\:30a1\:30a4\:30eb\:3092\:89e3\:6c7a\:3059\:308b\:3002\:512a\:5148\:9806: $ClaudeWolframScriptExecutable > Environment[\"WOLFRAMSCRIPT\"] > $InstallationDirectory \:8fd1\:508d > PATH \:4e0a\:306e \"wolframscript\"\:3002";

ClaudeExternalJobRoot::usage =
  "ClaudeExternalJobRoot[] \:306f durable \:306a job root ($ClaudeExternalJobRoot \:307e\:305f\:306f $UserBaseDirectory/ClaudeRuntime/jobs) \:3092\:8fd4\:3057\:3001\:7121\:3051\:308c\:3070\:4f5c\:6210\:3059\:308b\:3002";

ClaudeExternalWolframScriptLauncher::usage =
  "ClaudeExternalWolframScriptLauncher[jobSpec] \:306f job dir \:3092\:4f5c\:308a manifest/input/run.wls \:3092\:66f8\:304d\:3001wolframscript runner \:3092 StartProcess \:3067\:8d77\:52d5\:3057\:3066 <|\"Status\"->\"Launched\", \"JobID\", \"JobDir\", \"PID\"|> \:3092\:8fd4\:3059\:3002$ClaudeExternalJobLauncher \:3078\:7d50\:7dda\:3057\:3066\:4f7f\:3046\:3002";

ClaudeExternalInProcessLauncher::usage =
  "ClaudeExternalInProcessLauncher[jobSpec] \:306f job dir/manifest \:3092\:6e96\:5099\:3057 runner \:3092\:73fe\:5728\:306e\:30ab\:30fc\:30cd\:30eb\:3067\:540c\:671f\:5b9f\:884c\:3059\:308b (\:5225\:30d7\:30ed\:30bb\:30b9\:3092\:8d77\:3053\:3055\:306a\:3044)\:3002\:30c6\:30b9\:30c8\:30fb\:5358\:4e00\:30e9\:30a4\:30bb\:30f3\:30b9\:74b0\:5883\:30fb\:77ed\:6642\:9593\:30bf\:30b9\:30af\:7528\:3002long-running \:306b\:306f\:4f7f\:308f\:306a\:3044 (main kernel \:3092\:30d6\:30ed\:30c3\:30af\:3059\:308b)\:3002";

ClaudeExternalWolframScriptKiller::usage =
  "ClaudeExternalWolframScriptKiller[awaitMeta] \:306f\:8d77\:52d5\:6e08\:307f ProcessObject \:3092\:540c\:4e00\:6027\:78ba\:8a8d\:5f8c\:306b\:7d42\:4e86\:3059\:308b\:3002$ClaudeExternalJobKiller \:3078\:7d50\:7dda\:3057\:3066\:4f7f\:3046\:3002";

ClaudeWireExternalRunner::usage =
  "ClaudeWireExternalRunner[] \:306f ClaudeOrchestrator`Workflow` \:306e External executor \:30d5\:30c3\:30af ($ClaudeExternalJobLauncher / StatusReader / Killer) \:3092\:672c\:30d1\:30c3\:30b1\:30fc\:30b8\:306e\:5b9f\:88c5\:3078\:7d50\:7dda\:3059\:308b\:3002";

ClaudeExternalJobRecover::usage =
  "ClaudeExternalJobRecover[opts] \:306f job root \:3092\:8d70\:67fb\:3057\:3001status \:304c Running \:3060\:304c registry \:306b\:7121\:3044\:5b64\:5150 job \:3092\:56de\:53ce\:3059\:308b\:3002opts \"Kill\"->True \:3067 pid.json \:540c\:4e00\:6027\:78ba\:8a8d\:5f8c\:306b kill\:3001\"Mark\"->True \:3067 status \:3092 Expired \:306b\:66f4\:65b0\:3002\:8fd4\:308a\:5024\:306b\:56de\:53ce\:7d50\:679c\:3002";

$ClaudeExternalProcessProbe::usage =
  "$ClaudeExternalProcessProbe \:306f PID \:306e\:30d7\:30ed\:30bb\:30b9\:60c5\:5831\:3092\:8fd4\:3059\:95a2\:6570 (fn[pid] -> <|\"Alive\"->_, \"Executable\"->_|> | None)\:3002Automatic \:306f OS \:554f\:3044\:5408\:308f\:305b (Windows: tasklist)\:3002cross-restart kill \:306e\:540c\:4e00\:6027\:78ba\:8a8d\:306b\:4f7f\:3046\:3002\:30c6\:30b9\:30c8\:3067 mock \:6ce8\:5165\:53ef\:3002";
$ClaudeExternalProcessKill::usage =
  "$ClaudeExternalProcessKill \:306f PID \:3092\:5f37\:5236\:7d42\:4e86\:3059\:308b\:95a2\:6570 (fn[pid] -> Bool)\:3002Automatic \:306f OS kill (Windows: taskkill /F)\:3002\:30c6\:30b9\:30c8\:3067 mock \:6ce8\:5165\:53ef\:3002";

ClaudeLintExternalHandler::usage =
  "ClaudeLintExternalHandler[HoldComplete[body]] \:306f handler \:672c\:4f53\:306b raw I/O (Export/Import/URLRead/StartProcess/OpenWrite/DeleteFile/DialogInput/AuthenticationDialog \:7b49) \:304c\:76f4\:66f8\:304d\:3055\:308c\:3066\:3044\:306a\:3044\:304b\:691c\:67fb\:3059\:308b\:3002handler \:306f NBChecked* / NBCheck* \:7d4c\:7531\:3067 I/O \:3059\:3079\:304d (v7 \[Section]13/\[Section]16)\:3002<|\"Clean\"->_, \"Violations\"->{...}|>\:3002";

$ClaudeBatchProcessorOverrides::usage =
  "$ClaudeBatchProcessorOverrides \:306f batch handler (BulkFileProcessing/BulkLLMProcessing/MailFetch/SourceVaultIngest) \:306e per-item processor \:3092\:5dee\:3057\:66ff\:3048\:308b Association (handlerName -> Function[{item,idx,ctx}, <|\"Status\"->\"OK\"|\"Failed\",\"Result\"->_|>])\:3002\:9023\:7d50 (override \:304c\:6700\:512a\:5148)\:3002";

$ClaudeLLMConnector::usage =
  "$ClaudeLLMConnector \:306f BulkLLMProcessing \:304c\:4f7f\:3046 LLM \:547c\:51fa\:95a2\:6570 (fn[prompt])\:3002Automatic \:306f ClaudeCode`ClaudeQuerySync (\:30ed\:30fc\:30c9\:6642) \:3078\:89e3\:6c7a\:3057\:3001\:672a\:30ed\:30fc\:30c9\:6642\:306f graceful fail\:3002\:30c6\:30b9\:30c8\:3067 mock \:6ce8\:5165\:53ef\:3002\:9375\:306f ClaudeQuerySync \:5074\:304c NBGetAPIKey \:3067\:6271\:3046 (rules/20)\:3002";
$ClaudeSourceVaultIngestConnector::usage =
  "$ClaudeSourceVaultIngestConnector \:306f SourceVaultIngest \:304c\:4f7f\:3046\:53d6\:8fbc\:95a2\:6570 (fn[source])\:3002Automatic \:306f SourceVault`SourceVaultIngest \:3078\:89e3\:6c7a\:3002";
$ClaudeMailFetchConnector::usage =
  "$ClaudeMailFetchConnector \:306f MailFetch \:304c\:4f7f\:3046\:53d6\:5f97\:95a2\:6570 (fn[mbox, period])\:3002Automatic \:306f SourceVault`SourceVaultMailEnsureLoaded \:3078\:89e3\:6c7a\:3002";
ClaudeWireExternalProviders::usage =
  "ClaudeWireExternalProviders[spec] \:306f provider connector \:3092\:7d50\:7dda\:3059\:308b (spec \:30ad\:30fc: \"LLM\",\"SourceVaultIngest\",\"MailFetch\")\:3002\:5f15\:6570\:7701\:7565\:6642\:306f\:5404 connector \:306e\:73fe\:5728\:306e\:5229\:7528\:53ef\:5426\:3092\:8fd4\:3059\:3002\:5b9f provider \:306f claudecode.wl / SourceVault.wl \:30ed\:30fc\:30c9\:6642\:306b Automatic \:7d4c\:7531\:3067\:81ea\:52d5\:5229\:7528\:3055\:308c\:308b\:3002";

ClaudeActivateExternalExecutor::usage =
  "ClaudeActivateExternalExecutor[opts] \:306f External executor \:3092 live \:7a3c\:50cd\:3055\:305b\:308b: launcher/killer \:7d50\:7dda (ClaudeWireExternalRunner)\:3001ClaudeExternalJobPollTick \:3092\:5171\:6709 polling tick (ClaudeCode`ClaudeRegisterPollingTick) \:3078\:767b\:9332\:3001\:5b8c\:4e86 hook \:3092\:8a2d\:5b9a\:3057 job \:5b8c\:4e86\:6642\:306b summary final action \:3092 FinalActionQueue \:3078 enqueue\:3002\:8fd4\:308a\:5024\:306f\:7d50\:7dda\:72b6\:6cc1\:3002";
ClaudeDeactivateExternalExecutor::usage =
  "ClaudeDeactivateExternalExecutor[] \:306f poll tick \:767b\:9332\:89e3\:9664\:3068\:5b8c\:4e86 hook \:30af\:30ea\:30a2\:3092\:884c\:3046\:3002";
$ClaudeExternalFinalActionEnqueue::usage =
  "$ClaudeExternalFinalActionEnqueue \:306f\:5b8c\:4e86 final action \:3092 enqueue \:3059\:308b\:95a2\:6570 (fn[action, accessSpec])\:3002Automatic \:306f ClaudeCode`ClaudeEnqueueFinalAction (\:30ed\:30fc\:30c9\:6642)\:3002\:30c6\:30b9\:30c8\:3067 mock \:6ce8\:5165\:53ef\:3002";
$ClaudeExternalPollTickKey::usage =
  "$ClaudeExternalPollTickKey \:306f\:5171\:6709 polling tick \:3078\:306e\:767b\:9332 key (\:65e2\:5b9a \"external-job-poll\")\:3002";

ClaudeExternalJobSummary::usage =
  "ClaudeExternalJobSummary[output, completion] \:306f\:5916\:90e8\:30b8\:30e7\:30d6\:51fa\:529b\:306e summary (Head/ByteCount/OutputRef/Preview) \:3092\:8fd4\:3059\:3002\:30b5\:30a4\:30ba\:304c $ClaudeExternalInlineLimit \:8d85\:306a\:3089 Preview \:3092\:7701\:304f (v7 \[Section]6/\[Section]10.2: \:5de8\:5927\:51fa\:529b\:3092 inline \:3057\:306a\:3044)\:3002";

ClaudeExternalJobFinalAction::usage =
  "ClaudeExternalJobFinalAction[completion] \:306f\:5b8c\:4e86 payload \:306e OutputRef \:3092\:89e3\:6c7a\:3057\:3001Notebook \:3078\:53cd\:6620\:3059\:308b final action (WriteNotebookCell, summary \:306e\:307f) \:3092\:69cb\:7bc9\:3057\:3066\:8fd4\:3059\:3002\:672c\:4f53\:306f inline \:305b\:305a\:3001\:53cd\:6620\:306f FinalActionQueue / \:627f\:8a8d\:7d4c\:7531 (single committer)\:3002<|\"Status\"->_, \"FinalAction\"->_|>\:3002";

ClaudeExternalInlineAllowedQ::usage =
  "ClaudeExternalInlineAllowedQ[bytes] \:306f\:51fa\:529b\:3092 Notebook \:3078 inline \:3057\:3066\:3088\:3044\:30b5\:30a4\:30ba\:304b ($ClaudeExternalInlineLimit \:4ee5\:4e0b\:304b) \:3092\:8fd4\:3059\:3002Unknown \:306f\:5b89\:5168\:5074 False\:3002";

$ClaudeExternalInlineLimit::usage =
  "$ClaudeExternalInlineLimit \:306f Notebook \:3078 inline \:3067\:304d\:308b\:51fa\:529b ByteCount \:306e\:4e0a\:9650 (\:65e2\:5b9a 64KB)\:3002\:8d85\:904e\:6642\:306f ref/summary \:306e\:307f\:3002";

$ClaudeWolframScriptExecutable::usage =
  "$ClaudeWolframScriptExecutable \:306f wolframscript \:5b9f\:884c\:30d5\:30a1\:30a4\:30eb\:306e\:660e\:793a\:30d1\:30b9 (\:672a\:8a2d\:5b9a\:306a\:3089\:81ea\:52d5\:89e3\:6c7a)\:3002";

$ClaudeExternalJobRoot::usage =
  "$ClaudeExternalJobRoot \:306f External job \:306e durable root \:306e\:660e\:793a\:30d1\:30b9 (\:672a\:8a2d\:5b9a\:306a\:3089 $UserBaseDirectory/ClaudeRuntime/jobs)\:3002";

Begin["`Private`"];

If[! ValueQ[$ClaudeWolframScriptExecutable], $ClaudeWolframScriptExecutable = Automatic];
If[! ValueQ[$ClaudeExternalJobRoot],         $ClaudeExternalJobRoot = Automatic];

(* \:8d77\:52d5\:6e08\:307f ProcessObject \:306e registry (\:89aa\:30d7\:30ed\:30bb\:30b9\:5185\:3001jobId -> proc)\:3002
   cross-restart \:3067\:306f\:5931\:308f\:308c\:308b (Phase 4.B \:3067 pid.txt taskkill)\:3002 *)
If[! AssociationQ[$iExternalProcs], $iExternalProcs = <||>];

(* hardening 05 Inc1 (2026-07-07): SIEM emit 委譲。
   claudecode.wl の per-process spool shim (ClaudeCode`Private`iClaudeDiagEmit)
   へ Producer 上書きで委譲する。本番は claudecode.wl が先にロードされる前提
   (ClaudeRuntime.wl 冒頭の依存注記と同じ)。standalone ロード (子 runner /
   スタブテスト) では定義が無いので no-op。emit 失敗は握り潰してよい
   (spec 05 §3.1: 無限再帰防止)。 *)
iCRDiagEmit[class_String, payload_Association, severity_String: "warn"] :=
  Quiet @ Check[
    If[Length[DownValues[ClaudeCode`Private`iClaudeDiagEmit]] > 0,
      ClaudeCode`Private`iClaudeDiagEmit[class, payload, severity,
        "Producer" -> "ClaudeRuntime"]];
    Null,
    Null];

(* hardening 01 Inc2 (2026-07-07): 席 token registry (jobId -> token)。
   Acquire は launcher、Release は 完了 hook (iExternalReflectCompletion) /
   killer / spawn 失敗の 3 経路。poll tick 停止等で release が漏れても
   TTL (1800s) 失効で SeatBroker reaper が回収する (SeatLeaked が痕跡)。
   本格的なライフサイクル管理は ProcessSupervisor (03) が引き継ぐ。 *)
If[! AssociationQ[$iExternalSeatTokens], $iExternalSeatTokens = <||>];

iERSeatRelease[jobId_] := Module[{tok = Lookup[$iExternalSeatTokens, jobId, None]},
  If[StringQ[tok] && Length[DownValues[ClaudeSeatRelease]] > 0,
    Quiet @ ClaudeSeatRelease[tok]];
  KeyDropFrom[$iExternalSeatTokens, jobId];
  Null];

(* \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] wolframscript \:89e3\:6c7a \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] *)
ClaudeResolveWolframScriptExecutable[] :=
  Module[{cands, exe},
    cands = {
      If[StringQ[$ClaudeWolframScriptExecutable], $ClaudeWolframScriptExecutable, Nothing],
      With[{e = Environment["WOLFRAMSCRIPT"]}, If[StringQ[e], e, Nothing]],
      FileNameJoin[{$InstallationDirectory, "wolframscript.exe"}],
      FileNameJoin[{$InstallationDirectory, "wolframscript"}]
    };
    exe = SelectFirst[cands, StringQ[#] && FileExistsQ[#] &, Missing[]];
    (* \:898b\:3064\:304b\:3089\:306a\:3051\:308c\:3070 PATH \:4e0a\:306e bare \:540d\:306b\:59d4\:306d\:308b *)
    If[MissingQ[exe], "wolframscript", exe]
  ];

(* \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] durable job root \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] *)
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

(* forward-slash \:5316 (Windows path \:3092 script \:6587\:5b57\:5217\:3078\:5b89\:5168\:306b\:57cb\:3081\:8fbc\:3080) *)
iFwd[p_String] := StringReplace[p, "\\" -> "/"];

(* atomic JSON write: tmp \:3078\:66f8\:3044\:3066 rename *)
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

(* \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550
   Phase 4.B: \:6a5f\:5bc6 input/output \:306e\:5b9f\:6697\:53f7\:5316 (SourceVault crypto \:7d4c\:7531)
   - ConfidentialHandling=="EncryptedBundle" \:306e\:30b8\:30e7\:30d6\:3060\:3051\:6697\:53f7\:5316\:3059\:308b\:3002
   - \:6697\:53f7\:5316\:306f SourceVault`SourceVaultSealPayload / UnsealPayload \:306b\:59d4\:8b72\:3057\:3001
     \:9375\:306f NBAccess credential store \:306b\:9589\:3058\:308b (\:9375\:6750\:6599\:306f runtime \:306b\:51fa\:306a\:3044)\:3002
   - cross-process \:3067\:306f Memory backend \:306f\:5171\:6709\:3055\:308c\:306a\:3044\:305f\:3081 SystemCredential \:3092\:5fc5\:9808\:306b\:3059\:308b\:3002
   - \:6a5f\:5bc6\:30b8\:30e7\:30d6\:3067\:6697\:53f7\:5316\:3067\:304d\:306a\:3044\:5834\:5408\:306f fail-closed (\:5e73\:6587\:3092\:66f8\:304b\:306a\:3044)\:3002
   \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550 *)

iConfidentialJobQ[manifest_Association] :=
  Lookup[manifest, "ConfidentialHandling", "ReferenceOnly"] === "EncryptedBundle";
iConfidentialJobQ[_] := False;

iSVCryptoReadyQ[] := TrueQ[Quiet @ Check[
  Length[DownValues[SourceVault`SourceVaultSealPayload]] > 0 &&
  Length[DownValues[SourceVault`SourceVaultUnsealPayload]] > 0, False]];

iSVBackend[] := Quiet @ Check[NBAccess`$NBCredentialBackend, "Memory"];

iEncryptedRecordQ[x_] :=
  TrueQ[Quiet @ Check[SourceVault`SourceVaultEncryptedRecordQ[x], False]];

(* \:89aa\:5074: \:6a5f\:5bc6\:30b8\:30e7\:30d6\:306e\:6697\:53f7\:5316\:524d\:63d0\:3092\:6e80\:305f\:3059\:304b\:78ba\:8a8d\:3057\:3001\:6b20\:843d\:9375\:3092 bootstrap \:3059\:308b\:3002 *)
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

(* expr -> \:5c01\:5370 record (\:5931\:6557\:6642 $Failed)\:3002store \:306b\:306f\:6b8b\:3055\:306a\:3044\:3002 *)
iSealForJob[expr_] := Module[{r},
  r = Quiet @ Check[SourceVault`SourceVaultSealPayload[expr], $Failed];
  If[AssociationQ[r] && Lookup[r, "Status", ""] === "Stored", r["Record"], $Failed]];

(* \:5c01\:5370 record -> expr (\:5931\:6557\:30fb\:6539\:3056\:3093\:6642 $Failed; plaintext \:306f\:8fd4\:3089\:306a\:3044) *)
iUnsealFromJob[record_] := Module[{r},
  r = Quiet @ Check[SourceVault`SourceVaultUnsealPayload[record], $Failed];
  If[AssociationQ[r] && Lookup[r, "Status", ""] === "Ok", r["Payload"], $Failed]];

(* error.txt \:7528: \:6a5f\:5bc6\:30b8\:30e7\:30d6\:3067\:306f result \:672c\:6587\:3092\:5410\:304b\:305a redact \:3059\:308b (log \:6f0f\:6d29\:9632\:6b62) *)
iSafeErrorText[result_, manifest_Association] :=
  If[iConfidentialJobQ[manifest],
    "HandlerFailed (confidential job; details redacted)",
    ToString[result]];

(* \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] handler registry \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] *)
If[! AssociationQ[$iExtHandlers], $iExtHandlers = <||>];

ClaudeRegisterExternalTaskHandler[name_String, fn_, opts_:<||>] :=
  ($iExtHandlers[name] = <|"Fn" -> fn, "Options" -> opts|>; name);

(* \:30c6\:30b9\:30c8/\:758e\:901a\:7528\:306e\:7d44\:8fbc\:30cf\:30f3\:30c9\:30e9: \:5165\:529b\:3092\:305d\:306e\:307e\:307e\:7d50\:679c\:306b echo *)
ClaudeRegisterExternalTaskHandler["Echo",
  Function[ctx, <|"Status" -> "OK", "Result" -> Lookup[ctx, "Input", None]|>],
  <|"Backend" -> "WolframScript"|>];

(* Phase 4.B \:758e\:901a\:7528: cooperative I/O guard (NBCheckedFileWrite) \:3092\:901a\:3057\:3066\:66f8\:304d\:8fbc\:3080\:3002
   ctx["Input"]["Target"] \:3078\:306e\:66f8\:8fbc\:304c AccessSpec scope \:5185\:306a\:3089\:6210\:529f\:3001scope \:5916\:306a\:3089
   AccessSpecViolation \:3067 Failed\:3002 *)
(* NOTE: handler \:672c\:4f53\:306f\:5fc5\:305a DownValue \:95a2\:6570\:306b\:3059\:308b\:3002pure Function \:306e body \:3067\:306f
   Return[..] \:304c\:5438\:53ce\:3055\:308c\:305a (Module \:3082\:5438\:53ce\:3057\:306a\:3044)\:3001Return[assoc] \:304c\:751f\:5024\:306e\:307e\:307e
   handler \:306e\:623b\:308a\:5024\:306b\:6f0f\:308c\:308b (2026-07-09 \:767a\:898b\:306e\:6f5c\:5728\:30d0\:30b0; runner \:306e
   !AssociationQ \:5224\:5b9a\:306b\:62fe\:308f\:308c\:3066\:5b9f\:5bb3\:304c\:96a0\:308c\:3066\:3044\:305f)\:3002 *)
iExtGuardedWriteRun[ctx_Association] :=
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
  ];
iExtGuardedWriteRun[_] := <|"Status" -> "Failed", "Reason" -> "BadContext"|>;

ClaudeRegisterExternalTaskHandler["GuardedWrite",
  iExtGuardedWriteRun,
  <|"Backend" -> "WolframScript"|>];

(* \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550
   ApprovedHeldExpr handler (2026-06-12, ClaudeEval external dispatch)
   main \:5074\:3067 NBAccess \:691c\:8a3c\:30fb(\:5fc5\:8981\:306a\:3089) \:30e6\:30fc\:30b6\:30fc\:627f\:8a8d\:6e08\:307f\:306e held expr \:3092
   \:5b50\:30d7\:30ed\:30bb\:30b9\:3067\:5b9f\:884c\:3059\:308b\:3002\:5bfe\:8c61\:306f\:5f15\:6570\:3060\:3051\:3067\:5b8c\:7d50\:3059\:308b\:5ba3\:8a00\:7684\:30d0\:30c3\:30c1 head
   (\:4f8b: SourceVaultEagleSummarizeBatch)\:3002head \:306f AllowedHeads \:3067\:518d\:691c\:8a3c\:3059\:308b
   (defense in depth)\:3002\:8a2d\:8a08: \:30c9\:30ad\:30e5\:30e1\:30f3\:30c8/ClaudeEval_external_dispatch_design.md
   \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550 *)

If[! IntegerQ[$ClaudeExternalHeldExprResultLimit],
  $ClaudeExternalHeldExprResultLimit = 1024*1024];

(* HoldComplete[h[...]] / HoldComplete[h] \:306e head \:540d (\:975e\:8a55\:4fa1\:3067\:53d6\:5f97) *)
iHeldExprHeadName[held_HoldComplete] :=
  Replace[held, {
    HoldComplete[(h_Symbol)[___]] :> SymbolName[Unevaluated[h]],
    HoldComplete[h_Symbol]        :> SymbolName[Unevaluated[h]],
    _ :> $Failed}];
iHeldExprHeadName[_] := $Failed;

(* head \:306b\:5b9a\:7fa9 (DownValues \:7b49) \:304c\:3042\:308b\:304b\:3002Bootstrap \:6f0f\:308c\:306e\:8a3a\:65ad\:7528\:3002 *)
iHeldHeadDefinedQ[held_HoldComplete] :=
  TrueQ @ Replace[held, {
    HoldComplete[(h_Symbol)[___]] :>
      (Length[DownValues[h]] > 0 || Length[SubValues[h]] > 0 ||
       Length[OwnValues[h]] > 0),
    HoldComplete[h_Symbol] :> (Length[OwnValues[h]] > 0),
    _ :> False}];
iHeldHeadDefinedQ[_] := False;

(* binding \:5f62 (place -> token | {token..}) \:304b\:3089\:6700\:521d\:306e "HeldExpr" \:5165\:308a Payload \:3092\:63a2\:3059\:3002
   Input \:304c\:76f4\:63a5 payload \:5f62 (<|"HeldExpr"->..|>) \:306e\:5834\:5408\:306b\:3082\:5bfe\:5fdc\:3002 *)
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

(* handler \:672c\:4f53\:306f DownValue \:95a2\:6570 (Function body \:3060\:3068 Return[..] \:304c\:751f\:5024\:6f0f\:308c\:3059\:308b;
   GuardedWrite \:306e\:6ce8\:8a18\:53c2\:7167)\:3002 *)
iExtApprovedHeldExprRun[ctx_Association] :=
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
          " (BootstrapFiles \:306e\:30ed\:30fc\:30c9\:6f0f\:308c/\:5931\:6557\:3092\:78ba\:8a8d)"|>]];
    (* Quiet + CheckAbort (NOT Check): a benign message during the body must
       not be misread as failure -- genuine failure is detected by the RESULT
       shape instead (same rationale as the autotrigger main-kernel executor).
       Real incident 2026-07-08 (rapterlake4t): one transient un-quieted
       message during Dropbox congestion turned a fully successful CUDA run
       into "ExecutionError", discarding its valid return value. *)
    result = Quiet @ CheckAbort[
      TimeConstrained[ReleaseHold[held], tc, $TimedOut], $Aborted];
    Which[
      result === $TimedOut,
        <|"Status" -> "Failed",
          "Reason" -> "ExecutionTimedOut:" <> ToString[tc] <> "s"|>,
      MatchQ[result, $Failed | $Aborted],
        <|"Status" -> "Failed", "Reason" -> "ExecutionError"|>,
      True,
        bytes = Quiet @ Check[ByteCount[result], 0];
        If[IntegerQ[bytes] && bytes > $ClaudeExternalHeldExprResultLimit,
          (* \:5de8\:5927\:7d50\:679c\:306f output.wxf \:80a5\:5927\:9632\:6b62\:306e\:305f\:3081\:8981\:7d04\:306b\:7f6e\:63db (v7 \[Section]10.2) *)
          <|"Status" -> "OK", "Result" -> <|
            "Head" -> ToString[Head[result]], "ByteCount" -> bytes,
            "Short" -> Quiet @ Check[ToString[Short[result, 10]], "?"],
            "Truncated" -> True|>|>,
          <|"Status" -> "OK", "Result" -> result|>]
    ]
  ];
iExtApprovedHeldExprRun[_] := <|"Status" -> "Failed", "Reason" -> "BadContext"|>;

ClaudeRegisterExternalTaskHandler["ApprovedHeldExpr",
  iExtApprovedHeldExprRun,
  <|"Backend" -> "WolframScript"|>];

(* \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] handler lint (raw I/O \:76f4\:66f8\:304d\:691c\:51fa) \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] *)
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

(* \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550
   Phase 5: checkpointable batch handler \:30a8\:30f3\:30b8\:30f3
   v7 \[Section]7.5/\[Section]9.3: checkpoint-aware retry\:3002\:540c\:4e00 JobDir \:3067 resume \:3057\:3001
   \:5b8c\:4e86\:6e08\:307f item \:306f\:518d\:51e6\:7406\:3057\:306a\:3044 (\:975e\:51aa\:7b49 task \:306e\:4e8c\:91cd\:5b9f\:884c\:3092\:9632\:3050)\:3002
   per-item \:51e6\:7406\:306f handler \:7a2e\:5225\:3054\:3068\:306e processor (\:5dee\:3057\:66ff\:3048\:53ef\:80fd\:30d5\:30c3\:30af)\:3002
   \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550 *)

If[! AssociationQ[$ClaudeBatchProcessorOverrides], $ClaudeBatchProcessorOverrides = <||>];

iCheckpointDir[jobDir_]  := FileNameJoin[{jobDir, "checkpoint"}];
iCheckpointFile[jobDir_] := FileNameJoin[{iCheckpointDir[jobDir], "state.wxf"}];
iCheckpointSave[jobDir_, state_] := (
  Quiet @ CreateDirectory[iCheckpointDir[jobDir], CreateIntermediateDirectories -> True];
  Quiet @ Export[iCheckpointFile[jobDir], state, "WXF"]);
iCheckpointLoad[jobDir_] :=
  If[FileExistsQ[iCheckpointFile[jobDir]],
    Quiet @ Check[Import[iCheckpointFile[jobDir], "WXF"], <||>], <||>];

(* batch \:306e item \:53d6\:5f97: ctx Input["Items"] (\:30ea\:30b9\:30c8) \:307e\:305f\:306f ["ItemsRef"] (file, NBChecked) *)
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

(* \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] \:5b9f provider connector (seam: \:6ce8\:5165\:53ef / Automatic \:306f\:65e2\:5b58 vetted \:95a2\:6570\:3078) \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] *)
If[! ValueQ[$ClaudeLLMConnector],                $ClaudeLLMConnector = Automatic];
If[! ValueQ[$ClaudeSourceVaultIngestConnector],  $ClaudeSourceVaultIngestConnector = Automatic];
If[! ValueQ[$ClaudeMailFetchConnector],          $ClaudeMailFetchConnector = Automatic];

(* Automatic \:306f\:5b9f\:95a2\:6570 (full context) \:304c\:5b9a\:7fa9\:6e08\:307f\:306a\:3089\:63a1\:7528\:3001\:672a\:30ed\:30fc\:30c9\:306a\:3089 None\:3002
   \:5b9f HTTP/IMAP/\:6697\:53f7\:306f\:65e2\:5b58\:95a2\:6570\:306b\:59d4\:8b72 (\:518d\:767a\:660e\:3057\:306a\:3044\:30fb\:9375\:306f\:5404\:95a2\:6570\:304c NBGetAPIKey \:3067\:6271\:3046)\:3002 *)
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

(* \:65e2\:5b9a processor\:3002BulkFileProcessing \:306f echo (\:7d14\:30d5\:30a1\:30a4\:30eb\:51e6\:7406\:306e\:96db\:5f62)\:3002
   provider \:7cfb\:306f connector \:3078\:59d4\:8b72\:3057\:3001\:672a\:5229\:7528\:6642\:306f graceful fail\:3002 *)
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
          (* mbox \:672a\:6307\:5b9a\:3067\:5b9f\:30e1\:30fc\:30eb\:53d6\:5f97\:3092\:8d70\:3089\:305b\:306a\:3044 (fast-fail) *)
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

(* credential descriptor \:3092\:89e3\:6c7a (secret \:306f\:6301\:3061\:56de\:3055\:306a\:3044)\:3002\:975e\:81f4\:547d: \:5931\:6557\:306f\:8a18\:9332\:306e\:307f\:3002 *)
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
    (* credential descriptor \:3092 ctx \:3078 (handler/processor \:304c NBGetAPIKey \:306b\:4f7f\:3046) *)
    ctx2 = Append[ctx, "Credentials" -> iResolveBatchCredentials[ctx]];

    (* checkpoint \:304b\:3089 resume *)
    cp      = iCheckpointLoad[jobDir];
    done    = Lookup[cp, "Done", {}];
    results = Lookup[cp, "Results", <||>];

    (* \:6ce8: Return[] \:306f Do \:5185\:3067\:306f Module \:3092\:629c\:3051\:306a\:3044\:305f\:3081\:3001flag + Break \:3092\:4f7f\:3046 *)
    Do[
      If[MemberQ[done, i], Continue[]];   (* \:5b8c\:4e86\:6e08\:307f\:306f\:518d\:51e6\:7406\:3057\:306a\:3044 *)
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

(* 4 \:7a2e\:306e batch handler \:3092\:767b\:9332 (item \:51e6\:7406\:306f processor \:30d5\:30c3\:30af\:5dee\:3057\:66ff\:3048\:3067\:5207\:66ff) *)
Scan[
  Function[nm,
    ClaudeRegisterExternalTaskHandler[nm,
      With[{name = nm}, Function[ctx, iRunBatchHandler[ctx, name]]],
      <|"Backend" -> "WolframScript", "Checkpointable" -> True|>]],
  {"BulkFileProcessing", "BulkLLMProcessing", "MailFetch", "SourceVaultIngest"}];

(* \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550
   Phase 6: final action \:69cb\:7bc9
   \:5916\:90e8\:30b8\:30e7\:30d6\:5b8c\:4e86 payload \:306e OutputRef \:3092\:89e3\:6c7a\:3057\:3001Notebook \:3078\:53cd\:6620\:3059\:308b
   final action (WriteNotebookCell, summary \:306e\:307f) \:3092\:4f5c\:308b\:3002\:672c\:4f53\:306f inline \:305b\:305a\:3001
   \:53cd\:6620\:306f FinalActionQueue / \:627f\:8a8d\:7d4c\:7531 (single committer)\:3002v7 \[Section]6/\[Section]10.2/\[Section]15.6\:3002
   \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550 *)

If[! IntegerQ[$ClaudeExternalInlineLimit], $ClaudeExternalInlineLimit = 64*1024];

ClaudeExternalInlineAllowedQ[b_Integer] := b <= $ClaudeExternalInlineLimit;
ClaudeExternalInlineAllowedQ[_] := False;   (* Unknown \:306f\:5b89\:5168\:5074\:3067 inline \:3057\:306a\:3044 *)

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
      "(\:51fa\:529b\:304c\:5927\:304d\:3044\:305f\:3081 inline \:305b\:305a: ref/summary \:306e\:307f)"]
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
    (* \:6a5f\:5bc6\:30b8\:30e7\:30d6\:306e output.wxf \:306f\:5c01\:5370 record\:3002\:5fa9\:53f7\:3057\:3066\:672c\:4f53\:3092\:53d6\:308a\:51fa\:3059
       (\:6539\:3056\:3093\:30fbwrong key \:306a\:3089 $Failed = OutputUnreadable \:306b\:5012\:3059)\:3002 *)
    If[output =!= $Failed && iEncryptedRecordQ[output],
      output = iUnsealFromJob[output]];
    If[output === $Failed,
      Return[<|"Status" -> "Failed", "Reason" -> "OutputUnreadable", "Path" -> path|>]];
    summary = ClaudeExternalJobSummary[output, completion];
    text    = iFormatExternalSummary[summary];
    (* WriteNotebookCell action: NBAccess \:306e final action \:7d4c\:7531\:3067\:627f\:8a8d\:30fbcommit \:3055\:308c\:308b\:3002
       Cell \:306b\:306f summary \:306e\:307f (\:5de8\:5927\:672c\:4f53\:306f inline \:3057\:306a\:3044)\:3002
       \:305f\:3060\:3057\:6295\:5165\:5143\:304c "ResultRetriever" (\:7d50\:679c\:53d6\:5f97\:95a2\:6570\:540d) \:3092\:6307\:5b9a\:3057\:3066\:3044\:308c\:3070\:3001summary \:3092
       \:30b3\:30e1\:30f3\:30c8\:306b\:542b\:3080\:300c\:8a55\:4fa1\:53ef\:80fd\:306a Input \:30bb\:30eb\:300d\:3092\:66f8\:304f: \:5229\:7528\:8005\:306f\:305d\:306e\:30bb\:30eb\:3092\:8a55\:4fa1\:3059\:308b\:3060\:3051\:3067
       \:7d50\:679c (<retriever>["<jobId>"]) \:3092\:53d6\:308a\:51fa\:305b\:308b (\:81ea\:52d5\:8a55\:4fa1\:306f\:3057\:306a\:3044 = \:627f\:8a8d/\:624b\:52d5\:8a55\:4fa1)\:3002 *)
    Module[{fa, retriever, jobId, cellExpr},
      retriever = Lookup[completion, "ResultRetriever", None];
      jobId     = ToString @ Lookup[completion, "JobID", "?"];
      cellExpr = If[StringQ[retriever] && retriever =!= "" && jobId =!= "?",
        Cell[
          "(* External job " <> jobId <> " Completed - evaluate to view the result *)\n" <>
            retriever <> "[\"" <> jobId <> "\"]",
          "Input"],
        Cell[text, "Text"]];
      fa = <|
        "Action"           -> "WriteNotebookCell",
        "Cell"             -> cellExpr,
        "Source"           -> "ExternalJob",
        "JobID"            -> jobId,
        "RequiresFinalNode"-> True,
        "Summary"          -> summary|>;
      (* 2026-06-12: \:767a\:884c\:5143 notebook \:304c\:5206\:304b\:308b\:5834\:5408\:306f summary \:3092\:305d\:3053\:3078\:66f8\:304f
         (iNBExecuteWriteNotebookCell \:304c TargetNotebook \:3092\:89e3\:6c7a\:3002\:7121\:3051\:308c\:3070 CellPrint)\:3002 *)
      If[MatchQ[Lookup[completion, "TargetNotebook", None], _NotebookObject],
        fa["TargetNotebook"] = completion["TargetNotebook"]];
      <|"Status" -> "OK", "FinalAction" -> fa|>]
  ];

(* \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] runner entrypoint (\:5b50\:30d7\:30ed\:30bb\:30b9\:3067\:5b9f\:884c) \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] *)
ClaudeRunTaskFromManifest[jobDir_String] :=
  Module[{manifest, handlerName, reg, fn, inputData, inputFile, result,
          outFile, ok, accessSpec, snap, snapApplied, confJob, decIn,
          sealedOut, outputEncrypted = False},
    (* 1. manifest \:8aad\:307f\:8fbc\:307f *)
    manifest = Quiet @ Check[Get[FileNameJoin[{jobDir, "manifest.wl"}]], $Failed];
    If[! AssociationQ[manifest],
      iWriteStatus[jobDir, <|"Status" -> "Failed", "ErrorRef" -> "ManifestUnreadable"|>];
      Return[<|"Status" -> "Failed", "Reason" -> "ManifestUnreadable"|>]];

    (* 1b. AccessSpec \:3092\:53d6\:308a\:51fa\:3057\:3001PolicySnapshot \:304c\:3042\:308c\:3070 per-call \:9069\:7528 (digest \:691c\:8a3c)\:3002
       NBAccess \:672a\:30ed\:30fc\:30c9\:306a\:3089\:691c\:8a3c\:306f\:30b9\:30ad\:30c3\:30d7 (Phase 4.A \:4e92\:63db)\:3002AccessSpec \:306f handler
       ctx \:3078\:6e21\:3057\:3001handler \:306f NBCheck* / NBChecked* \:3092\:901a\:3057\:3066 I/O \:3059\:308b (cooperative)\:3002 *)
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

    (* 2. handler \:89e3\:6c7a *)
    handlerName = Lookup[manifest, "Handler", Missing[]];
    reg = Lookup[$iExtHandlers, handlerName, None];
    If[! AssociationQ[reg],
      iWriteStatus[jobDir, <|"Status" -> "Failed",
        "ErrorRef" -> "UnknownHandler:" <> ToString[handlerName]|>];
      Return[<|"Status" -> "Failed", "Reason" -> "UnknownHandler"|>]];
    fn = reg["Fn"];

    (* 3. input \:8aad\:307f\:8fbc\:307f (input.wxf, \:7121\:3051\:308c\:3070 None)\:3002\:5c01\:5370 record \:306a\:3089\:5fa9\:53f7\:3059\:308b\:3002 *)
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

    (* 4. handler \:5b9f\:884c (ctx \:306b AccessSpec \:3092\:6e21\:3059\:3002handler \:306f NBChecked* \:3067 I/O \:3059\:308b)
       Quiet + CheckAbort (NOT Check): handler \:5185\:306e\:826f\:6027\:30e1\:30c3\:30bb\:30fc\:30b8\:3092\:5931\:6557\:3068
       \:8aa4\:8aad\:3057\:306a\:3044\:3002\:771f\:306e\:5931\:6557\:306f\:76f4\:5f8c\:306e result \:5f62\:72b6\:5224\:5b9a\:304c\:62fe\:3046
       (ApprovedHeldExpr \:5074\:306e\:4fee\:6b63\:3068\:5bfe; 2026-07-08 rapterlake4t \:5b9f\:6a5f)\:3002 *)
    result = Quiet @ CheckAbort[
      fn[<|"Manifest" -> manifest, "Input" -> inputData, "JobDir" -> jobDir,
           "AccessSpec" -> accessSpec|>],
      $Failed];

    If[result === $Failed || ! AssociationQ[result] ||
       Lookup[result, "Status", "OK"] === "Failed",
      iWriteStatus[jobDir, <|"Status" -> "Failed",
        "JobID" -> Lookup[manifest, "JobID", "?"],
        "ErrorRef" -> "error.txt"|>];
      (* \:6a5f\:5bc6\:30b8\:30e7\:30d6\:3067\:306f result \:672c\:6587\:3092 error.txt \:306b\:5410\:304b\:306a\:3044 (log \:6f0f\:6d29\:9632\:6b62) *)
      Quiet @ Export[FileNameJoin[{jobDir, "error.txt"}],
        iSafeErrorText[result, manifest], "Text"];
      iAppendProgress[jobDir, <|"Event" -> "Failed", "At" -> UnixTime[]|>];
      Return[<|"Status" -> "Failed", "Reason" -> "HandlerFailed"|>]];

    (* 5. output \:66f8\:304d\:51fa\:3057 (output.wxf) + status Completed\:3002
       \:6a5f\:5bc6\:30b8\:30e7\:30d6\:306f\:7d50\:679c\:3092\:5c01\:5370\:3057\:3066\:304b\:3089\:66f8\:304f\:3002\:6697\:53f7\:5316\:3067\:304d\:306a\:3051\:308c\:3070 fail-closed
       (\:6a5f\:5bc6 output \:3092\:5e73\:6587\:3067\:6b8b\:3055\:306a\:3044)\:3002 *)
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

(* \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] job \:6e96\:5099 (dir / input / manifest / run.wls) \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] *)
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

    (* Resume (retry) \:30b8\:30e7\:30d6: \:65e2\:5b58 manifest \:3092\:6b20\:843d field \:306e fallback \:306b\:4f7f\:3046\:3002
       (retry jobSpec \:306f Binding / AccessSpec \:7b49\:3092\:6301\:305f\:306a\:3044: workflow.wl iExternalRetry) *)
    resumeJob = TrueQ[Lookup[jobSpec, "Resume", False]];
    oldManifest = If[resumeJob,
      Quiet @ Check[Get[FileNameJoin[{jobDir, "manifest.wl"}]], <||>], <||>];
    If[! AssociationQ[oldManifest], oldManifest = <||>];

    handler = Lookup[jobSpec, "Handler",
      Lookup[oldManifest, "Handler", Missing[]]];
    timeout = Lookup[jobSpec, "Timeout",
      Lookup[oldManifest, "Timeout", 3600]];

    (* BootstrapFiles (2026-06-12): \:5b50\:30d7\:30ed\:30bb\:30b9\:304c handler \:5b9f\:884c\:524d\:306b\:30ed\:30fc\:30c9\:3059\:308b
       \:30d1\:30c3\:30b1\:30fc\:30b8\:7fa4\:3002bare \:540d\:306f\:30d1\:30c3\:30b1\:30fc\:30b8\:30c7\:30a3\:30ec\:30af\:30c8\:30ea (runner \:3068\:540c\:3058\:5834\:6240) \:57fa\:6e96\:3067
       \:7d76\:5bfe\:5316\:3059\:308b (\:4f8b: ApprovedHeldExpr handler \:304c SourceVault \:30b9\:30bf\:30c3\:30af\:3092\:8981\:3059\:308b\:5834\:5408)\:3002
       \:8a2d\:8a08: \:30c9\:30ad\:30e5\:30e1\:30f3\:30c8/ClaudeEval_external_dispatch_design.md *)
    bootFiles = Lookup[jobSpec, "BootstrapFiles",
      Lookup[oldManifest, "BootstrapFiles", {}]];
    If[! ListQ[bootFiles], bootFiles = {}];
    bootFiles = Select[
      Map[Function[f, Which[
        ! StringQ[f], "",
        iAbsPathQ[f], f,
        True, FileNameJoin[{DirectoryName[runnerFile], f}]]], bootFiles],
      StringQ[#] && # =!= "" && FileExistsQ[#] &];

    (* input.wxf: jobSpec \:306e "Input" \:3092\:512a\:5148\:3001\:7121\:3051\:308c\:3070 Binding\:3002
       ConfidentialHandling=="EncryptedBundle" \:306e\:3068\:304d\:306f SourceVault crypto \:3067\:5b9f\:6697\:53f7\:5316\:3057\:3001
       \:5e73\:6587\:3092 job dir \:3078\:66f8\:304b\:306a\:3044 (Phase 4.B)\:3002\:975e\:6a5f\:5bc6\:30b8\:30e7\:30d6\:306f\:5f93\:6765\:3069\:304a\:308a\:5e73\:6587 WXF\:3002 *)
    inputData = Lookup[jobSpec, "Input", Lookup[jobSpec, "Binding", <||>]];
    confidentialJob =
      Lookup[jobSpec, "ConfidentialHandling",
        Lookup[oldManifest, "ConfidentialHandling", "ReferenceOnly"]] ===
      "EncryptedBundle";
    Which[
      (* 2026-06-12 fix: Resume \:6642\:306f\:65e2\:5b58 input.wxf \:3092\:4e0a\:66f8\:304d\:3057\:306a\:3044\:3002
         retry \:306e jobSpec \:306f Binding \:3092\:6301\:305f\:306a\:3044\:305f\:3081\:3001\:5f93\:6765\:306f input \:304c <||> \:306b
         \:6f70\:308c\:3066 checkpoint resume \:304c\:5165\:529b\:3092\:5931\:3063\:3066\:3044\:305f\:3002 *)
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

    (* manifest.wl (credential \:672c\:4f53 / \:6a5f\:5bc6\:672c\:6587\:306f\:5165\:308c\:306a\:3044; AccessSpec / CredentialRefs
       \:306f\:53c2\:7167\:306e\:307f\:3002PolicySnapshot \:306f AccessSpec \:914d\:4e0b\:306b\:542b\:307e\:308c\:308b) *)
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

    (* run.wls bootstrap: runner package \:3092 Get \:3057\:3066 entrypoint \:3092\:547c\:3076\:3002
       \:6a5f\:5bc6\:30b8\:30e7\:30d6\:3067\:306f\:3001\:5b50\:30d7\:30ed\:30bb\:30b9\:304c input/output \:3092\:5fa9\:53f7/\:6697\:53f7\:5316\:3067\:304d\:308b\:3088\:3046
       \:8efd\:91cf crypto 2 package \:3092\:5148\:306b\:30ed\:30fc\:30c9\:3057\:3001backend \:3092\:89aa\:3068\:63c3\:3048\:308b\:3002 *)
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
    (* BootstrapFiles \:3092\:5b50\:3067\:5148\:30ed\:30fc\:30c9\:3002claudecode.wl \:306e Needs["NBAccess`","NBAccess.wl"]
       \:306e\:3088\:3046\:306a\:76f8\:5bfe\:30d1\:30b9\:89e3\:6c7a\:304c\:3042\:308b\:305f\:3081\:3001\:30d1\:30c3\:30b1\:30fc\:30b8\:30c7\:30a3\:30ec\:30af\:30c8\:30ea\:3078 SetDirectory \:3057\:3066
       \:304b\:3089 Get \:3059\:308b\:3002crypto boot (backend \:8a2d\:5b9a) \:306f bootstrap \:306e\:5f8c (\:4e0a\:66f8\:304d\:9632\:6b62)\:3002 *)
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

(* \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] \:5b9f launcher (\:89aa\:30d7\:30ed\:30bb\:30b9, StartProcess \:3067\:5225 wolframscript \:8d77\:52d5) \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] *)
ClaudeExternalWolframScriptLauncher[jobSpec_Association] :=
  Module[{prep, jobId, jobDir, runWls, exe, proc, pid, seat, seatPrio},
    prep = iPrepareExternalJob[jobSpec];
    If[Lookup[prep, "Status", ""] =!= "Prepared", Return[prep]];
    jobId = prep["JobID"]; jobDir = prep["JobDir"]; runWls = prep["RunWls"];

    exe = ClaudeResolveWolframScriptExecutable[];
    (* hardening 01 Inc2: 席ゲート。broker (ClaudeRuntime_seatbroker.wl)
       未ロード時は素通り (claudecode 側の probe fallback は経由しない:
       runner は Orchestrator の RetryPolicy が再試行主体のため)。
       席優先度は jobSpec の "SeatPriority" を尊重する (既定 40)。ユーザー操作
       起点のジョブ (SourceVaultRunWorkflowAsync 等) は 90 を渡し、broker の
       FE 対話用 Reserve へ食い込める -- FE+常駐で空き=Reserve のトポロジーが
       恒久 NoSeat になるのを防ぐ (ユーザーの FE 対話の代理実行のため)。 *)
    seatPrio = With[{p = Lookup[jobSpec, "SeatPriority", Automatic]},
      If[IntegerQ[p] && 0 <= p <= 100, p, 40]];
    seat = If[Length[DownValues[ClaudeSeatAcquire]] > 0,
      ClaudeSeatAcquire["ExternalRunner", "Priority" -> seatPrio,
        "TTLSeconds" -> 1800, "JobId" -> jobId],
      <|"Token" -> None|>];
    If[FailureQ[seat],
      iWriteStatus[jobDir, <|"Status" -> "Failed", "ErrorRef" -> "NoSeat"|>];
      Return[<|"Status" -> "Failed", "Reason" -> "NoSeat",
        "SeatPriority" -> seatPrio, "Retryable" -> True|>]];
    (* ProcessEnvironment \:306f\:74b0\:5883\:3092\:300c\:7f6e\:63db\:300d\:3059\:308b\:3002<|"CLAUDE_JOB_ID"->..|> \:3060\:3051\:3092\:6e21\:3059\:3068
       PATH/SystemRoot \:7b49\:304c\:5931\:308f\:308c\:3001Windows \:3067\:306f\:5b50 wolframscript \:304c DLL/\:30e9\:30a4\:30bb\:30f3\:30b9\:3092
       \:89e3\:6c7a\:3067\:304d\:305a\:5373\:6b7b\:3059\:308b (PID \:53d6\:5f97\:4e0d\:53ef -> pid.json PID=-1\:30fb\:51fa\:529b\:306a\:3057)\:3002\:73fe\:5728\:306e\:74b0\:5883\:306b
       \:30de\:30fc\:30b8\:3057\:3066\:6e21\:3059\:3002 *)
    (* hardening 03 Inc3: supervisor 経由 (2 相 manifest)。poll tick 停止でも
       reap が output.wxf (DoneMarker)/消滅/期限で回収する。未ロード時は素の
       StartProcess に fallback。 *)
    Module[{psOpts = {ProcessDirectory -> jobDir,
        ProcessEnvironment -> Append[
          Quiet @ Check[GetEnvironment[], {}], "CLAUDE_JOB_ID" -> jobId]}},
      proc = If[Length[DownValues[ClaudeSupervisedStartProcess]] > 0,
        Module[{r = ClaudeSupervisedStartProcess[{exe, "-file", runWls},
            "ExternalRunner", "JobId" -> jobId,
            "DoneMarker" -> FileNameJoin[{jobDir, "output.wxf"}],
            "SeatToken" -> Lookup[seat, "Token", None],
            "DeadlineSeconds" -> 1800,
            "ProcessOptions" -> psOpts]},
          If[AssociationQ[r] && MatchQ[Lookup[r, "Process"], _ProcessObject],
            r["Process"], $Failed]],
        Quiet @ Check[
          StartProcess[{exe, "-file", runWls}, Sequence @@ psOpts],
          $Failed]]];
    If[proc === $Failed || ! MatchQ[proc, _ProcessObject],
      If[StringQ[Lookup[seat, "Token", None]],
        Quiet @ ClaudeSeatRelease[seat["Token"]]];   (* spawn 失敗 → 即返却 *)
      iWriteStatus[jobDir, <|"Status" -> "Failed", "ErrorRef" -> "LaunchFailed"|>];
      iCRDiagEmit["SpawnFailed",
        <|"Purpose" -> "ExternalRunner", "Exe" -> ToString[exe],
          "JobId" -> jobId|>, "error"];
      Return[<|"Status" -> "Failed", "Reason" -> "StartProcessFailed"|>]];

    (* hardening 03 Inc3: PID は ProcessObject 自身のデータから取る。
       ProcessInformation は本環境では ExitCode しか持たない (2026-07-07 実測)。
       これが従来の pid.json PID=-1 の真因 (環境破壊起因の即死とは別系統)。 *)
    pid = Quiet @ Check[Lookup[First[proc], "PID", None], None];
    $iExternalProcs[jobId] = proc;
    If[StringQ[Lookup[seat, "Token", None]],
      $iExternalSeatTokens[jobId] = seat["Token"]];

    iAtomicWriteJSON[FileNameJoin[{jobDir, "pid.json"}], <|
      "PID"        -> If[IntegerQ[pid], pid, -1],
      "Executable" -> "wolframscript",
      "JobID"      -> jobId,
      "StartedAt"  -> UnixTime[]
    |>];

    <|"Status" -> "Launched", "JobID" -> jobId, "JobDir" -> jobDir,
      "PID" -> If[IntegerQ[pid], pid, None]|>
  ];

(* \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] in-process launcher (\:30c6\:30b9\:30c8 / \:5358\:4e00\:30e9\:30a4\:30bb\:30f3\:30b9\:74b0\:5883 / \:77ed\:6642\:9593\:30bf\:30b9\:30af\:7528) \[HorizontalLine]\[HorizontalLine]\[HorizontalLine]
   runner \:3092\:73fe\:5728\:306e\:30ab\:30fc\:30cd\:30eb\:3067\:540c\:671f\:5b9f\:884c\:3059\:308b\:3002\:5225\:30d7\:30ed\:30bb\:30b9\:3092\:8d77\:3053\:3055\:306a\:3044\:305f\:3081
   long-running \:306b\:306f\:4f7f\:308f\:306a\:3044 (main kernel \:3092\:30d6\:30ed\:30c3\:30af\:3059\:308b)\:3002job dir / manifest /
   status.json / output.wxf \:306f\:5b9f launcher \:3068\:540c\:3058\:5f62\:3067\:751f\:6210\:3055\:308c\:308b\:306e\:3067\:3001
   poller \[RightArrow] \:5b8c\:4e86 \[RightArrow] slot \:8fd4\:5374\:306e\:5168\:30c1\:30a7\:30fc\:30f3\:3092\:6c7a\:5b9a\:7684\:306b\:691c\:8a3c\:3067\:304d\:308b\:3002 *)
ClaudeExternalInProcessLauncher[jobSpec_Association] :=
  Module[{prep, jobId, jobDir},
    prep = iPrepareExternalJob[jobSpec];
    If[Lookup[prep, "Status", ""] =!= "Prepared", Return[prep]];
    jobId = prep["JobID"]; jobDir = prep["JobDir"];
    ClaudeRunTaskFromManifest[jobDir];   (* \:540c\:671f\:5b9f\:884c -> status.json \:3092\:66f8\:304f *)
    <|"Status" -> "Launched", "JobID" -> jobId, "JobDir" -> jobDir,
      "PID" -> None, "InProcess" -> True|>
  ];

(* \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] \:30d7\:30ed\:30bb\:30b9 probe / kill seam (cross-restart \:540c\:4e00\:6027\:78ba\:8a8d\:7528) \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] *)
If[! ValueQ[$ClaudeExternalProcessProbe], $ClaudeExternalProcessProbe = Automatic];
If[! ValueQ[$ClaudeExternalProcessKill],  $ClaudeExternalProcessKill = Automatic];

(* \:65e2\:5b9a probe: Windows tasklist \:3067 PID \:306e\:751f\:5b58\:3068 image \:540d\:3092\:5f97\:308b\:3002 *)
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

(* \:65e2\:5b9a kill: Windows taskkill /F\:3002 *)
iDefaultProcessKill[pid_Integer] :=
  pid > 0 && TrueQ[Quiet @ Check[
    Lookup[RunProcess[{"taskkill", "/PID", ToString[pid], "/F"}], "ExitCode", 1] === 0,
    False]];
iDefaultProcessKill[_] := False;

iResolveProcessProbe[] := If[$ClaudeExternalProcessProbe === Automatic,
  iDefaultProcessProbe, $ClaudeExternalProcessProbe];
iResolveProcessKill[]  := If[$ClaudeExternalProcessKill === Automatic,
  iDefaultProcessKill, $ClaudeExternalProcessKill];

(* pid.json \:306e PID \:304c\:300c\:751f\:304d\:3066\:3044\:308b wolframscript\:300d\:304b\:691c\:8a3c (PID \:518d\:5229\:7528\:3067\:306e\:8aa4 kill \:9632\:6b62)\:3002
   P0: alive + image=wolframscript\:3002\:5225\:306e wolframscript \:3078\:306e PID \:518d\:5229\:7528\:306f
   image \:3060\:3051\:3067\:306f\:5224\:5225\:4e0d\:80fd (StartTime/CommandLine \:7167\:5408\:306f P1)\:3002 *)
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

(* \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] killer (same-session: ProcessObject / cross-restart: pid.json \:540c\:4e00\:6027 kill) \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] *)
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
        iERSeatRelease[jobId];   (* hardening 01 Inc2: kill 経路の席返却 *)
        <|"Killed" -> True, "Via" -> "ProcessObject", "JobID" -> jobId|>,
      StringQ[jobDir],
        pidJson = iReadPidJson[jobDir];
        ver = iVerifyJobProcessIdentity[pidJson];
        If[TrueQ[Lookup[ver, "Verified", False]],
          pid = ver["PID"]; killer = iResolveProcessKill[];
          iERSeatRelease[jobId],
          Null];
        If[TrueQ[Lookup[ver, "Verified", False]],
          <|"Killed" -> TrueQ[Quiet @ Check[killer[pid], False]],
            "Via" -> "PidIdentity", "PID" -> pid, "JobID" -> jobId|>,
          (* \:540c\:4e00\:6027\:4e0d\:4e00\:81f4 -> \:8aa4 kill \:56de\:907f\:3067\:30b9\:30ad\:30c3\:30d7 *)
          <|"Killed" -> False, "Via" -> "SkippedIdentity",
            "Reason" -> Lookup[ver, "Reason", "?"], "JobID" -> jobId|>],
      True,
        <|"Killed" -> False, "Via" -> "NoTarget", "JobID" -> jobId|>]
  ];

(* \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] orphan recovery \:672c\:4f53 (\:691c\:51fa + identity kill + mark) \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] *)
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

(* \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] Workflow \:30d5\:30c3\:30af\:3078\:7d50\:7dda \[HorizontalLine]\[HorizontalLine]\[HorizontalLine] *)
ClaudeWireExternalRunner[] :=
  If[TrueQ[Quiet @ Check[
        ValueQ[ClaudeOrchestrator`Workflow`$ClaudeExternalJobLauncher] ||
        StringQ[ClaudeOrchestrator`Workflow`ClaudeExternalJobPollTick::usage], False]],
    ClaudeOrchestrator`Workflow`$ClaudeExternalJobLauncher     = ClaudeExternalWolframScriptLauncher;
    ClaudeOrchestrator`Workflow`$ClaudeExternalJobKiller       = ClaudeExternalWolframScriptKiller;
    (* StatusReader \:306f\:65e2\:5b9a (JobDir/status.json \:8aad\:307f) \:3067\:5341\:5206\:306a\:306e\:3067\:7d50\:7dda\:3057\:306a\:3044 *)
    "Wired",
    "WorkflowNotLoaded"
  ];

(* \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550
   Live \:7d71\:5408: \:5171\:6709 tick \:3078\:306e poll \:767b\:9332 + \:5b8c\:4e86 hook \:3067\:306e final action enqueue
   (v7 \[Section]12.2)\:3002\:72ec\:81ea scheduler \:306f\:4f5c\:3089\:305a ClaudeCode`ClaudeRegisterPollingTick \:306b
   \:76f8\:4e57\:308a\:3059\:308b\:3002Notebook \:53cd\:6620\:306f ClaudeEnqueueFinalAction (\:627f\:8a8d/single committer)\:3002
   \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550 *)

If[! ValueQ[$ClaudeExternalFinalActionEnqueue], $ClaudeExternalFinalActionEnqueue = Automatic];
If[! StringQ[$ClaudeExternalPollTickKey],       $ClaudeExternalPollTickKey = "external-job-poll"];

iFinalActionEnqueue[] := Which[
  $ClaudeExternalFinalActionEnqueue =!= Automatic, $ClaudeExternalFinalActionEnqueue,
  Length[DownValues[ClaudeCode`ClaudeEnqueueFinalAction]] > 0,
    ClaudeCode`ClaudeEnqueueFinalAction,
  True, None];

(* \:53cd\:6620\:7528 accessSpec (FinalAction role)\:3002NBAccess \:672a\:30ed\:30fc\:30c9\:306a\:3089\:6700\:5c0f\:9650\:3002 *)
iReflectAccessSpec[] :=
  If[Length[DownValues[NBAccess`NBMakeRuntimeAccessSpec]] > 0,
    NBAccess`NBMakeRuntimeAccessSpec[<|"PermissionMode" -> "WorkflowSafe"|>, "FinalAction"],
    <|"PermissionMode" -> "WorkflowSafe"|>];

(* workflow \:306e\:5b8c\:4e86 hook \:304b\:3089\:547c\:3070\:308c\:308b: \:5b8c\:4e86 payload \:304b\:3089 summary final action \:3092\:4f5c\:308a
   FinalActionQueue \:3078 enqueue (\:627f\:8a8d\:7d4c\:7531)\:3002\:672c\:4f53\:306f inline \:3057\:306a\:3044 (ClaudeExternalJobFinalAction)\:3002 *)
iExternalReflectCompletion[info_Association] :=
  Module[{awaitMeta, status, completion, built, enq},
    awaitMeta = Lookup[info, "AwaitMeta", <||>];
    status    = Lookup[info, "Status", <||>];
    (* hardening 01 Inc2: job 終端で席を返却 (正常完了経路の release) *)
    iERSeatRelease[Lookup[awaitMeta, "JobID", None]];
    completion = <|
      "Status"         -> "Completed",
      "JobID"          -> Lookup[awaitMeta, "JobID", "?"],
      "JobDir"         -> Lookup[awaitMeta, "JobDir", None],
      "OutputRef"      -> Lookup[status, "OutputRef", None],
      "SourceVaultRef" -> Lookup[status, "SourceVaultRef", None]|>;
    (* 2026-06-12: \:6295\:5165\:5143\:304c NotifyNotebook \:3092\:6307\:5b9a\:3057\:3066\:3044\:308c\:3070 summary \:306e\:66f8\:8fbc\:5148\:306b\:3059\:308b
       (awaitMeta \:7d4c\:7531 = \:89aa\:30e1\:30e2\:30ea\:5185\:306e\:307f\:3002manifest / \:5b50\:30d7\:30ed\:30bb\:30b9\:3078\:306f\:6e21\:3089\:306a\:3044)\:3002 *)
    If[MatchQ[Lookup[awaitMeta, "NotifyNotebook", None], _NotebookObject],
      completion["TargetNotebook"] = awaitMeta["NotifyNotebook"]];
    (* \:6295\:5165\:5143\:304c\:7d50\:679c\:53d6\:5f97\:95a2\:6570\:540d\:3092\:6307\:5b9a\:3057\:3066\:3044\:308c\:3070\:3001\:5b8c\:4e86\:30bb\:30eb\:3092 Input \:30bb\:30eb\:5316\:3057\:3066\:4f1d\:3048\:308b *)
    If[StringQ[Lookup[awaitMeta, "ResultRetriever", None]] && awaitMeta["ResultRetriever"] =!= "",
      completion["ResultRetriever"] = awaitMeta["ResultRetriever"]];
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
    (* 1. launcher / killer \:7d50\:7dda *)
    wired = ClaudeWireExternalRunner[];
    (* 2. External / Subkernel poll tick \:3092\:5171\:6709 tick \:3078\:767b\:9332 (\:72ec\:81ea scheduler \:3092\:4f5c\:3089\:306a\:3044) *)
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
    (* 3. \:5b8c\:4e86 hook \:8a2d\:5b9a (job \:5b8c\:4e86 -> summary final action -> FinalActionQueue) *)
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

(*Print[Style["ClaudeRuntime_externalrunner.wl (Phase 4.A) \:304c\:30ed\:30fc\:30c9\:3055\:308c\:307e\:3057\:305f\:3002", Bold]];
Print["
  ClaudeRunTaskFromManifest[jobDir]      -> runner entrypoint (\:5b50\:30d7\:30ed\:30bb\:30b9)
  ClaudeRegisterExternalTaskHandler[..]  -> handler \:767b\:9332 (\:7d44\:8fbc: \"Echo\")
  ClaudeExternalWolframScriptLauncher    -> \:5b9f wolframscript \:8d77\:52d5 launcher
  ClaudeResolveWolframScriptExecutable[] -> wolframscript \:89e3\:6c7a
  ClaudeExternalJobRoot[]                 -> durable job root
  ClaudeWireExternalRunner[]             -> Workflow \:30d5\:30c3\:30af\:3078\:7d50\:7dda
"];*)
