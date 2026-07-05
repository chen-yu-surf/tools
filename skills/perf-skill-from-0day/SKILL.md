---
name: lkp-auditperf
description: "Analyze a Linux kernel commit for performance impact: bisect-driven regression audit, result-search analysis, or static diff analysis when no bisect data exists. For regressions: produces root cause analysis and fix patch. For improvements: extracts the optimization pattern and proposes applying it to similar kernel code paths (Optimization Discovery). Triggered by: LKP FBC audit, bisect report analysis, kernel performance regression or improvement, kernel commit performance review, pre-merge performance check, mailing list performance report URL (lore.kernel.org or similar)."
---

# LKP Kernel Commit Performance Analyzer

Analyze kernel commits for **performance impact** across three modes:
- **`bisect-driven`**: a validated bisect email exists — full confirmed regression audit (original flow)
- **`result-search`**: no bisect email, but result roots exist for the commit — evidence-based analysis
- **`static-only`**: no bisect email, no result roots — diff + LLM knowledge static analysis with optional job queuing

Stop immediately for boot or functional regressions (non-performance `report_type`).

## Rules (always active)

| Rule | Detail |
|---|---|
| Bisect report is one input, not the goal | The goal is the commit's actual performance impact, not confirming the bisect tool's verdict. Never skip Phase 3 Step 0's independent `static_prediction` (computed from the diff **before** reading bisect perf-stat/perf-profile data) in `bisect-driven` mode, and never write "Root cause confirmed" in `## Verdict` without completing the Prediction vs Measurement comparison in Phase 4. If evidence shows the bisected commit is an exposing commit rather than the true mechanism, report that — it is a valid, useful outcome, not a failure to reproduce the bisect. |
| No silent caching | If the same `fbc_hash` was analyzed earlier in this session, **ask the user** before re-running: *"This commit was analyzed earlier in this session. Re-run all phases fresh (e.g. to verify agent changes), or show the cached summary?"* Never silently shortcut a re-invocation. |
| Performance only | Stop if `report_type ≠ "performance"` (bisect-driven mode only; skip check in other modes) |
| Always call `mcp_shz_git_mcp_get_linux_commit` | Before any RCA conclusion, in all modes |
| Apply LLM knowledge | In result-search and static-only modes, use your own training knowledge of kernel code flow, data structures, memory access patterns, and locking to assess performance impact — do not limit analysis to domain-reference.md tables alone |
| LSP when needed | `mcp_<site>_lsp_mcp_init_lsp_workspace` for multi-file diffs or `[CHAIN TRUNCATED]`; `mcp_<site>_lsp_mcp_cleanup_lsp_workspace` after Phase 4 — `<site>` is the resolved `site` session variable (`shz`/`igk`), never assume `shz` |
| No full-file dumps | `grep_extracted_data` first; `read_extracted_data` only when needed |
| No force-pushes | Present patch and stop; user pushes |
| No external kernel submission | NEVER use `git send-email`, `git push` to any Linux kernel tree, or submit to LKML/mailing lists. Kernel patches produced by this skill are internal proposals only — they go to the user's email for review. Phase 6 (`validate`) compile-verifies and commits to an internal LKP branch only. |
| No fabrication | Stop clearly if result root is inaccessible or report is invalid |
| Never revert security/functional fixes | If commit subject or body contains `CVE-`, `spectre`, `IBRS`, `STIBP`, `retbleed`, `MDS`, use-after-free, race condition, memory leak, overflow — find a reduced-overhead alternative; revert is not a valid fix |
| Generate fix patch for regressions | After Phase 4, always proceed to Phase 5 if a regression or predicted regression is identified, regardless of analysis mode |
| Optimization Discovery for improvements | After Phase 4, if `change_direction == "improvement"`: proceed to Phase 5 to extract the optimization pattern and search the kernel for similar code paths that could benefit from the same technique |
| In-task self-tuning | If any phase requires manually performing mechanical, judgment-free work (tallying/counting rows, classifying strings against a fixed rubric, structural validation of rendered text) that no existing script already covers, fix it directly (new script, rewritten instruction) and commit it immediately, in the same turn — see `.github/agents/lkp.tuneagent.agent.md` § In-task Self-Tuning. Do not wait for Phase 8 or an explicit user request. |

## MCP Fallback *(cluster accessible via SSH)*

If any MCP tool call fails or is reported unavailable, read
[references/mcp-fallback.md](references/mcp-fallback.md) now for the full SSH drop-in catalog
(cluster file access, git tools, LSP degraded mode, email/external tools). Do not load it on a
normal run where every tool call succeeds.

## Session State

Declare and carry these values across every phase. Never re-derive them after they are set.

| Variable | Set in | Carried into |
|---|---|---|
| `fbc_hash` | Phase 1 | 2, 3, 4, 5, 6, 7 |
| `analysis_mode` (`bisect-driven` / `result-search` / `static-only`) | Phase 1 mode selection | all phases |
| `data_source_tag` (`[BISECT-REPORT]` / `[RESULT-FOUND]` / `[STATIC-ONLY]`) | Phase 1 mode selection | 4, 5, 6 |
| `tmp_dir` | Phase 1 manifest (bisect-driven only) | 3, 6 |
| `result_root` | Phase 1 manifest or Phase 3 search | 3, 4, 6 |
| `perf_change` | Phase 1/2 manifest or Phase 3 compare; `"N/A"` in static-only | 2, 4, 6 |
| `boundary_valid` | Phase 1 manifest (bisect-driven); `false` otherwise | 2, 4, 6 |
| `search_suite` | User-supplied optional hint for result search | 2, 3 |
| `workspace_id` | Phase 1 derived | 3B, 4 |
| `metric_tag` (`[MULTI-METRIC CONFIRMED]` / `[SINGLE-METRIC]` / `[INCONSISTENT]`) | Phase 3 step 4 | Phase 4 confidence |
| `hw_tag` (`[MEMORY-BOUND]` / `[TLB-BOUND]` / `[LOCK-CONTENTION]` / `none`) | Phase 3 step 5 — from hardware counters + diff mechanism | Phase 4 pattern match hint |
| `user_email` | Phase 1: from user prompt if provided, else `git config user.email`, else ask user before Phase 5 | 4, 5 |
| `mail_subject` | Phase 1: `grep '^Subject: '` on report file, or constructed | 4, 5 |
| `email_archive_server` | Phase 1: server where bisect email was found (`shz_server` or `igk_server`) | 1, 3, 6 |
| `site` (`shz` / `igk`) | Phase 1: `bisect_tag` stripped of brackets (bisect-driven mode); `shz` default in result-search/static-only modes | 3B, 4, 5 |
| `static_prediction` | Phase 3 Step 0 (bisect-driven only): `"{direction} | {mechanism} | hw_tag={tag} | scale_condition={cond}"`; unset for other modes | 4 |
| `rca_email_body` | Phase 4: markdown body built at end of Phase 4 | 5, 8 |
| `confidence` (`"High"` / `"Medium"` / `"Low"`) | Phase 4 JSON | 5 |
| `is_true_root_cause` (`true` / `false`) | Phase 4 JSON | 5 |
| `regression_type` (`[MEMORY-BOUND]` / `[LOCK-CONTENTION]` / `[TLB-BOUND]` / `general`) | Phase 4 JSON — final classification, may differ from `hw_tag` | 5 |
| `fix_status` (`"fix posted: …"` / `"unaddressed"` / `"unknown"`) | Phase 4 Step 5 git grep | Phase 5 `## Community Awareness` |
| `lore_url` | Phase 1 (URL input only): original URL provided by user | 1, 4 |
| `external_metrics` | Phase 1 (URL input only): list of dicts `[{metric, perf_change, suite, stressor, parent_hash, change_direction, tbox, nr_task, kconfig, compiler, git_url, git_branch}]`, one entry per reported metric; primary signal = entry with largest `|perf_change|`; parsed from email body/subject per phase1-validate.md Step U3 | 2, 3, 4 |
| `change_direction` (`"regression"` / `"improvement"`) | Phase 1: from primary `external_metrics` entry's `change_direction` field, or inferred from sign of `perf_change`; `"regression"` by default for bisect-driven | 4, 5 |
| `start_time` | Phase 1 Step 1: Unix timestamp captured with `date +%s` immediately before any other Phase 1 work | 5 |

## Input Formats

| Input | Resolution |
|---|---|
| Absolute bisect report path | Confirm via `mcp_shz_lkp_mcp_list_external_directory` → `bisect-driven` mode |
| Commit SHA (10–40 hex) with bisect email | List `/zdci/archive/email/`, match `*validated_1__<sha10>*` → `bisect-driven` mode |
| Commit SHA (10–40 hex) — no bisect email | Mode detection in Phase 1 → `result-search` or `static-only` |
| Jira key `ZDAYCI-NNNNN` | `mcp_shz_zdci_mcp_get_issue` → extract SHA or path → then resolve mode |
| Patch/diff text | Extract commit SHA from `From <sha>` header; proceed as bare SHA |
| Mailing list URL (`https://lore.kernel.org/...` or similar) | `fetch_webpage` → parse commit SHA, metrics, suite/stressor from email body → check for matching bisect email → `bisect-driven`, `result-search`, or `static-only` mode; see Phase 1 URL branch. **Both regression and improvement reports from oe-lkp are valid inputs**; improvement reports carry `change_direction: improvement` in body and `+X% improvement of` in subject — process through all phases normally. |

## Workflow

**You MUST read the corresponding reference file before executing each phase.** All files are in
`.agents/skills/lkp-auditperf/references/`. Phases 1–5 run automatically, back to back, with no
pause for user confirmation — Phase 4 always proceeds straight into Phase 5 (patch generation for
regressions, optimization proposal for improvements) per the Rules table above. Phases 6–8 are all
user-triggered, independently and in any order, via three trigger words offered together in one
consolidated message at the end of Phase 4's post-analysis domain update (never split across
separate messages): `validate` (Phase 6 — compile-verify the patch and commit it to an internal
LKP branch; previously called `commit`, renamed because Phase 6 is a compile-verification gate
first and an internal commit second, not an upstream submission), `e2e` (Phase 7 — generate a test
fixture), `review` (Phase 8 — fresh-context quality review subagent).

Phase 3 has **two tracks**: Track A (`bisect-driven`) uses `phase3-evidence.md`; Track B
(`result-search` / `static-only`) uses `phase3-commit-only.md`.

| Phase | Auto/User | Track | Reference file |
|---|---|---|---|
| **1 — Validate & Mode Select** | Auto | All | [references/phase1-validate.md](references/phase1-validate.md) |
| **2 — Verify / Detect Signal** | Auto (stops if noise/flake/no signal) | All | [references/phase2-signal.md](references/phase2-signal.md) |
| **3A — Gather Evidence** | Auto | `bisect-driven` | [references/phase3-evidence.md](references/phase3-evidence.md) |
| **3B — Diff + Search Analysis** | Auto | `result-search` / `static-only` | [references/phase3-commit-only.md](references/phase3-commit-only.md) |
| **3C — Queue Jobs** *(optional)* | User-triggered from 3B | `result-search` / `static-only` | [references/phase3-commit-only.md](references/phase3-commit-only.md) §Queue |
| **4 — Root Cause Analysis** | Auto | All | [references/phase4-rca.md](references/phase4-rca.md) |
| **↳ Post-analysis domain update** | Auto — run immediately after Phase 5's email send, do NOT wait for the user to ask | All | Inline in [references/phase4-rca.md](references/phase4-rca.md) §Post-analysis domain knowledge update — no separate file read needed. Self-reflection criteria (evidence chain rating, alternative hypotheses, prediction calibration, skill gaps) are handled by Phase 8 (subagent review), not here — do NOT add `## Analysis Reflection` to the email. |
| **5 — Patch Generation** | Auto | All | [references/phase5-patch.md](references/phase5-patch.md) |
| **6 — Validate & Commit** | User-triggered after Phase 5 (`validate`) | All | [references/phase6-commit.md](references/phase6-commit.md) |
| **7 — e2e Fixture** | User-triggered after Phase 5 (`e2e`) | All | [references/phase7-e2e.md](references/phase7-e2e.md) |
| **8 — Quality Review** | User-triggered after Phase 5 (`review`) | All | [references/phase8-review.md](references/phase8-review.md) — spawns a fresh-context subagent; evaluates the completed audit against 4 criteria (evidence chain, alternative hypotheses, prediction calibration, skill gaps); reports findings in chat; does NOT modify the sent email. |
