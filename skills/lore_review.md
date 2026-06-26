# Lore Patchset Review Workflow

A reusable workflow for downloading and reviewing a kernel patchset (and its
discussion threads) from [lore.kernel.org](https://lore.kernel.org).

Follow the steps below in order. Each step describes both the action to take and
the artifact to produce.

> **Local source code is available.** The kernel source tree that the patchset
> applies to is checked out in the **current directory**. While reading the
> patches and their replies, cross-reference the actual code (function bodies,
> surrounding context, call sites, data structures) to verify and enrich your
> understanding of the implementation. Use it whenever a patch hunk or a review
> comment refers to code that is not fully shown in the email.

---

## Step 1 — Ask for the lore address

Prompt the user for the **lore address** of the patchset they want to review.

> **Question to ask:**
> "Please provide the lore address (URL) of the patchset you want to review.
> For example: `https://lore.kernel.org/all/<message-id>/`"

Notes:
- Accept either a link to the cover letter or to any message in the thread.
- A message-id alone (e.g. `20260613-foo@bar`) is also acceptable; it can be
  turned into a URL: `https://lore.kernel.org/all/<message-id>/`.

---

## Step 2 — Download all threads for that patchset

Once the lore address is provided, download the **entire thread** (cover letter,
all patches, and every reply) so the whole conversation is available locally.

### Recommended: `b4`

[`b4`](https://github.com/mricon/b4) is the standard tool for fetching lore
threads as a complete mbox.

```bash
# Fetch the full thread mbox for the given message-id / URL.
# NOTE: -o expects a DIRECTORY, not a file name.
mkdir -p ./lore_threads
b4 mbox <lore-address-or-message-id> -o ./lore_threads/
```

### Fallback: raw mbox download

If `b4` is unavailable, download via curl (`t.mbox.gz` appended to the thread
URL):

```bash
mkdir -p ./lore_threads
curl -sL "https://lore.kernel.org/all/<message-id>/t.mbox.gz" | gunzip > ./lore_threads/full_thread.mbox
```

### Parse the mbox into individual messages

After downloading, split the mbox into separate text files for easy reading:

```python
import mailbox, os

mbox = mailbox.mbox('./lore_threads/full_thread.mbox')  # or the .mbx file from b4
os.makedirs('./lore_threads/messages', exist_ok=True)

for i, msg in enumerate(mbox):
    subj = msg['subject'] or 'no-subject'
    with open(f'./lore_threads/messages/msg_{i:02d}.txt', 'w') as f:
        f.write(f"From: {msg['from']}\n")
        f.write(f"Subject: {subj}\n")
        f.write(f"Date: {msg['date']}\n")
        f.write(f"Message-ID: {msg['message-id']}\n")
        f.write(f"In-Reply-To: {msg.get('in-reply-to', '(none)')}\n")
        f.write('---\n')
        payload = msg.get_payload(decode=True)
        if payload:
            f.write(payload.decode('utf-8', errors='replace'))
        else:
            for part in msg.walk():
                if part.get_content_type() == 'text/plain':
                    p = part.get_payload(decode=True)
                    if p:
                        f.write(p.decode('utf-8', errors='replace'))
```

Store everything under a working directory (e.g. `./lore_threads/`). Make sure
you have captured:
- The cover letter (patch `0/N`, if present).
- Every individual patch (`1/N` … `N/N`).
- Every reply/review message in the thread.

**Identifying patches vs. replies:** Original patches have subjects like
`[PATCH vN M/N] ...` and their `In-Reply-To` points to the cover letter.
Replies have subjects starting with `Re:` and their `In-Reply-To` points to the
specific patch they are responding to.

---

## Step 3 — Read the original patchset and summarize it

Carefully read **all of the original patches** (and the cover letter) and write a
summary of what the patchset is trying to achieve into **`orig_patch.md`**.

While reading, consult the **local kernel source code in the current directory**
to check how the touched functions, structures, and call sites actually work.
This helps you describe the root cause and the fix accurately rather than relying
on the diff alone.

Use simple, plain wording. Tailor the content to the type of patchset:

### 3.1 — If the patchset is a bug fix

Include the following sections:

- **Problem statement** — What goes wrong? Describe the observable symptom in
  simple terms.
- **Root cause** — Why does it happen? Explain the underlying reason simply.
- **The fix** — How does the patch resolve it?
- **Example** — Give a simple concrete example:
  - What the original (buggy) behavior looks like.
  - What the behavior looks like after the fix.

> Template:
> ```markdown
> # Original Patchset Summary
>
> ## Type: Bug Fix
>
> ### Problem statement
> <plain-language description of the symptom>
>
> ### Root cause
> <plain-language explanation of why it happens>
>
> ### How the patch fixes it
> <plain-language description of the fix>
>
> ### Example
> **Before (buggy):**
> <simple example>
>
> **After (fixed):**
> <simple example>
> ```

### 3.2 — If the patchset is a feature enablement

Include a summary of **what the feature is**, in simple words:

- **What the feature does** — The capability being added, explained simply.
- **Why it is useful** — The motivation/benefit.
- **High-level approach** — How it is implemented, at a glance.

> Template:
> ```markdown
> # Original Patchset Summary
>
> ## Type: Feature
>
> ### What the feature is
> <plain-language description of the feature>
>
> ### Why it matters
> <plain-language motivation>
>
> ### How it works (high level)
> <plain-language overview of the approach>
> ```

---

## Step 4 — Summarize the replies per sub-patch

If the thread contains **replies** to the original patchset, read them one by one
and produce a per-patch review summary.

**IMPORTANT:** Read each reply message **in its entirety** — do not stop after the
first screenful. Reviewer emails on kernel patches are often very long (hundreds
of lines) with inline comments interspersed throughout the quoted patch diff.
Every inline comment is a piece of feedback that must be captured. Verify that
you have reached the end of each message (look for the reviewer's sign-off or
end-of-file) before moving on.

When a reviewer comment references code (a function, a check, a corner case, etc.),
look it up in the **local kernel source code in the current directory** to
understand the context and to explain the suggestion with an accurate example.

For each sub-patch `N` that received feedback, create a file named
**`subpatch_N_review.md`** (e.g. `subpatch_1_review.md`, `subpatch_2_review.md`).

Each `subpatch_N_review.md` must contain **separate sections for each reviewer**,
where each section summarizes the full conversation between that reviewer and
the author independently. This prevents mixing up feedback from different
reviewers and keeps each discussion self-contained.

For each reviewer who commented on the sub-patch, include:

1. **Reviewer feedback** — A summary of what this reviewer thinks and suggests.
   Give **simple examples** illustrating each suggestion (e.g. "the reviewer
   suggests using X instead of Y, like `... before ...` → `... after ...`").
2. **Author's response to this reviewer** — How the author reacted to this
   specific reviewer's feedback: agreed / disagreed / will fix in v_next /
   explained the rationale, etc.

> Template for `subpatch_N_review.md`:
> ```markdown
> # Sub-patch N Review: <patch subject line>
>
> ## Discussion with <Reviewer A name>
>
> ### Feedback
> - <what they think / what they suggest>
>   - Example: <simple before/after or concrete illustration>
> - <additional points from this reviewer>
>
> ### Author's response
> - <how the author reacted to this reviewer's feedback>
> - <agreements, disagreements, planned changes>
>
> ---
>
> ## Discussion with <Reviewer B name>
>
> ### Feedback
> - <what they think / what they suggest>
>   - Example: <simple before/after or concrete illustration>
>
> ### Author's response
> - <how the author reacted to this reviewer's feedback>
> - <agreements, disagreements, planned changes>
> ```

Notes:
- Only create `subpatch_N_review.md` for sub-patches that actually received
  replies. Skip patches with no discussion.
- If the cover letter (`0/N`) received review comments, capture them in
  `subpatch_0_review.md`.
- Keep each reviewer's discussion **completely separate** — do not interleave
  or merge feedback from different reviewers. This makes it easy to follow
  each individual conversation thread without confusion.

---

## Output artifacts

After completing the workflow you should have:

| File | Contents |
|------|----------|
| `./lore_threads/` | Raw downloaded thread (mbox + patches) |
| `orig_patch.md` | Plain-language summary of the original patchset |
| `subpatch_N_review.md` | Per-patch reviewer feedback + author responses |
