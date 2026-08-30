<!--
  agentQ MAIN report skeleton — rendered by scripts/render-report.ps1
  (deterministic, zero model calls; the plain-language prose comes verbatim
  from analyst-brief.json's plain fields, scenarios' plainTitle, and
  suggestedFix's plainOneLiner — written by the judgment agents during the
  overlapped phase).
  Audience: a developer with NO QA background and NO full-application context.
  Rules (from CLAUDE.md Reporting):
    - Max 2 pages. Plain everyday words — no QA jargon ("mutant", "coverage %",
      "contract", "vacuous", "flaky" are said in their fixed plain phrasings).
    - Feature/user-flow framing only — never a class name, file path, or
      file:line here; that detail lives in the -evidence.md companion.
    - Fixed icon set only: 🔴/🟢 result · ❌ problem · 🛠️ action · ✅ good ·
      ⚠️ attention/couldn't check · ⏭️ not needed · ❓ question · 🖐️ manual
      check · 🧪 ready-made test · ⚖️ merge risk · 📄 evidence pointer ·
      🧭 what the branch does. Never improvise new icons.
    - Hard caps: 3 findings, 3 questions, 3 manual-check suggestions. Cut,
      don't compress — overflow goes to the evidence file.
    - A skipped/degraded check reads "⚠️ couldn't check — <plain why>" — never
      a pass, never an omitted row.
    - Numbers come from the workspace JSON artifacts verbatim.
    - When a reason is long or has more than one part (multiple blockers, an
      investigation, a suggested follow-up), state only the single most
      actionable one here and link to the evidence file for the rest — never
      paste the full essay into this file. This is the main report: a non-QA
      reader with no context. The evidence-file pointer appears twice: once
      right after the Result line (for someone who wants full detail
      immediately) and again at the bottom (the traditional full index) —
      both point to the same file, never a different link.
    - {{token}} = replace; the guidance comments = delete after filling.
-->

# 🧾 QA review — {{repoShort}} · {{ticketKey-or-branch}}

`{{branch}}` · {{YYYY-MM-DD}} · 

**Result: {{🔴 Not ready yet | 🟢 Ready to open}}**

📄 Full technical detail: [{{report-name}}-evidence.md]({{report-name}}-evidence.md)

**🧭 What this branch does:** {{one plain sentence, from the intake brief}}

## ❌ {{N}} things to fix first

<!-- Max 3, ranked: breaking API > silent wrong behavior > missing test.
     Each: plain title = what would go wrong for a user/partner/production,
     then 2–3 plain sentences (what happens + why nothing catches it today),
     then ONE action. Clean run: replace this whole section with
     "## ✅ Nothing blocking found". -->

**1. {{plain title}}**
{{2–3 plain sentences on the consequence}}

🛠️ **Do this:** {{the one action doable right now}}

📄 [More detail]({{report-name}}-evidence.md#{{github-slug of "N. <raw finding title from analyst-brief.json>", matching that finding's own "### N. <title>" heading in the evidence file — see CONTRACTS.md report-selection.json for why the numbering always lines up}})

## ✅ What's good

<!-- FIRST bullet is ALWAYS the acceptance-criteria note — one plain sentence
     rolling up the evidence file's AC grades, never a bare "met" without its
     basis: all met+verified → "✅ The ticket's acceptance criteria are met —
     proven by tests that ran"; appears-met/static-only → "✅ The acceptance
     criteria appear met — from reading the code only, no test proved it";
     any NOT MET → "⚠️ N of M acceptance criteria are not met — see finding X";
     unverifiable/no ticket → "⚠️ Couldn't check the acceptance criteria —
     <plain why>". Then the other bullets, ONE concise sentence each — only
     claims the artifacts support. -->

- {{acceptance-criteria note — always present, evidence-qualified}}
- {{e.g. "All NNN existing tests around this change pass."}}
- {{…}}

**⚖️ Merge risk: {{band}}** — {{one plain sentence of why; band verbatim from risk-score.json; never a "probability of passing CI"}}.

## ❓ Questions for the team

<!-- Max 3, plain-language versions of the analyst's Socratic questions.
     The full set (≤5, with evidence) lives in the evidence file. -->

1. {{plain question}}

## 🖐️ Worth checking by hand

<!-- ONLY when Phase 1c produced candidates: ≤3 plain titles, diff-seed matches
     first, then "+N more in the evidence file". Degraded/skipped/none →
     DELETE this section; the 🔍 table row explains why. -->

- {{manual test candidate, plain title}}

## 🔍 What was checked

<!-- One plain question per row. Result = one icon + a plain half-sentence.
     Skipped/degraded = "⚠️ couldn't check — <plain why>"; not applicable =
     "⏭️ not needed — <why>". Never an omitted row. -->

| Check | Result |
|---|---|
| Existing tests around this change | {{✅ NNN of NNN pass \| ❌ N fail}} |
| Would tests catch a deliberately broken rule? | {{✅ yes \| ⚠️ N gaps (item …)}} |
| Changed code that runs under tests | {{e.g. "⚠️ about 7 lines in 10 — the gap is …"}} |
| Public API compatibility | {{✅ safe — … \| ❌ breaking — item N}} |
| Ticket acceptance criteria | {{✅/⚠️ … \| ⚠️ couldn't check — <plain why>}} |
| Other repos / suggested manual tests | {{result \| ⚠️ couldn't check — <plain why>}} |
| UI tests | {{result \| ⏭️ not needed — no frontend change \| ⚠️ couldn't check — <ONE short reason + the one concrete fix> ([full detail]({{report-name}}-evidence.md#e2e))}} |

## 🧪 Ready-made tests ({{N}}) — keep them?

<!-- Same tests, same order as the evidence file's Generated scenarios table.
     Numbered ONE-LINE plain descriptions — no paths (paths live in the
     evidence file). A mutation-level entry is an edit to an existing test,
     not a new file. On explicit yes the orchestrator applies them as a
     reviewed diff — never silently. If none: "No ready-made tests this run." -->

They only touch your repo if you say yes and review the diff.

1. {{one-line plain description}}

Reply with the ones to keep, or "none".

<!-- The evidence pointer is a clickable relative markdown link (both files
     live in reports/, so the bare filename is the correct relative path) —
     never just the name in backticks. -->
📄 *Full technical detail (files, line numbers, timings, risk formula): [{{report-name}}-evidence.md]({{report-name}}-evidence.md)*
