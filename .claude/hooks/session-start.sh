#!/usr/bin/env bash
# SessionStart hook. Prints a one-line project pulse so the agent (and user)
# know where they are without having to re-discover state.

set -euo pipefail

# Derived from this script's own location, so the banner works in any
# clone rather than only the maintainer's (GH #204).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$REPO_ROOT" 2>/dev/null || exit 0

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
short="$(git rev-parse --short HEAD 2>/dev/null || echo '?')"

# Commits ahead of origin/main and main.
ahead_origin="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo '?')"
ahead_main="$(git rev-list --count main..HEAD 2>/dev/null || echo '?')"

# Working tree state.
if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
  tree='clean'
else
  tree='dirty'
fi

# Last recorded `make test` verdict, if any. Written by test/run-headless.sh.
last_test=''
if [ -f "$REPO_ROOT/build/last-test.txt" ]; then
  last_test=" • last test: $(head -1 "$REPO_ROOT/build/last-test.txt")"
fi

# Print to stdout (the SessionStart hook output is shown in the conversation).
printf '[dezogif_ng] branch=%s @ %s • +%s vs main / +%s vs origin/main • tree=%s%s\n' \
  "$branch" "$short" "$ahead_main" "$ahead_origin" "$tree" "$last_test"
