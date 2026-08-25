# agentQ — Shift-Left QA Assistant

## Purpose

This project turns Claude Code into a shift-left QA assistant. A developer asks it —
in chat, before opening a PR — to evaluate a feature **branch** of one of the
registered product repos. It answers: what's untested, what's risky, whether the code
meets the Jira ticket's acceptance criteria — backed by tests that were **really
executed**, with every claim qualified by its evidence. It never modifies a product
repo (one exception: generated tests the developer explicitly chooses to keep,
applied as a reviewed diff), never touches shared environments, and produces a
human-readable report under `reports/`.

Invoke with something like: *"Review my branch for EC-1234 in the payroll repo"*,
*"/qa-review payroll-poc"*, just *"Test my branch EC-8876"* with no repo named at
all, or the explicit flag form `/qa-review --branch feature/EC-8876 --repo
payroll-poc --worktree <local-path>/payroll-poc-EC-8876 --ticket EC-8876` — every one of
those four is optional and order-independent (`.claude/skills/qa-review/SKILL.md`
Inputs). `--quick` (or "quick review") runs the static lanes only — intake,
committed-spec contract diff, impact/manual candidates, analysis, report — no test
execution, no mutation; every execution-dependent claim is graded honestly
(`APPEARS MET — static reading only`, coverage/mutation rows `SKIPPED — quick
mode`) and the report's header names the mode. The repo/worktree doesn't need to be stated: since the branch under review
must already be checked out locally (see Preconditions), agentQ finds it by scanning
every registered repo's worktrees — including a developer's own `git worktree add`
siblings, not just the one path in config — for a match, and only asks if that's
ambiguous. The branch itself is always whatever the local checkout has checked out,
including uncommitted and untracked work.

**Test levels covered** (the tool's dedicated scope): **Unit**, **Mutation**
(mechanical + AI business-rule), **Component/Module**, **API/Service** (+ contract
testing when the repo is a service), and **E2E — only when the branch touches
frontend code** (+ Figma design conformance when the ticket links a design).
Pipeline/CI mode is Phase 2 of the roadmap — nothing here assumes it.

## Preconditions (check before every run)

1. `.claude/qa-agent-config.jsonc` exists (copy from `qa-agent-config.example.jsonc`)
   with `productRepos` pointing at real local checkouts. The target repo's checkout
   must contain the branch under review — agentQ never clones, pulls, or checks out
   branches itself; it reviews what's there (after a `git fetch` for a fresh
   merge-base). This precondition is also what makes repo auto-detect possible: if
   the developer doesn't name a repo, agentQ finds it by scanning every worktree of
   every registered repo — not just each one's currently-checked-out branch (see
   Phase 0).
2. `.env` exists if a lane needs it (copy from `.env.example`) — local-dev URLs for
   E2E, Pact broker token for the contract lane. Missing values degrade the lane
   honestly; they never block the rest of the review.
3. MCPs — **Playwright** and **Testomatio** are pre-declared in `.mcp.json`
   (approve once when Claude Code prompts on first open); Testomatio needs
   `TESTOMATIO_API_TOKEN` set as a real OS environment variable (never in
   agentQ's own `.env` — `.mcp.json` substitution reads the process environment,
   and a token value must never land in a file agentQ manages). **Figma** is a
   claude.ai connector (account-level OAuth), authorized once outside this repo —
   only needed when the ticket links a design on a frontend branch. **Jira is NOT
   an MCP**: `scripts/jira.ps1` calls the Visma integration-hub gateway directly
   (read-only `get_issue`), needing only `JIRA_PERSONAL_ACCESS_TOKEN` as an OS
   env var — set per machine by `scripts/setup-mcp.ps1`, never assumed present
   (`JIRA_INTEGRATION_HUB_URL` is an optional override; the generic prod gateway
   is the script's committed default). Verify everything with
   `scripts/check-mcp.ps1` (includes a live Jira probe) or `/mcp`. Jira is
   degradable to pasted AC text; Playwright/Figma are
   frontend-branch-only; Testomatio is probed by the impact phase on every run with
   a real query, not just connectivity — a token can authenticate (`system_ping`
   succeeds) yet be read-only and 403 on `tests_list`/`tests_search`, which reads
   nothing like "not configured" and must not be classified as it: reports
   `SKIPPED — Testomatio MCP not configured` when its token/server is missing on a
   machine, and distinctly `DEGRADED — Testomatio token is read-only` when the
   query itself 403s — never assume it works because it works elsewhere, and never
   let a live-but-403 connection read as "available". No
   other MCP is used — everything else is CLI (`git`,
   `dotnet`, `npx jest`/`nx`, `dotnet stryker`, `npx playwright test`, `oasdiff`,
   `scripts/jira.ps1`).
4. .NET SDK on PATH for .NET repos (`dotnet --list-sdks`), Node ≥ the repo's engines
   for JS repos. Docker only matters for consented Testcontainers/compose paths.
5. Lane tools are installed and verified by `scripts/setup-mcp.ps1` — running
   setup IS the consent, so no review ever pauses to ask for an install: pinned
   `dotnet-stryker` once per machine into `tools/stryker` (a repo's own
   committed tool-manifest pin wins and is restored in the worktree instead),
   `oasdiff` pinned-binary download into `tools/` (checksum-verified),
   `dotnet-coverage` as a global dotnet tool, Playwright browsers for
   registered repos declaring `@playwright/test`. The version pins live only in
   the owning runtime scripts (`contract-check.ps1`, `stryker-run.ps1` — their
   `-EnsureTool` modes do the install); `scripts/check-mcp.ps1` verifies all of
   them read-only against those pins. Cross-platform (Windows + macOS). The
   on-demand install at first use remains only as a safety net for a machine
   that skipped setup (`oasdiff` / `dotnet-stryker` / `dotnet-coverage`).
   `coverlet.console` (coverage FALLBACK for a machine where `dotnet-coverage`'s
   native profiler never attaches — documented gap on osx-arm64) is
   deliberately NEVER pre-installed by setup at all: `run-tests.ps1` installs
   it itself, lazily, at the exact moment it is about to escalate to it — only
   on a machine where `dotnet-coverage` has ALREADY been proven broken by a
   prior run — kicked off as a non-blocking background process so it overlaps
   with that run's own test-project builds instead of adding serial latency.
   `scripts/check-mcp.ps1` still reports its presence read-only, purely
   informational.
6. Impact lanes (Phase 1b — opt-in: enabled by `toggles.skipQaImpact: false`; the
   default `true` skips the phase, shown honestly as `SKIPPED — disabled by config`
   in the report's Impact row): `testRepos` in the config points at the local
   UI-automation (BA) test repo checkout — its own config slot, never
   `productRepos` (test repos are scanned for references only, never reviewed or
   built; future entries: API-testing, performance repos). Missing path or missing Testomatio MCP → a DEGRADED/SKIPPED Impact row
   in the report; never a blocked run, never a silent hole.
7. Manual-test recommendation (Phase 1c — opt-**out**: enabled by default,
   disabled by `toggles.skipManualTestAnalysis: true`): the opposite default of
   precondition 6 above, on purpose — the whole point is a developer sees it
   unless they deliberately turn it off. Shares Phase 1b's seed extraction, so it
   still runs even when `skipQaImpact` skips the Impact map itself. Same
   Testomatio MCP dependency and degrade-honestly behavior as Phase 1b.

## Safety rules (non-negotiable)

- **Cross-platform: Windows AND macOS, always.** Most developers on this team
  use macOS; agentQ itself is authored and tested on Windows. Every script
  change, bugfix, or new feature MUST work on both — this is never an
  afterthought bolted on later. Concretely: no hardcoded `.exe` suffixes (probe
  `$IsWindows`/`$IsMacOS` — absent on Windows PowerShell 5.1, so check via
  `Get-Variable -ErrorAction SilentlyContinue`, never a bare reference under
  StrictMode), no `cmd.exe`/`taskkill`/backslash-only paths without a Unix
  branch, `Join-Path` (never string-concatenated backslashes) for every path,
  no Windows-only env-var scope (`[Environment]::...'User'` scope doesn't
  exist on Unix — see `setup-mcp.ps1`/`check-mcp.ps1` for the profile-file
  fallback pattern), pinned-tool downloads must resolve the right OS/arch asset
  (darwin/linux + arm64/amd64, not just windows/amd64). When a script can't
  reasonably be tested on the other OS in this session, say so explicitly
  rather than silently assuming Windows-only is good enough.
- **Product repos are read-only.** All work products live in this repo's
  `workspace/` (worktrees, coverage, caches) and `reports/`. The single exception:
  generated tests the developer explicitly asked to keep, applied as a diff they
  reviewed in chat. Never edit `.csproj`/`package.json`/config of a product repo —
  not even to add a coverage collector (use `dotnet-coverage`, which needs none).
- **Local execution only.** Test targets are hard-validated to resolve to loopback.
  Before any in-process app boot or E2E run, disclose the app's own outbound
  destinations found during intake ("this run will touch db-dev01.internal via the
  app's connection string") and get consent — agentQ cannot sandbox the app's
  outbound traffic, so consent must be informed. No DI seam to swap the data layer →
  offer Testcontainers (Docker, dynamic ports) or mark scenarios NOT EXECUTED. Never
  a shared resource by default.
- **Never auto-start the dev stack** (ports, migrations, first-compile minutes are
  not ours to burn). Health-check, and hand the user the exact command to run.
- **Isolation for anything that mutates code**: mutation testing and base-branch
  checks run in a git worktree under `workspace/`, never the developer's tree.
  Stryker's `Restore()` is not crash-safe (verified) — Phase 0 always heals orphaned
  worktrees and `*.dll.stryker-unchanged` backups from interrupted runs.
- **Secrets**: never read, log, or embed credential values; write env-var
  *references* only. Broker access is read-only; publish-enabling env vars
  (`PACT_BROKER_PUBLISH_*`, `--publish`) are stripped from child processes — pact
  verification results are published from CI only, never from a local run. Never
  write a token value into `.env` under any circumstances (same standing rule as
  manual-testing-ai-agents, and it binds the orchestrator too, not just subagents).
- **Consent is per-run and informed.** Two consent moments (mutation, execution) are
  chat questions unless the config toggles say `always`/`never`. A denied consent is
  a SKIPPED ledger line, never a silent hole.
- **Honesty over completeness** (see Reporting): a skipped or degraded check must
  never read as a pass; every requirement claim carries its evidence source; the
  risk score is a labeled heuristic, never a "probability of passing CI".

## Architecture in one paragraph

**Agents judge, scripts execute.** Six subagents in `.claude/agents/` do only
judgment work (classification, analysis, test authoring, business-rule mutation
design, design conformance, report synthesis). Twelve deterministic PowerShell scripts
in `scripts/` do everything mechanical — cross-platform: Windows PowerShell 5.1+ or
pwsh 7+ on macOS/Linux (from a bash/zsh shell, invoke as `pwsh scripts/<name>.ps1 …`) (git worktrees, running tests, parsing
coverage, driving Stryker, contract diffs, the Jira ticket fetch, the risk formula,
artifact rendering, cache pre-warming) —
because the tool's credibility depends on the same branch producing the same verdict
twice, and LLMs don't do byte-identical. Scripts exchange JSON artifacts under
`workspace/<repo>/<branch>/` with shapes defined in `scripts/CONTRACTS.md` — agents
consume those files and never re-parse raw TRX/XML. At most 4 agents spawn in a
normal run; model-bound work overlaps CPU-bound work, but CPU-heavy phases never
overlap each other (WebApplicationFactory's non-configurable 5s host-build timeout
and Stryker's Timeout verdicts are load-sensitive — overlap manufactures false reds).
WITHIN a phase, execution is bounded-parallel with a fixed total core budget:
test projects (and semantic mutants) that cannot boot a WebApplicationFactory run
up to 3-at-a-time with `MaxCpuCount` divided so machine load stays ~constant;
anything factory-booting runs strictly one-at-a-time with all cores — each run
entry's `runNote` states which lane it got and why.

## Performance principles (fast by construction — target: 10 minutes, max)

**Target (set 2026-08-25): a full run takes 10 minutes at most.** Honest ranges:
steady-state re-run 5–7 min; clean full run 8–10 min; a run where one background
agent stalls, +4–5 min over those (a stall can't be made free, only capped — see
the run-budget watchdog below). First-ever run on a newly registered repo (cold
worktrees, no calibration, cold builds) is 15–25 min and honestly cannot meet the
10-minute target today — tracked as its own improvement item, mitigated for now by
`scripts/warm-cache.ps1` run unattended (e.g. nightly).

Nothing stops because time passed for its own sake — every hard timeout in this
tool is either (a) a generous anti-hang safety valve for a known pathological case
at the script level (coverage collection has documented 4×–47× blowups; Stryker
has no time-limit option of its own), or (b) the **orchestrator-level agent-dispatch
watchdog**: every background subagent dispatch (`qa-intake`, `qa-analyst`,
`qa-scenario-writer`, `qa-mutation-author`, `qa-report-synthesizer`,
`qa-e2e-author`) is paired with a background timer at 1.5× that agent's target
duration (floor 3 min) started in the same tool-call batch as the dispatch; a
timer that fires before the agent's own completion notification means the
dispatch is running unusually long or has stalled outright (verified live
2026-08-25: a session-level stream stall left two agents silent for 52 minutes
with zero recovery, because no such watchdog existed) — see `.claude/skills/
qa-review/SKILL.md`'s watchdog section for the full nudge/re-dispatch/degrade
procedure, gated by a 10-minute run-wide budget so a retry can never blow the
target. Both kinds of timeout degrade honestly, never silently, and the real
elapsed time (including any stall) is always what lands in `time-ledger.json` —
never zeroed out or approximated away, even when the cause is infrastructure
flakiness rather than agentQ's own work.

- Lean orchestrator turns: deterministic script sequences with zero judgment
  between them (`merge-mutation-reports.ps1` → `risk-score.ps1`; the preflight
  `-Heal` → `-EnsureWorkspace` → `-DiffSet` trio; the report's ledger-append →
  `render-evidence.ps1` → BOM re-save) run as ONE chained command, not N
  round-trips, and `scripts/report-pack.ps1` mechanically assembles an agent
  dispatch's inline evidence pack instead of the orchestrator hand-composing
  it — verified live (2026-08-25) that hand-composing was one of the longest
  single orchestrator turns in a run, and that a heavier orchestrator context
  correlates with mid-run compaction risk (one froze a run for ~3.5 minutes).
- Do less, not faster: affected-subset tests only, at TEST-CLASS granularity —
  filters derive from both sides of the diff (SUT files → `<Class>Tests`, changed
  test-project files → their own class names, untracked files included); a profile
  marked `suiteScope: "solution-wide"` (arch/static-analysis suites) is never run
  unfiltered off the diff heuristic — honest SKIP instead. There is deliberately
  NO local run-everything mode anywhere in the tool: the PR pipeline always runs
  the full suite plus ui-automation, so a local full run only duplicates CI and
  manufactures load-flaky noise. Coverage narrowed to changed
  assemblies + `SingleHit`; mutation scoped to changed hunks minus uncovered
  regions; contract lane gated on the diff touching API surface; no flaky
  re-runs — a failed test is tagged *might be flaky* with a ready-to-run rerun
  command instead of agentQ re-running anything (re-runs multiply run time for
  signal the developer gets themselves in seconds).
- Calibration-driven pre-scoping: per-repo measured numbers in
  `workspace/<repo>/calibration.json` size each phase up front; every estimate shown
  to the developer comes from measurements, never guesses ("unknown — first run on
  this repo" until they exist). Calibration also self-records coverage
  **capability** (`coverage.dotnetCoverageWorks` / `coverage.collectorWorks` /
  `coverage.coverletConsoleWorks`): a machine whose profiler yields no class data
  skips that mechanism's instrumentation up front on later runs (DEGRADED row,
  `-ForceCoverage` re-probes) — and a completed coverage-wrapped run is NEVER
  re-run just because its coverage came back empty (the TRX results are real;
  only a timed-out wrapped run re-runs plainly). Specifically for
  `dotnet-coverage` (documented gap: its native profiler never attaches on
  osx-arm64, so class data would otherwise be empty on EVERY run there, not just
  the first): once calibrated broken, `run-tests.ps1` escalates to
  `coverlet.console` instead of a bare skip — IL-rewrite based, so it needs zero
  product `.csproj` change either, same as `dotnet-coverage` itself.
  `coverlet.console` itself is fetched on demand, right at this escalation
  point, by `run-tests.ps1` — kicked off as a non-blocking background process
  as soon as calibration shows `dotnet-coverage` broken (before any test
  project builds), so the install overlaps with this loop's own build time
  instead of adding serial latency; cached for the invocation and, once
  installed, for every later run on that machine. Never pre-installed by
  `setup-mcp.ps1` — the large majority of machines never reach this branch at
  all. Only when that fallback is ALSO calibrated broken (or the on-demand
  install itself fails) does coverage skip outright, and the note names
  exactly which of the two was tried and why the other wasn't.
- Front-loaded consent: both consent moments (mutation, execution) are asked in ONE
  message right after intake, with intake's outbound destinations and calibrated
  estimates — human answer latency then overlaps machine work instead of
  serializing between phases. The per-toggle semantics are unchanged (`ask` /
  `always` / `never`, and the mutation auto-skip judgment still applies).
- Two persistent worktrees: `worktree/` (branch state) and `worktree-base/`
  (pinned at baseSha, `worktree.ps1 -EnsureBase`). Anti-vacuity runs in the base
  worktree — never by flipping the main worktree to base and back, which cost two
  full checkouts and a cold rebuild each way. Both keep bin/obj warm across runs;
  `scripts/warm-cache.ps1` can pre-warm fetch + worktrees + builds unattended
  (e.g. a nightly scheduled job).
- Generated tests live in `workspace/<repo>/<branch>/generated/` (staging — the
  source of truth); `worktree.ps1` materializes them into both worktrees on every
  ensure/flip, so no reset can lose an authored test and no agent ever writes into
  a worktree that doesn't exist yet.
- Mutation ordering: the AI business-rule tier runs FIRST (~30–45 s), Stryker after
  it — the user's core ask is never the part that suffers under time pressure.
- E2E never blocks the verdict: only cached specs execute in-run; new-scenario
  authoring is a background task ("next run includes it").
- Warm-start everything: persistent per-branch worktree + build output,
  adapter-profile cache, scenario/spec cache, mutation results keyed by file-content
  hash, `WithReuse` containers.
- The evidence file ends with a time ledger (per-phase seconds) so slowness is
  visible and tunable.

## Workflow

The primary agent (this session) runs the phases below, delegating judgment to the
subagents in `.claude/agents/` and mechanics to `scripts/`. Stream a one-line status
as each phase completes so the developer sees progress.

### Phase 0 — Preflight (scripts, 5–15 s)
Resolve the repo: an explicit repo name/fragment wins outright (`-RepoFilter`,
narrowing the scan to it); an explicit worktree that resolves to a real local path
wins harder still (`-WorktreePath`, skips matching entirely). Otherwise
`scripts/worktree.ps1 -DetectRepo -ConfigPath <config> [-Hint <ticket, branch, or
worktree-name text>]` scans every worktree of every `productRepos` entry — a
developer's own `git worktree add` siblings included, not just the one path in
config — matching -Hint against each worktree's branch name, its directory's
basename, or its last 5 commit subjects when given; otherwise any worktree sitting
on a non-default branch counts. Its one stdout line is JSON (`{candidates,
skipped}` — CONTRACTS.md), not prose. Exactly one candidate → proceed, telling the
developer which repo/branch (/worktree, if not the registered path) was
auto-detected; zero or multiple → ask.
Then `git fetch origin`; pin the **base SHA** once (`git merge-base HEAD
<auto-detected base>` — origin/HEAD, falling back to origin/main|master|develop) into
`run-manifest.json`; never re-resolve mid-run. Probe SDKs/node/git/docker. Heal prior
crashes: `scripts/worktree.ps1 -Heal` (orphaned worktrees, `*.dll.stryker-unchanged`).
Load calibration.

### Phase 1 — Intake (agent: qa-intake, ~30 s)
- Diff set via `scripts/worktree.ps1 -DiffSet`: merge-base
  `git diff --unified=0 --diff-filter=ACMR` **∪ untracked files**
  (`git ls-files --others --exclude-standard`) — plain diff silently misses a
  developer's brand-new class.
- Classify levels (frontend touched → E2E + design-conformance arm).
- Resolve per-test-project **adapter profiles** (framework, runner, dialect,
  placement rules → `adapter-profiles.json`). e-conomic: the CI matrices are the
  authoritative test-project inventory, filename globs are the fallback. client:
  Nx repo — but selection is file-granular `jest --findRelatedTests`, NOT
  `nx affected` (see Phase 2). Suites whose tests
  scan the whole solution rather than specific SUT code (arch / static-analysis /
  convention projects, e.g. ContainerIntegrity) are tagged
  `suiteScope: "solution-wide"` so Phase 2 never runs them unfiltered.
- Jira: ticket key from branch/commits → `scripts/jira.ps1` (direct REST
  `get_issue` against the integration hub — no MCP) → `jira-ticket.json` (ALWAYS
  written when a key exists; honest `SKIPPED — Jira not configured…` /
  `DEGRADED — <why>` status when the token is missing or the call fails) → ACs +
  any Figma links. Ticket itself has no AC-relevant info but carries a
  `parentKey`/`epicKey` → fetch that key too (`jira-ticket-parent.json`) and
  extract from the parent, labeling the source ("ACs from parent EC-1200"). No
  key / SKIPPED / DEGRADED → ask the user to paste AC text; none → AC alignment is
  UNVERIFIABLE, say so. If the ticket/pasted text already cites concrete evidence
  (file:line, a key, a function name), carry it into the brief verbatim —
  Phase 4's agents verify/extend it, never re-derive it from zero.
- Bootability probe (entry point visibility per repo — e-conomic has public
  Program/Startup/EntryPoint classes; payroll-poc has top-level statements and needs
  the `public partial class Program {}` shim **in the worktree copy only**), DI seam
  check, `Database.Migrate()`-on-boot check.
- Outbound-config scan (non-loopback connection strings / external URLs reachable
  from changed code) — held for the execution consent moment.
- Contract gate: service candidate (Web SDK + Swashbuckle/NSwag/AspNetCore.OpenApi;
  ApiGateway's surface is its Ocelot route configs) AND diff touches API surface
  (`[ApiController]`, `[Route(`, `[Http*]`, `Map*(`, `ProducesResponseType`,
  DTO-path files). Pact detected independently (packages, pact JSONs, broker env).
- When the gate opens on a **committed-spec or ocelot capture path**, the
  orchestrator runs `scripts/contract-check.ps1` right here at intake — it's pure
  git + oasdiff (spec paths auto-derived from the diff set), needs no boot and no
  execution consent, and its verdict feeds the risk score on the first computation
  instead of forcing a recompute. Only the boot-capture path (payroll-poc) and the
  Pact verifier wait for Phase 7's execution consent.

### 💬 Consent — both gates, asked once, right after intake
One message, two decisions, while the machines already work: (1) **mutation** —
files in scope, estimated mutant count (calibrated density), time estimate; the
orchestrator's auto-skip judgment still applies first (a diff with nothing worth
mutating is stated in one line, never asked about); (2) **execution** — the
generated/component/API run and anti-vacuity, disclosing intake's outbound
destinations verbatim. Each answer is remembered and applied when its phase
arrives. Toggle semantics are unchanged and per-gate (`toggles.mutationConsent`,
`toggles.executionConsent`: `ask` → part of this message, `always` → stated not
asked, `never` → SKIPPED line). WHY front-loaded: consent questions used to sit
between CPU phases, so the developer's answer latency serialized with machine
time; asked here, Phases 1b–4 run while the developer reads.

### Phase 1b — Impact (script + MCP queries, 5–15 s; gated by `toggles.skipQaImpact`)
`scripts/impact-index.ps1` runs whenever `skipQaImpact` is `false` OR Phase 1c's
`skipManualTestAnalysis` is `false` (the default) — Phase 1c needs these same
seeds, so the script isn't run twice for one workspace. Both toggles `true` → skip
entirely: records the phase as `SKIPPED — disabled by config (skipQaImpact)` in the
time-ledger — the report still shows the Impact row with exactly that status, never
an omitted row — and no impact artifacts are expected. Otherwise:
`scripts/impact-index.ps1 -Manifest <path> -ConfigPath <cfg>`: seeds extracted from
the diff set (routes, symbols, DTOs, migration tables/columns), scanned across
`productRepos` ∪ `testRepos` — the UI-automation (BA) repo lives in the
latter — into `impact-index.json`. If `skipQaImpact` itself is `false`, the
orchestrator also consults Testomat for cross-repo candidates: probe whether a
Testomatio MCP is available in THIS session (pre-declared in `.mcp.json`, but its
token is per-machine — never assume it works from connectivity alone; the probe
IS the real seed query below, not a separate ping) →
search tests/suites by the seeds + the
ticket's component → `testomat-candidates.json`; no MCP configured → the same file
with `status: "SKIPPED — Testomatio MCP not configured"`; MCP connects but the
query itself 403s (a read-only token — `system_ping` can succeed while
`tests_list`/`tests_search` still reject) → `status: "DEGRADED — Testomatio token
is read-only"`, a distinct named state, never folded into the "not configured"
skip (written whenever `skipQaImpact`
is false). Overlaps
Phases 2–3 (pure scan + MCP I/O, no build contention). Feeds qa-analyst (cross-repo
fan-in) and the report's impact map + Impact matrix row. UI-automation and Testomat
hits are always **candidates** (keyword evidence), never "affected". Never blocks:
a failure here degrades the Impact row only. See Phase 1c for the separate
manual-test-candidate query, which reuses these seeds under its own toggle.

### Phase 1c — Manual test recommendation (MCP query, shares Phase 1b's 5–15 s
window; gated by `toggles.skipManualTestAnalysis`, default `false` = runs)
Opt-**out**, not opt-in like every other gated phase — the point is a developer
sees this unless they deliberately turn it off. Needs Phase 1b's
`impact-index.json` seeds (the script ran for this even if `skipQaImpact` skipped
the Impact map display). Toggle `true` → `SKIPPED — disabled by config
(skipManualTestAnalysis)`, always shown, never omitted. Otherwise: same Testomatio
MCP probe as Phase 1b — the real query classifies the lane, not a bare
connectivity check; no MCP → `manual-test-candidates.json` with `status:
"SKIPPED — Testomatio MCP not configured"`; read-only-token 403 → `status:
"DEGRADED — Testomatio token is read-only"`. Otherwise → two TQL queries, both
filtered to `state == 'manual'` (Testomat's own field distinguishing manual from
automated test records — verified live against the real project): one OR-ing the
(low-signal-filtered) seed values, one on `jira == '<ticketKey>'` when a ticket key
exists. Rank seed matches (`matchedBy: "diff-seed"` — the manual test's own text
mentions the changed code) above ticket-only matches (`matchedBy: "ticket-link"` —
filed under the same ticket, weaker evidence); cap at 5 shown, `+N more` pointing at
`manual-test-candidates.json`. Same honesty rules as every other Testomat hit:
**candidates (keyword/ticket match)**, never "this needs testing" asserted as fact.
Feeds qa-analyst and the report's own Manual testing section — visible near the
verdict, not buried in Full Evidence (see Reporting).

### Phase 2 — Unit level (scripts, 30–90 s; one artifact, four consumers)
`scripts/run-tests.ps1`: build the affected project graph once (**never the whole
e-conomic solution**), then everything `--no-build --no-restore`. Selection is
**test-class granular, both sides of the diff**: changed SUT files →
`<Class>Tests`/`<Class>Test` terms, changed files under a test project's own dir →
their own class names, untracked files included in both derivations. A profile
marked `suiteScope: "solution-wide"` (arch/static-analysis suites — qa-intake tags
them) never runs unfiltered off that heuristic: changed classes inside it run
filtered, otherwise an honest `skippedReason` entry — no local override exists;
the PR pipeline runs those suites on every PR. Coverage wraps the
affected-subset run — `--collect "XPlat Code Coverage"` where coverlet.collector is
already referenced, `dotnet-coverage collect` elsewhere (zero csproj changes) — with
`SingleHit=true`, includes narrowed to changed assemblies,
`RunConfiguration.TreatNoTestsAsError=true` (a zero-match filter must never read
green), raised `MaxCpuCount`, anti-hang timeout. Coverage capability is
self-calibrating: a mechanism recorded broken on this machine
(`calibration.coverage.*Works=false`) is skipped up front, and a completed wrapped
run with empty coverage keeps its real TRX results — only a TIMED-OUT wrapped run
re-runs plainly. `dotnet-coverage` specifically escalates to `coverlet.console`
once calibrated broken (documented osx-arm64 profiler-attach gap) rather than
skipping outright — same "no product `.csproj` change" guarantee, a genuinely
different mechanism (IL rewrite, not a profiler attach), never attempted until
`dotnet-coverage` is already proven broken HERE, at which point `run-tests.ps1`
installs `coverlet.console` itself, on demand and overlapped with build time
(never pre-installed by `setup-mcp.ps1`). **Execution is two-lane, bounded-parallel**: test projects with
no `Microsoft.AspNetCore.Mvc.Testing` reference (direct or one ProjectReference
level deep) run up to 3 concurrently with `MaxCpuCount` split so total machine
load stays ~constant; factory-booting projects run one-at-a-time with all cores
(the 5s host-build timeout is load-sensitive — sharing the machine manufactures
false reds). Every run entry's `runNote` names its lane. Every run — plain
included — now carries the anti-hang valve (a wedged testhost is killed and
reported, never hung on). Filters are built per project from
the adapter profile: `FullyQualifiedName~<TestClass>` terms (never `=` —
parameterized names), xUnit categories via trait `Category=`, NUnit via
`TestCategory=`. JS: **file-granular related selection on every runner, Nx
included** — per project, `npx jest --config <project jest.config> --ci --silent
--findRelatedTests <changed files> --json --outputFile=…` with per-test results
and cobertura coverage copied into `cov\` (so diff-coverage reads the JS lane).
Dependent projects are deliberately NOT run locally, and no mode exists to run
them — verified live before removal: `nx affected --target=test` fanned a
4-file leaf-component diff out to 40 transitive-dependent projects / 2504 tests
/ 13 min whose only signal was load-flaky failures in unrelated modules; the PR
pipeline runs the full suite plus ui-automation on every PR. The run entry's
`selection`/`selectionNote` fields state the not-run-locally scope honestly
(never silently implied covered). Then `scripts/diff-coverage.ps1` → line + branch diff
coverage ("of the lines you changed…"), refusing to report if <80% of changed files
resolve against the coverage paths. The artifact feeds: verdict, diff coverage, TRX
durations, mutation scoping. Launched in the SAME tool-call batch as Phase 4's agent
dispatch, not before it — see Phase 4.

### Phase 3 — Might-be-flaky tagging (in-artifact, zero extra runtime)
agentQ never re-runs tests to confirm flakiness — removed by design: re-runs
multiplied the run's wall-clock, and one machine's re-run still can't prove
stability. Instead `run-tests.ps1` tags **every failed test** in
`test-results.json` (`flaky.mightBeFlaky`) with a ready-to-run `rerunCommand`;
the report presents each as *failed — might be flaky: run it again yourself
(outside agentQ) with this command; a pass on re-run suggests flaky, a repeat
fail is a real failure*. The tag never softens the failure and "flaky" is never
asserted as fact from one run. Static smells (DateTime.Now, unseeded Random,
Thread.Sleep, static mutable state) are only ever **smells** — never report a
regex hit as "this test is flaky".

### Phase 4 — Analysis & authoring (agents, overlaps Phases 2–3)
Dispatch qa-analyst and (on cache miss) qa-scenario-writer in the SAME tool-call
batch as Phase 2's script call — real overlap, not two sequential phases: the
scripts finish in under two minutes, the agents run for several, so a script
artifact is ready by the time either agent needs it. When mutation consent is
already resolved yes (it was asked right after intake) and the worktree exists
(`worktree.ps1 -Ensure` issued in the same batch — checkout is I/O, it doesn't
contend with the test run), dispatch **qa-mutation-author here too**: mutant
design + injection are model/file work that overlaps Phase 2 freely; only the
DRIVER (build + test passes) waits for Phase 2 to finish (CPU-heavy phases never
overlap). qa-scenario-writer renders into the `generated/` staging dir (never a
worktree directly), so it never depends on worktree existence either. It never
reads Phase 2/3 output (only intake's `diff-set.json`/`adapter-profiles.json`), so
it's always safe to start immediately; qa-analyst does its non-coverage-dependent
sections first and treats a missing `diff-coverage.json`/`test-results.json` as
"not ready yet," not an error, if it starts before Phase 2 finishes writing them.
Both agents reuse any concrete file:line/key evidence intake already carried
forward from the AC/bug-report text instead of re-tracing it from zero — qa-analyst
verifies/extends it, qa-scenario-writer writes directly against it. This is also
where duplicate exploration used to creep in: if both agents independently grep the
same coupling, that's a sign the evidence should have been carried forward from
intake instead. qa-analyst: regression risk (including cross-repo fan-in from
`impact-index.json` / `testomat-candidates.json`), AC alignment, Socratic questions
under the
contract (≤5; each anchored to file:line evidence — an uncovered branch, a surviving
mutant, an unmet AC; answerable by one nameable test; embeds the actual domain
value; suppressed if an existing test answers it). Written QA-style — leads with
the real business/user scenario the gap represents ("if a customer's order nets to
zero…", "if Finance changes the VAT rate…"), the code citation is the evidence, not
the opener. qa-scenario-writer: scenario IR
per AC (level-tagged: business rule → component test, endpoint behavior → API test,
user journey on frontend branches → E2E spec), rendered per adapter profile into the
worktree; `scripts/render-artifacts.ps1` template-renders Postman/Hurl artifacts
from the IR (byte-stable; human artifacts, never part of a verdict). Everything
cached by base-SHA + diff-hash + AC-hash — regenerate only what changed.

### 💬 Consent: mutation
Asked as part of the combined post-intake consent (see above) — by the time this
phase arrives the answer already exists. The auto-skip judgment is unchanged:
never ask when the diff itself has nothing worth mutating (pure
literal/label/copy/config changes with no branches, conditionals, or business
logic — e.g. a UI string rename); state the skip and why in one line, don't just
go silent.

### Phase 5 — Mutation level (scripts + agent: qa-mutation-author)
Persistent worktree (`scripts/worktree.ps1 -Ensure`; dev's uncommitted diff applied
via `git apply`, untracked files copied in — usually already ensured back in Phase
4's dispatch batch). Design + injection may already have happened during Phase 4
(overlapped model/file work); the CPU-heavy steps below start only after Phase 2's
run has finished.
1. **AI business-rule tier first** (~30–45 s): qa-mutation-author designs 3–5
   semantic mutants — prefer fewer, higher-value over reaching for the old
   upper end (numeric/decimal literals, enum members, date arithmetic,
   multi-site rule rewrites — the mutations Stryker verifiably cannot express; only
   where mechanical mutants all die or none applies). All injected at once behind
   `AGENTQ_MUTANT` env-var switches (a `const` is promoted to a static property in
   the worktree copy), **one** build, then
   `scripts/semantic-mutant-driver.ps1` runs one filtered test pass per id —
   bounded-parallel (up to 3 concurrent; the switch is a per-PROCESS env var set
   via a cmd wrapper, so concurrent mutants cannot see each other's value —
   verified by an isolation test; factory-booting test projects still run
   one-at-a-time). For
   each of its OWN mutants that survives, qa-mutation-author drafts a concrete
   strengthened-assertion edit to the covering test (worktree-only) — a real
   "keep this?" candidate in the report, not just a verbal recommendation.
   Stryker's mechanical survivors (found after this tier runs) never get one —
   they stay a verbal recommendation.
2. **Reset, then Stryker mechanical tier**: after the driver, `worktree.ps1
   -Ensure` again (cheap reuse; generated tests re-materialize from staging) so the
   `AGENTQ_MUTANT` switches are GONE before Stryker runs — verified live: Stryker
   mutates the injected switch lines themselves otherwise, manufacturing artifact
   "survivors"; `stryker-run.ps1` refuses to start if it still finds them. Then
   `scripts/stryker-run.ps1` — pinned tool resolved ONCE per machine into
   `tools\stryker` via `--tool-path` (like oasdiff; a repo-committed tool-manifest
   pin still wins and is restored in the worktree — never a per-worktree install),
   **never `--since`** (verified broken for this use); `-m` globs on changed files
   minus changed-but-uncovered regions, `{start..end}` char-span hunks (padded,
   whole-file fallback if 0 mutants), `-l Basic`, `-c` = logical cores, config file
   for `coverage-analysis: perTest` / `ignore-mutations` / **`test-case-filter`
   derived from the diff-related test classes** — the baseline + per-mutant runs
   execute only those tests, because the whole-project baseline dominated the
   tier's wall-clock; the consequence binds every consumer: a survivor means
   **"no test related to this change kills it"**, never "no test in the project" —
   pre-created `-O`, anti-hang valve (kill → restore DLLs → "tested X of Y
   mutants — no claims about the rest"). **Result cache**: each (test project ×
   SUT) run is keyed by source-content hash + scope + filter + level + tool
   version into `workspace/<repoSlug>/mutation-cache/` — identical inputs reuse
   the prior report verbatim (`fromCache: true` in summary.json; steady-state
   re-runs skip Stryker entirely); timeouts/partials are never cached.
3. `scripts/merge-mutation-reports.ps1` unions both into one
   mutation-testing-elements JSON. JS side: StrykerJS + jest-runner, `--incremental`.
`-Deep` opt-in: Standard level, whole files, no scoping.

### Phase 6 — Risk score (script, <1 s)
`scripts/risk-score.ps1` — deterministic weighted formula + hard overrides; missing
signals renormalize the weights (never a silent zero) and lower the stated
confidence.

### 💬 Consent: execution
Asked as part of the combined post-intake consent (see above), outbound
destinations disclosed there. Unlike mutation, this is never the orchestrator's
judgment call to skip — it always follows `toggles.executionConsent` literally
(`ask` → part of the combined question; `always` → proceed and say so; `never` →
skip and say so). E2E additionally: dev-stack health check at THIS point (never
auto-start) — the health of the stack is checked when it's about to be used, not
when consent was asked.

### Phase 7 — Component, API & contract execution (scripts, 30 s–2 min)
- Generated component/API tests run in the worktree via
  `scripts/run-tests.ps1 -GeneratedOnly -ResultsLabel branch` (per-project
  `dotnet test --no-build --filter <profile category>` and Jest) →
  `test-results-generated-branch.json` — NEVER `test-results.json` (Phase 2's
  artifact stays intact; verified live that it used to get clobbered). One
  WebApplicationFactory per assembly (`[SetUpFixture]` / collection fixture — never
  per-test boots); `UseKestrel(0)` before init for real-HTTP on net10; EF swap
  descriptor branches by TFM.
- **Anti-vacuity in the BASE worktree**: `worktree.ps1 -EnsureBase` (persistent
  second worktree pinned at baseSha, generated tests materialized from staging,
  warm build output across runs) then `run-tests.ps1 -GeneratedOnly -WorktreeRoot
  <worktreeBaseDir> -ResultsLabel base` — every generated test must FAIL (or
  not compile) there — evidence graded "verified against base" vs "static only". A
  base-side compile failure is not automatically "failed there": `run-tests.ps1`
  now carries the real compiler diagnostic in the run entry's `failures[0].message`
  (never the old opaque "dotnet build failed"), and only a failure that names a
  symbol the diff actually adds counts as non-vacuity evidence, graded
  `verified_non_compiling_on_base` — a compile failure unrelated to the diff is a
  base-environment problem, not vacuity evidence, and must never be counted as a
  pass on the anti-vacuity check. A vacuously-green generated test is worse than
  none. Never flip the main worktree
  to base and back (each flip cost a full checkout + cold rebuild — the legacy
  `-FlipToBase`/`-FlipToBranch` modes exist for recovery only).
- **Contract lane** (`scripts/contract-check.ps1`):
  - e-conomic: committed-spec shortcut — working-tree `openapi-*.json` vs
    `git show <baseSha>:<path>`, no boot needed.
  - payroll-poc: boot-capture — `/openapi/v1.json` then `/swagger/v1/swagger.json`
    from the booted factory (base side from the warm worktree boot).
  - ApiGateway: diff the Ocelot route configs — its API surface IS config.
  - Diff via pinned `oasdiff`: `breaking --fail-on ERR --format json` + `changelog`;
    classification from the JSON `level` field, never the exit code; cite rule ids.
  - Pact (when detected): existing verifier project → run it whole (it owns the
    provider states), consent-gated; else an ephemeral in-run PactNet verifier
    against the Kestrel URL (broker read-only, selectors MainBranch +
    DeployedOrReleased + EnablePending, or `WithDirectorySource("pacts")`). Unknown
    `Given(...)` states → **unverifiable, not failed**. Never publish.

### Phase 7b — E2E (frontend branches, dev stack confirmed)
Execute **cached** specs: `npx playwright test --grep @agentq` with the JSON
reporter configured in the config file (the `--reporter` flag can't carry options),
`--trace=retain-on-failure`. New scenarios: qa-e2e-author authors via Playwright MCP
**as a background task** → specs land in the cache for the next run, flake-gated
(`--repeat-each=3 --fail-on-flaky-tests`) and linted (no waitForTimeout / XPath /
`.nth()` / `force:true` / `test.only` / hardcoded URLs; web-first asserts; ≥1 assert
traced to a named AC). `@playwright/test` must be a local devDependency — never let
npx float-install. Login: the credential-less local dev logon
(`/secure/default_dev.aspx`, option `<agreement>/<user>`, then navigate to
`LOCAL_DEV_CLIENT_URL`) — same mechanics as manual-testing-ai-agents.

### Phase 7c — Design conformance (frontend branches with a Figma link)
qa-e2e-author (off the critical path): pull the linked frames via Figma MCP
(read-only), screenshot the implemented screens on the dev stack, compare structure /
text / layout / tokens / designed states. Findings: `DEVIATES — objective` (side-by-
side evidence) vs `NEEDS HUMAN JUDGMENT` (never asserted as a defect). Scoped to the
linked frames only. No link → `SKIPPED — no design linked in ticket`.

### Phase 8 — Report (agent: qa-report-synthesizer, then script: render-evidence.ps1)
Two writers, in order, not one agent writing both files (all binding rules in
Reporting below):
1. **`qa-report-synthesizer` writes the main report** —
   `reports/<repoShort>-<ticket-or-branch>-<YYYY-MM-DD-HHmm>.md`: max 2 pages,
   plain language for a reader with no QA background and no full-application
   context, feature/user-flow framing (never file:line), the fixed icon set.
   Header line with result → what the branch does → ≤3 findings (each with a
   🛠️ Do-this action) → ✅ What's good bullets (first bullet: were the
   ticket's acceptance criteria met — always, evidence-qualified) → ⚖️ merge
   risk in one plain sentence → ❓ ≤3 questions → 🖐️ manual-check suggestions
   (when any) → 🔍 what-was-checked table → 🧪 keep-these-tests list →
   📄 evidence-file link. Its inputs are `analyst-brief.json`,
   `risk-score.json`, `jira-ticket.json`, plus inline context the orchestrator
   passes in the dispatch prompt (branch summary, manual-test titles, failed
   tests, the keep-list) — it never reads raw artifacts like
   `test-results.json` directly. It also writes `report-selection.json`
   (shape in `scripts/CONTRACTS.md`): which ≤3 findings/questions (by
   `analyst-brief.json`'s own ids) it used, so the evidence file shares the
   exact same numbering.
2. The orchestrator times step 1's dispatch and appends
   `{ name: "report", actor: "qa-report-synthesizer", seconds: <measured>,
   outcome: "RAN" }` to `time-ledger.json` — the one phase that used to be
   unmeasurable because it lived only inside the file it was writing.
3. **`scripts/render-evidence.ps1` writes the evidence file** — same name +
   `-evidence.md`, deterministically, zero model calls: ONE merged
   Phase/Actor/Seconds/Outcome table (from `time-ledger.json`, now including
   the report phase from step 2 — no more separate, duplicated "Run summary"
   and "Time ledger" tables), per-finding file:line detail (from
   `analyst-brief.json` + `report-selection.json`, exact same numbering as the
   main report), capability matrix, impact map + manual-testing detail,
   per-level sections (contract ERR/WARN phrasing and the "most likely to
   catch a regression" list render straight from `contract-report.json`/
   `risk-score.json` — no agent judgment needed for either), the
   generated-scenarios table, the full Socratic questions, the risk-signal
   ledger, capture provenance, and the command log.
After both writers finish, the orchestrator re-saves both files as UTF-8
**with BOM** (one PowerShell `[IO.File]::WriteAllText` with
`UTF8Encoding($true)`) so Windows editors render the icons and dashes
correctly. Append score→outcome to `workspace/<repo>/history.jsonl`.
**Chat delivery rule: never restate the verdict or findings in chat.** The
report file is the single place the verdict lives — the closing chat message is
a clickable link to the main report (evidence file linked inside it), plus only
what the report cannot carry: the keep-tests question and any consent-denied /
follow-up offers. Duplicating the Result line, findings, or risk band in chat
creates a second, drifting copy of the verdict. Then ask **which generated
tests to keep** — on explicit yes, apply them to the product repo as a diff the
developer reviewed in chat (placement per the adapter profile — payroll's
`test_placement` allow-list is enforced there).

### Phase 9 — Cleanup verification (script)
`scripts/worktree.ps1 -Verify`: worktree clean and rebuildable, no
stryker-unchanged orphans, product repo untouched.

## Reporting (the rules that keep the tool trusted)

**Audience first.** The main report is for a developer with **no QA background
and no full-application context**: max 2 pages, plain everyday words, every
finding framed by the feature and the user flow ("a settled payment that fails
to post disappears silently") — never opened with a class name or line number.
Everything technical lives in the sibling `-evidence.md` file, linked once at
the bottom. The honesty rules bind both files.

**Fixed icon set** — the same icons in every report, so readers learn to scan:
🔴/🟢 overall result · ❌ problem found · 🛠️ the one action that fixes it ·
✅ good / passed · ⚠️ needs attention or couldn't be checked · ⏭️ not needed
this run · ❓ question for the team · 🖐️ manual-check suggestion · 🧪 ready-made
test · ⚖️ merge risk · 📄 evidence-file pointer · 🧭 what the branch does.
Never improvise new icons.

**Plain-language rule** — no QA jargon in the main report; fixed phrasings:
- surviving mutant → "we deliberately broke this rule and every test stayed
  green"
- diff coverage 70% → "about 7 in 10 changed lines run under a test (counting
  only tests related to this branch)" — never a global percentage
- breaking contract change → "a change that breaks anyone already using this
  API"
- flaky test → "a test that passes and fails randomly"
- vacuous test → "a test that would pass even without your change"
The precise vocabulary (scenario states, AC evidence grades, mutant ids, oasdiff
rule ids) is mandatory in the evidence file and forbidden in the main report.

**Main report structure** (`templates/report/report-template.md`; hard caps —
cut, don't compress; overflow goes to the evidence file):

```
# 🧾 QA review — <repo> · <ticket>
<branch> · <date> · **Result: 🔴 Not ready yet | 🟢 Ready to open**
**🧭 What this branch does:** one plain sentence.

## ❌ N things to fix first          (max 3 — or "## ✅ Nothing blocking found")
**1. <plain title — what would go wrong for a user/partner>**
2–3 plain sentences on the consequence and why nothing catches it today.
🛠️ **Do this:** the one action doable right now.

## ✅ What's good                     (bullet points, one concise sentence each;
                                     first bullet is ALWAYS the acceptance-
                                     criteria note — met or not, evidence-
                                     qualified, ⚠️ when unverifiable)
**⚖️ Merge risk: <band>** — one plain sentence why.

## ❓ Questions for the team          (max 3; full set in the evidence file)
## 🖐️ Worth checking by hand         (only when Phase 1c found candidates; ≤3)
## 🔍 What was checked               (one table: plain question per row, ✅/⚠️/❌/⏭️)
## 🧪 Ready-made tests (N) — keep them?   (numbered one-liners, no paths)
📄 Full technical detail: [<name>-evidence.md](<name>-evidence.md)   (relative markdown link, not just the filename)
```

- Finding ranking: breaking API > silent wrong behavior > missing test. A clean
  run gets `🟢 Ready to open` + the ✅ bullets — telling a developer they're
  *done* is what builds the habit.
- In the 🔍 table a skipped or degraded check reads `⚠️ couldn't check — <plain
  why>` — never a pass, never an omitted row. Merge risk band verbatim from
  `risk-score.json`; never a "probability of passing CI".

**Evidence file** (`templates/report/evidence-template.md`, rendered
deterministically by `scripts/render-evidence.ps1` — zero model calls) holds
everything the main report dropped, at full rigor:
- ONE merged run/phase table (Phase/Actor/Seconds/Outcome — no separate,
  duplicated "Run summary" and "Time ledger" sections) + per-finding technical
  detail (file:line, mutant ids, coverage numbers, test names — one subsection
  per main-report finding, from `analyst-brief.json` + `report-selection.json`).
- Capability matrix: one row per level **plus one Impact row** (cross-repo /
  UI-automation / Testomat), exactly one of `RAN` / `DEGRADED — <why>` /
  `SKIPPED — <why>`. A skipped stage can never read as a pass; the Impact row
  appears in every report (config-skipped → `SKIPPED — disabled by config`).
- Impact map (only when the phase ran): ≤3 evidence items per lane (same repo /
  other repos / UI-automation / Testomat / Pact consumers), `+N more` pointing
  at `impact-index.json`; UI-automation and Testomat hits are always
  *candidates (keyword match)*, never "affected" or failures; always closes
  with "no signal ≠ not affected". A main-report finding may cite impact reach
  only when attached to a confirmed finding.
- Manual testing detail (whenever Phase 1c ran, independent of the Impact map):
  ≤5 candidates, `diff-seed` matches ranked above `ticket-link` matches,
  `+N more` pointing at the artifact. Always *candidates (keyword/ticket
  match)* — never "you must test this". Toggled off or no Testomatio MCP →
  state that plainly, never omit silently.
- Scenario states, only: `EXECUTED — PASSED` / `EXECUTED — FAILED (finding)` /
  `GENERATED, COMPILES, NOT EXECUTED — <reason> — run: <command>` /
  `GENERATED, NOT EXECUTED — <reason>`.
- AC claims carry their evidence source: `MET — verified by executed scenario X
  (failed on base)` ≠ `MET — verified (vacuity: static only)` ≠ `MET — verified
  (vacuity: does not compile on base — references branch-new <symbol>)` — a base
  build that fails because the generated test names a symbol the diff itself adds
  is *stronger* non-vacuity evidence than a plain runtime failure (the test can't
  even exist without the branch change), so it earns its own grade rather than
  folding into "static only"; a base compile failure that does NOT trace to
  anything the diff adds is not vacuity evidence at all — that's `UNVERIFIABLE —
  base build fails for reasons unrelated to this diff` plus a separate
  environment-risk note, never claimed as AC evidence either way — ≠ `APPEARS MET —
  static reading only` ≠ `NOT MET — <observed vs expected>` ≠ `UNVERIFIABLE —
  <reason>`.
- Mutation reports **absolute survivors** ("a wrong X would ship"), never a
  percentage — a scoped mutation score compares to nothing. Suppress
  `NoCoverage` mutants (they're coverage findings). When the run used a
  `test-case-filter` (summary.json carries it), every survivor claim is scoped
  honestly: "no test **related to this change** kills it" — never "no test in
  the project kills it". A `fromCache: true` run states that its verdicts were
  reused from an identical prior run, not re-executed.
- Contract: ERR → "breaking change to the documented API contract (rule <id>) —
  any consumer relying on this shape will break"; WARN → "potentially
  breaking — needs human judgment"; only Pact findings may name a consumer.
- Diff coverage is always "coverage of changed lines, from tests related to
  this branch". Never "riskiest tests" — three named lists: *most likely to
  catch a regression here* / *flaky-risk smells (static)* / *might be flaky
  (failed this run — each with its verbatim rerun command, confirmed only by the
  developer's own re-run outside agentQ)*.
- Risk score: signal ledger + methodology ("heuristic scored from this diff
  only; not calibrated against CI history"); missing signals show as reduced
  confidence, never silently absent.

## Subagents

| Agent | Judgment it owns | Spawns |
|---|---|---|
| `qa-intake` | Diff classification, adapter profiles, Jira ACs + Figma links, bootability/outbound/contract probes | every run |
| `qa-analyst` | Regression risk, AC alignment, gap lattice, static flaky-smell detection, Socratic questions, manual-test-candidate framing — from script JSON only; writes `analyst-brief.json`, not prose (contract phrasing and the "most likely to catch a regression" list are fully mechanical, rendered by `render-evidence.ps1`) | every run |
| `qa-scenario-writer` | Scenario IR per AC + component/API test renders per adapter profile | cache miss |
| `qa-mutation-author` | The 3–5 business-rule mutants | mutation consented |
| `qa-e2e-author` | Playwright authoring/healing + Figma design conformance — never spec execution | background, frontend branches |
| `qa-report-synthesizer` | The main report only — selects/ranks findings into `report-selection.json` | every run |

**Model tiers**: `qa-intake` and `qa-report-synthesizer` are pinned to a faster
model (`model: sonnet` in their frontmatter) — both sit alone on the critical
path (intake opens every run, the report closes it with nothing overlapping)
and their work is rule-following extraction/rendering, not open judgment. The
other four inherit the session model: qa-analyst and qa-mutation-author carry
the judgment the tool's findings depend on, qa-scenario-writer's tests must
compile first try (a bad render burns a CPU cycle), and qa-e2e-author runs in
the background where a faster model buys no wall-clock.

## /qa-impact — blast-radius analysis (standalone entry point)

"What could my change affect?" — same-repo features, other repos, UI-automation
(BA) specs, Testomat tests — for a branch diff or a named `--target` (endpoint,
table, symbol) before any code exists. The same lanes run inside `/qa-review`
(Phase 1b — same script, same artifacts) when `toggles.skipQaImpact` is set to
`false` (the default `true` skips them, honestly reported); this skill is the
standalone entry for asking without a review and **ignores that toggle** — explicit
invocation always runs. Static and strictly read-only:
`scripts/impact-index.ps1` extracts seeds from the diff (routes, symbols, DTOs,
migration tables) and scans `productRepos` ∪ `testRepos` for
references (`impact-index.json`, CONTRACTS.md). Existing-test and Pact lanes reuse
prior `/qa-review` artifacts, never generate their own. The Testomat lane runs
only when a Testomatio MCP is configured in the current session — probed per run,
never assumed present, never required; absent → `SKIPPED`. Output is a
deliberately concise impact map: ≤3 evidence items per lane with `+N more`
pointing at the artifact, textual UI/Testomat hits always labeled *candidates*,
closing with "no signal ≠ not affected". Details: `.claude/skills/qa-impact/SKILL.md`.

## Roadmap (Phase 2 — explicitly not built yet)

Plugin packaging (internal marketplace, `/agentq:qa-review`) and headless CI mode
(`claude -p … --bare --output-format json`; consent gates become flags; Socratic
questions become report annotations; results posted to the PR). Same agents, skills,
and scripts — different invocation shell. Also noted for v2: the
gateway-vs-monolith spec drift check, message/proto contract checks beyond
detection, Testomatio sync of kept tests.
