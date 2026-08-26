---
name: qa-review
description: Shift-left QA review of a product-repo feature branch before it becomes a PR — unit/mutation/component/API(+contract) levels, plus E2E and Figma design conformance on frontend branches. Usage - /qa-review [--branch <name-or-fragment>] [--repo <slug-or-fragment>] [--worktree <path-or-name>] [--ticket <KEY>] [--quick], all optional, order-independent, and combinable with plain natural language ("test my branch EC-8876") or a bare branch name with no flags at all. --quick = static lanes only (intake, committed-spec contract diff, impact, analysis, report — no test execution, no mutation), every execution-dependent claim honestly graded. The repo/worktree is auto-detected from whichever registered checkout (including a developer's own `git worktree add` siblings) has a matching branch checked out. Reviews the branch currently checked out in the configured local clone, including uncommitted and untracked work.
---

# /qa-review — orchestration

You are the primary agent for an agentQ run. `CLAUDE.md` is the authoritative
workflow document — phases, safety rules, reporting rules. This skill is the
run-loop checklist. Artifact shapes: `scripts/CONTRACTS.md`.

All `scripts/*.ps1` are cross-platform PowerShell. In a PowerShell session invoke
them directly; from a bash/zsh shell (macOS/Linux) prefix with `pwsh`, e.g.
`pwsh scripts/worktree.ps1 -DetectRepo …`.

**Lean reads (standing rule)**: never `Read` a full artifact when a script's own
stdout summary line already answers the question, or a script exists to answer
it mechanically — `test-results.json`'s pass/fail counts come from
`run-tests.ps1`'s own summary line, not a `Read`; `analyst-brief.json`/
`mutants.json`/etc. for a report or analyst dispatch come from
`scripts/report-pack.ps1` (below), not a whole-file `Read`. Reserve full `Read`s
for debugging a specific failure, never normal flow — a heavier orchestrator
context is more likely to trigger a mid-run compaction (verified live
2026-08-25: one froze a run for ~3.5 minutes) and every full artifact read is a
round-trip that isn't free. Concretely, `mutation-report.json` (can run 1MB+)
should never be `Read` at all; `jira-ticket.json`'s full description is for
`qa-intake` to read once, not for the orchestrator to re-read later.

## Inputs
All inputs are optional and order-independent — provide whichever you know, as plain
language or as flags (`--branch feature/EC-8876 --ticket EC-8876`), or nothing but a
bare branch name (`/qa-review feature/EC-8876`, no flag prefix at all — still just a
hint, handled the same as `--branch`). None of this is a rigid CLI grammar — read
intent, then map onto these four slots:

- **`--worktree <path-or-name>`** — the developer knows which worktree they mean,
  either as a real local path OR as its short name (the directory's basename —
  e.g. `payroll-poc-EC-8876` from `git worktree add ../payroll-poc-EC-8876 ...`).
  Check `Test-Path` yourself first: if it resolves to a real directory on this
  machine → `-WorktreePath <path>` (exact override, skips ALL branch/hint matching,
  step 1). If it does NOT resolve as a path (just a bare name/fragment) → fold it
  into `-Hint` instead — the scan matches a hint against branch name, worktree
  directory basename, *and* commit subjects, so a bare name still resolves.
- **`--repo <slug-or-fragment>`** — narrows which registered repo to look at.
  Resolve a fragment ("payroll" → `e-conomic/payroll-poc`) yourself against
  `productRepos` before calling the script — it wants the exact key
  (`-RepoFilter`). Without `--worktree`, this only picks the repo; if that repo has
  more than one matching worktree, resolution still has to pick among them (below).
- **`--branch <name-or-fragment>`** and **`--ticket <KEY>`** — both are just a
  **hint** (`-Hint`) for matching a worktree's branch name, its directory basename,
  or its last 5 commit subjects; a ticket key matches the exact same way a branch
  fragment does. If both are given, prefer `--branch` (more specific); a Jira key
  mentioned in plain prose (no flag at all) works identically to `--ticket`.
- Nothing given at all → still works: no `-Hint` finds whichever registered repo
  (or worktree of it) has a non-default branch checked out.
- Ticket key, if not otherwise given, is still extracted from the branch/commits by
  `qa-intake` in step 2 — `--ticket` only short-circuits that extraction.
- **`--quick`** (or plain language: "quick review", "static only") — run steps
  1–2c + the committed-spec contract diff + `qa-analyst` + the report ONLY: no
  unit execution, no mutation, no generated-test execution. Every
  execution-dependent claim is graded honestly (`APPEARS MET — static reading
  only`; the 🔍 table's unit/mutation/execution rows read `SKIPPED — quick mode`,
  never a pass), the report header names the mode, and both consent gates are
  skipped as `SKIPPED — quick mode`. Offer the full run as the follow-up.

## Background-agent & background-job watchdog (applies to every dispatch below)

**Why this exists:** on 2026-08-25, `qa-scenario-writer` and `qa-mutation-author`
were dispatched in the background and both hit a session-level stream stall. With
no watchdog, the orchestrator's only strategy was "wait for the completion
notification" — which never came for 52 minutes. This procedure bounds that to a
few minutes and keeps the developer informed the whole time. Target: **a full run
never exceeds 10 minutes** (see CLAUDE.md Performance principles).

**Run budget**: at the combined-consent moment (step 2), capture the current time
(`date +%s` via Bash, or `Get-Date` via PowerShell) as the run's start. Every
stall decision below checks `remaining = 600s - (now - runStart)`.

**Per-dispatch ceiling** (1.5× the agent's target, floor 3 min — see each step
below for which applies):
| Agent | Target | Ceiling |
|---|---|---|
| `qa-intake` | 90s (cache hit) | 3 min |
| `qa-analyst` | 180s | 4.5 min |
| `qa-scenario-writer` | 180s | 4.5 min |
| `qa-mutation-author` (either dispatch) | 180s | 4.5 min |
| `qa-e2e-author` | n/a — background, off critical path (CLAUDE.md Phase 7b: never blocks the verdict) | 15 min, informational only — not gated by the run budget; a stall here just means its addendum is missing this run, reported as such |
| background shell job (`stryker-run.ps1`, `worktree.ps1 -EnsureBase`) | the script's own `-TimeoutMinutes`/anti-hang valve | that valve + 1 min |

**Procedure for an agent dispatch** (every `Agent` tool call in this skill except
`qa-e2e-author`):
1. Dispatch the agent AND start a paired background timer for its ceiling
   (`sleep <ceilingSeconds>` via Bash, or `Start-Sleep -Seconds <n>` via
   PowerShell — either is cross-platform; never a `cmd.exe`-only construct) with
   `run_in_background: true`, in the **same tool-call batch** as the dispatch.
   Whichever completes first re-invokes you.
2. **Agent's own completion notification arrives first** → sanity-check it
   before accepting it as done: does its result actually match what it was
   asked for (the expected workspace artifact exists / the response isn't a
   vague "I'll wait for X" placeholder)? Verified live 2026-08-25: a dispatched
   agent can report **completed** to the harness while it had spawned its own
   untracked background work and returned an incomplete placeholder answer — a
   **false completion**, distinct from a silent stall, that a bare "wait for
   the notification" check does not catch. If the result looks genuinely done →
   normal flow, the timer later firing is a no-op. If it looks incomplete →
   treat it exactly like a stalled dispatch from step 3b onward (`SendMessage` a
   nudge to resume it — confirmed live: a nudged agent correctly picked back up
   and finished with the right answer once told to actually wait for its own
   background work).
3. **Timer fires first** → the agent is running long or has stalled:
   a. Stream one status line immediately ("`<agent>` is past its expected time
      (ceiling `<n>`s) — checking on it"). Never go dark.
   b. `ListAgents` to confirm it's still listed, then `SendMessage` a short nudge
      ("status check — please report progress or continue") and start a second,
      short **20s grace timer** the same way — tightened from an initial 45s
      after live testing (2026-08-25) showed a nudged, genuinely-alive agent
      engages essentially immediately; 45s was untested caution with no
      justification once real data existed, and every second of it is dead
      weight against the 10-min target on a true stall.
   c. Grace timer fires with still no response → the dispatch is stalled. Check
      the run budget: if `remaining >= ceiling + 20s + 15s buffer`, re-dispatch a
      **fresh** `Agent` call (new instance, not a resume of the stalled one — same
      original inputs; all six agents are idempotent over their workspace inputs)
      paired with its own new watchdog timer at the same ceiling. If the budget
      does not allow it, or this is already a retry, stop: don't retry a third
      time regardless of budget.
   d. Any stall/retry gets an honest `time-ledger.json` row with the REAL elapsed
      seconds (never 0, never "not comparable" — see the corrected-ledger rule),
      labeled `DEGRADED — agent stalled, lane skipped (run-budget)` if given up,
      or noting the retry if one happened and then succeeded. The report/evidence
      file must reflect a given-up lane as degraded, never silently missing it.

**Procedure for a background shell job** (`stryker-run.ps1` in step 5,
`worktree.ps1 -EnsureBase` in step 7): same paired-timer start, but there's no
`SendMessage` target — on the timer firing first, stream the status line, then
check the job's actual state (its own log/output files, or `TaskOutput` if the
harness exposes it for that background task) rather than nudging: growing
output → extend once with a timer at half the original ceiling; no progress /
process gone → `DEGRADED` row with real elapsed time, run continues without that
phase's result (e.g., mutation results marked not completed this run).

## Run loop

1. **Preflight** — read `.claude/qa-agent-config.jsonc` (missing → tell the user to
   copy the example; stop). Resolve the repo/worktree:
   - `--worktree <value>` given AND it resolves to a real directory on this
     machine → `scripts/worktree.ps1 -DetectRepo -ConfigPath <cfg> -WorktreePath
     <value> [-RepoFilter <exact key, if --repo was also given>]`.
   - Else, `--repo` given (resolve any fragment to its exact `productRepos` key
     first) → `scripts/worktree.ps1 -DetectRepo -ConfigPath <cfg> -RepoFilter
     <exact key> [-Hint <branch, worktree-name, or ticket text>]`.
   - Else → `scripts/worktree.ps1 -DetectRepo -ConfigPath <cfg> [-Hint <branch, worktree-name, or ticket text>]`.
     (a `--worktree <value>` that did NOT resolve as a real path folds in here, as
     the hint — same slot as `--branch`/`--ticket`/a bare branch name in prose.)
   In every case, the stdout is one line of JSON (`{candidates, skipped}`) — parse
   it directly, don't treat it as prose. Exactly one candidate → proceed, telling
   the developer which repo/branch (/worktree, if it's not the registered path) was
   resolved. Zero → say what was checked and ask. Multiple → list each
   `repoSlug`/`branch`/`repoPath` and ask which one.
   Then issue `-Heal` → `-EnsureWorkspace` → `-DiffSet` as **ONE chained
   command** (`;`-chained pwsh invocations, or three PowerShell statements in one
   call) — each consumes the previous one's FILE output, not its stdout, so
   there is no judgment gate between them and no reason to spend three
   round-trips: `scripts/worktree.ps1 -Heal -RepoPath <path>` then
   `-EnsureWorkspace -RepoSlug <candidate's repoSlug> -Branch <candidate's branch>
   -RepoPath <candidate's repoPath> [-TicketKey <KEY, if known>]` — all three of
   `-RepoSlug`/`-Branch`/`-RepoPath` are required (the script throws otherwise);
   take them verbatim from the resolved candidate above, not the registered
   config path, since a `git worktree add` sibling's `repoPath` differs from it —
   to create `workspace/<repo>/<branch>/` and write `run-manifest.json` (pin the
   base SHA once — never re-resolve), then `-DiffSet -Manifest <path>` — pure
   git, no reason to make `qa-intake` wait to derive it itself. This is what lets
   `scripts/adapter-cache.ps1 -Probe` (step 2, task 3) run immediately when
   `qa-intake` starts instead of after its own diff-set derivation; `qa-intake`'s
   own task 1 guard ("if `diff-set.json` doesn't exist yet") already no-ops
   cleanly if this pre-run raced ahead of it or wasn't reached for some reason.
   Probe SDK/node/docker. First run on a repo → offer the one-time setup
   (Stryker tool restore, oasdiff download) as a consented step; declining just
   narrows lanes.
2. **Intake** — delegate to `qa-intake` with the manifest path, applying the
   watchdog procedure above (ceiling 3 min; pre-consent, so a stall here retries
   once unconditionally — the run budget hasn't started yet, see below). It writes
   `diff-set.json` + `adapter-profiles.json` + `jira-ticket.json` (the last via
   `scripts/jira.ps1` — direct REST, no Jira MCP; ALWAYS written when a ticket
   key exists, with an honest `SKIPPED — Jira not configured…` / `DEGRADED — …`
   status when the token is missing or the call fails — never assume the token
   exists on this machine. When the ticket itself has no AC-relevant info it
   follows `parentKey`/`epicKey` into `jira-ticket-parent.json` and labels the
   AC source) and returns the brief (levels armed, ACs + Jira status, Figma
   links, bootability, outbound destinations, contract gate). If it reports no
   diff vs base → tell the user there's nothing to review; stop.
   If no ticket/AC source (or the Jira lane is SKIPPED/DEGRADED with nothing
   pasted) → ask the user to paste ACs or continue with
   AC-alignment UNVERIFIABLE.
   **Contract lane, committed-spec/ocelot capture paths only**: when intake's
   contract gate opens and the capture path needs no boot, run
   `scripts/contract-check.ps1 -Manifest <path>` NOW (spec paths auto-derived
   from diff-set.json; ApiGateway → `-Mode ocelot-diff`) — pure git + oasdiff,
   no consent needed, and the risk score gets its contract signal on the first
   computation. The boot-capture path (payroll-poc) and Pact stay in step 7.
   **💬 Combined consent (immediately after intake, one message)**: capture the
   run-start timestamp now (`date +%s` / `Get-Date`) — this anchors the
   10-minute run-wide budget the watchdog procedure above checks for every
   dispatch from here on. Ask BOTH
   gates now per their toggles — mutation (scope, calibrated mutant/time
   estimate; your nothing-worth-mutating auto-skip judgment still applies first)
   and execution (disclose intake's outbound destinations verbatim). Remember
   the answers; apply them when steps 5/7 arrive. WHY: the developer's answer
   latency then overlaps steps 2b–4's machine work instead of serializing
   between phases. `--quick` → skip the question entirely, record both gates
   `SKIPPED — quick mode`.
2b. **Impact (gated by `toggles.skipQaImpact`, never blocking)** —
   `scripts/impact-index.ps1 -Manifest <path> -ConfigPath <cfg>` runs whenever
   `skipQaImpact` is `false` OR step 2c's `skipManualTestAnalysis` is `false` (the
   default) — step 2c needs the same seeds, don't run the script twice. Both
   toggles `true` → record `SKIPPED — disabled by config (skipQaImpact)` in the
   time-ledger and skip to step 3 (the report still shows the Impact row with that
   status). Otherwise the script writes seeds from the diff set (scans
   `productRepos` ∪ `testRepos` — the UI-automation/BA repo lives in the latter) →
   `impact-index.json`. If `skipQaImpact` itself is `false`, also consult Testomat
   for cross-repo candidates: probe with the REAL seed query, not bare
   connectivity — a Testomatio MCP pre-declared in `.mcp.json` can connect fine
   (`system_ping` OK) while its per-machine `TESTOMATIO_API_TOKEN` is read-only
   and 403s on `tests_list`/`tests_search`; classify that distinctly from "not
   configured" → search tests/suites by the seeds + ticket
   component; ALWAYS write `testomat-candidates.json` when `skipQaImpact` is false
   (status `SKIPPED — Testomatio
   MCP not configured` when no MCP; `DEGRADED — Testomatio token is read-only`
   when the query 403s — a fixed string, not ad hoc wording, so the same failure
   reads the same way on every run). Stream one line ("Impact: client 4 refs · 3 BA
   specs"). Overlaps step 3; a failure here degrades the
   Impact row only, nothing else.
2c. **Manual test recommendation (gated by `toggles.skipManualTestAnalysis`,
   default `false` — opt-**out**, unlike 2b which is opt-in)** — needs step 2b's
   seeds (`impact-index.json`, which ran above even if `skipQaImpact` skipped the
   Impact map itself). Toggle `true` → record `SKIPPED — disabled by config
   (skipManualTestAnalysis)` and skip. Otherwise, same Testomatio MCP probe as 2b
   (real query, not connectivity); available → two TQL queries, both `state ==
   'manual'`: one OR-ing the seed
   values, one on `jira == '<ticketKey>'` if a ticket key exists → write
   `manual-test-candidates.json`, ranking seed matches (`diff-seed`) above
   ticket-only matches (`ticket-link`), capped at 5. No MCP → the same file
   with `status: "SKIPPED — Testomatio MCP not configured"`; read-only-token 403 →
   `status: "DEGRADED — Testomatio token is read-only"`. Stream one line
   ("Manual testing: 2 candidates — see report"). Overlaps step 3; a failure here
   degrades this lane only.
3. **Unit** (skipped under `--quick`) — issue
   `scripts/run-tests.ps1 -Manifest <path>` (chained into
   `scripts/diff-coverage.ps1`) in the SAME tool-call batch as step 4's agent
   dispatch — don't wait for this to finish first. Selection is test-class
   granular on both sides of the diff (.NET) and file-granular
   `jest --findRelatedTests` on JS — Nx repos included, never `nx affected`:
   there is NO local run-everything mode in the tool (the PR pipeline runs the
   full suite plus ui-automation on every PR; verified live before removal that
   nx fanned a 4-file diff out to 40 projects/2504 tests/13 min of load-flaky
   noise — relay the run entry's `selectionNote` so the
   dependents-not-run-locally caveat reaches the
   developer). `suiteScope: "solution-wide"` profiles skip
   honestly (relay the skippedReason lines, they are findings about scope, not
   noise); coverage self-calibrates (a broken mechanism on this machine is skipped
   up front and reported DEGRADED; the JS related lane emits cobertura, so
   diff-coverage works there too). .NET projects execute two-lane
   bounded-parallel (factory-free projects share the machine 3-at-a-time with a
   split core budget; anything referencing Mvc.Testing runs alone — relay each
   entry's `runNote`). There are NO flaky re-runs (removed — they
   multiplied run time): every failed test lands in the artifact's
   `flaky.mightBeFlaky` with a ready-to-run `rerunCommand`; the report presents
   it as *failed — might be flaky, re-run yourself outside agentQ with this
   command* — never softening the failure, never asserting flaky as fact.
   Stream a one-liner once it lands
   ("Unit: 43/43 affected tests passed · changed-line coverage 54%").
4. **Analysis & authoring** — dispatch `qa-analyst` (always) and `qa-scenario-writer`
   (only if the scenario cache is stale for this diff/AC hash) together with step
   3's script call, in the same message — real overlap, not just the two agents
   together: the scripts finish in under two minutes, the agents run for several, so
   by the time either needs a script artifact it already exists. Apply the
   watchdog procedure to EACH agent dispatched here independently — each gets its
   own paired timer (ceiling 4.5 min) and its own stall/retry/degrade decision;
   one agent stalling must never block or delay the others. ALSO include
   `scripts/test-inventory.ps1 -Manifest <path>` in this same batch (mechanical,
   <1s — a regex scan, not a build) — its output, `test-inventory.json`, is what
   lets `qa-scenario-writer` judge per-AC coverage from existing test METHOD names
   before opening any whole file. When the mutation consent from step 2 resolved
   yes, ALSO include `scripts/worktree.ps1 -Ensure` (checkout is I/O — it doesn't
   contend with the test run) and dispatch `qa-mutation-author` in the same batch
   (its own paired watchdog timer, ceiling 4.5 min, same as the other two):
   design + injection overlap step 3 freely; only the semantic-mutant DRIVER waits
   for step 3 to finish (CPU-heavy phases never overlap).
   - `scripts/report-pack.ps1 -Manifest <path> -For analyst` (mechanical,
     included in this same batch) assembles the diff-hunks-and-adapter-profile
     half of the inline pack below — real `git diff` text per changed/untracked
     file plus the adapter-profile one-line summary — so the orchestrator's
     part of building the pack shrinks to pasting its output plus the AC text
     and intake's citations (genuine judgment from step 2's brief, not
     something a script can derive — see `scripts/CONTRACTS.md`'s
     `report-pack.ps1 output` section for why). `qa-scenario-writer` and
     `qa-mutation-author` below reuse the SAME assembled pack as `qa-analyst`
     — one script run, three dispatch prompts, not three hand-built packs.
   - `qa-scenario-writer`'s dispatch prompt carries the SAME inline evidence pack
     as `qa-analyst` (AC text verbatim, diff hunks in full, intake's citations,
     adapter-profile summary, workspace dir path) — never a re-read of
     `run-manifest.json`/`diff-set.json`/`adapter-profiles.json`. It reads
     `test-inventory.json` itself (mechanical output, not something to inline)
     before any product-repo source file, and opens an existing test file only
     to extend it or resolve a genuine name-level ambiguity — never "for
     context". It never reads step 3's output (`test-results.json`,
     `diff-coverage.json`) — nothing here depends on it, so it's always safe to
     start immediately. It renders into `<workspaceDir>/generated/` (staging —
     worktree.ps1 materializes the files into both worktrees), so it doesn't
     depend on any worktree existing.
   - `qa-mutation-author`'s dispatch prompt ALSO carries the same inline pack
     (ACs, diff hunks, citations) plus the worktree dir's absolute path (where
     it edits) — never a re-read of `run-manifest.json`/`diff-set.json`. It
     designs **3–5** mutants now (down from the old 3–8 — prefer fewer,
     higher-value ones), reading product-repo source only for injection
     mechanics (matching an existing pattern it must reproduce exactly), never
     for general context the pack already gives it.
   - `qa-analyst`'s dispatch prompt MUST carry an inline evidence pack, not just a
     workspace-dir path — this is what keeps it inside its ~10-tool-call budget
     (verified live: without this it took 437s, the single largest phase, largely
     re-reading things the orchestrator already had in-conversation). The pack is
     `report-pack.ps1 -For analyst`'s output (diff hunks, adapter-profile
     summary, impact/testomat/manual-candidate summaries, workspace path —
     mechanical) plus the AC text verbatim and
     intake's already-cited file:line evidence (from step 2's intake brief —
     genuine judgment, not something the script derives). `qa-analyst` still
     reads `diff-coverage.json`/`test-results.json` itself
     (only for its Gap Lattice and flaky sections — it's briefed to do its other
     sections first and treat those two files as "not ready yet," not an error,
     if missing when it starts) plus `mutation-report.json` when present —
     everything else (`run-manifest.json`, `diff-set.json`, `adapter-profiles.json`,
     `jira-ticket.json`, `impact-index.json`, `testomat-candidates.json`,
     `manual-test-candidates.json`) comes from the inline pack, never a disk
     re-read. Its
     output is a file, `<workspaceDir>/analyst-brief.json` (shape in
     `scripts/CONTRACTS.md`), not chat prose — its final message is a one-line
     count summary only. It does NOT interpret `contract-report.json` or rank a
     "most likely to catch a regression" list — both are fully mechanical and
     `scripts/render-evidence.ps1` renders them directly from
     `contract-report.json`/`risk-score.json`.
   - Both agents reuse any file:line/key evidence intake already carried forward
     from the AC/bug-report text instead of re-tracing it from zero — if you notice
     both agents independently grepping the same coupling on a run, that's a sign
     step 2 should have carried the evidence forward instead. `qa-analyst` in
     particular takes intake's citations as verified by default — it spends a
     read re-confirming one only when a specific finding depends on that exact
     citation being accurate, never as a blanket double-check.
   - The impact/manual lanes reach `qa-analyst` through the pack (built by
     `report-pack.ps1 -For analyst` AFTER steps 2b/2c have written their
     artifacts — build it in this step's batch, never earlier) — cross-repo
     fan-in and manual-test interpretation are part of its regression-risk
     brief, from the pack, not disk reads.
5. **Mutation** (consent already answered in step 2; the auto-skip judgment and a
   `SKIPPED — consent denied` line still apply; skipped under `--quick`) — after
   step 3 has finished (the driver and Stryker are CPU-heavy): design + injection
   may already be done from step 4's early dispatch →
   `scripts/semantic-mutant-driver.ps1`. In the SAME tool-call batch as the next
   two steps below (`worktree.ps1 -Ensure` + kicking off Stryker), dispatch
   `qa-mutation-author` again to draft `suggestedFix` entries for whichever of
   ITS OWN mutants the driver just reported as survived — this overlaps
   Stryker's own multi-minute run instead of running serially after it (this
   was ad hoc the first time it happened; it's the rule now, since suggestedFix
   drafting is model/file work with nothing to wait on once the driver's
   results exist). Apply the watchdog to this dispatch too (ceiling 4.5 min,
   same agent). Then **`scripts/worktree.ps1 -Ensure` again** (cheap reuse
   reset — removes the AGENTQ_MUTANT switches; generated tests re-materialize
   from staging; stryker-run refuses to start while switches remain) →
   `scripts/stryker-run.ps1` (**must be a background shell job, not a
   foreground command** — this phase is legitimately multi-minute; a short
   foreground timeout sends SIGTERM before the script's own anti-hang valve
   fires, yielding no mutation results and potentially orphaning
   `.dll.stryker-unchanged` backups; apply the background-shell-job watchdog,
   ceiling = its `-TimeoutMinutes` + 1 min) → `scripts/merge-mutation-reports.ps1`
   → `scripts/risk-score.ps1` (step 6, below) **as ONE chained command** — the
   two scripts have a strict sequential data dependency (risk-score reads
   merge's output file) with zero judgment in between, so there is no reason
   to spend two round-trips on it. Stream survivors as they land.
6. **Risk score** — `scripts/risk-score.ps1` (the contract signal already exists
   from step 2 on committed-spec/ocelot repos — no recompute needed later).
7. **Execution** (consent already answered in step 2, per
   `toggles.executionConsent` literally — never a judgment call to bypass;
   skipped under `--quick`): E2E additionally needs the dev-stack health check to
   pass NOW (never auto-start — hand over the command). On yes:
   `scripts/run-tests.ps1 -GeneratedOnly -ResultsLabel branch` (component/API in
   the worktree → `test-results-generated-branch.json`, never clobbering Phase
   2's `test-results.json`), then anti-vacuity AFTER mutation is done via
   `scripts/worktree.ps1 -EnsureBase` + `scripts/run-tests.ps1 -GeneratedOnly
   -WorktreeRoot <worktreeBaseDir> -ResultsLabel base` (**`-EnsureBase` can be
   multi-minute on a cold first run — background it like `stryker-run.ps1`**,
   with the same background-shell-job watchdog — no internal valve of its own
   today, so use a fixed 10-min ceiling) — never flip the main worktree.
   Boot-capture contract lane (payroll-poc) + Pact run here too.
   Frontend branches: run cached E2E specs
   (`npx playwright test --grep @agentq`); kick off `qa-e2e-author` in the
   background for new scenarios and (if a Figma link exists) design conformance
   — apply the watchdog for visibility (ceiling 15 min) but NOT the run-budget
   gate: it never blocks the report (CLAUDE.md Phase 7b), so a stall here is
   just noted and its addendum arrives next run.
8. **Report — both files are script-rendered, ONE chained command, zero model
   calls.** The plain-language judgment comes from the agents that already
   hold the context, written during the overlapped phase — qa-analyst's
   `plain`/`plainQuestion`/`mergeRiskPlain`/`whatsGoodBullets` fields,
   qa-scenario-writer's `plainTitle`, qa-mutation-author's
   `suggestedFix.plainOneLiner` — and the report phase itself is
   deterministic, ~2s, with a reproducible mechanical verdict. Run as ONE
   chained command —
   1. `scripts/render-report.ps1 -Manifest <path> -ReportPath <reports/…​.md>
      -BranchSummary "<the 🧭 one-sentence plain-language branch summary — the
      one input only the orchestrator holds>" [-Quick]` — writes the main
      report AND `report-selection.json` (mechanical: top ≤3 findings/questions
      in the analyst's own priority order; verdict = 🔴 iff a failed test, a
      NOT MET AC, a breaking contract change, or a risk hard-override, else 🟢).
   2. Append `{ name: "report", actor: "scripts/render-report.ps1", seconds:
      <measured, ~1-2s>, outcome: "RAN" }` to `time-ledger.json` + update
      `totalSeconds`.
   3. `scripts/render-evidence.ps1 -Manifest <path> -ReportPath <the same
      path>` — the `-evidence.md` companion, from the workspace artifacts +
      `analyst-brief.json` + `report-selection.json`.
   4. Re-save BOTH files as UTF-8 with BOM (PowerShell
      `[IO.File]::WriteAllText` with `UTF8Encoding($true)`).
   No agent dispatch, no watchdog, nothing to time but the chain itself.
   **Do NOT restate the verdict or findings in
   chat** — the closing message is a clickable link to the main report file
   and nothing of its content (the report is the single source of the
   verdict; a chat copy drifts). Then ask which generated tests to keep; on
   explicit yes apply them to the product repo as a reviewed diff (placement
   per adapter profile; the canonical file content lives in
   `<workspaceDir>/generated/`).
9. **Cleanup verify** — `scripts/worktree.ps1 -Verify`. Confirm product repo
   untouched.

## Hard rules (repeated because they get tested)
- A zero-match test filter, a 404'd OpenAPI route, an unreachable broker, a skipped
  consent — all become explicit `SKIPPED/DEGRADED — <why>` lines. Never a pass.
- Never write into the product repo except step 8's consented keep-tests diff.
- Never publish Pact results; never echo secret values.
- UI-automation and Testomat matches are *candidates (keyword evidence)* — never
  "affected", never failures. The Impact row follows the same SKIPPED/DEGRADED
  honesty as every other lane; never assume any MCP exists on this machine.
- Background `qa-e2e-author` results arrive after the report — relay them as an
  addendum, don't block.
