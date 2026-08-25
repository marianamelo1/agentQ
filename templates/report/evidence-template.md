<!--
  agentQ EVIDENCE file skeleton — the technical companion to the main report,
  filled by the qa-report-synthesizer agent. All rigor lives here:
    - Numbers come from the workspace JSON artifacts VERBATIM (shapes in
      scripts/CONTRACTS.md) — never recomputed, re-rounded, or inferred.
    - A skipped/degraded row can never read as a pass.
    - Never "probability of passing CI"; never a mutation percentage (absolute
      survivors only); diff coverage is always phrased "coverage of changed
      lines, from tests related to this branch".
    - {{token}} = replace; the guidance comments = delete after filling.
-->

# 📄 Evidence — {{repoShort}} · {{ticketKey-or-branch}}

Companion to `{{main-report-filename}}` — technical detail only; the verdict and
the plain-language summary live there.

| Repo | Branch | Base | Ticket | Date |
|---|---|---|---|---|
| {{repoSlug}} | `{{branch}}` | `{{baseSha-short}}` (fetched {{fetch-age, e.g. "4 min ago" — now minus run-manifest.fetchedAt}}) | {{ticketKey or "— none —"}} | {{YYYY-MM-DD HH:mm}} |

## Run summary

<!-- From time-ledger.json verbatim (agentsCalled/phases/totalSeconds), never
     recomputed. Lists only LLM subagents in "Agents called" (never scripts) —
     omit ones skipped this run (qa-scenario-writer on a cache hit,
     qa-e2e-author on a backend-only diff). The "Actor" column names whichever
     agent(s) and/or script(s) did that phase's work — this is what makes it
     honest that most wall-clock is deterministic scripts, not model calls. -->

**Agents called:** {{agentsCalled joined by " · ", or "— none (all cached / skipped) —"}}

| Phase | Actor | Seconds |
|---|---|---|
| {{phase name}} | {{actor}} | {{seconds}} |

**Total wall-clock: {{totalSeconds, formatted e.g. "3m 42s"}}** (phases marked
"overlapped" run concurrently — this is measured elapsed time, not the column sum)

## Finding detail

<!-- One subsection per main-report finding, same numbering and title: the
     file:line evidence, mutant ids, coverage numbers, and test names behind
     the plain sentences the developer read up front. -->

### 1. {{main-report finding title}}

{{file:line evidence, mutant ids, coverage numbers, covering/missing tests}}

## Capability matrix

<!-- One row per level, PLUS one Impact row (always present — never omitted
     even when config-skipped, see CLAUDE.md Preconditions #6/#7). State is
     exactly one of: RAN | DEGRADED — <why> | SKIPPED — <why> | PENDING — <why>.
     PENDING is only for E2E authoring still running in background:
     "PENDING — authoring in background; next run includes it". -->

| Level | State | Result |
|---|---|---|
| Unit | {{RAN \| DEGRADED — why \| SKIPPED — why}} | {{one-line result, e.g. "43/43 affected tests passed"}} |
| Mutation | {{state}} | {{e.g. "2 business-rule survivors, 0 mechanical survivors of 31 tested"}} |
| Component | {{state}} | {{one-line result}} |
| API + Contract | {{state}} | {{one-line result; contract phrasing per rules below}} |
| E2E | {{state \| PENDING — authoring in background; next run includes it}} | {{one-line result}} |
| Design conformance | {{state}} | {{one-line result or "SKIPPED — no design linked in ticket"}} |
| Impact | {{state, e.g. "SKIPPED — disabled by config"}} | {{one-line result, e.g. "4 refs across 2 repos; see Impact map"}} |

## Impact map

<!-- Only when the Impact phase ran (toggles.skipQaImpact: false) —
     config-skipped omits this whole section (the matrix row above already says
     why). One concise block, hard caps: ≤3 evidence items per lane (same repo /
     other repos / UI-automation / Testomat / Pact consumers), "+N more"
     pointing at impact-index.json — never inline the full match list.
     UI-automation and Testomat hits are always *candidates (keyword match)*,
     never "affected" or failures. Always closes with "no signal ≠ not
     affected". -->

{{impact map findings, or omit this whole section when config-skipped}}

## Manual testing

<!-- Only when Phase 1c ran (toggles.skipManualTestAnalysis: false, the
     default) — independent of the Impact map above. From
     manual-test-candidates.json: ≤5 candidates, diff-seed matches ranked above
     ticket-link matches, "+N more" pointing at the artifact. Always
     *candidates (keyword/ticket match)* — never "you must test this". Toggled
     off or no Testomatio MCP → state that plainly ("SKIPPED — <why>"), never
     omit the section silently. The main report shows ≤3 of these as
     "🖐️ Worth checking by hand" when any exist. -->

{{manual test candidates, or "SKIPPED — <why>"}}

## Unit level

<!-- From test-results.json + diff-coverage.json + the qa-analyst brief.
     Diff coverage phrasing is mandatory: "Of the lines you changed, X% ran
     under tests related to this branch (branch coverage Y%)". If
     diff-coverage.json has refused:true — state the refusal reason, no number.
     Test lists: three named lists ONLY — "most likely to catch a regression
     here" / "flaky-risk smells (static)" / "might be flaky (failed this run —
     rerun command provided; confirm outside agentQ)". Each might-be-flaky entry
     quotes its rerunCommand from test-results.json VERBATIM so the developer
     can copy-paste it. Never the word "riskiest".
     If any scenarios/*.json this run is level:"unit", end this section with:
     "🧪 Generated: `{{id}}` — {{title}}. See 'Generated scenarios' below."
     (one line per unit-level scenario). Omit the line entirely if none. -->

{{unit findings}}

## Mutation level

<!-- From mutation-report.json. Absolute survivors only, phrased as
     consequence: "a wrong {{X}} would ship — N tests covering {{file}} still
     pass when {{mutation}}". When stryker/summary.json carries a
     testCaseFilter, scope every survivor claim honestly: "no test RELATED TO
     THIS CHANGE kills it" — never "no test in the project". A fromCache:true
     run states its verdicts were reused from an identical prior run, not
     re-executed. Suppress NoCoverage mutants (they are coverage
     findings and belong in the Unit section). Name the assert to strengthen
     when known. If a surviving agentq-N mutant carries a suggestedFix, end
     that finding with: "🧪 Generated fix: strengthens `{{testFile}}`. See
     'Generated scenarios' below." A survivor with no suggestedFix (including
     every Stryker mechanical survivor) just keeps the verbal "→ strengthen
     the assert in X" recommendation — don't imply a diff exists when none was
     drafted. -->

{{mutation findings}}

## Component level

<!-- Scenario states, exactly one of:
     EXECUTED — PASSED | EXECUTED — FAILED (finding) |
     GENERATED, COMPILES, NOT EXECUTED — <reason> — run: <command> |
     GENERATED, NOT EXECUTED — <reason>.
     AC claims carry their evidence source:
     MET — verified by executed scenario X (failed on base) ≠
     MET — verified (vacuity: static only) ≠ APPEARS MET — static reading only ≠
     NOT MET — <observed vs expected> ≠ UNVERIFIABLE — <reason>.
     If any scenarios/*.json this run is level:"component", end this section
     with one "🧪 Generated: `{{id}}` — {{title}}. See 'Generated scenarios'
     below." line per scenario. Omit if none. -->

{{component findings + AC claims}}

## API + Contract level

<!-- Contract phrasing (from contract-report.json):
     ERR  → "breaking change to the documented API contract (rule <ruleId>) —
             any consumer relying on this shape will break"
     WARN → "potentially breaking — needs human judgment"
     Only Pact findings may name a consumer. Unknown provider states are
     "unverifiable, not failed".
     If any scenarios/*.json this run is level:"api", end this section with one
     "🧪 Generated: `{{id}}` — {{title}}. See 'Generated scenarios' below."
     line per scenario. Omit if none. -->

{{api + contract findings + AC claims}}

## E2E {{+ Design conformance — frontend branches only}}

<!-- Cached-spec results only; new authoring is PENDING (see matrix).
     Design conformance findings: "DEVIATES — objective" (side-by-side evidence
     in the sibling evidence dir) vs "NEEDS HUMAN JUDGMENT" — never asserted as
     a defect. Scoped to the linked frames only. -->

{{e2e + design findings}}

## Generated scenarios

<!-- ALWAYS render this table, even with zero rows this run — an omitted
     section reads as "nothing was generated," which the developer can't
     distinguish from "this section was forgotten." Empty → the single line
     "No scenarios generated this run." replaces the table.
     One row per: (a) scenarios/*.json → renderedTo (level = its own "level"
     field: unit/component/api/e2e — never invent a value outside that set),
     and (b) any mutants.json entry carrying a suggestedFix (level =
     "mutation", path = suggestedFix.testFile). Sort by level in the order
     Unit, Mutation, Component, API, E2E. Vacuity grade: "verified against
     base" (the test FAILED on the base build — the real guarantee) vs "static
     only" (not yet proven non-vacuous) — a mutation suggestedFix is "verified
     against base" once the semantic-mutant-driver confirms the strengthened
     assertion actually kills the mutant, "static only" otherwise.
     The main report's 🧪 keep-list shows these same rows, same order, as
     plain one-liners without paths. -->

| Level | Scenario | Path | State | Vacuity grade | Keep? |
|---|---|---|---|---|---|
| {{unit\|mutation\|component\|api\|e2e}} | {{id}} — {{title}} | `{{worktree-relative path}}` | {{scenario state}} | {{verified against base \| static only}} | {{candidate \| no — why}} |

## Questions worth answering before the PR

<!-- The qa-analyst's Socratic questions, VERBATIM — ≤5, each leading with the
     real business/user scenario, the file:line evidence cited as why it's
     worth asking, each answerable by one nameable test. The main report shows
     ≤3 of these in plain language. If none: "None — the existing tests
     already answer the questions this diff raises." -->

{{socratic questions}}

## Risk-score signal ledger

<!-- From risk-score.json, verbatim. If renormalized:true, add the note:
     "Missing signals: {{missingSignals}} — weights renormalized; confidence
     lowered to {{confidence}}." A hard override (build-failed /
     affected-test-failed) replaces the ledger with the override reason. -->

| Signal | Value | Weight | Contribution | Available |
|---|---|---|---|---|
| {{name}} | {{value}} | {{weight}} | {{contribution}} | {{available}} |

Score: **{{score}}** → band **{{band}}** · confidence **{{confidence}}**

Methodology: heuristic scored from this diff only; not calibrated against CI history.

## Time ledger

<!-- Same phases as the Run summary above, this time with per-phase outcome
     instead of actor — the two tables are complementary, not duplicates. -->

| Phase | Seconds | Outcome |
|---|---|---|
| {{name}} | {{seconds}} | {{RAN \| DEGRADED — … \| SKIPPED — …}} |

## Capture provenance

<!-- Contract lane only (contract-report.json.captureProvenance): how each side
     of the spec diff was obtained — committed-spec vs boot, and the route. -->

Base: {{base}} · Rev: {{rev}} · Route: `{{route}}` · Mode: {{mode}}

## Command log

{{paths to TRX/JSON/log files under the workspace dir, for reproduction}}
