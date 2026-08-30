#!/usr/bin/env bash
#
# download_lore.sh - Download a lore.kernel.org patch series together with its
#                    full discussion thread into a single Markdown file.
#
# Usage:
#   ./download_lore.sh <lore-url>
#
# Examples:
#   ./download_lore.sh https://lore.kernel.org/all/cover.1784968626.git.yu.c.chen@intel.com
#   ./download_lore.sh https://lore.kernel.org/all/20260605105513.354837583@infradead.org
#
# It uses `b4 mbox` to grab the entire thread (cover letter, every patch, and
# all replies) as an mbox, then renders each message - in chronological order -
# into a dedicated <slug>.md in the current directory.
#
# Requirements: b4, python3

set -euo pipefail

if [ "$#" -ne 1 ]; then
	echo "Usage: $0 <lore-url>" >&2
	exit 1
fi

URL="$1"

for tool in b4 python3; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "error: required tool '$tool' not found in PATH" >&2
		exit 1
	fi
done

# Work in a scratch dir so b4's intermediate files don't pollute cwd.
TMPDIR_LORE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LORE"' EXIT

echo ">> Fetching thread from: $URL"
# -o <dir> : output dir, -n <name> : fixed mbox name so we know the path.
b4 mbox -o "$TMPDIR_LORE" -n thread "$URL"

MBOX="$(ls "$TMPDIR_LORE"/thread* 2>/dev/null | head -n1 || true)"
if [ -z "$MBOX" ] || [ ! -s "$MBOX" ]; then
	echo "error: b4 did not produce a thread mbox" >&2
	exit 1
fi

echo ">> Rendering thread to Markdown..."
OUTFILE="$(MBOX="$MBOX" URL="$URL" python3 - <<'PY'
import email.utils
import mailbox
import os
import re
import sys

mbox_path = os.environ["MBOX"]
url = os.environ["URL"]
mbox = mailbox.mbox(mbox_path)


def get_body(msg):
    """Return the decoded text/plain body of a message."""
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == "text/plain":
                payload = part.get_payload(decode=True)
                if payload:
                    charset = part.get_content_charset() or "utf-8"
                    return payload.decode(charset, errors="replace")
        return ""
    payload = msg.get_payload(decode=True)
    if payload:
        charset = msg.get_content_charset() or "utf-8"
        return payload.decode(charset, errors="replace")
    return msg.get_payload()


def clean_subject(raw):
    return " ".join((raw or "").replace("\n", " ").replace("\t", " ").split())


# Sort messages chronologically.
msgs = []
for msg in mbox:
    try:
        sortkey = email.utils.parsedate_to_datetime(msg.get("Date", "")).timestamp()
    except Exception:
        sortkey = 0
    msgs.append((sortkey, msg))
msgs.sort(key=lambda x: x[0])

if not msgs:
    sys.stderr.write("error: thread mbox is empty\n")
    sys.exit(1)

# Derive a title/slug from the first (root) message's subject, stripping any
# leading "Re:" / "[PATCH ...]" noise for the human-readable title.
root_subject = clean_subject(msgs[0][1].get("Subject", "no-subject"))
title = re.sub(r"^(Re:\s*)+", "", root_subject, flags=re.I)
slug_src = re.sub(r"^\s*(Re:\s*)+", "", root_subject, flags=re.I)
slug_src = re.sub(r"\[[^\]]*\]", "", slug_src)  # drop [PATCH v2 3/9] etc.
slug = re.sub(r"[^a-zA-Z0-9]+", "-", slug_src).strip("-").lower()
slug = slug[:60] or "lore-thread"

out = []
out.append(f"# {title}\n")
out.append(f"Thread from lore.kernel.org ({len(msgs)} messages)\n")
out.append(f"Source: {url}\n")
out.append("\n---\n")

for i, (_, msg) in enumerate(msgs, 1):
    subj = clean_subject(msg.get("Subject", ""))
    out.append(f"\n## Message {i}: {subj}\n")
    out.append(f"- **From:** {clean_subject(msg.get('From', ''))}")
    out.append(f"- **Date:** {msg.get('Date', '')}")
    out.append(f"- **Message-ID:** {msg.get('Message-ID', '') or msg.get('Message-Id', '')}")
    inreply = msg.get("In-Reply-To", "")
    if inreply:
        out.append(f"- **In-Reply-To:** {inreply}")
    out.append("")
    out.append("```")
    out.append(get_body(msg).rstrip("\n"))
    out.append("```")
    out.append("\n---")

outfile = f"{slug}.md"
with open(outfile, "w") as f:
    f.write("\n".join(out) + "\n")

# Emit the filename on stdout so the shell wrapper can report it.
print(outfile)
PY
)"

echo ">> Saved: $(pwd)/$OUTFILE"
