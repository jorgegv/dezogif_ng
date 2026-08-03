# Worktrees

Worktrees live **outside the repository**, at `~/tmp/worktrees/dezogif_ng/<name>/`.
Never inside the repo — not even gitignored. Each agent gets its own worktree
off `main`; the manager creates them, agents work in them, the manager merges
and cleans up.

## Layout

The project was renamed `dezogif_esp` → `dezogif_ng` on 2026-08-03, but the **checkout on disk
still sits at the old path**. That mismatch is deliberate, not a leftover: paths below that say
`dezogif_esp` are real locations, paths that say `dezogif_ng` are the project's name.

```
/home/jorgegv/src/spectrum/dezogif_esp/     ← main checkout (old dir name), always on main
/home/jorgegv/tmp/worktrees/dezogif_ng/
├── agent-a562cf38/                         ← worktree, own branch, shared .git
├── agent-ad6b7cf6/
└── ...
```

Each worktree is a full working copy on its own branch, sharing the `.git`
object database with the main checkout. Cheap to create, cheap to delete.

## Creating

Use `/worktree-launch <agent-id> <branch-name>`. It creates the worktree off
an up-to-date `main` and prints a briefing footer for the agent prompt.

Nothing needs rsyncing into a fresh worktree: every build artefact this project
has is produced by `make` into `build/`, which is gitignored. The one thing
that is *not* rebuilt is the reference SD card image, and the bench copies that
from `~/.jnext/sdcard/` at run time rather than from the checkout.

## The five rules

1. **Stay in the worktree.** Agents work ONLY in their assigned worktree path.
   Never `cd` to the main checkout, never modify
   `/home/jorgegv/src/spectrum/dezogif_esp/` directly.

2. **Use `git -C` for git ops.** Never `cd <worktree> && git <cmd>`. The
   warn-cd-git hook warns.

3. **No writes to main from the worktree.** Workers commit on their branch.
   The manager handles merges. The block-main-write hook enforces this by
   looking at the target checkout's *branch*, so a worktree that somehow sits
   on main is blocked too.

4. **No pushes.** Worktree branches stay local. The user authorises any push.

5. **`make test` before you claim anything.** A worktree build is a fresh
   `build/`; the bench needs `make test`, not `make all`.

## Stale-base trap

If `main` is behind `origin/main`, a worktree created off `main` starts at the
stale SHA. `/worktree-launch` checks and asks first. If it happened anyway, the
second-to-merge agent rebases **on its own branch**:

```bash
git -C ~/tmp/worktrees/dezogif_ng/<name> fetch origin
git -C ~/tmp/worktrees/dezogif_ng/<name> rebase origin/main
```

## Cleanup

After a worker's branch is merged:

```bash
git worktree remove ~/tmp/worktrees/dezogif_ng/<name>
git branch -d <branch-name>   # only if the user authorises branch deletion
```

Branches still owned by another agent are re-homed
(`git -C <worktree> branch -m <new-name>`) rather than deleted, so work is not
lost.

## What goes in the worktree, what doesn't

- ✅ Source edits, test edits, new commits — all on the worktree branch.
- ✅ `build/` artefacts — gitignored, regenerated per worktree.
- ❌ Logs, probe output, screenshots kept for inspection — under the session
  scratchpad, not the worktree.
