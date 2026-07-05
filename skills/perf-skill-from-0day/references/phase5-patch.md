# Phase 5 — Patch Generation *(runs automatically after Phase 4; no user confirmation required)*

> **Branch on `change_direction`**: if `change_direction == "improvement"` follow the
> **Optimization Proposal** path (steps A–E below). If `change_direction == "regression"` follow
> the **Regression Fix** path (steps 1–8 below). Never mix the two paths.

---

## Optimization Proposal path *(improvements only)*

**A — Identify the top candidate** from Phase 4 `## Optimization Opportunities` (the table of
OTHER kernel code paths that share the same inefficiency pattern as `fbc_hash`). Use the #1 ranked
candidate (highest hot-path likelihood, lowest effort if tied).

**No candidate found**: if Phase 4's `## Optimization Opportunities` table has no real rows (a
genuine repo-wide search found no other in-tree call site sharing the same inefficiency pattern —
a valid, honest outcome, not a search failure to retry), skip steps B–D entirely. State the reason
explicitly in the email body (do not fail silently, matching the Regression Fix path's step 5 rule)
and proceed straight to step E to send the consolidated RCA-only email with no patch attachment.

**B — Read and understand the target function**:
1. `mcp_shz_git_mcp_read_repo_file` on the candidate file — read the full function (±30 lines of context).
2. `mcp_<site>_lsp_mcp_get_lsp_references` on the candidate function to confirm call frequency and
   callers (confirms it is actually on a hot path). `<site>` is the `site` session variable resolved
   in Phase 1, not always `shz`.
3. Read the style guide for the target language (C kernel patch → kernel coding style).

**C — Lint and validate** — run the `lkp-pre-commit` skill
(`.agents/skills/lkp-pre-commit/SKILL.md`) on the proposal patch before emitting output.

**D — Generate a proposal patch** applying the same technique as `fbc_hash`:
- Patch header must start with: `[OPTIMIZATION PROPOSAL — extends {fbc_hash[:10]} pattern]`
- Commit message subject: `<subsystem>: apply {technique_label} optimization to {function_name}`
- Body: explain the before-state inefficiency, the technique, expected improvement direction.
  Do NOT promise a specific percentage — write: *"expected to reduce overhead similarly to
  {fbc_hash[:10]} in {suite}/{stressor}"*.
- Produce **exactly one** unified diff — no truncation, ≥ 3 lines of context, applicable with
  `patch -p1`.

**Pre-send checklist** — verify before calling the send tool. Run the structural lint first and
read its output directly for the mechanical checks (section order, raw mermaid fence, Verdict
table row count, Impact Mechanism table, subject format); the remaining bullets below require your
own semantic judgment and are not covered by the script:
```bash
.agents/skills/lkp-auditperf/scripts/lint-email-body <md_body_file> "<subject>" improvement
```

- □ **`## Summary` is exactly 2 template sentences**: (1) prose, no Field/Value table; (2) no kernel mechanism explanation or internal symbol names — those belong in `## Impact Mechanism`; (3) `fix_hint_one_phrase` is ≤ 10 words; (4) `is_true_root_cause` is reflected.
  → If technical mechanism appears in Summary: move to `## Impact Mechanism`; do NOT send until corrected.
- □ **`## Verdict` is an 8-row table, not a paragraph** (script: `verdict_table=`). For bisect reports the Data source cell **must have two lines** (`<br>`-separated): `[BISECT-REPORT] {mail_subject}` on line 1 and `{email_archive_server}:{report_path}` on line 2 — the script does not check this two-line requirement, verify it yourself.
  → If it is a paragraph, missing hw_tag/Regression type rows, or Data source has only one line for a bisect report: rebuild `md_body` before sending.
- □ **`## Impact Mechanism` has no metric delta table** (script: `impact_mechanism_table=`): inline metric references are fine; a `| Metric | Before | After |` table is not. That table belongs in `## Evidence` only.
  → If a metric table appears in `## Impact Mechanism`: remove it; do NOT send until corrected.
- □ **`subject` is `[auditperf] {fbc_hash[:10]}: {commit_subject}`** (script: `subject_format=`) — `fbc_hash[:10]` and `commit_subject` come from Phase 1 session variables (`commit_subject` = first line of the git commit message, not the bisect email subject; e.g. `sched/fair: Allocate cfs_tg_state with percpu allocator`).
  → If subject contains `optimization:` or copies the bisect mail subject: correct it to the `[auditperf] sha: title` form.
- □ **`cc_email` is always `lkp@intel.com`** (fixed — do not derive from git config; not covered by the script).
  → If `mail_cc` is missing from the send call: add it now.
- □ **`## Causal Chain` mermaid block was converted** to `![Causal chain diagram](https://mermaid.ink/img/<base64>)` — no raw ` ```mermaid ``` ` fenced block remains in `md_body` (script: `mermaid_raw_fence=`).
  → If not converted: base64-encode the mermaid source now and replace the fenced block inline.
- □ **Email sections are in the required order** (script: `section_order=`): `## Summary` → `## Verdict` → `## Impact Mechanism` → `## Causal Chain` → `## Evidence` → `## Prediction vs Measurement` → `## Community Awareness` → `## Optimization Opportunities` → `## Optimization Proposal`.
  → If any section is out of order: reorder `md_body` before calling the send tool.
- □ **All workspace temp files are under `workspace_tmp/`** — not under `/tmp` on the local host (not covered by the script — about files on disk, not body content).
  → If any file was written to `/tmp` locally: note it; the cleanup command must target that path.

**E — Send the consolidated email**:

**Email format: HTML.** The body is the Phase 4 markdown output rendered to HTML.
`mcp_shz_email_mcp_send_markdown_email` handles markdown→HTML conversion automatically
(GitHub-like CSS via `render_html_body`). The sendmail fallback MUST also call
`render_html_body` (imported from `/lkp/lkp/src/llm/lib/html_render.py` on the server)
— never use bare `markdown.markdown()` directly, which produces unstyled HTML that does
not match other LKP emails.

The patch file must be a real email **attachment** (not inlined in the body). Use `sendmail` via
SSH when `mcp_shz_email_mcp_send_markdown_email` attachment encoding fails:

```bash
mkdir -p workspace_tmp
cat > workspace_tmp/opt-{fbc_hash[:12]}.patch << 'PATCHEOF'
<unified diff content>
PATCHEOF
# Primary: mcp_shz_email_mcp_send_markdown_email — renders markdown to HTML automatically
base64 -w 0 workspace_tmp/opt-{fbc_hash[:12]}.patch > workspace_tmp/opt-{fbc_hash[:12]}.b64

# Fallback: write a Python script to a file, scp it, run it — never use a here-doc
# because the markdown body contains backticks, angle-brackets, and shell metacharacters
# that bash will expand or break when reading a here-document.
#
# Instead: write the Python script locally via create_file (absolute path inside
# workspace_tmp/), scp both files, run the script, then delete everything.
#
# The script MUST import render_html_body from the deployed LKP source so the email
# uses the same GitHub-like CSS styling as all other LKP emails. Do NOT call
# markdown.markdown() directly — that produces unstyled bare HTML.
#
# Python script template (save to workspace_tmp/send_opt_{fbc_hash[:12]}.py):
"""
import subprocess, sys, time
sys.path.insert(0, "/lkp/lkp/src/llm")
from lib.html_render import render_html_body
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.base import MIMEBase
from email import encoders

with open("/tmp/opt-{fbc_hash[:12]}.patch", "rb") as f:
    patch_data = f.read()

md_body = """{full markdown body — sections in order: ## Summary → ## Verdict → ## Impact Mechanism → ## Causal Chain → ## Evidence → ## Prediction vs Measurement → ## Community Awareness → ## Optimization Opportunities → ## Optimization Proposal → ## Analysis Reflection.}"""

html_body = render_html_body(
    "[improvement] {metric} +{perf_change}% on {tbox}",
    md_body,
)

msg = MIMEMultipart("mixed")
msg["Subject"] = "[auditperf] {fbc_hash[:10]}: {commit_subject}"
msg["From"]    = "kernel test robot <lkp@intel.com>"
msg["To"]      = "{user_email}"
msg["Cc"]      = "lkp@intel.com"

msg.attach(MIMEText(html_body, "html", "utf-8"))

part = MIMEBase("application", "octet-stream")
part.set_payload(patch_data)
encoders.encode_base64(part)
part.add_header("Content-Disposition", "attachment; filename=\\"opt-{fbc_hash[:12]}.patch\\"")
msg.attach(part)

result = subprocess.run(["/usr/sbin/sendmail", "-t"],
    input=msg.as_string(), capture_output=True, text=True, timeout=15)
print("returncode:", result.returncode)
if result.stderr: print("stderr:", result.stderr[:200])
"""
# Then:
scp workspace_tmp/opt-{fbc_hash[:12]}.patch workspace_tmp/send_opt_{fbc_hash[:12]}.py \
    <lkp_server>:/tmp/
ssh <lkp_server> "python3 /tmp/send_opt_{fbc_hash[:12]}.py"
ssh <lkp_server> "rm -f /tmp/opt-{fbc_hash[:12]}.patch /tmp/send_opt_{fbc_hash[:12]}.py"
```

The email **body** MUST be identical to the Phase 4 Copilot output — copy all `##` sections
verbatim, exactly as they appeared in the IDE analysis. Do NOT paraphrase, abbreviate, or omit
any section. The only permitted adaptations from the IDE output are:

- `## Causal Chain`: the mermaid fenced block does not render in email clients. Replace it with:
  1. An **embedded diagram image** so the diagram renders inline in the email:
     encode the mermaid source as URL-safe base64, then use the mermaid.ink rendering service:
     ```
     ![Causal chain diagram](https://mermaid.ink/img/<base64>)
     ```
     The `![...]` form embeds the image inline (HTML email clients load it from mermaid.ink).
  2. Followed by the 1–2 sentence text summary (unchanged from IDE output).
- `## Prediction vs Measurement`: render `static_prediction` as a **4-row table** (not
  pipe-delimited string):
  | Field | Value |
  |---|---|
  | Direction | {direction} |
  | Mechanism | {mechanism_1_sentence} |
  | hw_tag | {hw_tag} |
  | scale_condition | {scale_condition_or_none} |
  Then the bisect outcome and agreement tag lines unchanged.

The following sections are copied verbatim from the IDE Phase 4 output **in this order**:
`## Summary`, `## Verdict`, `## Impact Mechanism`, `## Causal Chain` (adapted per above),
`## Evidence`, `## Prediction vs Measurement` (adapted per above), `## Community Awareness`.

`## Optimization Opportunities` is **moved to the end**, immediately before
`## Optimization Proposal` — reorder it from wherever it appeared in the Phase 4 IDE output.

Then append the `## Optimization Proposal` section (not part of Phase 4 output):
```
---

## Optimization Proposal

**Applying Candidate 1 from `## Optimization Opportunities` above** — {file.c:function()},
{one-line candidate description from the candidates table}.

**Technique**: `{technique_label}` — {same Pattern description as in Optimization Opportunities}.

Patch attached as `opt-{fbc_hash[:12]}.patch` (unified diff, `patch -p1` applicable).

Expected to reduce overhead similarly to `{fbc_hash[:10]}` in `{suite}/{stressor}`.
```

Do **NOT** include the patch diff inline in the email body — the patch is already attached
as `opt-{fbc_hash[:12]}.patch`. The prose `## Optimization Proposal` section referencing the
attachment is sufficient; the reader downloads and applies the attached file.

Subject rule: use `fbc_hash[:10]` and `commit_subject` from Phase 1 session variables
(`commit_subject` = first line of the kernel git commit message, obtained via
`mcp_shz_git_mcp_get_linux_commit` or `mcp_shz_git_mcp_get_git_commits`). The correct form is:
`subject="[auditperf] {fbc_hash[:10]}: {commit_subject}"` (e.g.
`"[auditperf] b8fea7af0e40: sched/fair: Allocate cfs_tg_state with percpu allocator"`).
Never use the bisect email subject (`mail_subject`) in the email subject line.

Clean up: `rm -f workspace_tmp/opt-{fbc_hash[:12]}.patch workspace_tmp/opt-{fbc_hash[:12]}.b64`

**⛔ External submission is FORBIDDEN**: the patch IS generated and attached to the internal RCA
email above — that is the correct and expected behaviour. What is forbidden is any attempt to
submit it upstream: never run `git send-email`, never push to any Linux kernel tree, and never
submit to LKML or any upstream mailing list. The patch is an internal proposal only.

Do NOT tell the user next steps here and do NOT stop the turn yet — Phase 4's Post-analysis
domain knowledge update (`phase4-rca.md` §Post-analysis domain knowledge update) still runs after
this phase, in the same turn, and it emits the one consolidated `## Session Summary` +
next-steps message (`validate`/`e2e`/`review` together). Do NOT mention `lkp-submit-patch`,
`./email`, upstream kernel mailing lists, or kernel authors anywhere. Never prompt to forward the
patch externally.

1. Use `mcp_shz_git_mcp_read_repo_file`, `mcp_<site>_lsp_mcp_get_lsp_references`, and `mcp_<site>_lsp_mcp_get_lsp_definition` to design the fix. `<site>` is the `site` session variable resolved in Phase 1, not always `shz`.

2. Even if `fbc_hash` is only an exposing commit, patch the underlying kernel performance fault. If
   `fbc_hash` is a functional or security fix, generate a patch that reduces overhead without
   breaking the fix — never recommend reverting.

3. Read the relevant style guide before writing code:
   - C kernel patch → kernel coding style (no LKP instruction file)
   - Bash/shell → `.github/instructions/bash.instructions.md`
   - Python → `.github/instructions/python.instructions.md`

4. Produce **exactly one** unified diff — no truncation, ≥ 3 lines of context, applicable with
   `patch -p1`:
   ````diff
   <unified diff>
   ````

5. If no safe fix is possible, state the reason explicitly — do not fail silently.

6. **Stable backport**: for `High`-confidence regressions in a core subsystem (`mm/`,
   `kernel/sched/`, `fs/`, `block/`) — recommend adding `Cc: stable@vger.kernel.org` to the kernel
   patch commit message. Flag this to the user; do not add it silently.

7. Run the `lkp-pre-commit` skill (`.agents/skills/lkp-pre-commit/SKILL.md`) to lint and validate.

Output:

```
## Patch
<unified diff or explicit reason>
```

**Pre-send checklist** — verify before calling the send tool. Run the structural lint first and
read its output directly for the mechanical checks (section order, raw mermaid fence, Verdict
table row count, Impact Mechanism table, subject format); the remaining bullets below require your
own semantic judgment and are not covered by the script:
```bash
.agents/skills/lkp-auditperf/scripts/lint-email-body <rca_email_body_file> "<subject>" regression
```

- □ **`## Summary` is exactly 2 template sentences**: (1) prose, no Field/Value table; (2) no kernel mechanism explanation or internal symbol names (`mmap_miss`, function names, constants, etc.) — those belong in `## Impact Mechanism`; (3) `fix_hint_one_phrase` is ≤ 10 words, not a mechanism description; (4) `is_true_root_cause` is reflected ("Root cause confirmed" vs "Root cause not confirmed").
  → If technical mechanism or kernel internals appear in Summary: move them to `## Impact Mechanism` and replace with the 2-sentence template; do NOT send until corrected.
- □ **`## Verdict` is an 8-row table, not a paragraph** (script: `verdict_table=`): rows must be Regression/Improvement, Commit, True root cause, Confidence, Data source, hw_tag, Regression type, Fix hint — no `[TAG]` paragraph. For bisect reports the Data source cell **must have two lines** (`<br>`-separated): `[BISECT-REPORT] {mail_subject}` on line 1 and `{email_archive_server}:{report_path}` on line 2 — the script does not check this two-line requirement, verify it yourself.
  → If it is a paragraph, missing hw_tag/Regression type rows, or Data source has only one line for a bisect report: rebuild `rca_email_body` before sending.
- □ **`## Impact Mechanism` has no metric delta table** (script: `impact_mechanism_table=`): the Measured facts paragraph may reference metrics inline (e.g. *"major faults increased +5895%"*) but must NOT contain a `| Metric | Before | After |` table. That table belongs in `## Evidence` only.
  → If a metric table appears in `## Impact Mechanism`: remove it from that section (keep it in `## Evidence` only); do NOT send until corrected.
- □ **`subject` is `[auditperf] {fbc_hash[:10]}: {commit_subject}`** (script: `subject_format=`) — `fbc_hash[:10]` and `commit_subject` come from Phase 1 session variables (`commit_subject` = first line of the git commit message, not the bisect email subject).
  → If subject contains `skill] RE:` or copies the bisect mail subject: correct it to the `[auditperf] sha: title` form.
- □ **`cc_email` is always `lkp@intel.com`** (fixed — do not derive from git config; not covered by the script).
  → If `mail_cc` is missing from the send call: add it now.
- □ **`## Causal Chain` mermaid block was converted** to `![Causal chain diagram](https://mermaid.ink/img/<base64>)` — no raw ` ```mermaid ``` ` fenced block remains in `rca_email_body` (script: `mermaid_raw_fence=`).
  → If not converted: base64-encode the mermaid source now and replace the fenced block inline.
- □ **Email sections are in the required order** (script: `section_order=`): `## Summary` → `## Verdict` → `## Impact Mechanism` → `## Causal Chain` → `## Evidence` → `## Prediction vs Measurement` → `## Fix Strategy` → `## Community Awareness` → `## Patch`.
  → If any section is out of order: reorder `rca_email_body` before calling the send tool.
- □ **All workspace temp files are under `workspace_tmp/`** — not under `/tmp` on the local host (not covered by the script — about files on disk, not body content).
  → If any file was written to `/tmp` locally: note it; the cleanup command must target that path.

8. **Send the consolidated email** — always, whether a patch was generated or not. Base64-encode
   the patch (or skip attachment if no patch):

   ```bash
   mkdir -p workspace_tmp
   cat > workspace_tmp/fix-{fbc_hash[:12]}.patch << 'PATCHEOF'
   <unified diff content>
   PATCHEOF
   base64 -w 0 workspace_tmp/fix-{fbc_hash[:12]}.patch

   **Static-only / result-search note**: a patch is equally valid in all modes —
   the diff analysis already identifies the mechanism. Note in the patch header whether
   the regression was `[CONFIRMED]` (bisect/result data exists) or `[PREDICTED]` (static analysis).
   ```

   ```
   mcp_shz_email_mcp_send_markdown_email(
     subject="[auditperf] {fbc_hash[:10]}: {commit_subject}",
     report_header="[performance] {perf_change}",
     markdown_body=rca_email_body + "\n\n---\n\n## Patch\n\n```diff\n{unified diff content}\n```,",
     mail_to=user_email,
     mail_cc="lkp@intel.com",
     attachments_json='[{"filename": "fix-{fbc_hash[:12]}.patch", "base64_content": "<base64>"}]',
   )
   ```

   If no patch was generated (step 5 applies): omit the diff block and `attachments_json`; append
   the explicit reason to `rca_email_body` instead.

   Clean up after sending: `rm -f workspace_tmp/fix-{fbc_hash[:12]}.patch`.

   **If `mcp_shz_email_mcp_send_markdown_email` is unavailable**: print the full email body in an
   output code block and tell the user to send it manually (see SKILL.md `## MCP Fallback`).

**⛔ External submission is FORBIDDEN**: the patch IS generated and attached to the internal RCA
email above — that is the correct and expected behaviour. What is forbidden is any attempt to
submit it upstream: never run `git send-email`, never push to any Linux kernel tree, and never
submit to LKML or any upstream mailing list. The patch is an internal proposal only.

Do NOT tell the user next steps here and do NOT stop the turn yet — Phase 4's Post-analysis
domain knowledge update (`phase4-rca.md` §Post-analysis domain knowledge update) still runs after
this phase, in the same turn, and it emits the one consolidated `## Session Summary` +
next-steps message (`validate`/`e2e`/`review` together). Do NOT mention `lkp-submit-patch`,
`./email`, upstream kernel mailing lists, or kernel authors anywhere. Never prompt to forward the
patch externally.
