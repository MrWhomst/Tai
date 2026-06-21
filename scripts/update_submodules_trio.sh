#!/bin/zsh
#
# Walk each Trio submodule listed in TRIO_PROJECTS and fast-forward it to the
# tip of its configured branch on origin. Refuses to move a submodule pointer
# backward — if the remote branch is not a strict descendant of the currently
# checked-out commit, the run aborts loudly rather than silently regressing
# the parent repo's pointer.
#
# History: an earlier `git checkout $branch && git pull` version regressed
# OmniKit from 2b4253b → 48a35ef in one update, dropping loopandlearn/OmniKit
# commit 05683a2 "Add link dependencies" and triggering the recurring Clang
# dep-scanning failures on Xcode Cloud archive runs. The checkout+pull pair
# is sensitive to stale local branches inside the submodule worktree; the
# fetch+reset variant below ignores local refs entirely.

set -euo pipefail

source scripts/define_common_trio.sh

repo_root=$(pwd)

for project in ${TRIO_PROJECTS}; do
  IFS=":" read user dir branch <<< "$project"
  echo "Updating $dir to $branch on $user (from $repo_root)"

  cd "$repo_root/$dir"

  if git remote get-url "$user" >/dev/null 2>&1; then
    remote="$user"
  else
    remote="origin"
  fi

  git fetch "$remote" "$branch"

  before=$(git rev-parse HEAD)
  after=$(git rev-parse "$remote/$branch")

  if [ "$before" = "$after" ]; then
    echo "  $dir already at $remote/$branch ($after), no change"
    continue
  fi

  if ! git merge-base --is-ancestor "$before" "$after"; then
    echo "  REFUSE: $dir would move backward or sideways:" >&2
    echo "    current: $before" >&2
    echo "    remote : $after  (not a descendant)" >&2
    echo "  Investigate the remote branch before proceeding." >&2
    exit 1
  fi

  echo "  fast-forwarding $dir: $before → $after"
  git reset --hard "$after"
done

cd "$repo_root"
echo "All submodules updated."
