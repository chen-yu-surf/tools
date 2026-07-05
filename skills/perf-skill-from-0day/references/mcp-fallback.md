# MCP Fallback *(cluster accessible via SSH)*

**Read this file only when an MCP tool call actually fails or is reported unavailable.**
Do not preload this on a normal run — every phase reference file already states the direct
SSH drop-in inline for the one or two tools it depends on most; this file is the complete
catalog for less-common failures.

When any MCP server is unavailable, resolve `<lkp_server>` from `llm/config.yml` (same as
Phase 1 Step 1) and substitute the SSH equivalent below. Announce to the user which server
is being used before issuing SSH commands.

**Cluster file access** — direct drop-ins:

| Unavailable tool | SSH equivalent |
|---|---|
| `mcp_shz_lkp_mcp_list_external_directory(path)` | `ssh <lkp_server> "ls -1 <path>"` |
| `mcp_shz_lkp_mcp_read_external_file(path)` | `ssh <lkp_server> "cat <path>"` |
| `mcp_shz_lkp_mcp_search_external_file(path, pat)` | `ssh <lkp_server> "grep -rn '<pat>' <path>"` |
| `mcp_shz_lkp_mcp_read_extracted_data(tmp, file)` | `ssh <lkp_server> "cat <tmp>/<file>"` |
| `mcp_shz_lkp_mcp_grep_extracted_data(tmp, file, pat)` | `ssh <lkp_server> "grep '<pat>' <tmp>/<file>"` |
| `mcp_shz_lkp_mcp_extract_bisect_report(path)` | `ssh <lkp_server> "cat <path>"` → save locally → run `python3 llm/lib/bisect_report.py` (see Phase 1 Step 2 fallback for exact logic) |
| `mcp_shz_lkp_mcp_search_lkp_test_roots(commit, suite)` | `ssh <lkp_server> "find /result/<suite or '*'> -maxdepth 8 -type d -name '<commit[:12]>*' 2>/dev/null \| head -20"` |
| `mcp_shz_lkp_mcp_compare_lkp_results([a, b])` | `ssh <lkp_server> "lkp compare <a> <b>"` |

**Git tools** — cluster mirrors at `/var/repo/`:

| Unavailable tool | SSH equivalent |
|---|---|
| `mcp_shz_git_mcp_get_linux_commit(sha)` | `ssh <lkp_server> "git -C /var/repo/linux show <sha>"` |
| `mcp_shz_git_mcp_grep_repo(pat, repo='linux')` | commit search: `ssh <lkp_server> "git -C /var/repo/linux log --all --oneline --grep='<pat>'"` · source grep: `ssh <lkp_server> "git -C /var/repo/linux grep -n '<pat>'"` |
| `mcp_shz_git_mcp_read_repo_file(repo, path, sha)` | `ssh <lkp_server> "git -C /var/repo/<repo> show <sha>:<path>"` |
| `mcp_shz_git_mcp_ensure_repo(url)` | locate existing mirror: `ssh <lkp_server> "find /var/repo -maxdepth 2 -name '*.git' \| grep <suite>"` |

**LSP tools — degraded mode** (grep only; evidence tier drops). Tool names below use `<site>` for
the resolved `site` session variable (`shz`/`igk`) — never hardcode `shz`:

| Unavailable tool | SSH equivalent | Evidence impact |
|---|---|---|
| `mcp_<site>_lsp_mcp_init_lsp_workspace` + `mcp_<site>_lsp_mcp_get_lsp_references` + `mcp_<site>_lsp_mcp_get_lsp_definition` | `ssh <lkp_server> "git -C /var/repo/linux grep -rn '<symbol>'"` for callers; `grep -n '^[a-zA-Z].*<symbol>'` for definition | **Callgraph-backed causation cannot be asserted** — downgrade all claims to path-level correlation; add `[LSP unavailable — grep fallback]` to `## Evidence` |
| `mcp_<site>_lsp_mcp_cleanup_lsp_workspace` | No-op — skip | — |

**Email and external tools** — manual fallback:

| Unavailable tool | Fallback |
|---|---|
| `mcp_shz_email_mcp_send_markdown_email(...)` | Print full email body in output block; user sends manually; or `ssh <lkp_server> "mail -s '<subject>' <to> << 'EOF'\n<body>\nEOF"` |
| `mcp_shz_zdci_mcp_get_issue(key)` | Ask user to paste the issue description directly into the chat |
| `fetch_webpage(url)` | Ask user to paste the email body (already handled in Phase 1 URL branch) |
