#!/usr/bin/env bash
#
# One-shot setup: point git at .githooks/ so the hooks in this repo run.
#
# Idempotent - safe to run repeatedly. Every clone needs it once, because
# core.hooksPath lives in .git/config and git deliberately refuses to
# check that into the repository: a hook that installed itself on clone
# would be arbitrary code execution on `git clone`.
#
# The hooks themselves are tracked files under .githooks/, so nothing is
# copied here and there is no second copy to drift.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

[ -d .githooks ] || { echo "no .githooks/ directory here" >&2; exit 1; }

git config core.hooksPath .githooks
chmod +x .githooks/* 2>/dev/null || true
[ -f bin/preflight.sh ] && chmod +x bin/preflight.sh

echo "core.hooksPath -> .githooks"
echo "hooks marked executable"
echo
echo "Check the gate order for this repo with:"
echo "    bin/preflight.sh --list"
echo
echo "Run the whole suite against HEAD without pushing:"
echo "    bin/preflight.sh"
