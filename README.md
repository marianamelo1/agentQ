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
3. Run `/mcp` and check the connectors: **Jira** (AC extraction), **Playwright**
   and **Figma** (frontend branches only). Everything else is plain CLI.
4. Check out the branch under review in the product repo (agentQ never clones,
   pulls, or switches branches — it reviews what's there, including uncommitted
   and untracked work).
5. Say: **"Review my branch for EC-1234 in the payroll repo"**, `/qa-review payroll-poc`,
   or just **"Test my branch EC-8876"** — the repo name is optional; agentQ finds it
   by checking which registered repo has a matching branch checked out.

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
/qa-review EC-8876
/qa-review --repo payroll-poc --branch feature/EC-8876
/qa-review --worktree payroll-poc-EC-8876
/qa-review --worktree C:\dev\payroll-poc-EC-8876
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
than one worktree matches (e.g. you have two feature branches checked out and
gave no hint), it asks you which one. Not using worktrees at all works exactly the
same way — there's just the one checkout to find.

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

Two per run, asked in chat (unless your config toggles say `always`/`never`):

1. **Mutation** — files in scope, estimated mutant count, time estimate.
2. **Execution** — before any in-process app boot or E2E run, agentQ lists the
   app's own outbound destinations found during intake (it cannot sandbox the
   app's traffic, so consent must be informed). E2E additionally requires your
   dev stack to already be running — agentQ health-checks and hands you the
   start command, it never auto-starts it.

A denied consent becomes a SKIPPED line in the report, never a silent hole.

## Honest reporting

- A skipped or degraded check never reads as a pass — the capability matrix
  shows exactly `RAN` / `DEGRADED — why` / `SKIPPED — why` per level.
- Every acceptance-criterion claim carries its evidence source (executed
  scenario vs static reading vs unverifiable).
- Mutation findings are absolute survivors ("a wrong X would ship"), never a
  percentage; diff coverage is always "coverage of the lines you changed",
  never a global number.
- The risk score is a labeled heuristic with its signal ledger below the fold —
  never a "probability of passing CI". Missing signals lower the stated
  confidence instead of vanishing.

## One-time setup (offered on first run, never silent)

- .NET SDK on PATH for .NET repos; Node matching the repo's `engines` for JS.
- Per-repo, with your consent: local `dotnet-stryker` tool restore, a pinned
  checksum-verified `oasdiff` binary into `tools/`, Playwright browsers
  (frontend repos). Docker only if you consent to Testcontainers paths.

## Roadmap (Phase 2 — not built yet)

Plugin packaging (`/agentq:qa-review` from the internal marketplace) and
headless CI mode posting results to the PR — same agents, skills, and scripts,
different invocation shell.
