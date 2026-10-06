#!/bin/sh
# Installs this repo's git hooks. Run ONCE per clone, per machine.
#
# Git deliberately does not copy hooks when a repository is cloned, so a hook that lives
# only in .git/hooks is one machine away from not existing at all. Keeping the real copy
# in Scripts/ and installing from there means the behaviour travels with the repository.
#
# THREE HOOKS, BECAUSE HEAD MOVES THREE WAYS:
#   post-commit    you committed
#   post-checkout  you checked out a branch or a TAG   <- the rollback case
#   post-merge     you pulled or merged
# Any one of them missing reopens the same gap: a working tree whose stamped build
# number does not match the commit it is actually sitting on.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
chmod +x "$ROOT/Scripts/stamp-build.sh"

for h in post-commit post-checkout post-merge; do
    [ -f "$ROOT/Scripts/$h" ] || { echo "MISSING: Scripts/$h" >&2; exit 1; }
    cp "$ROOT/Scripts/$h" "$ROOT/.git/hooks/$h"
    chmod +x "$ROOT/.git/hooks/$h"
done

# ⚠️ PROVE THEY RUN. Installing a hook and never firing it is how the first version of
# this went unnoticed through twelve commits. Do not report success on a copy alone.
"$ROOT/.git/hooks/post-commit" || { echo "post-commit INSTALLED BUT FAILED TO RUN" >&2; exit 1; }
"$ROOT/.git/hooks/post-merge"  || { echo "post-merge INSTALLED BUT FAILED TO RUN"  >&2; exit 1; }

# post-checkout takes three arguments and must act on ONLY the third being 1. Test it
# in BOTH directions — a guard that can only ever say yes is not a guard.
#   -> Skills Lab: test-that-your-alarm-can-say-no
BEFORE=$(/usr/bin/git -C "$ROOT" status --porcelain 2>/dev/null | wc -l)
"$ROOT/.git/hooks/post-checkout" x y 0 || { echo "post-checkout FAILED on the file-checkout case" >&2; exit 1; }
AFTER=$(/usr/bin/git -C "$ROOT" status --porcelain 2>/dev/null | wc -l)
[ "$BEFORE" = "$AFTER" ] || { echo "post-checkout WROTE on a file checkout — the \$3 guard is not working" >&2; exit 1; }
"$ROOT/.git/hooks/post-checkout" x y 1 || { echo "post-checkout FAILED on the branch-checkout case" >&2; exit 1; }

echo "installed and verified: post-commit, post-checkout (both directions), post-merge"
