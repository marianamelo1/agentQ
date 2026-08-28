---
name: qa-review
description: Shift-left QA review of a product-repo feature branch before it becomes a PR — unit/mutation/component/API(+contract) levels, plus E2E and Figma design conformance on frontend branches. Usage - /qa-review [--branch <name-or-fragment>] [--repo <slug-or-fragment>] [--worktree <path-or-name>] [--ticket <KEY>] [--quick], all optional, order-independent, and combinable with plain natural language ("test my branch EC-8876") or a bare branch name with no flags at all. --quick = static lanes only (intake, committed-spec contract diff, impact, analysis, report — no test execution, no mutation), every execution-dependent claim honestly graded. The repo/worktree is auto-detected from whichever registered checkout (including a developer's own `git worktree add` siblings) has a matching branch checked out. Reviews the branch currently checked out in the configured local clone, including uncommitted and untracked work.
hooks:
  Stop:
    - hooks:
        - type: command
          command: "pwsh"
          args: ["-NoProfile", "-File", "scripts/watchdog-hook.ps1", "-Stop"]
          timeout: 15
  SubagentStop:
    - hooks:
        - type: command
          command: "pwsh"
          args: ["-NoProfile", "-File", "scripts/watchdog-hook.ps1", "-SubagentStop"]
          timeout: 15
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
  1–2c + the committed-spec contract diff + `qa-analyst` + **step 6 (risk
  score)** + the report ONLY: no unit execution, no mutation, no
  generated-test execution. Risk-score.ps1 still runs under `--quick` — it
  degrades honestly on its own (missing execution-dependent signals
  renormalize, `confidence: "low"`), and `testToSourceBalance`/`churn90d`
  (pure diff/git, no execution) plus `crossRepoImpact`/`uiAutomationExposure`/
  `manualTestVolume` (from step 2b/2c's artifacts, which always run in
  `--quick` too) are commonly available — so merge risk reads a real band, not
  a blanket "couldn't check". Every other execution-dependent claim is graded
  honestly (`APPEARS MET — static reading only`; the 🔍 table's unit/mutation/
  execution rows read `SKIPPED — quick mode`, never a pass), the report header
  names the mode, and both consent gates are skipped as `SKIPPED — quick
  mode`. Offer the full run as the follow-up.

## Background-agent & background-job watchdog (applies to every dispatch below)

**Why this exists:** on 2026-08-25, `qa-scenario-writer` and `qa-mutation-author`
were dispatched in the background and both hit a session-level stream stall. With
no watchdog, the orchestrator's only strategy was "wait for the completion
notification" — which never came for 52 minutes. This procedure bounds that to a
few minutes and keeps the developer informed the whole time. Target: **a full run
never exceeds 10 minutes** (see CLAUDE.md Performance principles).

**Enforcement, not just prose (GH issue #36):** this frontmatter registers a
`Stop` hook and a `SubagentStop` hook (`scripts/watchdog-hook.ps1`) for the rest
of this session. They exist because the procedure below previously worked ONLY
if the orchestrator remembered, on some later turn, to poll a deadline and to
sanity-check a subagent's final message — verified live: an overdue dispatch sat
uncleared for 13–17 minutes with zero nudge/re-dispatch/degrade, because nothing
forced the check. Now: every `-Arm`/`-Extend`/`-Clear` call below writes to
`workspace/watchdog-state.json`, and the `Stop` hook blocks (exit 2, reason on
stderr) at the end of ANY turn where an armed entry is past its deadline — so
forgetting step 3 below no longer loses the stall silently, the hook forces a
resume. The `SubagentStop` hook independently catches the false-completion
pattern in step 2 (a stall placeholder reported as done) on the four
model/file-work agents, before you'd even see the result. Treat a watchdog
block as the hook doing its job, not an error: read the reason, act on it (per
steps 3b–3e below), then continue. Run `pwsh scripts/watchdog-hook.ps1
-ClearAll` once at Phase 0 (below) and once at Phase 9 cleanup, so a run never
starts or ends with a stale entry from an earlier task in this same session.

**Run budget**: at the combined-consent moment (step 2), capture the current time
(`date +%s` via Bash, or `Get-Date` via PowerShell) as the run's start. Every
stall decision below checks `remaining = 600s - (now - runStart)`.

**Per-dispatch ceiling** (1.5× the agent's target, floor 3 min — see each step
below for which applies) and **checkpoint artifact** (the file each agent is
briefed to write EARLY, before its expensive step — GH issue #32: on-disk
progress is the only liveness signal this procedure trusts):
| Agent | Target | Ceiling | Checkpoint artifact |
|---|---|---|---|
| `qa-intake` | 90s (cache hit) | 3 min | `adapter-profiles.json` (written before the deeper probes) |
| `qa-analyst` | 180s | 4.5 min | `analyst-brief.json` at `status: "partial"` (findings/AC/questions before the coverage-dependent sections) |
| `qa-scenario-writer` | 180s | 4.5 min | first file under `<workspaceDir>/scenarios/` or `generated/` |
| `qa-mutation-author` (either dispatch) | 180s | 4.5 min | `mutants.json` at `status: "designed"` (design before injection) |
| `qa-e2e-author` | n/a — background, off critical path (CLAUDE.md Phase 7b: never blocks the verdict) | 15 min, informational only — not gated by the run budget; a stall here just means its addendum is missing this run, reported as such | n/a |
| background shell job (`stryker-run.ps1`, `worktree.ps1 -EnsureBase`) | the script's own `-TimeoutMinutes`/anti-hang valve | that valve + 1 min | the job's own log/output files |

**Procedure for an agent dispatch** (every `Agent` tool call in this skill except
`qa-e2e-author`):
1. Dispatch the agent AND start a paired background timer for its ceiling
   (`sleep <ceilingSeconds>` via Bash, or `Start-Sleep -Seconds <n>` via
   PowerShell — either is cross-platform; never a `cmd.exe`-only construct) with
   `run_in_background: true`, in the **same tool-call batch** as the dispatch.
   **Capture the timer's own task id from that tool call's result** — you need
   it later to stop the timer (GH issue #52 below). In the SAME batch, also arm
   the watchdog state file (this is what the `Stop` hook enforces, per GH issue
   #36 above): `pwsh scripts/watchdog-hook.ps1 -Arm -Label <label> -Agent
   <agent-type> -CeilingSeconds <ceiling> -TimerTaskId <the captured timer task
   id>` (drop the `pwsh` prefix in a native PowerShell session). Use the SAME
   `<label>` at every subsequent `-Extend`/`-Clear`/re-`-Arm` for this dispatch
   — it's the only key the hooks and this procedure use to refer to it.
   Whichever completes first re-invokes you.
2. **Agent's own completion notification arrives first** → sanity-check it
   before accepting it as done: does its result actually match what it was
   asked for (the expected workspace artifact exists / the response isn't a
   vague "I'll wait for X" placeholder)? Verified live 2026-08-25: a dispatched
   agent can report **completed** to the harness while it had spawned its own
   untracked background work and returned an incomplete placeholder answer — a
   **false completion**, distinct from a silent stall, that a bare "wait for
   the notification" check does not catch (the `SubagentStop` hook now also
   screens for this pattern independently, before this check even runs). If
   the result looks genuinely done → clear its entry (`-Clear -Label <label>`)
   **and, in the SAME turn, `TaskStop` the paired timer** (GH issue #52: the
   timer keeps running after `-Clear` otherwise, and fires its own useless
   "background command completed" notification minutes later). Don't rely on
   having remembered the timer's task id from step 1 across the wait — `-Clear`
   itself echoes it back on stdout as `ACTION REQUIRED: ... call TaskStop
   '<id>' now` whenever the entry was armed with one; treat that line as a
   literal instruction for this same turn, not just informational. If it looks
   incomplete → treat it exactly like a stalled dispatch from step 3b onward
   (`SendMessage` a nudge to resume it — confirmed live: a nudged agent
   correctly picked back up and finished with the right answer once told to
   actually wait for its own background work). Leave the entry armed while
   incomplete — clearing it early would blind the `Stop` hook to a dispatch
   that isn't actually done (and would prematurely tell you to stop a timer
   still doing its job).
3. **Timer fires first** → the agent is running long or has stalled:
   a. Stream one status line immediately ("`<agent>` is past its expected time
      (ceiling `<n>`s) — checking on it"). Never go dark.
   b. **Check the dispatch's checkpoint artifact FIRST** (per-agent, from the
      table above — existence + last-write time): written or updated since this
      dispatch started → the agent is demonstrably progressing; extend ONCE by
      ~60s (a new background timer — the original one already fired, that's
      why you're here; capture ITS task id too — AND `pwsh
      scripts/watchdog-hook.ps1 -Extend -Label <label> -AdditionalSeconds 60
      -TimerTaskId <the new timer's task id>` so the `Stop` hook's deadline
      moves with it and the state file's paired-timer id stays current for
      whichever `-Clear` eventually fires per step 2 above; at most one
      extension per dispatch, ever) and skip the nudge. On-disk progress is
      the ONLY liveness signal this
      procedure trusts — verified live (GH issue #32, reproduced 2-for-2): a
      nudged `qa-mutation-author` replied immediately and coherently
      ("Injecting now — four switches") having written zero bytes, and the
      lane was still lost; a second run's agent never replied at all with the
      identical outcome. A chat reply is not evidence of anything.
   c. No checkpoint progress → `ListAgents` to confirm it's still listed, then
      `SendMessage` a short nudge ("status check — Write your checkpoint
      artifact NOW with whatever you have, then continue") and start a second,
      short **20s grace timer** the same way. When the grace timer fires,
      re-check the checkpoint artifact: appeared/updated during the grace →
      treat as (b), one ~60s extension. Still nothing on disk — whether or not
      the agent replied — the dispatch is stalled; stop it (`TaskStop`). (The
      20s figure stands from 2026-08-25 live testing — an alive agent engages
      essentially immediately — but per the above, engaging ≠ progressing:
      only the artifact re-check decides, never the reply.)
   d. **Salvage before deciding on a retry** — a checkpoint left by the dead
      dispatch changes what a retry even is. A **retry** (inject-only or full
      fresh) is a fresh dispatch cycle exactly like step 1 — start its own new
      paired background timer, capture ITS task id, and re-`-Arm` the SAME
      label with a fresh ceiling AND that new `-TimerTaskId` (upsert — no
      separate clear needed first; this overwrites the old, already-fired
      timer id, same as step 3b's `-Extend`); **giving up** clears it
      (`-Clear -Label <label>`) since there's nothing left to watch — the
      original timer for THIS dispatch already fired (that's why you're in
      step 3 at all), so there's normally nothing live to stop here, but
      follow the same rule as step 2 regardless: if `-Clear`'s output still
      names a live timer task id (e.g. one left over from an extension in
      (b)), `TaskStop` it in this same turn:
      - `mutants.json` at `status: "designed"` → the design work is safe; the
        retry is a cheap **inject-only** re-dispatch of `qa-mutation-author`
        ("`mutants.json` exists at status designed — read it, inject the
        switches, update the status; do NOT redesign") — re-`-Arm` the label
        for the new dispatch's ceiling. If the budget can't
        even carry that, degrade the lane to `DEGRADED — mutants designed,
        not executed (agent stalled before injection)` and `-Clear` the label —
        the designs stay in
        `mutants.json` and the evidence file says so; never report the tier
        as if nothing was produced.
      - `analyst-brief.json` at `status: "partial"` → render from the partial
        brief with the gap-lattice/flaky sections honestly degraded
        (`DEGRADED — analysis cut short after checkpoint`) and `-Clear` the
        label, rather than
        losing the findings/AC grades/questions it already contains.
      - No checkpoint at all → full fresh re-dispatch (same original inputs;
        all six agents are idempotent over their workspace inputs), budget
        permitting: `remaining >= ceiling + 20s + 15s buffer` — re-`-Arm` the
        label for the new dispatch. If the budget
        does not allow it, or this is already a retry, stop: don't retry a
        third time regardless of budget — `-Clear` the label and degrade the
        lane instead.
   e. Any stall/extension/retry gets an honest `time-ledger.json` row with the
      REAL elapsed seconds (never 0, never "not comparable" — see the
      corrected-ledger rule), labeled `DEGRADED — agent stalled, lane skipped
      (run-budget)` if given up with nothing salvaged, the specific salvage
      label from (d) if partially salvaged, or noting the retry if one
      happened and then succeeded. The report/evidence file must reflect a
      given-up lane as degraded, never silently missing it.

**Procedure for a background shell job** (`stryker-run.ps1` in step 5,
`worktree.ps1 -EnsureBase` in step 7): same paired-timer start (also `-Arm` a
label for it with the paired timer's captured `-TimerTaskId`, same as an agent
dispatch — the `Stop` hook doesn't distinguish agent dispatches from background
shell jobs, it just checks the state file), but there's no
`SendMessage` target — on the timer firing first, stream the status line, then
check the job's actual state (its own log/output files, or `TaskOutput` if the
harness exposes it for that background task) rather than nudging: growing
output → extend once with a timer at half the original ceiling (a fresh timer,
its task id passed via `-Extend ... -TimerTaskId <id>`, same as the agent
procedure's step 3b); no progress /
process gone → `DEGRADED` row with real elapsed time, `-Clear` the label, run
continues without that
phase's result (e.g., mutation results marked not completed this run). Same
rule as everywhere else in this procedure (GH issue #52): when the job finishes
on its own before its timer fires, `-Clear` the label AND, in the same turn,
`TaskStop` whichever timer task id `-Clear`'s own stdout names — never leave
the paired timer to fire its own now-useless notification later.

## Run loop

**Real-timestamp run log (applies to the whole run loop, every step below):**
capture `$runStartedAt` (ISO8601 UTC — `Get-Date -Format o` / `date -u
+%Y-%m-%dT%H:%M:%SZ`) as the literal FIRST action of step 1, before even
reading the config — this is the "developer's first message" anchor for the
evidence file's Run timeline (CONTRACTS.md `run-manifest.json`/`time-ledger.json`).
Pass it to `-EnsureWorkspace -RunStartedAt $runStartedAt` in step 1 so it lands
in `run-manifest.json`. From then on, every `time-ledger.json` phase row you
append (per the existing per-phase append pattern used throughout this run
loop) SHOULD also carry `startedAt`/`endedAt` (same ISO8601 format) bracketing
that phase's own work — additive to the `seconds` field every consumer already
reads, never a replacement. Around each consent question (the combined
consent below, and any later one), append a `"consent-wait"` row (`actor:
"developer (chat reply)"`) spanning from asking to the developer's answer —
this is what lets the evidence file separate human answer-latency from
machine time, so a slow run caused by the developer thinking is never misread
as agentQ being slow. This is a DIFFERENT, earlier timestamp than the
watchdog's own `runStart` below (which anchors the 10-minute run-budget check,
not reporting) — capture both, don't conflate them.

1. **Preflight** — capture `$runStartedAt` right now, per the note above. Read
   `.claude/qa-agent-config.jsonc` (missing → tell the user to
   copy the example; stop). Run `pwsh scripts/watchdog-hook.ps1 -ClearAll` here
   too (harmless if already empty) — a stale armed entry from an earlier task in
   this same session must never carry into a fresh run. Resolve the repo/worktree:
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
   -RepoPath <candidate's repoPath> [-TicketKey <KEY, if known>]
   -RunStartedAt <$runStartedAt captured above>` — all three of
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
   dispatch from here on (distinct from `$runStartedAt` above — see the note
   at the top of this run loop). Also note the wall-clock right before sending
   this message; when the developer answers, append a `"consent-wait"` row to
   `time-ledger.json` (`startedAt`/`endedAt` bracketing the ask-to-answer span,
   `outcome: "ANSWERED"`) — per the real-timestamp note at the top of this run
   loop. Ask BOTH
   gates now per their toggles — mutation (scope, calibrated mutant/time
   estimate; your nothing-worth-mutating auto-skip judgment still applies first)
   and execution (disclose intake's outbound destinations verbatim). Remember
   the answers; apply them when steps 5/7 arrive. WHY: the developer's answer
   latency then overlaps steps 2b–4's machine work instead of serializing
   between phases. `--quick` → skip the question entirely, record both gates
   `SKIPPED — quick mode` (no `consent-wait` row either — nothing was asked).
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
   seeds AND `domainKeywords` (`impact-index.json`, which ran above even if
   `skipQaImpact` skipped the Impact map itself). Toggle `true` → record
   `SKIPPED — disabled by config (skipManualTestAnalysis)` and skip. Otherwise,
   same Testomatio MCP probe as 2b (real query, not connectivity); available →
   up to THREE TQL queries against `mcp__testomatio__tests_search`, all scoped
   `state == 'manual'`:
   1. **Domain-keyword query** (fixes GH: a manual test titled in plain
      business language, e.g. "Processed Registrations and Expenses", shares
      no text with a code symbol — verified live that a code-symbol-only seed
      query missed it outright). Read `impact-index.json`'s `domainKeywords`
      (`{page: [...], value: [...]}`). Both groups non-empty → AND the two
      OR-groups: `(test % 'p1' or test % 'p2' ...) and (test % 'v1' or test %
      'v2' ...)` — page keywords alone are too broad (a whole feature area),
      value keywords alone too broad the other way (generic status words), the
      combination is what narrows to the actually-relevant tests (verified
      live: page-only returned 12 hits across an entire feature area,
      page+value narrowed to 2, both genuinely relevant). Only one group
      populated → OR that group alone. Neither → skip this query.
   2. **Code-symbol seed query** (unchanged from before): OR the `seeds` array
      values (kind=symbol/endpoint/dto/table/column, low-signal ones already
      dropped by `impact-index.ps1`) — still worth running alongside the
      keyword query when seeds exist, since an exact symbol/endpoint mention
      in a test's own text is stronger evidence than a keyword match.
   3. **Ticket-link query**: `jira == '<ticketKey>'`, if a ticket key exists.

   Merge results (dedupe by `id`): a hit from query 1 or 2 is `matchedBy:
   "diff-seed"` (`matchedSeed` = whichever keyword/seed matched); a hit ONLY
   from query 3 is `matchedBy: "ticket-link"`. Rank `diff-seed` above
   `ticket-link`, cap at 5. For each kept candidate, build its Testomat URL as
   `<baseUrl>/projects/<projectId>/test/<id>-<slug(title)>` (`baseUrl`/
   `projectId` from `mcp__testomatio__system_ping`; `slug` = lowercase, spaces
   → hyphens, strip non-alphanumeric) — write `manual-test-candidates.json`
   in the exact shape CONTRACTS.md documents: `{status: "RAN", queriedBy:
   {seeds: [...], ticket: "<key or null>"}, candidates: [{id, title, suite,
   matchedBy, matchedSeed, url}]}`. No MCP → the same file with `status:
   "SKIPPED — Testomatio MCP not configured"`; read-only-token 403 → `status:
   "DEGRADED — Testomatio token is read-only"` — never the ad hoc `status:
   "OK"`/`seedQuery`/`ticketQuery` shape a past run used by mistake; that
   breaks `risk-score.ps1`'s `manualTestVolume` signal, which gates strictly
   on `status == "RAN"`. Stream one line ("Manual testing: 2 candidates — see
   report"). Overlaps step 3; a failure here degrades this lane only.
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
     (ACs, diff hunks, citations — including the pack's "Const declarations in
     the diff" section, which pre-resolves the const → static-property
     promotion sites so the agent holds less un-written state before its first
     checkpoint) plus the worktree dir's absolute path (where it edits) — never
     a re-read of `run-manifest.json`/`diff-set.json`. It designs **up to 3**
     mutants now (down from 3–5, GH issue #32 — six candidate sites plus
     promotion surgery was too much state to hold before the first write), and
     its briefed work order is checkpoint-first: Write `mutants.json` at
     `status: "designed"` BEFORE any worktree edit, inject, then update to
     `status: "injected"`. It reads product-repo source only for injection
     mechanics (matching an existing pattern it must reproduce exactly), never
     for general context the pack already gives it.
   - **Co-dispatch diagnostic (GH issue #32, one-run experiment)**: both
     reproduced `qa-mutation-author` stalls shared exactly one structural
     trait — dispatched in the same tool-call batch as `qa-analyst`. On the
     next real run, dispatch `qa-mutation-author` ALONE, immediately after
     `qa-analyst`'s completion notification (everything else in this step
     stays batched as written), and record the outcome in issue #32:
     completes solo → the batching here needs revisiting for this agent;
     stalls solo → the cause is its own prompt/workload and the
     checkpoint/cap fixes are the whole cure. Then delete this bullet.
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
   `scripts/semantic-mutant-driver.ps1`. **The AI tier holds first claim on the
   remaining run budget at this point** (GH issue #32: CLAUDE.md calls it the
   core ask and orders it before Stryker, yet in both reproduced stall runs it
   lost the budget race — once while Stryker cache-hit in 42s, so the window
   existed and simply wasn't allocated): if step 4's `qa-mutation-author`
   dispatch stalled but left `mutants.json` at `status: "designed"`, spend the
   budget on the inject-only salvage re-dispatch (watchdog step 3d) and the
   driver run BEFORE kicking off Stryker or any other optional work — never
   the other way around. The driver itself refuses a `status: "designed"` file,
   so this ordering is also what makes the lane runnable at all. In the SAME tool-call batch as the next
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
6. **Risk score — runs in EVERY mode, including `--quick`.** `scripts/risk-score.ps1
   -Manifest <path>` (the contract signal already exists from step 2 on
   committed-spec/ocelot repos — no recompute needed later). It reads
   `impact-index.json`/`manual-test-candidates.json` too (`crossRepoImpact`/
   `uiAutomationExposure`/`manualTestVolume` signals) alongside the
   execution-dependent ones — every signal individually renormalizes when its
   own artifact is missing, so the script never refuses to run just because
   some inputs don't exist yet. **Under `--quick`**: run it right after step 2c
   (impact + manual-test), chained with nothing else since there's no mutation
   merge to wait on — `diff-coverage.json`/`test-results.json`/
   `mutation-report.json` won't exist, so `branchDiffCoverage`/
   `changedMethodComplexity`/`changedExecutableLines`/
   `survivingBusinessRuleMutants` are honestly unavailable, but
   `testToSourceBalance`/`churn90d` (pure diff/git) and `crossRepoImpact`/
   `uiAutomationExposure`/`manualTestVolume` (from step 2b/2c, which always ran)
   are commonly still available — a quick review gets a real band with
   `confidence: "low"`, never a blanket "couldn't check". **Under a full run**:
   same invocation also writes `gap-lattice.json` (GH issue #26): the script
   already loads `diff-coverage.json`/`mutation-report.json`/`mutants.json` for
   its own signals, and only ever runs here — after step 5's mutation merge —
   so this is what makes the evidence file's gap lattice mechanical and
   timing-proof, replacing qa-analyst's own (unreliable, race-prone)
   `gapLattice` as its source. No separate script, no extra step.
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
   2. Capture `$runEndedAt` (ISO8601 UTC) right now — this is "the moment the
      orchestrator is about to answer with the report link", the real-timestamp
      note's other bookend. Append `{ name: "report", actor:
      "scripts/render-report.ps1", seconds: <measured, ~1-2s>, startedAt:
      <before render-report.ps1 ran>, endedAt: $runEndedAt, outcome: "RAN" }`
      to `time-ledger.json`, then set its `runStartedAt` (copy from
      `run-manifest.json`, written in step 1) and `runEndedAt` ($runEndedAt
      just captured), and recompute `totalSeconds` as
      `(runEndedAt - runStartedAt).TotalSeconds` — the literal real elapsed
      time since the developer's first message, not a manual estimate
      (CONTRACTS.md `time-ledger.json`). `--quick` runs skip almost nothing
      here — the timestamps still matter for a quick run's own honesty.
   3. **Slow-run check (every run — the maintainer's runtime telemetry)**:
      `scripts/file-perf-issue.ps1 -TimeLedgerPath
      <workspaceDir>/time-ledger.json -RunManifestPath <path>
      -OutPath <workspaceDir>/perf-issue.json -RunKind qa-review`. The script
      owns the threshold decision itself (its `-ThresholdMinutes` parameter
      default — never pass a value; the script is the single source of truth.
      Under it → writes
      `perf-issue.json` with `overThreshold:false` and does nothing else) —
      always safe to call, and the target repo (agentQ's own, its `-TargetRepo`
      default) lives there too. Parse its one stdout JSON line;
      never block or delay the report on its result (it runs AFTER the report
      files already exist), and if the script itself fails or produces nothing,
      just continue — telemetry never stops a run. This must run BEFORE step 4
      below so `render-evidence.ps1` can pick up `perf-issue.json`.
   4. `scripts/render-evidence.ps1 -Manifest <path> -ReportPath <the same
      path>` — the `-evidence.md` companion, from the workspace artifacts +
      `analyst-brief.json` + `report-selection.json` + the Run timeline built
      from `time-ledger.json`/`perf-issue.json` above.
   5. Re-save BOTH files as UTF-8 with BOM (PowerShell
      `[IO.File]::WriteAllText` with `UTF8Encoding($true)`).
   No agent dispatch, no watchdog, nothing to time but the chain itself.
   **Do NOT restate the verdict or findings in
   chat** — the closing message is a clickable link to the main report file
   and nothing of its content (the report is the single source of the
   verdict; a chat copy drifts). The one exception this step 8 adds: if
   `perf-issue.json` came back `filed:true`, add ONE line — "⚠️ this run took
   <duration>, over the <perf-issue.json's thresholdSeconds, as minutes>
   target — filed <issueUrl>."; if it came back
   `overThreshold:true, filed:false`, add ONE line naming the honest reason
   (e.g. "gh CLI not authenticated on this machine") instead — never silent
   either way, and never more than this one line. Then ask which generated
   tests to keep; on
   explicit yes apply them to the product repo as a reviewed diff (placement
   per adapter profile; the canonical file content lives in
   `<workspaceDir>/generated/`).
9. **Cleanup verify** — `scripts/worktree.ps1 -Verify`. Confirm product repo
   untouched. Run `pwsh scripts/watchdog-hook.ps1 -ClearAll` as a final
   belt-and-suspenders — every dispatch above should already have cleared its
   own label, so this is normally a no-op; it exists to guarantee the run never
   ends leaving an armed entry behind.

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
