# agentQ — shift-left QA assistant

Ask Claude Code to review a feature **branch** before you open the PR. It answers:
what's untested, what's risky, and whether the code meets the Jira ticket's
acceptance criteria — backed by tests that were **really executed**, with every
claim qualified by its evidence.

Five test levels: **Unit** · **Mutation** (mechanical + AI business-rule) ·
**Component/Module** · **API/Service** (+ contract testing for services) ·
**E2E** (frontend branches only, + Figma design conformance when the ticket
links a design).

The full workflow, safety rules, and phase-by-phase detail live in
[`CLAUDE.md`](CLAUDE.md). JSON artifact shapes live in
[`scripts/CONTRACTS.md`](scripts/CONTRACTS.md).

## Quickstart

1. Clone this repo
2. Copy the two example configs:
   - `.claude/qa-agent-config.example.jsonc` → `.claude/qa-agent-config.jsonc`
     (point `productRepos` at your real local checkouts)
   - `.env.example` → `.env` (only needed for the E2E and Pact lanes)
3. Open PowerShell, go to the project, and run `.\scripts\setup-mcp.ps1`.
   On macOS: `brew install --cask powershell` first, then
   `pwsh ./scripts/setup-mcp.ps1`.
5. Go to Claude Code/CLi or Visual Studio with Claude Code.
6. Run `claude` and approve the MCP prompt
7. Go to your project repo, check out in the branch that you want to review
8. For E2E tests (frontend branches only), have your local dev stack already
   running. Other levels don't need this.
9. Go back to AgenQ project, on Claude Code, Say: **"Review my branch {branch_name} in the {product} repo"** or use `/qa-review {branch_name} --{repo}` (see [Command-line style invocation](#command-line-style-invocation)),
   or just **"Test my branch EC-8876"** — the repo name is optional; agentQ finds it
   by checking which registered repo has a matching branch checked out.

## Issue on setup

Entered a wrong value? `.\scripts\setup-mcp.ps1 -Reset <VAR_NAME>` (macOS:
`pwsh ./scripts/setup-mcp.ps1 -Reset <VAR_NAME>`), then re-run without
`-Reset` to set it again.

 Check status any time with `.\scripts\check-mcp.ps1`
(macOS: `pwsh ./scripts/check-mcp.ps1`) — tools, this project's MCP servers,
env vars, a live Jira probe, and Figma.

## Command-line style invocation

`/qa-review` also takes explicit flags, if you'd rather be precise than
conversational. All four are optional, order-independent, and can be mixed with
plain language:

| Flag | Meaning |
|---|---|
| `--branch <name-or-fragment>` | The branch (or a fragment of it) to review |
| `--repo <slug-or-fragment>` | Which registered repo (e.g. `payroll-poc`, or the full `e-conomic/payroll-poc` key) |
| `--worktree <path-or-name>` | A specific local checkout — a full path, or just the worktree's directory name |
| `--ticket <KEY>` | The Jira ticket key, if you don't want it inferred from the branch/commits |
| `--quick` | Static lanes only — no test execution, no mutation (see [Quick mode](#quick-mode---quick)) |

```
/qa-review feature/EC-8876
/qa-review EC-8876 - Add a new feature to payroll
/qa-review --repo payroll-poc --branch feature/EC-8876
/qa-review --worktree payroll-poc-EC-8876
/qa-review --worktree <local-path>/payroll-poc-EC-8876
/qa-review --branch feature/EC-8876 --repo payroll-poc --ticket EC-8876
```

None of this is required — a bare branch name or ticket key with no flags at all
works the same way, and so does a plain sentence like *"test my branch EC-8876"*.

**If you work in `git worktree`s** (multiple checkouts of the same repo, each on
its own branch), agentQ finds the right one automatically: it scans every worktree
of every registered repo, not just the one path in `productRepos`. Give it a
branch name, a ticket key, or the worktree's own directory name (e.g.
`payroll-poc-EC-8876`) and it matches against whichever worktree that identifies —
even if it's a `git worktree add` sibling that was never added to config. If more
than one worktree matches — two feature branches checked out with no hint given,
or a single ticket key that matches two branches (a ticket with a PR in two repos,
or two candidate branches for the same ticket) — agentQ never guesses: it lists
every match (repo, branch, path) and asks which one you mean. Add `--repo` or
`--branch` if you already know which one and want to skip the question. Not using
worktrees at all works exactly the same way — there's just the one checkout to find.

## Quick mode (`--quick`)

`--quick` runs only the static lanes — intake, committed-spec contract diff,
impact/manual-test candidates, analysis, and the report. Nothing executes: no
test run, no mutation. It answers from *reading* the code, not from running it,
so it finishes in a fraction of a full run.

```
/qa-review --quick
/qa-review payroll-poc --quick
/qa-review --branch feature/EC-8876 --ticket EC-8876 --quick
quick review of my branch EC-8876
```

You still get: what the branch changes, whether it looks aligned with the
ticket's ACs, breaking API contract changes, the impact map, and the analyst's
questions. 

**When to use it:**

- **Mid-development**, while the branch is still moving — a fast sanity loop
  ("am I drifting from the ticket? did I just break the API contract?") without
  paying for builds and test runs each time.
- **Early direction checks** — right after the first commits, before investing
  more.
- **When you can't execute** — dev stack down, or a machine without warm SDKs.

**When not to use it:** right before opening the PR. That's the moment for the
full run — executed tests, anti-vacuity, mutation survivors. "Appears met by
reading" and "verified by a test that failed on base" are very different levels
of confidence.

## Get QA Impact on you code

"What could my change affect?" — without running a review. `/qa-impact` scans
what references the code your branch touches (or a named target, before any
code exists) across four lanes: same-repo features, other registered repos,
UI-automation (BA) specs, and Testomat tests.

Run:

```
/qa-impact                                    blast radius of the current branch diff
/qa-impact EC-8876                            same, finding the branch by ticket
/qa-impact --target /api/v2/entries           a named endpoint, table, or symbol — no code needed
what's affected if I change the entries endpoint?
```

Same flags as `/qa-review` (`--branch`, `--repo`, `--worktree`, `--ticket`),
plus `--target`. 

## What runs where

- **Agents judge, scripts execute.** Six subagents in `.claude/agents/` do only
  judgment work (classification, analysis, test authoring, mutation design,
  design conformance, report synthesis). Twelve deterministic PowerShell scripts
  in `scripts/` do everything mechanical — so the same branch produces the same
  verdict twice. The scripts are cross-platform: Windows PowerShell 5.1+ or
  pwsh 7+ on macOS/Linux (invoke as `pwsh scripts/<name>.ps1 …` there).
- Everything lands in this repo: intermediate JSON under
  `workspace/<repo>/<branch>/`, the human-readable report under `reports/`.
- **Product repos are read-only.** The single exception: generated tests you
  explicitly choose to keep, applied as a diff you reviewed in chat.

## Consent moments

- Before mutation testing runs, agentQ tells you the scope and how long it'll take — your call to proceed.
- Before running your code (including E2E), agentQ tells you exactly what it'll touch — like an external URL or database — so nothing happens without you knowing.
- Both questions arrive together in one message right after intake, so you answer while agentQ is already working — your reading time never stalls the run.
- Say no to either, and the report just shows it as skipped.
- For E2E, agentQ checks your dev server is already running and gives you the command to start it.
- Set `always`/`never` in config if you'd rather skip being asked.
- In a hurry? `/qa-review --quick` skips both execution gates entirely — see [Quick mode](#quick-mode---quick).


## Honest reporting

- Know in seconds if the branch is ready for a PR, and if not, what to fix first.
- See real proof, not guesses — a tested claim looks different from a "looks fine" reading.
- Never get fooled — if something wasn't checked, the report says so instead of hiding it.
- Decide yourself whether to keep any test agentQ wrote — nothing is added without you saying yes.
- Get pointed at manual regression tests worth running by hand, based on what actually changed — on by default, skip it with `skipManualTestAnalysis`.
- Inside: a verdict, risk score, pass/fail per level, generated tests, manual tests to run, and full evidence if you want to dig in.

