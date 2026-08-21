<!--
  agentQ report skeleton — filled by the qa-report-synthesizer agent.
  Rules the synthesizer must keep (from .claude/agents/qa-report-synthesizer.md):
    - Numbers come from the workspace JSON artifacts VERBATIM (shapes in
      scripts/CONTRACTS.md) — never recomputed, re-rounded, or inferred.
    - A skipped/degraded row can never read as a pass.
    - Never "probability of passing CI"; never a mutation percentage (absolute
      survivors only); diff coverage is always phrased "coverage of changed
      lines, from tests related to this branch".
    - {{token}} = replace; the guidance comments = delete after filling.
-->

# agentQ review — {{repoShort}} · {{ticketKey-or-branch}}

| Repo | Branch | Base | Ticket | Date |
|---|---|---|---|---|
| {{repoSlug}} | `{{branch}}` | `{{baseSha-short}}` (fetched {{fetch-age, e.g. "4 min ago" — now minus run-manifest.fetchedAt}}) | {{ticketKey or "— none —"}} | {{YYYY-MM-DD HH:mm}} |

<!-- RUN SUMMARY — from time-ledger.json verbatim (agentsCalled/phases/totalSeconds),
     never recomputed. Lists only LLM subagents in "Agents called" (never scripts) —
     omit ones skipped this run (qa-scenario-writer on a cache hit, qa-e2e-author on
     a backend-only diff). The per-phase table's "Actor" column names whichever
     agent(s) and/or script(s) did that phase's work — this is what makes it honest
     that most wall-clock is deterministic scripts, not model calls. -->

**Agents called:** {{agentsCalled joined by " · ", or "— none (all cached / skipped) —"}}

| Phase | Actor | Seconds |
|---|---|---|
| {{phase name}} | {{actor}} | {{seconds}} |

**Total wall-clock: {{totalSeconds, formatted e.g. "3m 42s"}}** (phases marked
"overlapped" run concurrently — this is measured elapsed time, not the column sum)

---

<!-- VERDICT BLOCK — consequence-first, the whole point of the report.
     Max 3 headline items, ranked by blast radius:
       breaking contract > silent wrong behavior (surviving business-rule mutant)
       > failing scenario / AC NOT MET > missing test for an AC.
     Each item = concrete failure in plain language + file:line + evidence tag
     (oasdiff rule id / surviving mutant / uncovered AC branch) + "→" one action
     doable right now. Clean run: use the 🟢 form + the ✅ line only. -->

{{🔴 Not ready yet — N things a reviewer (or production) would catch: | 🟢 Ready to open — nothing blocking found.}}

1. {{concrete failure, plain language}} ({{file:line}}; {{evidence tag}}).
   → {{one action doable right now}}
2. {{…max 3 items…}}

✅ Solid: {{one line of what held — only claims the artifacts support}}

Merge risk: **{{band}}** · confidence: **{{confidence}}** — {{missing-signal reasons, verbatim from risk-score.json}}. Full evidence ↓

---

## Capability matrix

<!-- One row per level. State is exactly one of:
     RAN | DEGRADED — <why> | SKIPPED — <why> | PENDING — <why>.
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

## Unit level

<!-- From test-results.json + diff-coverage.json + the qa-analyst brief.
     Diff coverage phrasing is mandatory: "Of the lines you changed, X% ran
     under tests related to this branch (branch coverage Y%)". If
     diff-coverage.json has refused:true — state the refusal reason, no number.
     Test lists: three named lists ONLY — "most likely to catch a regression
     here" / "flaky-risk smells (static)" / "observed flaky (flipped across
     runs)". Never the word "riskiest". -->

{{unit findings}}

## Mutation level

<!-- From mutation-report.json. Absolute survivors only, phrased as consequence:
     "a wrong {{X}} would ship — N tests covering {{file}} still pass when
     {{mutation}}". Suppress NoCoverage mutants (they are coverage findings and
     belong in the Unit section). Name the assert to strengthen when known. -->

{{mutation findings}}

## Component level

<!-- Scenario states, exactly one of:
     EXECUTED — PASSED | EXECUTED — FAILED (finding) |
     GENERATED, COMPILES, NOT EXECUTED — <reason> — run: <command> |
     GENERATED, NOT EXECUTED — <reason>.
     AC claims carry their evidence source:
     MET — verified by executed scenario X (failed on base) ≠
     MET — verified (vacuity: static only) ≠ APPEARS MET — static reading only ≠
     NOT MET — <observed vs expected> ≠ UNVERIFIABLE — <reason>. -->

{{component findings + AC claims}}

## API + Contract level

<!-- Contract phrasing (from contract-report.json):
     ERR  → "breaking change to the documented API contract (rule <ruleId>) —
             any consumer relying on this shape will break"
     WARN → "potentially breaking — needs human judgment"
     Only Pact findings may name a consumer. Unknown provider states are
     "unverifiable, not failed". -->

{{api + contract findings + AC claims}}

## E2E {{+ Design conformance — frontend branches only}}

<!-- Cached-spec results only; new authoring is PENDING (see matrix).
     Design conformance findings: "DEVIATES — objective" (side-by-side evidence
     in the sibling evidence dir) vs "NEEDS HUMAN JUDGMENT" — never asserted as
     a defect. Scoped to the linked frames only. -->

{{e2e + design findings}}

## Generated tests

<!-- One row per rendered scenario (scenarios/*.json → renderedTo). Vacuity
     grade: "verified against base" (the test FAILED on the base build — the
     real guarantee) vs "static only" (not yet proven non-vacuous). -->

| Scenario | Path | State | Vacuity grade | Keep? |
|---|---|---|---|---|
| {{id}} — {{title}} | `{{worktree-relative path}}` | {{scenario state}} | {{verified against base \| static only}} | {{candidate \| no — why}} |

## Questions worth answering before the PR

<!-- The qa-analyst's Socratic questions, VERBATIM — written QA-style: each one
     leads with the real business/user scenario the gap represents ("if a
     customer's order nets to zero…", "if Finance changes the VAT rate…"), with
     the file:line evidence cited as why it's worth asking, not as the opener.
     ≤5, each answerable by one nameable test. If none: "None — the existing
     tests already answer the questions this diff raises." -->

{{socratic questions}}

<details>
<summary>Full evidence</summary>

### Risk-score signal ledger

<!-- From risk-score.json, verbatim. If renormalized:true, add the note:
     "Missing signals: {{missingSignals}} — weights renormalized; confidence
     lowered to {{confidence}}." A hard override (build-failed /
     affected-test-failed) replaces the ledger with the override reason. -->

| Signal | Value | Weight | Contribution | Available |
|---|---|---|---|---|
| {{name}} | {{value}} | {{weight}} | {{contribution}} | {{available}} |

Score: **{{score}}** → band **{{band}}** · confidence **{{confidence}}**

Methodology: heuristic scored from this diff only; not calibrated against CI history.

### Time ledger

<!-- Same phases as the top Run summary, this time with per-phase outcome instead
     of actor — the two tables are complementary, not duplicates. -->

| Phase | Seconds | Outcome |
|---|---|---|
| {{name}} | {{seconds}} | {{RAN \| DEGRADED — … \| SKIPPED — …}} |

### Capture provenance

<!-- Contract lane only (contract-report.json.captureProvenance): how each side
     of the spec diff was obtained — committed-spec vs boot, and the route. -->

Base: {{base}} · Rev: {{rev}} · Route: `{{route}}` · Mode: {{mode}}

### Command log

{{paths to TRX/JSON/log files under the workspace dir, for reproduction}}

</details>

---

<!-- KEEP-THESE-TESTS BLOCK — the orchestrator relays this question to the
     developer. List only keep-candidates (compiling, non-vacuous where
     verifiable, placement-legal per the adapter profile). On explicit yes, the
     orchestrator applies them to the product repo as a reviewed diff — never
     silently. -->

**Keep any of these tests?** They currently live only in agentQ's worktree; nothing touches your repo until you say yes and review the diff.

- `{{path}}` — {{one-line rationale, e.g. "covers AC-3's negative-total branch; failed on base"}}
- {{…}}

Reply with the ones to keep (or "none") — placement follows the repo's test-placement rules.
