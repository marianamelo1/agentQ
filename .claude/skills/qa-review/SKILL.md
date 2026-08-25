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
   Then run `scripts/worktree.ps1 -Heal -RepoPath <path>` then
   `-EnsureWorkspace` to create `workspace/<repo>/<branch>/` and write
   `run-manifest.json` (pin the base SHA once — never re-resolve). Probe
   SDK/node/docker. First run on a repo → offer the one-time setup (Stryker tool
   restore, oasdiff download) as a consented step; declining just narrows lanes.
2. **Intake** — delegate to `qa-intake` with the manifest path. It writes
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
   **💬 Combined consent (immediately after intake, one message)**: ask BOTH
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
   for cross-repo candidates: probe whether a Testomatio
   MCP is available in THIS session (pre-declared in `.mcp.json`, but its
   `TESTOMATIO_API_TOKEN` is per-machine — never assume it's working); available →
   search tests/suites by the seeds + ticket
   component; ALWAYS write `testomat-candidates.json` when `skipQaImpact` is false
   (status `SKIPPED — Testomatio
   MCP not configured` when absent). Stream one line ("Impact: client 4 refs · 3 BA
   specs"). Overlaps step 3; a failure here degrades the
   Impact row only, nothing else.
2c. **Manual test recommendation (gated by `toggles.skipManualTestAnalysis`,
   default `false` — opt-**out**, unlike 2b which is opt-in)** — needs step 2b's
   seeds (`impact-index.json`, which ran above even if `skipQaImpact` skipped the
   Impact map itself). Toggle `true` → record `SKIPPED — disabled by config
   (skipManualTestAnalysis)` and skip. Otherwise, same Testomatio MCP probe as 2b;
   available → two TQL queries, both `state == 'manual'`: one OR-ing the seed
   values, one on `jira == '<ticketKey>'` if a ticket key exists → write
   `manual-test-candidates.json`, ranking seed matches (`diff-seed`) above
   ticket-only matches (`ticket-link`), capped at 5. Absent MCP → the same file
   with `status: "SKIPPED — Testomatio MCP not configured"`. Stream one line
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
   by the time either needs a script artifact it already exists. When the mutation
   consent from step 2 resolved yes, ALSO include `scripts/worktree.ps1 -Ensure`
   (checkout is I/O — it doesn't contend with the test run) and dispatch
   `qa-mutation-author` in the same batch: design + injection overlap step 3
   freely; only the semantic-mutant DRIVER waits for step 3 to finish (CPU-heavy
   phases never overlap).
   - `qa-scenario-writer` never reads step 3's output (only `diff-set.json`/
     `adapter-profiles.json` from intake) — always safe to start immediately. It
     renders into `<workspaceDir>/generated/` (staging — worktree.ps1 materializes
     the files into both worktrees), so it doesn't depend on any worktree existing.
   - `qa-analyst` reads `diff-coverage.json`/`test-results.json` only for its Gap
     Lattice and flaky sections — it's briefed to do its other sections first and
     treat those two files as "not ready yet," not an error, if missing when it
     starts.
   - Both agents reuse any file:line/key evidence intake already carried forward
     from the AC/bug-report text instead of re-tracing it from zero — if you notice
     both agents independently grepping the same coupling on a run, that's a sign
     step 2 should have carried the evidence forward instead.
   - If step 2b ran, point `qa-analyst` at `impact-index.json` +
     `testomat-candidates.json` too — cross-repo fan-in is part of its
     regression-risk brief. If step 2c ran, also point it at
     `manual-test-candidates.json` — manual-test interpretation is part of the same
     brief.
5. **Mutation** (consent already answered in step 2; the auto-skip judgment and a
   `SKIPPED — consent denied` line still apply; skipped under `--quick`) — after
   step 3 has finished (the driver and Stryker are CPU-heavy): design + injection
   may already be done from step 4's early dispatch →
   `scripts/semantic-mutant-driver.ps1` → **`scripts/worktree.ps1 -Ensure` again**
   (cheap reuse reset — removes the AGENTQ_MUTANT switches; generated tests
   re-materialize from staging; stryker-run refuses to start while switches
   remain) → `scripts/stryker-run.ps1` → `scripts/merge-mutation-reports.ps1`.
   Stream survivors as they land.
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
   -WorktreeRoot <worktreeBaseDir> -ResultsLabel base` — never flip the main
   worktree. Boot-capture contract lane (payroll-poc) + Pact run here too.
   Frontend branches: run cached E2E specs
   (`npx playwright test --grep @agentq`); kick off `qa-e2e-author` in the
   background for new scenarios and (if a Figma link exists) design conformance.
8. **Report** — delegate `qa-report-synthesizer` with the workspace dir. It
   writes TWO files under `reports/`: the max-2-page plain-language main report
   and its `-evidence.md` technical companion (which renders the Impact matrix
   row + impact map from `impact-index.json` / `testomat-candidates.json`).
   Re-save both as UTF-8 with BOM (PowerShell `[IO.File]::WriteAllText` with
   `UTF8Encoding($true)`). **Do NOT restate the verdict or findings in chat** —
   the closing message is a clickable link to the main report file and nothing
   of its content (the report is the single source of the verdict; a chat copy
   drifts). Then ask which generated tests to keep; on explicit yes apply them
   to the product repo as a reviewed diff (placement per adapter profile; the
   canonical file content lives in `<workspaceDir>/generated/`).
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
