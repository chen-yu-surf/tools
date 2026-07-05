# Phase 1 — Validate & Parse

0. **Capture start time** — run `date +%s` in a terminal and store the integer result as
   session variable `start_time`. Do this before any other Phase 1 work so the full analysis
   duration is captured.

1. Resolve the report path using the Input Formats table in the SKILL.md:
   - **Absolute path** → confirm accessible via `mcp_shz_lkp_mcp_list_external_directory`
   - **Mailing list URL** (`https://lore.kernel.org/...`, `https://lkml.org/...`, or any
     public ML archive URL) → see **URL branch** below.
   - **Commit SHA** → run the resolver script (do NOT call
     `mcp_shz_lkp_mcp_list_external_directory("/zdci/archive/email")` — it returns thousands of
     date directories and requires a second round-trip to locate the file):
     ```bash
     .agents/skills/lkp-auditperf/scripts/resolve-bisect-email <lkp_core_root> <sha10>
     ```
     It reads `shz.lkp_server` / `default.lkp_server` / `igk.lkp_server` from `llm/config.yml`,
     searches SHZ first and falls back to IGK (at most two SSH calls), and excludes self-generated
     report emails from this skill family by substring match on `auditfbc`/`auditperf` anywhere in
     the filename (not just as a literal prefix) — real examples include
     `Subject___auditfbc___copilot_v0.1.0___shz___validated_1__...` and
     `Subject___Error___auditfbc___langchain_v0.2.0___...`, which also match `*validated_1__<sha10>*`
     but are NOT the original LKP bisect report.

     Record from its `key=value` output: `email_archive_server` ← `server`, `report_path` ←
     `path`, `bisect_tag` ← `bisect_tag`. If `found=false`, no bisect email exists for this SHA —
     fall through to the no-bisect-email path in Step 5 below.
     Use `email_archive_server` (not `lkp_server`) for all subsequent archive file reads.
     Also derive `site` by stripping the brackets from `bisect_tag` (e.g. `[shz]` → `shz`,
     `[igk]` → `igk`). Use `site` as the `mcp_<site>_lsp_mcp_*` prefix for all LSP tool calls in
     Phase 3B/4/5 — the LSP workspace's `build_dir` is only reachable from the MCP server on the
     same site that hosts `result_root`. In result-search/static-only modes (no `bisect_tag`),
     default `site` to `shz`.

     **`mail_subject` is NOT available yet** — it also needs `metric_from_perf_change`, which
     only becomes known after Step 2's `extract_bisect_report` call. Construct it in Step 2b
     below once `perf_change` is known; do not attempt to derive it here.
   - **Jira key** → `mcp_shz_zdci_mcp_get_issue` → extract SHA or path from description/comments

---

### URL Branch — Mailing List Report

When the user provides a mailing list URL: read
[phase1-url-branch.md](phase1-url-branch.md) now (Steps U1–U4) and follow it to completion, then
continue at Step 2 below. Skip this branch entirely for path/SHA/Jira-key input.

---

2. Call `mcp_shz_lkp_mcp_extract_bisect_report(report_path)`. Read these fields from the manifest:
   - `report_type` — must be `"performance"` → **stop and tell the user if not**
   - `tmp_dir`, `fbc_hash`, `perf_change`, `result_root`
   - `boundary_valid`, `parent_fails`, `fbc_fails`
   - `change_direction` — grep `history.txt` for `change_direction:` after extraction (see step 2b)
   - `mcp_shz_lkp_mcp_read_extracted_data` and `mcp_shz_lkp_mcp_grep_extracted_data` — use to read files; prefer `grep_extracted_data` for large files
   - If `extract_bisect_report` fails: stop and report the exact error — cannot continue without the manifest.
   - **If `mcp_shz_lkp_mcp_extract_bisect_report` is not in the available tools**: resolve
     `lkp_server` from `llm/config.yml` (steps 1–2 above), then copy the report via
     `ssh <lkp_server> "cat <report_path>"` and save locally. Replicate the extraction using
     `python3` with `llm/lib/bisect_report.py`'s `BisectReport` class (see
     `llm/fast_mcp/lkp_mcp.py:extract_bisect_report` for the exact logic). Write files to
     `workspace_tmp/lkp-auditperf-<fbc_hash[:16]>/` using the same layout.

   **2b. Read `change_direction`**: after extraction, run:
   ```
   grep 'change_direction:' <tmp_dir>/history.txt
   ```
   Record the value (`improvement` or `regression`). Carry into Phase 2 and Phase 4.
   If grep returns empty (field absent from older reports): default `change_direction = "regression"`.

   **2c. Construct `mail_subject`** (bisect-driven path only, now that `perf_change` is known):
   `metric_from_perf_change` = the metric key from the `perf_change` manifest field
   (e.g. `stress-ng.session.ops_per_sec`). Build:
   `"{bisect_tag} {fbc_hash[:10]} bisect for {metric_from_perf_change}"` using the
   `bisect_tag` recorded in Step 1. Example:
   `"[shz] [validated 1] b8fea7af0e bisect for stress-ng.session.ops_per_sec"`
   Never copy a `mail_subject` from a previously generated auditperf report email — always
   derive it fresh from `bisect_tag` + `fbc_hash` + the manifest `perf_change`.

3. Derive `workspace_id = lkp-auditperf-{fbc_hash[:12]}`.

4. Confirm `result_root` is accessible via `mcp_shz_lkp_mcp_list_external_directory`; stop if not.

5. **Analysis path selection**: if steps 1–4 above succeeded (bisect report found and extracted):
   - Set `analysis_mode = bisect-driven`, `data_source_tag = [BISECT-REPORT]`
   - Proceed to Phase 2 (normal path)

   If `resolve-bisect-email` in step 1 returns **`found=false`** (bare SHA, no bisect email):
   - Set `analysis_mode` tentatively; actual mode (`result-search` vs `static-only`) is resolved in Phase 2
   - Set `data_source_tag = [STATIC-ONLY]` (placeholder; upgraded in Phase 2 if results found)
   - Set `perf_change = "N/A"`, `boundary_valid = false`, `tmp_dir = null`
   - Construct `mail_subject = "lkp-auditperf: {fbc_hash[:12]} (commit subject TBD — not yet fetched)"`
     — the commit isn't fetched until Phase 3B Step 1 / Phase 4 Step 1, so no real subject line
     exists yet here; this value is informational only (Phase 1 checkpoint display) and is never
     rendered in the final Verdict for `result-search`/`static-only` modes (those use the literal
     `[RESULT-FOUND]`/`[STATIC-ONLY]` tag instead, per phase4-rca.md `## Verdict` Data source row)
   - Proceed to Phase 2 (result-search / static-only path)

Output this checkpoint before continuing:

```
Phase 1 ✓
  fbc_hash:      {fbc_hash[:12]}
  analysis_mode: {analysis_mode}
  perf_change:   {perf_change}
  result_root:   {result_root or "TBD — searched in Phase 2"}
  mail_subject:  {mail_subject}
```
(mail_subject: full `Subject:` header from the bisect email, or constructed string for non-bisect input)

## Pre-flight checklist — verify before proceeding to Phase 2

Binary preconditions: if any fails, apply the stated correction now before advancing.

- □ **`start_time` is a numeric Unix timestamp** (e.g. `1719571234`) — not a string or placeholder.
  → If absent: run `date +%s` now and record the integer result.
- □ **`fbc_hash` is a lowercase hex string** of 10–40 characters — not a commit subject or path fragment.
  → If absent or non-hex: stop; ask the user to provide the commit SHA directly.
- □ **`analysis_mode`** is one of `bisect-driven` / `result-search` / `static-only` — not unset.
  → If unset: re-read Step 5 above and apply the analysis path selection logic.
- □ **`user_email` is set and not empty** — the primary recipient of the analysis email. Defaults to
  `git config user.email`; may be overridden when sending to a specific kernel developer.
  → If empty: run `git config user.email` now; if still empty, ask the user before proceeding.
- □ **`cc_email` is `lkp@intel.com`** — fixed constant; do not derive from git config.
  → This is always `lkp@intel.com`; no lookup needed.
- □ **`mail_subject` was constructed fresh** — from the bisect report Subject line or the `{bisect_tag} {fbc_hash[:10]} bisect for {metric}` formula. Must NOT be copied verbatim from a previously generated auditperf output email.
  → If it begins with `[auditperf]`: it was copied from a generated report — rederive it now from the original bisect email Subject line.
