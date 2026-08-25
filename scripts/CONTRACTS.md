# Artifact contracts

Every script reads/writes JSON under `workspace/<repoSlug>/<branchSlug>/` (created by
`worktree.ps1 -EnsureWorkspace`). `<repoSlug>` is the config key with `/`→`__`;
`<branchSlug>` is the branch name with unsafe chars →`-`. All JSON is UTF-8, no BOM.
Scripts NEVER print secrets and NEVER write outside `workspace/`, `reports/`, `tools/`,
or the run's worktree. Agents consume these files; they never re-parse raw TRX/XML.
Absolute paths in artifacts are **platform-native** (`C:\…` with `\` on Windows,
`/Users/…` with `/` on macOS/Linux — the Windows-shaped examples below are just
examples); consumers must accept both separators, and repo-relative paths always
use `/`.

## repo-detect output  (worktree.ps1 -DetectRepo, stdout only — no file, no manifest yet)
Runs before any workspaceDir exists, so there is nowhere to write a file; its one
contractual stdout line **is** this JSON (every other mode's one line is prose).
Per registered `productRepos` entry, scans **every worktree of that repo** (`git
worktree list --porcelain`, repo-wide regardless of which of its worktrees you run
it from) — not just the one path in config — so a developer's own `git worktree add
../payroll-poc-EC-8876 feature/EC-8876` sibling is found too. A repo with N matching
worktrees yields N candidates, each carrying **that worktree's own path** (not
necessarily the registered one):
```json
{
  "candidates": [
    { "repoSlug": "e-conomic/payroll-poc", "repoPath": "<local path>\\payroll-poc-EC-8876",
      "branch": "feature/EC-1234-vat-rounding", "matchedBy": "hint-in-branch-name" }
  ],
  "skipped": [
    { "repoSlug": "e-conomic/client", "repoPath": "<local path>\\client", "reason": "path not found on this machine" }
  ]
}
```
`matchedBy`: `hint-in-branch-name` | `hint-in-worktree-name` | `hint-in-recent-commit` |
`non-default-branch-checked-out` | `explicit-worktree-path`. `hint-in-worktree-name`
matches the hint against the worktree directory's basename (e.g. a developer saying
just `payroll-poc-EC-8876`, not the full path or the branch) — approximated via the
path basename since porcelain output doesn't expose git's internal per-worktree
admin name, which defaults to that basename anyway. Detached worktrees are skipped
silently — that's what
agentQ's own `workspace/` worktrees always are, so they never show up here. The
orchestrator proceeds only on exactly one candidate; zero or multiple → ask the
developer, listing `repoSlug` + `branch` (+ path, if two candidates share a slug)
per candidate.

Two optional narrowing params, for when the developer already gave some of this
explicitly (see `SKILL.md` Inputs):
- `-RepoFilter <exact productRepos key>` — scope the scan to one already-known repo.
  Takes the exact key, not a fragment (the orchestrator resolves "payroll" →
  `e-conomic/payroll-poc` itself, since it already has the config loaded). An
  unknown key throws — the orchestrator should only pass a key it already validated.
- `-WorktreePath <path>` — a direct override: skips all branch/hint matching, just
  confirms the path is a worktree of a (possibly `-RepoFilter`-narrowed) registered
  repo and returns it as the sole candidate (`matchedBy: explicit-worktree-path`,
  `branch` is `(detached)` if it's not on a branch). Not a worktree of any
  registered repo → `candidates: []`, one `skipped` entry with `repoSlug: null`.

## run-manifest.json  (written by the orchestrator at Phase 0, read by everything)
```json
{
  "repoSlug": "e-conomic/payroll-poc",
  "repoPath": "<local path>\\payroll-poc",
  "branch": "feature/EC-1234-vat-rounding",
  "baseRef": "origin/main",
  "baseSha": "<40-char merge-base sha, pinned once>",
  "fetchedAt": "2026-08-20T14:05:00Z",
  "workspaceDir": "C:\\agentQ\\workspace\\e-conomic__payroll-poc\\feature-EC-1234-vat-rounding",
  "worktreeDir": "<workspaceDir>\\worktree",
  "worktreeBaseDir": "<workspaceDir>\\worktree-base",
  "ticketKey": "EC-1234"
}
```
`worktreeBaseDir` names the persistent BASE worktree (`worktree.ps1 -EnsureBase`,
created lazily — the path is in the manifest before the dir exists). Anti-vacuity
runs there (`run-tests.ps1 -GeneratedOnly -WorktreeRoot <worktreeBaseDir>
-ResultsLabel base`) instead of flipping the main worktree to base and back — each
flip cost a full checkout + cold rebuild; the base worktree's build output stays
warm across runs because baseSha changes rarely. Older manifests without the field
still work (`-EnsureBase` derives it from `workspaceDir`).

## generated/  (staging dir for agent-authored tests — source of truth)
Agents render generated tests into `<workspaceDir>/generated/<worktree-relative
path>` — NEVER directly into a worktree. WHY (verified live): a test written into
`worktree/` before `-Ensure` created it left a non-worktree husk dir that broke
`git worktree add`; and `-Ensure`'s reuse-path `clean -fd` deletes untracked files,
silently losing authored work. `worktree.ps1 -Ensure`, `-EnsureBase`, `-FlipToBase`
and `-FlipToBranch` all re-materialize the staging dir into the target worktree, so
generated tests survive every reset and exist in BOTH worktrees (branch run +
anti-vacuity base run) without hand-copying.

## jira-ticket.json  (scripts/jira.ps1 — invoked by qa-intake; direct REST, no MCP)
Written by `scripts/jira.ps1 -IssueIdOrKey <key-or-url> -OutPath <file>` — a direct
`GET {hub}/get_issue?issueIdOrKey=` against the Visma integration-hub Jira gateway,
authenticated with `JIRA_PERSONAL_ACCESS_TOKEN` (OS env var, set by
`scripts/setup-mcp.ps1` — never assumed present). `JIRA_INTEGRATION_HUB_URL`
optionally overrides the generic prod gateway defaulted in the script. Read-only:
`get_issue` is the only Jira operation agentQ performs. ALWAYS written when the run
has a ticket key — `status` carries the honesty when the fetch couldn't happen. The
script's one stdout line is compact JSON (`{status, issueKey, artifact}`).
```json
{
  "status": "OK",   // "OK" | "SKIPPED — Jira not configured (JIRA_PERSONAL_ACCESS_TOKEN not set; run scripts/setup-mcp.ps1)" | "DEGRADED — <humanized HTTP/timeout error>"
  "issueKey": "EC-1234",
  "browseUrl": "https://jira.visma.com/browse/EC-1234",
  "summary": "…",
  "descriptionWikiMarkup": "…",
  "issueType": "Story",
  "issueStatus": "In Progress",
  "labels": [],
  "parentKey": "EC-1200",     // fields.parent (sub-task parent); null when absent
  "epicKey": "EC-1100",       // customfield_13061 (epic link); null when absent
  "figmaLinks": [],           // mechanical regex pre-scan over summary/description/comments
  "comments": [{ "author": "…", "created": "…", "bodyWikiMarkup": "…" }],   // last 10
  "fetchedAt": "2026-08-24T09:00:00Z"
}
```
`descriptionWikiMarkup`/`bodyWikiMarkup` are **Jira wiki markup, not Markdown**
(`h2.`, `*bold*`, `{{code}}`, `# ` ordered lists) — never parse or render them as
Markdown. AC extraction is qa-intake's judgment, deliberately NOT in this file.
When the ticket itself has no AC-relevant info and `parentKey`/`epicKey` is set,
qa-intake fetches that key into `jira-ticket-parent.json` (same shape) and labels
the AC source in its brief ("ACs from parent EC-1200"). DEGRADED/SKIPPED status →
the orchestrator asks for pasted AC text; a missing file on a run that had a ticket
key means the fetch step was skipped — treat as `DEGRADED — artifact missing`,
never as a pass.

## diff-set.json  (worktree.ps1 -DiffSet)
```json
{
  "baseSha": "…",
  "files": [
    { "path": "src/payroll/VatCalculator.cs", "status": "M", "hunks": [{ "newStart": 40, "newCount": 12 }] }
  ],
  "untracked": ["src/payroll/NewRule.cs"],
  "levels": { "backend": true, "frontend": false, "apiSurface": true }
}
```
`levels` is filled in by qa-intake (not the script) after classification.

## adapter-profiles.json  (qa-intake writes; run-tests/stryker scripts read)
One entry per affected **test project**:
```json
{
  "projects": [
    {
      "projectPath": "apps/backend/tests/payroll/Visma.Payroll.Domain.UnitTests/Visma.Payroll.Domain.UnitTests.csproj",
      "framework": "xunit",              // xunit | nunit3 | nunit4 | jest | vitest | nodetest
      "frameworkVersion": "2.9.2",
      "runner": "vstest",                // vstest | mtp | nx | jest-cli
      "tfm": "net10.0",
      "assertionDialect": "fluentassertions",   // native | fluentassertions | shouldly | jest-dom
      "categoryFilter": "Category=agentQ-generated",   // xunit trait form; nunit uses TestCategory=
      "coverageMechanism": "collector",  // collector (coverlet referenced) | dotnet-coverage
      "suiteScope": "diff-sensitive",    // diff-sensitive (default) | solution-wide
      "placementRoot": "apps/backend/tests/payroll/Visma.Payroll.Domain.UnitTests",
      "placementAllowedFolders": ["Domain"],   // payroll test_placement allow-list; empty = unrestricted
      "sutProjects": ["apps/backend/src/payroll/Visma.Payroll.Domain/Visma.Payroll.Domain.csproj"]
    }
  ]
}
```
`suiteScope: "solution-wide"` marks architecture/static-analysis suites whose tests
scan the entire solution rather than specific SUT code (e.g. ContainerIntegrity /
convention / arch-rule projects — qa-intake sets it). `run-tests.ps1` never runs
such a suite unfiltered off the diff heuristic: changed test classes inside it run
filtered; otherwise the project is an honest `skippedReason` entry (verified live:
one solution-wide suite, 371 tests at 5m19s, dominated a review's wall-clock with
zero diff-relevant signal — and CI runs these suites on every PR anyway).
There is no local override — the PR pipeline runs these suites on every PR.

`coverageMechanism` is qa-intake's static per-project choice, but `run-tests.ps1`
can override it at RUN TIME to a third, undocumented-here value,
`"coverlet-console"` — never written by qa-intake, never a valid input value,
purely an execution-time escalation. It fires only when `coverageMechanism` is
`"dotnet-coverage"` AND `calibration.json`'s `coverage.dotnetCoverageWorks` is
already `false` on this machine (a documented gap: `dotnet-coverage`'s native
profiler never attaches on osx-arm64, so every run there would otherwise lose
coverage forever, not just once) — coverlet.console instruments the already-built
assemblies via IL rewrite instead of a profiler attach, so it needs no product
`.csproj` change either. The `coverlet.console` tool itself is installed on
demand by `run-tests.ps1` at the moment of this escalation — kicked off as a
non-blocking background process as soon as calibration shows `dotnet-coverage`
broken, so the install overlaps with the same run's other test-project builds
instead of adding serial latency — never by `setup-mcp.ps1`, which
deliberately does not pre-install it (most machines never reach this code
path). See `calibration.json` below for the
`coverletConsoleWorks` capability key this escalation self-records, and
`test-results.json`'s `coverageNote` for how a run states which path it took.

## test-results.json  (run-tests.ps1)
```json
{
  "runs": [
    {
      "projectPath": "…csproj-or-nx-project",
      "command": "<exact command executed>",
      "exitCode": 0,
      "testsDiscovered": 43, "testsExecuted": 43, "passed": 43, "failed": 0, "skipped": 0,
      "zeroMatchError": false,
      "durationSeconds": 4.1,
      "coverageDegraded": false,
      "coverageNote": null,          // WHY coverage degraded/was skipped, when it was
      "skippedReason": null,         // set (with exitCode 0) when the project run was honestly skipped
      "selection": "related-files",  // JS entries only (the only JS selection mode)
      "selectionNote": "…",          // JS entries only: what was selected AND what deliberately wasn't (dependents run in the PR pipeline)
      "runNote": "…",                // .NET entries only: which execution lane ran it — "parallel lane (up to N concurrent projects, MaxCpuCount=X each)" or "sequential lane — references Microsoft.AspNetCore.Mvc.Testing…" (the factory's 5s host-build timeout is load-sensitive)
      "failures": [{ "fqn": "…", "file": "…", "message": "…", "stack": "…", "rerunCommand": "…" }],
      "perTestDurations": [{ "fqn": "…", "seconds": 0.12 }],
      "trxPath": "…"
    }
  ],
  "flaky": {
    "policy": "no-local-reruns",
    "note": "<why agentQ never re-runs, and what the developer should do>",
    "mightBeFlaky": [{ "fqn": "…", "projectPath": "…", "rerunCommand": "…" }]
  }
}
```
`flaky` carries NO rerun results — agentQ never re-runs tests to confirm
flakiness (removed by design: re-runs multiply the run's wall-clock, and one
machine's re-run can't prove stability anyway). Every failed test appears in
`mightBeFlaky` with a ready-to-run `rerunCommand` (JS: config + test file +
regex-escaped `-t` name; .NET: `dotnet test <proj> --filter
"FullyQualifiedName~<name>"`). Consumers present each as *failed — might be
flaky; re-run outside agentQ to confirm*, quoting the command verbatim — the tag
never softens the failure, and "flaky" is never asserted as fact from one run.
`failures[].file`/`failures[].rerunCommand` exist on JS entries (the .NET
command is synthesized into `mightBeFlaky` from the fqn).
Affected mode (Phase 2) writes `test-results.json`. `-GeneratedOnly` (Phase 7)
writes `test-results-generated.json`, or `test-results-generated-<label>.json`
with `-ResultsLabel` — the orchestrator uses `-ResultsLabel branch` and
`-ResultsLabel base` so the branch-side and anti-vacuity runs never clobber each
other (or Phase 2's results — verified live, that clobbering happened). A run
entry with `skippedReason` (e.g. a solution-wide suite with nothing diff-relevant)
always carries `exitCode: 0` and `zeroMatchError: false` so risk-score's
build-failed heuristic cannot misread an honest skip.

A .NET project build failure (before any test runs) is its own run entry:
`testsExecuted: 0`, a single `failures` item with `fqn: "<build>"` and
`message` set to the actual `dotnet build` diagnostic text (the real
compiler errors, e.g. `error CS0234: ...` — never a generic placeholder
string). This matters most for the `-GeneratedOnly -WorktreeRoot
<worktreeBaseDir>` anti-vacuity run: a base-side build failure that names a
symbol the diff adds is strong non-vacuity evidence (see `vacuityGrade:
"verified_non_compiling_on_base"` above), so the real diagnostic has to be
readable from the artifact, not discarded.

**JS selection is file-granular, always** (every JS runner incl. Nx): per
project, `jest --findRelatedTests <changed files under the project>` with the
project's own jest.config, per-test JSON at `jest-results-<projKey>.json`,
and cobertura coverage copied to `cov\<projKey>.cobertura.xml` so
diff-coverage.ps1 reads the JS lane (verified live: the old json-summary
reporter left it REFUSED). Dependent projects are deliberately NOT run locally
and **no run-everything mode exists** (removed by design — verified live before
removal: `nx affected --target=test` fanned a 4-file leaf diff out to 40
projects / 2504 tests / 13 min of load-flaky noise, with aggregate counts only
and no flip detection); `selectionNote` states the not-run-locally scope, and
the PR pipeline runs the full suite plus ui-automation on every PR.

## calibration.json  (workspace/<repoSlug>/calibration.json — machine-local, merged never clobbered)
```json
{
  "plainRunSeconds": 42.3,           // last affected-subset wall-clock (run-tests.ps1)
  "coverage": {
    "dotnetCoverageWorks": false,    // dotnet-coverage produced parseable class data on this machine
    "collectorWorks": true,          // ditto for the XPlat/coverlet collector
    "coverletConsoleWorks": true,    // ditto for the coverlet.console FALLBACK (below) — absent until it's been tried at least once
    "probedAt": "2026-08-24T21:00:00Z"
  }
}
```
The `coverage` capability keys are self-recorded by `run-tests.ps1`: a completed
coverage-wrapped run with zero `<class>` elements records its mechanism `false`
(the run's TRX results are kept — a completed suite is NEVER re-run over empty
coverage); any run with real class data records `true` ("worked anywhere" wins —
one empty project on a working mechanism is a filter artifact, not a broken
profiler). A `false` key makes later runs skip that mechanism's instrumentation up
front, reporting the coverage row DEGRADED with the reason; `-ForceCoverage`
re-probes after a machine-level fix.

`coverletConsoleWorks` is different from the other two: it is never a project's
OWN declared mechanism (`coverageMechanism` has no `"coverlet-console"` value —
see the note above), only a fallback `run-tests.ps1` reaches for once
`dotnetCoverageWorks` is already `false` here. So it starts absent (not `false`)
on a machine that has never needed the fallback, gets its first real value the
first time `dotnet-coverage` is caught broken, and from then on gates the SAME
way the other two do: `true` keeps the fallback in play, `false` (it was tried
and also produced no `<class>` data) stops it being retried until
`-ForceCoverage`. When BOTH `dotnetCoverageWorks` and `coverletConsoleWorks` are
`false`, coverage is skipped outright and `coverageNote` says so explicitly —
never a bare "skipped" with no reason.

Note: `coverletConsoleWorks` tracks whether the mechanism, once run, PRODUCED
class data — it says nothing about whether the `coverlet.console` binary is
installed on this machine. That is orthogonal: `run-tests.ps1` installs the
tool on demand (`dotnet tool update --global coverlet.console`) only at the
moment it is about to use it, caching the result for the run. A failed
install does NOT set `coverletConsoleWorks: false` (that key is reserved for
"the mechanism ran and produced no class data") — it just falls through to
that run's `coverageNote` explaining the skip, and is retried next run.

## diff-coverage.json  (diff-coverage.ps1)
```json
{
  "resolvedFileRatio": 0.95,
  "refused": false, "refusalReason": null,
  "lineDiffCoverage": 0.54, "branchDiffCoverage": 0.41,
  "changedExecutableLines": 120, "coveredChangedLines": 65,
  "gaps": [
    {
      "file": "src/payroll/VatCalculator.cs", "line": 47,
      "kind": "uncovered" | "partial-branch",
      "conditionCoverage": "1/2",
      "enclosingMethod": "Apply(Order, decimal)", "methodComplexity": 14
    }
  ]
}
```
Refuse (`refused:true`) when `resolvedFileRatio < 0.8` — never report a number built
on broken path mapping.

## mutation-report.json  (merge-mutation-reports.ps1 — mutation-testing-elements schema v2)
Stryker's own JSON plus agentQ semantic mutants merged into the same `files` map, ids
`agentq-N`, `mutatorName` prefixed `BusinessRule/`. Per-mutant `status`:
Killed|Survived|NoCoverage|Timeout|Ignored|CompileError. Consumers: suppress
`NoCoverage` from mutation findings (they are coverage gaps), report absolute
survivors only. A surviving `agentq-N` mutant may carry a `suggestedFix` (see
`mutants.json` in `qa-mutation-author.md`) — a drafted, worktree-only edit that
strengthens the covering test's assertion enough to kill it. This is the
mutation level's equivalent of a generated scenario: a real "keep this?"
candidate, not just a verbal recommendation. Mechanical (Stryker) survivors
never carry one — qa-mutation-author only drafts fixes for mutants it designed
itself, since it authored them before Stryker's own survivors are even known
(Phase 5 ordering: business-rule tier runs first).

### stryker/summary.json (stryker-run.ps1) + workspace/<repoSlug>/mutation-cache/
Each summary entry additionally carries `testCaseFilter` (the vstest expression
Stryker's baseline AND per-mutant runs were limited to — derived from the
diff-related test classes; `null` = whole test project) and `fromCache` (`true`
= the report was reused verbatim from `workspace/<repoSlug>/mutation-cache/`,
no Stryker execution this run). Two consumer rules bind:
- With a `testCaseFilter`, a survivor claim is ALWAYS scoped: "no test
  **related to this change** kills it" — never "no test in the project".
- The cache is keyed by source-file CONTENT hash + mutate scope + filter +
  mutation level + pinned tool version (`<key>.report.json` + `<key>.meta.json`,
  branch-agnostic, repo-level). Only COMPLETE runs are cached — a timeout or
  partial result is re-attempted next run, never replayed.

## scenarios/  (qa-scenario-writer)
`scenarios/scenario-<AC>-<n>.json` — the framework-neutral IR:
```json
{
  "id": "EC-1234-AC3-1", "requirement": "AC-3", "level": "unit" | "component" | "api" | "e2e",
  "title": "Negative total is rejected",
  "given": "…", "when": "…", "then": "…",
  "http": { "method": "POST", "path": "/api/invoices", "body": {}, "expectStatus": 422, "expectBody": {} },
  "targetProject": "<projectPath from adapter-profiles>",
  "renderedTo": ["worktree-relative path of generated test file — the physical file lives in <workspaceDir>/generated/<that path> (the staging dir; see the generated/ section above), and worktree.ps1 materializes it into both worktrees"],
  "executionState": "EXECUTED_PASSED" | "EXECUTED_FAILED" | "GENERATED_NOT_EXECUTED" | null,
  "vacuityGrade": "verified_against_base" | "verified_non_compiling_on_base" | "static_only" | null
}
```
`level: "unit"` is for a scenario that calls a function/module directly with no
render, no DB, no HTTP — e.g. asserting an invariant on a pure helper's return
value (verified case: a column-header-uniqueness check with no React render
involved). `component` implies rendering/DOM or a real internal collaborator;
don't use it just because the target file lives under a "components/" folder.

`vacuityGrade: "verified_non_compiling_on_base"` is for the base-side run's
failing entry being a BUILD failure (no test executed) whose compiler diagnostic
names a symbol the diff itself adds — the generated test can't even exist
without the branch's change, which is *stronger* non-vacuity evidence than a
plain runtime failure. It is NOT the right grade for a base build that fails for
reasons unrelated to the diff (an unrelated missing package, a pre-existing
broken base) — that's a base-environment problem, not vacuity evidence, and
earns no `vacuityGrade` at all (leave `null`, raise it as its own finding
instead). Telling the two apart means reading the real compiler text: see
`test-results.json`'s `failures[].message` note below.

`executionState`/`vacuityGrade` are absent (`null`) when qa-scenario-writer first
writes the file — it doesn't know the outcome yet. The **orchestrator** fills them
in after Phase 7 actually runs the scenario and (when consented) the anti-vacuity
flip-to-base check, the same way it appends to `time-ledger.json`. `risk-score.ps1`
reads them (see `testToSourceBalance` below) — never invent a value here to make a
number look better; an untouched `null` correctly reads as "not yet executed."

## contract-report.json  (contract-check.ps1)
```json
{
  "mode": "schema-diff" | "ocelot-diff" | "pact",
  "captureProvenance": { "base": "committed-spec|boot", "rev": "committed-spec|boot", "route": "/openapi/v1.json" },
  "breaking": [{ "ruleId": "response-property-removed", "level": "ERR", "text": "…", "path": "/invoices" }],
  "warnings": [], "info": [],
  "pact": { "consumers": [], "failed": [], "unverifiable": [] },
  "skipped": false, "skipReason": null
}
```
schema-diff's committed-spec path no longer needs `-SpecPath`: the changed spec
file(s) are auto-derived from `diff-set.json` (changed ∪ untracked
`openapi*`/`swagger*` files). Several changed specs are each diffed and merged
into one report (`captureProvenance.route` lists them `; `-joined; a per-spec
skip becomes an INFO entry with `ruleId: "spec-skipped"`). No spec changed →
`skipped: true` with the honest reason — an unchanged committed spec is an
unchanged documented contract on this capture path, never "0 breaking".
Because it needs only git, the orchestrator runs this lane at INTAKE time on
committed-spec/ocelot repos — only the boot-capture path (payroll-poc) waits for
the execution consent.

## risk-score.json  (risk-score.ps1 — deterministic)
```json
{
  "score": 62, "band": "Elevated",   // 0-20 Low | 21-45 Moderate | 46-70 Elevated | 71-100 High
  "hardOverride": null,               // "build-failed" | "affected-test-failed"
  "signals": [{ "name": "branchDiffCoverage", "value": 0.41, "weight": 0.28, "contribution": 17, "available": true }],
  "renormalized": false, "missingSignals": [],
  "confidence": "moderate",           // high | moderate | low — from missing signals + coverage of evidence
  "topTests": [{ "fqn": "…", "reason": "unique cover of 6 changed lines", "runCommand": "…" }]
}
```
When signals are missing, `signals` also carries a synthetic `unknownEvidence` row
(`available: true`, `value` = the fraction of total documented weight that's
missing, `S: 0.35`) — see "Sparse-evidence dampening" below. Its `contribution`
plus every available signal's `contribution` (computed from each signal's
**original**, not renormalized, documented weight) sums to `score` — the ledger
is a true breakdown, not decoration.

### Sparse-evidence dampening (why the score can't be hijacked by one signal)
Pure proportional renormalization — treat whatever signals ARE available as if
they represented the full picture — has a real failure mode: with only, say, 14%
of the total documented weight available, that 14% gets rescaled to 100%, and a
single signal sitting at its worst possible value can drag the whole score to an
extreme the missing 86% might have told a completely different story about.
Verified live: a 3-line string-literal fix with a real, anti-vacuity-proven fix
scored "Elevated" purely because `testToSourceBalance` (normally a 9% weight) was
one of only two available signals. The fix: blend the renormalized weighted sum
toward a neutral baseline, weighted by how much of the total documented weight is
actually available (`W`) — `raw = W × (renormalized sum) + (1 − W) ×
NEUTRAL_UNKNOWN`. Full signal coverage (`W = 1`) reduces to the plain weighted
sum, unchanged. Sparse coverage pulls the score toward the baseline instead of
amplifying whatever little evidence exists — missing evidence still shows up as
lower `confidence`, never as a manufactured extreme in either direction.

`NEUTRAL_UNKNOWN = 0.35`, not a dead-neutral `0.5` — verified live that this
matters: the band table isn't symmetric around the midpoint (Low 0-20 | Moderate
21-45 | Elevated 46-70 | High 71-100), so a coin-flip default for *total absence
of evidence* lands at score 50 — Elevated by construction, the same band as
genuine risk evidence. "We know nothing about this diff" and "we have evidence
this diff is risky" must never read as the same verdict. `0.35` puts a
100%-unknown case (`W = 0`) comfortably inside Moderate instead.

### testToSourceBalance and generated scenarios
This signal reads `diff-set.json`'s own test-vs-source line counts, but a
developer's diff having zero test-line changes isn't the whole truth when
agentQ's own Phase 7 generated and **verified** a scenario closing exactly that
gap. `risk-score.ps1` also reads every `scenarios/*.json` in the workspace: each
one with `executionState: "EXECUTED_PASSED"` and `vacuityGrade:
"verified_against_base"` earns a 0.5 credit against the signal's worst-case value
(two such scenarios fully offset it) — a `mutation-report.json` survivor with a
`suggestedFix` counts the same way. A scenario that's merely `GENERATED_NOT_EXECUTED`
or `static_only` earns no credit — only proven-non-vacuous evidence moves this
number.

## time-ledger.json  (orchestrator appends per phase)
```json
{
  "agentsCalled": ["qa-intake", "qa-analyst", "qa-scenario-writer", "qa-mutation-author", "qa-report-synthesizer"],
  "phases": [
    { "name": "unit", "actor": "scripts/run-tests.ps1", "seconds": 42.3, "outcome": "RAN" | "DEGRADED — …" | "SKIPPED — …" }
  ],
  "totalSeconds": 222.0
}
```
`agentsCalled` lists only the LLM subagents actually spawned this run (never
scripts) — omit one that was skipped (e.g. `qa-scenario-writer` on a cache hit,
`qa-e2e-author` on a backend-only diff). `actor` on each phase names whichever
agent(s) and/or script(s) did that phase's work (e.g. `"qa-analyst +
qa-scenario-writer (overlapped)"`) — this is what lets the report show, honestly,
that most wall-clock time is deterministic scripts, not model calls. `totalSeconds`
is measured wall-clock for the whole run, not the sum of the `phases` column (phases
that overlap by design — Phase 4 with Phases 2–3, model work with CPU work — make
the sum larger than reality). `qa-report-synthesizer` reads all three fields
verbatim; it never recomputes a total or reclassifies who ran what.

## impact-index.json  (impact-index.ps1 — Phase 1b of every /qa-review + the standalone /qa-impact)
Static blast-radius index. Never builds, boots, or executes anything; read-only scan
of `productRepos` ∪ `testRepos` (config). Seeds come from the branch diff
(`-Manifest`, branch mode) or verbatim from `-Targets "term1,term2"` (target mode:
endpoint path, `Table`/`Table.Column`, type/method name, or file path).
```json
{
  "mode": "branch",                    // branch | target
  "seeds": [
    { "kind": "endpoint", "value": "POST /api/entries", "from": "src/payroll/EntriesController.cs:24" },
    { "kind": "table", "value": "Entries.PostingDate", "from": "migrations/20260812_AddPostingDate.cs:9" }
  ],
  "droppedSeeds": [{ "value": "Name", "reason": "low-signal — too generic to match on" }],
  "matches": [
    { "repoSlug": "e-conomic/client", "indexOnly": false,
      "file": "src/api/entries.ts", "line": 12,
      "seed": "POST /api/entries", "matchKind": "endpoint-reference",
      "context": "<the matching source line, trimmed, capped at 240 chars>" }
  ],
  "matchStats": [
    { "seed": "createdraftentries", "total": 1841, "kept": 200 }
  ],
  "reverseCoverage": {
    "available": false, "reason": "no coverage artifact for this branch",
    "tests": [{ "fqn": "…", "coversChangedLines": 6 }]
  },
  "scanned": [{ "repoSlug": "e-conomic/client", "files": 1240, "seconds": 2.9 }],
  "skipped": [{ "repoSlug": "e-conomic/ui-automation", "reason": "path not found on this machine" }]
}
```
Seed kinds: `endpoint | symbol | dto | table | column | file`. In branch mode the
script extracts them from the diff: routes from `[Route]`/`[Http*]`/`Map*(`/Ocelot
configs, tables/columns from changed migration files, type/method names from changed
hunks (comment lines are skipped and C# type captures must be PascalCase — prose
words like `with`/`explicitly` used to leak in as seeds and produce tens of
thousands of noise matches). Generic identifiers (short names, common words,
all-lowercase non-identifiers) are dropped into
`droppedSeeds` — a match on `Name` is noise, not impact. `matchStats` records any
seed whose matches were truncated at the per-seed cap (200): a seed with hundreds
of references means the identifier is ubiquitous, not that everything is affected,
and the cap is stated rather than silently implied as full coverage. `matchKind`:
`endpoint-reference | symbol-reference | dto-reference | table-reference |
route-config | package-reference`. `indexOnly: true` marks matches from
`testRepos` (e.g. the UI-automation repo) — always reported as
*candidates*, never as verified impact. `reverseCoverage` is filled from this
branch's existing `diff-coverage`/`test-results` artifacts when a prior `/qa-review`
produced them — the script never generates coverage itself. Testomatio results are
deliberately NOT in this file: they come from session-dependent MCP queries made by
the orchestrator (the MCP may not exist on a given machine) and land in
`testomat-candidates.json` (below), always labeled candidates.

## testomat-candidates.json  (orchestrator, Phase 1b — session-dependent, ALWAYS written)
Written by the orchestrator, not a script: Testomatio's MCP server is pre-declared
in `.mcp.json` but needs a per-machine `TESTOMATIO_API_TOKEN`, so availability
differs per machine. Probe with the real seed query itself, never with
connectivity alone — a read-only token authenticates fine (`system_ping`
succeeds) but 403s on `tests_list`/`tests_search`, which is a distinct,
NAMED state (`DEGRADED — Testomatio token is read-only`), not the generic
"not configured" skip and not folded into the generic query-error DEGRADED
either — a fixed string keeps this reading the same across runs instead of
each run improvising its own wording. The file is written
whenever the impact phase runs (`toggles.skipQaImpact: false`, or the standalone
`/qa-impact`) — `status` carries the honesty when the lane couldn't run. It does
not exist on runs where `skipQaImpact` (default `true`) skipped the phase.
```json
{
  "status": "RAN",   // "RAN" | "SKIPPED — Testomatio MCP not configured" | "DEGRADED — Testomatio token is read-only" | "DEGRADED — <query error>"
  "queriedBy": ["POST /api/entries", "ticket component: Entries"],
  "candidates": [
    { "id": "T1a2b3c", "title": "Create entry with posting date", "suite": "Entries",
      "matchedSeed": "POST /api/entries", "url": "<testomat test url>" }
  ]
}
```
Candidates are keyword matches — consumers (qa-analyst, qa-report-synthesizer) may
present them ONLY as *candidates (keyword match)*, never as affected or failed.
qa-report-synthesizer copies `status` verbatim into the Impact matrix row. A missing
file on a run where the impact phase RAN (per the time-ledger) means the
orchestrator skipped a step — treat as `DEGRADED — artifact missing`; on a
config-skipped run the row reads `SKIPPED — disabled by config`. Either way, never
silently omit the row.

## manual-test-candidates.json  (orchestrator, Phase 1c — session-dependent, ALWAYS written unless config-skipped)
Written by the orchestrator, same Testomatio MCP probe as `testomat-candidates.json`
above, but gated by its own toggle (`toggles.skipManualTestAnalysis`, default
`false`) — **opt-out, not opt-in**, unlike the Impact phase. Runs independently of
`skipQaImpact`: it only needs `impact-index.json`'s seeds, which `impact-index.ps1`
writes whenever either toggle needs them (see that section). Queries Testomat for
`state == 'manual'` tests only — this is what distinguishes it from
`testomat-candidates.json`, which searches all tests regardless of automation state.
```json
{
  "status": "RAN",   // "RAN" | "SKIPPED — Testomatio MCP not configured" | "SKIPPED — disabled by config (skipManualTestAnalysis)" | "DEGRADED — Testomatio token is read-only" | "DEGRADED — <query error>"
  "queriedBy": { "seeds": ["POST /api/entries"], "ticket": "EC-1234" },
  "candidates": [
    { "id": "de8c0276", "title": "Disconnect the employee after connecting an existing registration user",
      "suite": "Connect to existing Registration App User", "matchedBy": "diff-seed",
      "matchedSeed": "POST /api/entries", "url": "<testomat test url>" },
    { "id": "194c8320", "title": "Create employee group and verify it appears in the list",
      "suite": "Employee Group List", "matchedBy": "ticket-link", "url": "<testomat test url>" }
  ]
}
```
`matchedBy`: `diff-seed` (the manual test's own text matched a seed extracted from
the diff — the stronger signal) or `ticket-link` (matched only via `jira ==
'<ticketKey>'` — filed under the same ticket, weaker evidence since it doesn't
confirm the test text actually relates to the changed code). Rank `diff-seed`
candidates above `ticket-link` ones. Consumers present these ONLY as *candidates
(keyword/ticket match)* — never "this must be tested", never "affected". Cap at 5
shown in the report, `+N more` pointing at this file. A missing file on a run where
Phase 1c RAN is `DEGRADED — artifact missing`; toggle-skipped or no MCP → the
`status` field carries the honest reason — never silently omit the report's Manual
testing section, state the SKIPPED/DEGRADED reason instead.
