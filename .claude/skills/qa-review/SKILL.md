---
name: qa-review
description: Shift-left QA review of a product-repo feature branch before it becomes a PR — unit/mutation/component/API(+contract) levels, plus E2E and Figma design conformance on frontend branches. Usage - /qa-review [--branch <name-or-fragment>] [--repo <slug-or-fragment>] [--worktree <path-or-name>] [--ticket <KEY>], all optional, order-independent, and combinable with plain natural language ("test my branch EC-8876") or a bare branch name with no flags at all. The repo/worktree is auto-detected from whichever registered checkout (including a developer's own `git worktree add` siblings) has a matching branch checked out. Reviews the branch currently checked out in the configured local clone, including uncommitted and untracked work.
---

# /qa-review — orchestration

You are the primary agent for an agentQ run. `CLAUDE.md` is the authoritative
workflow document — phases, safety rules, reporting rules. This skill is the
run-loop checklist. Artifact shapes: `scripts/CONTRACTS.md`.

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
   `diff-set.json` + `adapter-profiles.json` and returns the brief (levels armed,
   ACs, Figma links, bootability, outbound destinations, contract gate). If it
   reports no diff vs base → tell the user there's nothing to review; stop.
   If no ticket/AC source → ask the user to paste ACs or continue with
   AC-alignment UNVERIFIABLE.
3. **Unit + flaky** — `scripts/run-tests.ps1 -Manifest <path>` then
   `scripts/diff-coverage.ps1`. Stream one-liners ("Unit: 43/43 affected tests
   passed · changed-line coverage 54%").
4. **Analysis & authoring** — in the SAME message dispatch `qa-analyst` (always) and
   `qa-scenario-writer` (only if the scenario cache is stale for this
   diff/AC hash). They overlap step 3's CPU work.
5. **💬 Mutation consent** (per `toggles.mutationConsent`; auto-skip if no backend
   change): show scope + calibrated estimate. On yes:
   `qa-mutation-author` designs semantic mutants →
   `scripts/semantic-mutant-driver.ps1` → `scripts/stryker-run.ps1` →
   `scripts/merge-mutation-reports.ps1`. Stream survivors as they land.
6. **Risk score** — `scripts/risk-score.ps1`.
7. **💬 Execution consent** (per `toggles.executionConsent`): disclose intake's
   outbound destinations; E2E additionally needs the dev-stack health check to pass
   (never auto-start — hand over the command). On yes:
   `scripts/run-tests.ps1 -GeneratedOnly` (component/API in the worktree,
   anti-vacuity against base AFTER mutation is done) and
   `scripts/contract-check.ps1`. Frontend branches: run cached E2E specs
   (`npx playwright test --grep @agentq`); kick off `qa-e2e-author` in the
   background for new scenarios and (if a Figma link exists) design conformance.
8. **Report** — delegate `qa-report-synthesizer` with the workspace dir. Save under
   `reports/`, show the verdict block in chat, then ask which generated tests to
   keep; on explicit yes apply them to the product repo as a reviewed diff
   (placement per adapter profile).
9. **Cleanup verify** — `scripts/worktree.ps1 -Verify`. Confirm product repo
   untouched.

## Hard rules (repeated because they get tested)
- A zero-match test filter, a 404'd OpenAPI route, an unreachable broker, a skipped
  consent — all become explicit `SKIPPED/DEGRADED — <why>` lines. Never a pass.
- Never write into the product repo except step 8's consented keep-tests diff.
- Never publish Pact results; never echo secret values.
- Background `qa-e2e-author` results arrive after the report — relay them as an
  addendum, don't block.
