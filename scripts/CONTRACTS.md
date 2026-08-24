# Artifact contracts

Every script reads/writes JSON under `workspace/<repoSlug>/<branchSlug>/` (created by
`worktree.ps1 -EnsureWorkspace`). `<repoSlug>` is the config key with `/`→`__`;
`<branchSlug>` is the branch name with unsafe chars →`-`. All JSON is UTF-8, no BOM.
Scripts NEVER print secrets and NEVER write outside `workspace/`, `reports/`, `tools/`,
or the run's worktree. Agents consume these files; they never re-parse raw TRX/XML.

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
  "ticketKey": "EC-1234"
}
```

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
      "placementRoot": "apps/backend/tests/payroll/Visma.Payroll.Domain.UnitTests",
      "placementAllowedFolders": ["Domain"],   // payroll test_placement allow-list; empty = unrestricted
      "sutProjects": ["apps/backend/src/payroll/Visma.Payroll.Domain/Visma.Payroll.Domain.csproj"]
    }
  ]
}
```

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
      "failures": [{ "fqn": "…", "message": "…", "stack": "…" }],
      "perTestDurations": [{ "fqn": "…", "seconds": 0.12 }],
      "trxPath": "…"
    }
  ],
  "flaky": { "repeats": 3, "flipped": [], "skippedReason": null }
}
```

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

## scenarios/  (qa-scenario-writer)
`scenarios/scenario-<AC>-<n>.json` — the framework-neutral IR:
```json
{
  "id": "EC-1234-AC3-1", "requirement": "AC-3", "level": "unit" | "component" | "api" | "e2e",
  "title": "Negative total is rejected",
  "given": "…", "when": "…", "then": "…",
  "http": { "method": "POST", "path": "/api/invoices", "body": {}, "expectStatus": 422, "expectBody": {} },
  "targetProject": "<projectPath from adapter-profiles>",
  "renderedTo": ["worktree-relative path of generated test file"],
  "executionState": "EXECUTED_PASSED" | "EXECUTED_FAILED" | "GENERATED_NOT_EXECUTED" | null,
  "vacuityGrade": "verified_against_base" | "static_only" | null
}
```
`level: "unit"` is for a scenario that calls a function/module directly with no
render, no DB, no HTTP — e.g. asserting an invariant on a pure helper's return
value (verified case: a column-header-uniqueness check with no React render
involved). `component` implies rendering/DOM or a real internal collaborator;
don't use it just because the target file lives under a "components/" folder.

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
      "context": "<the matching source line, trimmed>" }
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
hunks. Generic identifiers (short names, common words) are dropped into
`droppedSeeds` — a match on `Name` is noise, not impact. `matchKind`:
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
differs per machine. Probe first; never assume. The file is written
whenever the impact phase runs (`toggles.skipQaImpact: false`, or the standalone
`/qa-impact`) — `status` carries the honesty when the lane couldn't run. It does
not exist on runs where `skipQaImpact` (default `true`) skipped the phase.
```json
{
  "status": "RAN",   // "RAN" | "SKIPPED — Testomatio MCP not configured" | "DEGRADED — <query error>"
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
