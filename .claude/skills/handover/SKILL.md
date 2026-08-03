---
name: handover
description: Produce an end-of-session dezogif_ng handover memo (branch, HEAD, commits-ahead, build/test state, next-session priorities) and save it as an auto-memory entry. Use when the user says "prepare for handover", "prepare for session handover", "EOD", or similar.
---

# Session handover

Produce the end-of-session memo and save it to memory. Keep the format rigid so a fresh session can resume without re-discovery.

## Inputs to gather (auto, don't ask)

Run in parallel:

- `git rev-parse --abbrev-ref HEAD` → current branch
- `git rev-parse --short HEAD` → commit ID
- `git rev-list --count main..HEAD` → commits ahead of main
- `git rev-list --count origin/main..HEAD` → commits ahead of origin/main
- `git log --oneline main..HEAD` → session commits
- `git status --short` → working-tree state

## Build / test state

State honestly which of these was actually run this session, and when:

- `make all` — builds `build/enNextMf.rom`, `build/main.bin`, `build/ut.nex`
- Unit tests — `build/ut.nex` run in jnext
- jnext bench run — the stub loaded as `enNextMf.rom` on an SD image
- Real hardware — the only source of truth for transport behaviour

If none were run since the last commit, say "not verified this session". Never imply a build or a hardware check that did not happen.

## Memo content

Save to `/home/jorgegv/.claude/projects/-home-jorgegv-src-spectrum-dezogif-esp/memory/project_session_handover_<YYYY-MM-DD><suffix>.md`. Suffix is `_eod`, `b_eod`, `c_eod`… by count for the day. Frontmatter:

```yaml
---
name: dezogif_ng session handover <YYYY-MM-DD><suffix>
description: <one line — branch, what was done, what's next>
metadata:
  type: project
---
```

Body, in this order, terse:

1. **State** — branch, HEAD, +N vs main, +N vs origin/main, tree clean/dirty, push status (NOT pushed unless the user authorized it).
2. **What this session did** — one line per significant change, with commit SHAs.
3. **Build / test state** — per the section above, with what was and was not verified.
4. **Discoveries** — anything non-obvious learned, especially about ESP/AT behaviour, DZRP, or real-hardware quirks. These are expensive to rediscover.
5. **Next-session priority** — concrete, actionable without re-discovery. Reference the milestone in `doc/ZXNEXT-REMOTE-DEBUG-STUB.md` §9.
6. **Outstanding** — escalated to user, deferred, or blocked.

## Update MEMORY.md

Add a one-line index entry at the top of that memory directory's `MEMORY.md`:

```
- **[<file>](<file>) ← READ FIRST. <YYYY-MM-DD> — <one-line state>.** <build state>. <next priority>.
```

Downgrade the previous "READ FIRST" entry to "(legacy)".

## Hard rules

- **NEVER include Co-Authored-by lines.**
- **Terse but insightful.** Not a development diary.
- **Don't claim something works if it was not run.** A stub that assembles is not a stub that runs.
- **Don't push.** A handover is local. Note "NOT pushed (N ahead of origin)" if commits exist.
- **Convert relative dates to absolute.**
