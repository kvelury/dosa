---
name: read-handoff
description: Read handoff.md and pick up in-progress work left by a previous session or agent. Use when the user says "read the handoff", "pick up the work", "continue where we left off", "catch me up", or starts a session expecting context they have not given you. Verify the handoff against the real repo state before trusting it.
---

# Reading a handoff

`handoff.md` at the repo root is a snapshot written by a previous session for an agent
starting cold. It is gitignored. `.claude/skills/handoff/SKILL.md` is the counterpart that
writes it.

## The snapshot is a claim, not a fact

It was true when written. The repo may have moved since — the user may have committed,
switched branches, edited by hand, or worked in another session. **Verify before you act
on it.** Acting on a stale "Left to do" is the main way this goes wrong.

## Steps

1. **Read `handoff.md`.** If it is missing, empty, or still the placeholder, say so and ask
   the user what they want to work on — do not guess from `git log`.

2. **Check it against reality**, and use the real output, not the file's claims:

   ```bash
   git status --short
   git branch --show-current
   git log --oneline -5
   git diff --stat
   ```

   Compare against the handoff's Branch / Done / Left to do sections:

   - **Different branch than the handoff names** → stop and ask. Do not switch branches on
     your own.
   - **Clean tree where the handoff says "uncommitted"** → the work was committed or
     discarded. Check `git log` for it before assuming either.
   - **Commits on top of what the handoff describes** → read them; the handoff predates
     them and its "Left to do" may already be done.
   - **Files changed that the handoff does not mention** → someone worked outside it. Read
     those diffs.
   - **A timestamp much older than the newest commit** → treat the whole file as a lead,
     not an instruction.

3. **Read what it points at.** The handoff deliberately does not duplicate
   `docs/TECHNICAL_DESIGN.md`, `CLAUDE.md`, or the diff — it points at them. Follow the
   pointers for the parts you are about to touch. Verify that any file, function, or flag
   it names still exists before relying on it.

4. **Read Decisions and Dead ends before writing any code.** These are the sections that
   are not recoverable from the diff. A "Decision" marked *do not undo without asking* is
   a constraint on you; if the obvious approach contradicts one, raise it with the user
   rather than quietly doing it the obvious way. A "Dead end" is an hour someone already
   spent — do not re-spend it.

5. **Report before you act.** Give the user a short summary: what the previous session was
   doing, where it actually stands after your verification, anything that has drifted, and
   the proposed next step. Then wait, unless they already told you to continue.

## Do not

- **Do not write to `handoff.md`.** Updating it is gated behind an explicit user request —
  see the `handoff` skill. Reading it is not a reason to refresh it.
- Do not treat "Open questions for the user" as questions to answer yourself; surface them.
- Do not re-verify the whole feature from scratch if the handoff says it was confirmed —
  check what it lists as *unconfirmed* instead.
- Do not commit, push, or open a PR just because the handoff lists it under "Left to do".
  Those need the user's go-ahead in the current session.
