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

1. Clone this repo and open it in Claude Code.
2. Copy the two example configs:
   - `.claude/qa-agent-config.example.jsonc` → `.claude/qa-agent-config.jsonc`
     (point `productRepos` at your real local checkouts)
   - `.env.example` → `.env` (only needed for the E2E and Pact lanes; missing
     values degrade those lanes honestly, they never block the review)
3. Configure the MCPs — run `.\scripts\setup-mcp.ps1` once in your own
   PowerShell terminal, then restart Claude Code and approve the MCP prompt
   (see **MCP setup** below).
4. Check out the branch under review in the product repo.
5. For E2E tests (frontend branches only), have your local dev stack already
   running. Other levels don't need this.
6. Say: **"Review my branch {branch_name} in the {product} repo"** or use `/qa-review {branch_name} --{repo}` (see [Command-line style invocation](#command-line-style-invocation)),
   or just **"Test my branch EC-8876"** — the repo name is optional; agentQ finds it
   by checking which registered repo has a matching branch checked out.

## MCP setup

1. Clone `mcp-visma-jira` somewhere local, then run `.\scripts\setup-mcp.ps1`
   in your own PowerShell terminal.
   - `MCP_VISMA_JIRA_PATH` — path to your `mcp-visma-jira` checkout's `index.js`
   - `JIRA_INTEGRATION_HUB_URL` — value is in that repo's own README
   - `JIRA_PERSONAL_ACCESS_TOKEN` — Jira → Profile → Personal Access Tokens
   - `TESTOMATIO_API_TOKEN` — optional, only used by the impact/Testomat lane
2. Restart Claude Code — env vars only apply to new sessions — and approve
   the MCP prompt. Verify with `/mcp`.
3. **Playwright** needs no setup (zero-config). 
4. Connect **Figma** via /mcp server and login with your visma account

Check status any time with `.\scripts\check-mcp.ps1` — statuses and scope of
just this project's servers, plus whether the env vars are set (never their
values).

Entered a wrong value? `.\scripts\setup-mcp.ps1 -Reset <VAR_NAME>`, then
re-run without `-Reset` to set it again.

Jira behaving oddly? Two known traps: a server added with `claude mcp add` at
user scope silently shadows `.mcp.json` — `claude mcp get jira` must say
*Project config (shared via .mcp.json)*, otherwise `claude mcp remove jira -s
user`. And since the setup script skips vars that are already set, stale values
survive re-runs — fix them with `-Reset` as above.

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

```
/qa-review feature/EC-8876
/qa-review EC-8876 - Add a new feature to payroll
/qa-review --repo payroll-poc --branch feature/EC-8876
/qa-review --worktree payroll-poc-EC-8876
/qa-review --worktree <local-path>\payroll-poc-EC-8876
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

## What runs where

- **Agents judge, scripts execute.** Six subagents in `.claude/agents/` do only
  judgment work (classification, analysis, test authoring, mutation design,
  design conformance, report synthesis). Nine deterministic PowerShell scripts
  in `scripts/` do everything mechanical — so the same branch produces the same
  verdict twice.
- Everything lands in this repo: intermediate JSON under
  `workspace/<repo>/<branch>/`, the human-readable report under `reports/`.
- **Product repos are read-only.** The single exception: generated tests you
  explicitly choose to keep, applied as a diff you reviewed in chat.

## Consent moments

- Before mutation testing runs, agentQ tells you the scope and how long it'll take — your call to proceed.
- Before running your code (including E2E), agentQ tells you exactly what it'll touch — like an external URL or database — so nothing happens without you knowing.
- Say no to either, and the report just shows it as skipped.
- For E2E, agentQ checks your dev server is already running and gives you the command to start it.
- Set `always`/`never` in config if you'd rather skip being asked.


## Honest reporting

- Know in seconds if the branch is ready for a PR, and if not, what to fix first.
- See real proof, not guesses — a tested claim looks different from a "looks fine" reading.
- Never get fooled — if something wasn't checked, the report says so instead of hiding it.
- Decide yourself whether to keep any test agentQ wrote — nothing is added without you saying yes.
- Get pointed at manual regression tests worth running by hand, based on what actually changed — on by default, skip it with `skipManualTestAnalysis`.
- Inside: a verdict, risk score, pass/fail per level, generated tests, manual tests to run, and full evidence if you want to dig in.

