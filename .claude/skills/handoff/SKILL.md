---
name: handoff
description: Write the current state of in-progress work to handoff.md so another coding agent can pick it up. Use ONLY when the user explicitly asks — "add this to the handoff", "update the handoff", "handoff this". Never write handoff.md proactively or as part of finishing another task.
---

# Handoff notes

`handoff.md` at the repo root is a living snapshot of work in progress, written for
**an agent starting cold in a new session with none of this conversation's context**.
It is gitignored and never committed. The `read-handoff` skill is the counterpart that
consumes it — write for that reader.

## The hard rule

**Only write `handoff.md` when the user explicitly asks for it.** Triggers are phrases
like "add this to the handoff", "update the handoff", "handoff this", "put that in the
handoff". Finishing a task, committing, opening a PR, or a conversation getting long
are **not** triggers. If you think the handoff is stale, offer — do not write.

Everything else in this file describes what to do once that trigger has fired.

## What to capture

Write for a reader who cannot see the conversation. Prefer what is not recoverable
from `git diff` and the code — decisions, dead ends, and reasons.

Include:

1. **Goal** — what the user is trying to achieve, in their terms, not a restatement of
   the diff.
2. **Branch and base** — current branch, what it forked from, whether a PR exists.
3. **What is done** — changed files with a one-line why for each. Not a diff dump; the
   next agent can read the diff.
4. **What is left** — concrete next steps, in order.
5. **Decisions and their reasons** — especially where an obvious-looking alternative was
   rejected. This is the highest-value section: it is what stops the next agent from
   "fixing" a deliberate choice.
6. **Dead ends** — approaches tried that failed, and how they failed. Save the next
   agent the same hour.
7. **Open questions** — anything waiting on the user.
8. **How to verify** — the exact commands, and what to look at afterward.

Leave out: anything already written down in `docs/TECHNICAL_DESIGN.md`, `CLAUDE.md`, or
the commit history. Point at those instead of copying them.

## How to write it

- **Regenerate sections 1-8 in full each time.** The file is a current-state snapshot,
  not an append-only log. Stale "what is left" is worse than no handoff.
- **Keep the Session log append-only.** One dated line per update, newest last.
- Before rewriting, read the existing `handoff.md` if there is one, so nothing the user
  put there by hand is lost.
- Run `git status --short` and `git log --oneline -5` and use the real output — do not
  write the state from memory.
- Be specific: `Sources/Dosa/Views/SharedViews.swift:160` beats "the shared views file".
- Say what is **uncommitted**. That is the part a new agent will otherwise miss.
- Note anything mid-flight: a background job, a running app instance, a build that has
  not been re-run since the last edit.

## Template

```markdown
# Handoff — <short title of the work>

_Updated <YYYY-MM-DD HH:MM>. Local scratch, gitignored. Regenerated on request._

## Goal
<what the user actually wants, in their words>

## Branch
`<branch>` off `<base>`. PR: <url or "none yet">.
Uncommitted: <yes/no — and roughly what>

## Done
- `path/to/file.swift` — <what changed and why>

## Left to do
1. <next concrete step>

## Decisions (do not undo these without asking)
- **<decision>** — <why; what was rejected and what went wrong with it>

## Dead ends
- <approach> — <how it failed>

## Open questions for the user
- <question>

## Verify
```bash
<commands>
```
<what to look at afterward>

## Session log
- YYYY-MM-DD — <one line>
```

## After writing

Tell the user it is updated and give a one-line summary of what changed in it. Do not
paste the file back.
