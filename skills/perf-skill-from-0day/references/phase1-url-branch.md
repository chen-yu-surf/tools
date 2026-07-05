# Phase 1 — URL Branch (Mailing List Report)

Read this file only when the user's input is a mailing list URL (`https://lore.kernel.org/...`,
`https://lkml.org/...`, or similar). For all other input types (path, SHA, Jira key), skip this
file entirely — the SHA/path resolution steps in phase1-validate.md do not need it.

When the user provides a mailing list URL:

**Step U1 — Fetch page content**

Call `fetch_webpage(url, query="performance regression improvement commit hash metrics")`.
If the response contains anti-bot or CAPTCHA text (e.g. "Calculating…", "Anubis", "not a bot"),
stop and tell the user the page could not be fetched; ask them to paste the email body directly,
then re-enter Phase 1 treating the pasted text as the email body.

Set `lore_url = <provided URL>`.

**Step U2 — Extract commit SHA**

OE-LKP bisect reports share a canonical structure. Search the body and subject in this
priority order:
1. `first bad commit: \[([a-f0-9]{12,40})\]` — **most reliable**: LKP bisect conclusion line,
   present in nearly all oe-lkp performance bisect reports
2. `HEAD:\s+([0-9a-f]{12,40})` — explicit HEAD field in body
3. Subject `bisects to: ([0-9a-f]{10,40}):` — from `[lkp] [bisect] ±X% ... bisects to: <sha>:` format
4. Subject pattern `\[[\w/ -]+\]\s+([0-9a-f]{12,40}):` — general bracketed tag + SHA
5. `git commit:\s+([0-9a-f]{12,40})` — git commit field in email body
6. `commit/?id=([0-9a-f]{40})` — git.kernel.org URL embedded in body
7. `From ([0-9a-f]{40}) Mon` — git-format-patch header

Take the **first match** and record as `fbc_hash`. If nothing matches, stop and ask the user
to provide the commit SHA directly.

**Step U3 — Parse external metrics (best-effort)**

> **OE-LKP subject format**: Standard LKP bisect reports use this canonical subject pattern:
> ```
> [lkp] [bisect] ±X.X% improvement/regression of <metric> in <tag> bisects to: <sha10>: <title>
> ```
> Extract `perf_change` percentage and `metric` name from the subject first when present; body
> fields below are supplementary and authoritative when both exist.

Populate `external_metrics` as a **list of dicts** (one entry per reported metric — most reports
have one, some report multiple metrics in parallel). These fields are optional but seed Phase 2/3
signal and should be recorded if present:

| Field | Pattern to look for |
|---|---|
| `perf_change` | From subject: `([+-]?\d+\.?\d*)%` before `improvement`/`regression` of `<metric>`; from body: `perf change:\s+([+-]?\d+\.?\d*%)\s+(\S+)` (percentage then metric on same line) |
| `metric` | From subject: `of\s+(\S+)\s+in`; from body: metric name adjacent to `perf change:` percentage |
| `suite` | Metric key prefix before first `.`, e.g. `vm-scalability` from `vm-scalability.throughput` |
| `stressor` | Metric key suffix after first `.`, e.g. `anon-mmap-sequential-read-1byte` |
| `parent_hash` | `PARENT:\s+([0-9a-f]{12,40})` |
| `change_direction` | `change_direction:\s+(improvement\|regression)` — **explicit body field** in LKP emails; fallback: `improvement` if perf_change > 0, `regression` if < 0 |
| `tbox` | `tbox:\s+(\S+)` — e.g. `lkp-icx-2sp2`; prefix codes: `skl`=Skylake, `bdw`=Broadwell, `icx`=Ice Lake-X, `spr`=Sapphire Rapids, `adl`=Alder Lake; socket suffix: `1sp`=single-socket, `2sp`=2-socket (high NUMA pressure) |
| `nr_task` | `nr_task:\s+(\d+)` — parallelism level (key for lock-contention scaling analysis) |
| `kconfig` | `kconfig:\s+(\S+)` — kernel config variant, e.g. `x86_64-rhel-9.4` |
| `compiler` | `compiler:\s+(\S+)` — compiler version, e.g. `gcc-12` |
| `git_url` | `git url:\s+(https?://\S+)` — source repository URL |
| `git_branch` | `git branch:\s+(\S+)` — source branch (e.g. `master`, `linux-next/main`) |

**Multi-metric**: if the body contains multiple `perf change:` lines, create one dict entry per
line. Use the largest `|perf_change|` value as the primary signal for Phase 2 seeding.

**Step U4 — Check for matching bisect email**

Using `fbc_hash[:10]`, run the same `find` command as the SHA branch (Step 1 in phase1-validate.md)
to check whether an internal bisect report exists for this commit:

- **Found** → set `report_path`, `mail_subject`; proceed to `mcp_shz_lkp_mcp_extract_bisect_report`
  (standard bisect-driven flow from Step 2 onward in phase1-validate.md). External metrics from
  U3 are supplementary.
- **Not found** → set `perf_change = external_metrics.perf_change` (or `"N/A"` if absent),
  `boundary_valid = false`, `tmp_dir = null`. Construct:
  `mail_subject = "lkp-auditperf: {fbc_hash[:12]} {commit_subject_from_U2_or_TBD}"`.
  Proceed to Step 5 (analysis path selection) in phase1-validate.md — mode will be
  `result-search` or `static-only`.

Return to phase1-validate.md Step 2 onward after completing this branch.
