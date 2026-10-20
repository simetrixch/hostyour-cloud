# Sourced by every fixture suite that makes git repositories and removes them again.
#
# NO GIT CALL OF A FIXTURE LEAVES A PROCESS BEHIND IT. A commit, a fetch and the receiving end of a
# push each start `git maintenance run --auto --detach`, which forks away, takes
# objects/maintenance.lock in the repository and works there after the caller has gone on (the receiving end
# of git 2.39, Debian bookworm's, starts `git gc --auto` instead, which `receive.autogc` and not
# `maintenance.auto` turns off, so the template sets both). A case that
# removes its repository then races it, and `rm` ends "Directory not empty" with a line in the standard
# error that the case records. The setting stands in the repository's own config, put there by the
# template every `git init` and `git clone` copies — the scripts under test make their clones under it
# too. The environment's own `-c` is no use: git leaves it out of the environment of the other end of
# a local push, which is the one that matters. The template replaces git's own, so it carries the one
# thing a suite takes from that: the hooks folder, where a case writes the hook it plants.
GIT_TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-template"
export GIT_TEMPLATE_DIR

# WHAT IS MEASURED IS THE START, not the race it loses: whether the removal lost depends on the disk,
# so a test of the race goes red on one runner and not on another. A fixture commits and pushes with
# the trace on, which names every process git starts, the one at the far end of the push included.
git_maintenance_starts() { # a scratch folder; prints how many background maintenances a commit and a push in it started
  local d
  d="$(mktemp -d "$1/detached.XXXXXX")" || return 1
  git init --quiet --bare --initial-branch=master "$d/origin.git"
  git init --quiet --initial-branch=master "$d/work"
  git -C "$d/work" remote add origin "$d/origin.git"
  echo x > "$d/work/f"
  git -C "$d/work" add f
  GIT_TRACE="$d/trace" git -C "$d/work" -c user.name=fixture -c user.email=fixture@example.invalid commit --quiet -m x
  GIT_TRACE="$d/trace" git -C "$d/work" push --quiet origin master
  [ "$(git --git-dir="$d/origin.git" rev-parse master)" = "$(git -C "$d/work" rev-parse master)" ] || {
    echo 'the traced fixture push did not reach its origin, so a count of nothing would prove nothing' >&2
    return 1
  }
  grep -cE 'built-in: git (maintenance run|gc) --auto' "$d/trace" || true
}

# THE PROOF A SUITE RUNS ONCE: the fixture's commit and push start nothing, and the same commit and
# push in repositories made without the template — the planted defect — start something, so the zero
# is a measurement. Prints how many the planted run started; says why on the standard error otherwise.
git_quiet_proof() { # a scratch folder
  local started planted
  started="$(git_maintenance_starts "$1")" || return 1
  [ "$started" = '0' ] || {
    echo "a fixture's commit and push started $started background maintenance(s), which can still be writing when the case removes its repository" >&2
    return 1
  }
  planted="$(unset GIT_TEMPLATE_DIR; git_maintenance_starts "$1")" || return 1
  [ "$planted" -gt 0 ] || {
    echo 'a commit and push without the template started no background maintenance, so the zero above proves nothing' >&2
    return 1
  }
  echo "$planted"
}
