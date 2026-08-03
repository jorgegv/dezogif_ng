# Workflow rules

Project-wide workflow constraints. These apply to every session, regardless of
subsystem or task. Sourced from CLAUDE.md and from the user's standing
feedback.

## Branch & merge

- **No writes to `main` by any agent.** Workers commit on their own branch in
  their own worktree (`~/tmp/worktrees/dezogif_ng/<name>`, outside the repo).
  The manager merges to main, and only after independent review approves.
- **One branch per independent unit of work.** When parallel agents are
  dispatched, each gets its own branch + worktree. This prevents code-trashing.
- **Merge conflicts are the second-to-merge agent's responsibility.** They fix
  the conflict on their own branch, not on main.

## Commits

- **One concept per commit.** Don't bundle a fix and a refactor. Whitespace
  never rides along with behaviour — that is what the one-off normalisation
  commit was for.
- **Terse but insightful commit messages.** State what changed and the WHY.
- **NEVER `--amend`.** Always a new commit; the block-amend hook enforces it.
- **NEVER `--no-verify`.**
- **NEVER include `Co-Authored-By` lines.** Project mandate (CLAUDE.md).
- **Verify before commit.** `make test` before committing anything that touches
  the ROM, the NMI path or the build.

## Pushes

- **NEVER push to origin without explicit user authorization.** This applies to
  every agent, including the manager. The block-push hook enforces this.
  Override: `DEZOGIF_ALLOW_PUSH=1 git push ...`, only after the user says
  "push".
- **Local main can be ahead of origin/main for a long time.** That is normal
  and does not mean "we need to push".
- **Same rule applies to `gh pr create`** and any equivalent.

## Code review

- **Code review is NEVER by the same agent that wrote the code.** Use the
  `code-reviewer` agent, or dispatch a separate independent agent.
- **Verdict is binary: APPROVE or REJECT.** "Approve with nits" is not a
  verdict (CLAUDE.md).
- **Reviewers are critical by default.** "Looks fine" is not a review.
- **Reviewers don't defer findings.** If a bug is found, surface it now — no
  "follow-up" notes.
- **Reviewers run `make test`** for anything that could change what the stub
  does on screen, and read the failing screenshot rather than trusting the
  verdict line.
- **Reviewer also checks test-removal or test-weakening.** Removing a test, or
  loosening an assertion so a red test goes green, needs independent
  justification. The T4 assertion was once loose enough to pass on 24 pixels;
  that must not happen again.

## Parallel agents

- **Use the Agent Team pattern** when tasks are independent. Manager dispatches
  workers (one per task), each in its own branch/worktree.
- **Manager does NOT write code.** Manager plans, dispatches, merges.
- **Spawn parallel agents in one message** — a single tool-call message with
  multiple `Agent` invocations is what triggers parallelism.

## Code style

- **Match the surrounding code.** This is a fork; most of the tree is upstream's
  and future `git blame` against maziac/dezogif is worth preserving.
- **Leading indentation is 4 spaces, no tabs** (normalised 2026-08-03). Inner
  alignment was deliberately left alone.
- **Keep the routine banners.** Every routine carries `Parameters:` /
  `Returns:` / `Changes:` listing clobbered registers. New routines do too —
  in Z80 that block is the calling contract.
- **No trivial backlog.** Don't write "TODO: maybe rename this later".
- **Approximation comments are drift flags.** A comment saying "roughly what
  the VHDL does" means the stub does not match the hardware; flag it, don't
  normalise it.
- **No stray files.** Working files go under the session scratchpad; build
  output goes to `build/`. Nothing new at the repo root without a reason.

## Testing posture

See CLAUDE.md §Testing. Highlights:

- **The VHDL is the single oracle** for hardware behaviour.
- `make test` is the gate: four headless jnext runs, judged on screenshots.
- **T3 is a control.** If it fails, the bench is broken and T4's verdict is
  worthless — fix the bench before reading anything into T4.
- **T4 asserts a DECLINE, not a takeover.** Upstream's `nmi66h` serves button
  NMIs only, so the software fixture is correctly ignored. M2 must invert that
  assertion when it teaches `nmi66h` to accept the Copper/software cause —
  until then, a takeover at T4 is a regression, not progress.
- The `src/unit_tests/` suite needs VS Code + DeZog and therefore gates
  nothing. Treat it as a manual layer, and say so rather than implying
  coverage it does not give.
- Real hardware is the only truth for ESP timing and WiFi behaviour.

## Git command hygiene

- **Use `git -C <path>` instead of `cd <path> && git ...`.** The warn-cd-git
  hook warns when you don't.
- Read-only tools (`awk`, `sed -n`, `xxd`, `grep`) are pre-allowed in
  settings.json. Don't surprise the user with `chmod`, `rm -rf`, etc.

## Claims need proof

- **"I fixed it" requires output.** `make test` transcript, a screenshot, or a
  byte comparison — not an assertion.
- **Verify behaviour, not just compilation.** A clean assembly is not a fix;
  "a stub that assembles is not a stub that runs" (CLAUDE.md).
- **Verify the gating dependency.** If a change alters a code path, prove the
  test that passes actually exercises the new path.
