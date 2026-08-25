---
name: qa-impact
description: Blast-radius / impact analysis — what features, endpoints, other repos, Testomat tests, and UI-automation (BA) specs reference the code a branch touches, or a named target (endpoint, table, symbol) before any code is written. Usage - /qa-impact [--branch <name-or-fragment>] [--repo <slug-or-fragment>] [--worktree <path-or-name>] [--ticket <KEY>] [--target <endpoint-or-table-or-symbol>], all optional, order-independent, and combinable with plain language ("what's affected if I change the entries endpoint?"). Static analysis + optional MCP queries only — never builds, boots, or executes anything. Output is deliberately concise; the full match list stays in the JSON artifact.
---

# /qa-impact — orchestration

Answers "what could this change affect?" — not "is it tested?" (that's `/qa-review`).
The same lanes run inside `/qa-review` (Phase 1b — same script, same artifacts)
when the config sets `toggles.skipQaImpact: false` (default `true` skips them);
this skill is the standalone entry point, usable before any code exists
(`--target`), and **ignores that toggle** — an explicit invocation always runs. Read-only, seconds not minutes: it scans, it
never builds, boots, or runs tests.
Artifact shapes: `scripts/CONTRACTS.md` → `impact-index.json`,
`testomat-candidates.json`.

All `scripts/*.ps1` are cross-platform PowerShell. In a PowerShell session invoke
them directly; from a bash/zsh shell (macOS/Linux) prefix with `pwsh`, e.g.
`pwsh scripts/impact-index.ps1 -Manifest …`.

## Inputs
Same four optional slots as `/qa-review` (`--branch` / `--repo` / `--worktree` /
`--ticket`, resolved identically — see that skill's Inputs), plus one of its own:

- **`--target <term>[,<term>…]`** — target mode: analyze the impact of a named
  thing instead of a diff. Accepts an endpoint path (`/api/entries`), a table or
  `Table.Column`, a type/method name, or a file path. With `--target`, no branch
  diff is needed at all — the developer can ask *before* writing code.
- No `--target` → branch mode (default): seeds are extracted from the diff of the
  resolved branch (changed endpoints, symbols, DTOs, migration tables/columns).

## Run loop

1. **Preflight** — read `.claude/qa-agent-config.jsonc` (missing → point at the
   example; stop). Resolve repo/worktree exactly as `/qa-review` step 1
   (`worktree.ps1 -DetectRepo …`), then `-EnsureWorkspace` + `run-manifest.json`.
   No heal, no setup offers — nothing here mutates anything.
2. **Index** — `scripts/impact-index.ps1 -Manifest <path> -ConfigPath <cfg>
   [-Targets "<term1>,<term2>"]` → `impact-index.json`. It extracts seeds
   (branch mode) or takes them verbatim (target mode), then scans every readable
   repo in `productRepos` ∪ `testRepos` for references. Stream one
   line: "Indexed N repos in Xs — M references to K seeds".
3. **Existing-test lane** — the script fills `reverseCoverage` from this branch's
   coverage artifact **if a prior `/qa-review` produced one**; otherwise that lane
   is `SKIPPED — no coverage artifact (run /qa-review to get it)`. Never generate
   coverage from this skill.
4. **Testomat lane (session-dependent)** — probe with the REAL seed query, not
   bare tool discovery: the server is pre-declared in this repo's `.mcp.json` but
   needs `TESTOMATIO_API_TOKEN` set on the machine (do NOT assume it works
   because it works elsewhere), AND that token can be read-only — connects fine
   (`system_ping` OK) yet 403s on `tests_list`/`tests_search`, which is a
   distinct state from "not configured" and must be reported as such, not
   guessed at ad hoc. No MCP →
   `SKIPPED — Testomatio MCP not configured` plus a one-line enable hint (set
   `TESTOMATIO_API_TOKEN` as an OS env var and approve the server — never in
   `.env`). Query 403s (read-only token) → `DEGRADED — Testomatio token is
   read-only` — a fixed string, so this reads the same on every run. Query
   succeeds →
   search tests/suites by the seeds and the ticket's component; every hit is a
   **candidate (keyword match)** — never "affected". Either way, ALWAYS write
   `testomat-candidates.json` (CONTRACTS.md) — `status` carries the honesty.
5. **Pact consumers** — cite `contract-report.json` from a prior `/qa-review` run
   of this branch if it exists (`pact.consumers`); else one `SKIPPED` line. Never
   boot anything to get it.
6. **Impact map** — render the concise map (format below) in chat and save the
   same content to `reports/impact-<repoShort>-<ticket-or-branch>-<YYYY-MM-DD-HHmm>.md`.
   No agent needed for a normal run; delegate to `qa-analyst` only when the
   developer asks for interpretation beyond the map ("which of these is riskiest?").

## Impact map format (concise — hard caps)

Max one section per lane, max 3 evidence items per section, `+N more` for the
rest, every item carrying its evidence (`file:line`, Pact consumer name, or
Testomat id). Lanes with nothing found say `none found`; lanes that couldn't run
say `SKIPPED — <why>`. Always end with the two honesty lines. Nothing else — no
methodology, no tables, no per-seed breakdown (that's the artifact's job).

```
Impact of feature/EC-1234 (payroll-poc) — seeds: POST /api/entries, Entries.PostingDate

Same repo       2 call sites of VatCalculator.Apply (InvoiceService.cs:88, +1)
Other repos     client: 4 refs to POST /api/entries (src/api/entries.ts:12, +3)
UI-automation   3 BA specs hit /api/entries (entries.spec.ts:40, +2) — candidates
Testomat        SKIPPED — Testomatio MCP not configured
Pact consumers  SKIPPED — no contract run for this branch
Existing tests  12 tests execute the changed lines — top: EntriesTests.Create_Posts

Not indexed: repos outside the config, external consumers. No signal ≠ not affected.
Full matches: workspace/<repo>/<branch>/impact-index.json
```

## Hard rules
- **Read-only, everywhere.** No builds, no boots, no test execution, no worktree
  mutation — stricter than `/qa-review`.
- **MCP-agnostic.** Never assume any MCP (Testomatio or otherwise) is available
  because it was on the machine where this skill was written. Probe per session;
  absent → an explicit `SKIPPED` line, never an error and never a silent hole.
- **Textual matches are candidates.** UI-automation and Testomat hits are keyword
  evidence, not proof of impact — always label them as candidates.
- **Concise means concise.** The caps above are the format; overflow lives only
  in `impact-index.json`. Never inline the full match list into chat or report.
- The closing honesty line is not optional: absence of a match never means "not
  affected" — say so every time.
