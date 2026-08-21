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
survivors only.

## scenarios/  (qa-scenario-writer)
`scenarios/scenario-<AC>-<n>.json` — the framework-neutral IR:
```json
{
  "id": "EC-1234-AC3-1", "requirement": "AC-3", "level": "api" | "component" | "e2e",
  "title": "Negative total is rejected",
  "given": "…", "when": "…", "then": "…",
  "http": { "method": "POST", "path": "/api/invoices", "body": {}, "expectStatus": 422, "expectBody": {} },
  "targetProject": "<projectPath from adapter-profiles>",
  "renderedTo": ["worktree-relative path of generated test file"]
}
```

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
