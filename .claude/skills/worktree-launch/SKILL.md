---
name: worktree-launch
description: Create a fresh agent worktree under ~/tmp/worktrees/dezogif_ng/ (OUTSIDE the repo) off an up-to-date main, with the project's hygiene rules baked in. Use when the user says "spin up a worktree", "create a worktree for agent X", "set up a worktree for branch Y", or when about to dispatch an agent that needs an isolated work area.
---

# Launch an agent worktree

Create a worktree for an agent to work in, with the project's hygiene rules baked in.

## Inputs

Ask the user (if not specified):

- **Agent ID** (e.g. `a562cf38`, or a short descriptive slug like `esp-transport`).
- **Branch name** (e.g. `feat/esp-cipserver`).

## Steps

### 1. Verify main is up to date with origin/main

Per `feedback_agent_worktree_stale_base`:

```bash
git fetch origin main
ahead=$(git rev-list --count origin/main..main)
behind=$(git rev-list --count main..origin/main)
echo "main: +$ahead ahead, -$behind behind origin/main"
```

If `behind` > 0, ask the user whether to fast-forward main first. Do NOT auto-pull — `feedback_keep_main_clean` is about not surprising the user.

### 2. Create the worktree

```bash
git worktree add ~/tmp/worktrees/dezogif_ng/agent-<ID> -b <BRANCH> main
```

### 3. Smoke-test the fresh worktree

```bash
make -C ~/tmp/worktrees/dezogif_ng/agent-<ID> all
```

Nothing needs provisioning: every artefact is built into the gitignored `build/`,
and the bench takes its reference SD image from `~/.jnext/sdcard/` at run time,
not from the checkout. If `make all` does not come up clean on a fresh worktree,
stop — the base is wrong, not the agent's work.

### 4. Print the agent briefing footer

This goes into the agent's prompt:

```
WORKING DIRECTORY: ~/tmp/worktrees/dezogif_ng/agent-<ID>
BRANCH: <BRANCH>
BASE: main @ <SHA>

Hard rules per CLAUDE.md:
- Work ONLY in this worktree. Do NOT touch /home/jorgegv/src/spectrum/dezogif_ng directly.
- Do NOT write to main. Commit only on branch <BRANCH>.
- Do NOT push. The user authorizes pushes separately.
- Use `git -C <worktree-path> <cmd>` for git ops (not `cd ... && git ...`).
- When done, report:
  - List of commit SHAs on <BRANCH>
  - `make test` output on <BRANCH> (T1-T4), verbatim. All four pass at HEAD;
    a failure is never to be fixed by weakening the assertion
  - Anything that needs reviewer attention
- Do NOT mark work complete without an independent reviewer agent approving.
```

## Hard rules per CLAUDE.md

- Each independent function = its own branch.
- Agents do not write to main.
- Code review by a different agent than the author.
- No pushes without explicit user authorization.

## Cleanup

After the agent's branch is merged to main:

```bash
git worktree remove ~/tmp/worktrees/dezogif_ng/agent-<ID>
git branch -d <BRANCH>   # only if user authorizes
```

Per `feedback_rehome_to_owner_plan`, prefer re-homing over deleting if the original work might still be needed.
