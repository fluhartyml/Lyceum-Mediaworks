#!/bin/sh
# stamp-build.sh — set this app's BUILD NUMBER to the repository's commit count.
#
# ─── THE STANDARD ───────────────────────────────────────────────────────────────
# Michael, 2026-09-04: "lets make that number the build number of the app from now on
# so it is uniform viewable in the app in xcode and app store connect. legally without
# it being a debugging artifact that flags rejection."
#
#     CURRENT_PROJECT_VERSION = git rev-list --count HEAD
#
# WHY THE COMMIT COUNT AND NOT THE SHA. CFBundleVersion must be period-separated
# non-negative integers, and App Store Connect requires every upload to be numerically
# HIGHER than the last in its version train. A SHA is a hash — 0x68c0c9d is 109841565,
# but the next commit could hash lower and Apple would refuse the upload. The commit
# count increments by one per commit, never goes down on a branch, is an integer, and
# names a commit. Michael got this right when I had steered away from it: "githubs
# number has to increase and not go down becaue it has to be a counter number."
#
# It is ordinary version metadata. No review risk.
#
# ─── WHY NOT AN XCODE BUILD PHASE ───────────────────────────────────────────────
# Projects created by recent Xcode set ENABLE_USER_SCRIPT_SANDBOXING = YES, and a
# sandboxed Run Script phase cannot read .git or write into the built product. Turning
# that off to gain a version label trades a real security boundary for a convenience.
# So the stamp is written before the build instead of during it, by a post-commit hook.
#
# ─── PROJECT-AGNOSTIC ───────────────────────────────────────────────────────────
# Finds the .xcodeproj itself, so one copy works in every repo including future ones.
# If the project has a BuildStamp.swift it fills that in too; if not, the build number
# alone still works and the in-app display is the only thing missing.
#
# Absolute path to git: a hook does not inherit an interactive shell's PATH.
set -e
GIT=/usr/bin/git
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

PBX=$(find "$ROOT" -maxdepth 2 -name project.pbxproj -not -path "*/Pods/*" | head -1)
if [ -z "$PBX" ]; then
    echo "stamp-build: no .xcodeproj found under $ROOT — nothing to stamp" >&2
    exit 0
fi

BUILD_NUMBER=$($GIT rev-list --count HEAD 2>/dev/null || echo 1)
COMMIT=$($GIT rev-parse --short HEAD 2>/dev/null || echo "nogit")
BRANCH=$($GIT rev-parse --abbrev-ref HEAD 2>/dev/null || echo "nogit")
BUILT=$(date "+%Y-%m-%d %H:%M")

STAMP=$(find "$ROOT" -maxdepth 3 -name BuildStamp.swift | head -1)

# A dirty tree means the binary is that commit PLUS something unrecorded. Say so — a
# stamp claiming a clean commit it isn't is worse than no stamp. The files this script
# rewrites must not count as dirt.
DIRT=$($GIT status --porcelain 2>/dev/null \
        | grep -v "project.pbxproj" \
        | grep -v "BuildStamp.swift" || true)
if [ -n "$DIRT" ]; then
    COMMIT="${COMMIT}+"
fi

/usr/bin/sed -i '' \
    -e "s|CURRENT_PROJECT_VERSION = .*;|CURRENT_PROJECT_VERSION = $BUILD_NUMBER;|" \
    "$PBX"

if [ -n "$STAMP" ]; then
    /usr/bin/sed -i '' \
        -e "s|static let commit = \".*\"|static let commit = \"$COMMIT\"|" \
        -e "s|static let branch = \".*\"|static let branch = \"$BRANCH\"|" \
        -e "s|static let built = \".*\"|static let built = \"$BUILT\"|" \
        "$STAMP"
    echo "build number: $BUILD_NUMBER   commit: $COMMIT ($BRANCH)"
else
    echo "build number: $BUILD_NUMBER   commit: $COMMIT ($BRANCH)   [no BuildStamp.swift — in-app display not wired]"
fi
