#!/bin/sh
# Makes a disposable repository holding the candidate Kogen source with an ordinary Git baseline
# (REL-3). Its commits are test data. Prints the repository path.
#   sh test/live/self-repo.sh <dir>
set -eu
src=$(cd "$(dirname "$0")/../.." && pwd)
dir=$1
rm -rf "$dir"
mkdir -p "$dir"
rsync -a --exclude .git --exclude _build --exclude deps --exclude dist --exclude node_modules --exclude .kogen --exclude cli/kogen "$src/" "$dir/"
cd "$dir"
# A worktree has a .git file pointing outside it; never reuse that metadata or caller overrides.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
git init -q
[ "$(git rev-parse --absolute-git-dir)" = "$(pwd -P)/.git" ]
git add -A
git -c commit.gpgsign=false commit -q -m "Kogen candidate source"
echo "$dir"
