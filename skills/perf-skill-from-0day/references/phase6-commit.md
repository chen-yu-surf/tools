# Phase 6 — Compile-Verify and Internal Commit *(user-triggered via `validate`)*

> Trigger word is `validate`, not `commit` — this phase compile-verifies the patch first and
> only then commits it to an internal LKP branch; it never touches an upstream kernel tree.
> Renamed from the earlier `commit` trigger because that word alone implied an upstream action.

Only after explicit user approval of the patch.

> ⚠️ **No force-pushes** (SKILL.md Rule) — after committing, present the commit hash and stop. The user pushes.
>
> ⛔ **External submission is FORBIDDEN** — never run `git send-email`, never push to any Linux
> kernel tree, and never submit to LKML or any upstream mailing list. This phase commits the
> patch to an **internal LKP branch only**.

## Step 1 — Compile-verify the patch

The Linux kernel mirror is at `/var/repo/linux` on `<lkp_server>` (read-only). Clone it into a
temporary workspace, apply the patch, build, then clean up:

```bash
# On <lkp_server> via SSH:
git clone --shared /var/repo/linux workspace_tmp/linux-verify
cd workspace_tmp/linux-verify
git apply /path/to/patch.patch        # verify it applies cleanly
cp /boot/config-$(uname -r) .config   # use an existing config
make olddefconfig                     # absorb new symbols with defaults
make -j$(nproc) 2>&1 | tail -30       # build; watch for errors/warnings
cd ../..
rm -rf workspace_tmp/linux-verify     # always clean up
```

If the build fails: fix the patch first before proceeding to the commit step.

## Step 2 — Commit to an internal LKP branch

Stage and commit via the `lkp-git-commit` skill (`.agents/skills/lkp-git-commit/SKILL.md`) —
individual `git add`, heredoc commit message with `Signed-off-by`.

