#!/usr/bin/env bats

# Require minimum bats version for run -N syntax
bats_require_minimum_version 1.5.0

# Every assertion in this file ends in `|| return 1`. It is not decoration:
# bats relies on `set -e` to turn a failing assertion into a failing test, and
# two holes make a bare assertion silently unenforced.
#
#   1. bash 3.2 does not honour `set -e` for a failing `[[ ]]` or `(( ))` at
#      all -- execution simply continues. So on the bash 3 leg of the matrix
#      every assertion but the last one in a test was a no-op, and a trailing
#      command (this file used to end tests with `unset MOCK_...`) made even
#      the last one a no-op by supplying a zero exit status.
#   2. `set -e` is defined to skip a command prefixed with `!` on every bash
#      version, so `! git rev-parse ...` never failed a test anywhere.
#
# `|| return 1` closes both, on bash 3.2 through 5.x, and bats still reports
# the exact failing line. Do not drop it, and do not add a trailing command
# after an assertion. Tests need no `unset` cleanup: bats runs each test in
# its own process, so exported mocks never leak between them.

# Load status symbol constants from the main script
load_status_symbols() {
  # Source just the status symbol exports
  export STATUS_SUCCESS="✓"
  export STATUS_PENDING="⟳"
  export STATUS_FAILURE="✗"
}
load_status_symbols

setup() {
  TEST_DIR="$(mktemp -d)"
  cp "$(dirname "$BATS_TEST_DIRNAME")/gh-signoff" "$TEST_DIR/"
  cp "$BATS_TEST_DIRNAME/mocks/gh" "$TEST_DIR/"
  export PATH="$TEST_DIR:$PATH"

  cd "$TEST_DIR"
  git init -q
  git config user.name "Test User"
  git commit --no-gpg-sign --allow-empty -m "Initial commit" >/dev/null
}

# Remove the test's scratch repositories, tolerating concurrent writers.
#
# Every test builds real git repositories under TEST_DIR, and plenty of things
# write into a git repository behind our back: trace2 event daemons, fsmonitor,
# background `git maintenance` jobs, editor and IDE git integrations, file
# indexers (Spotlight/mds) and antivirus scanners. Any of them can drop a file
# into a directory rm is midway through emptying, and rm then fails with
# "Directory not empty". Left unhandled that makes teardown return nonzero and
# bats reports the test as failed with every assertion having passed — a
# different test each run, which is what makes it so confusing to chase.
#
# So retry, briefly and a bounded number of times: these writers arrive in a
# short burst once the last git command exits, so a second attempt almost
# always wins. Do not replace this with a bare `rm -rf`.
#
# Exhausting the retries warns rather than fails. A leaked directory under
# TMPDIR is cheap and visible; a suite that reports phantom failures is not,
# and teardown has no business deciding whether a test passed. The warning
# goes to bats' terminal descriptor so a persistent leak still gets noticed.
teardown() {
  local attempt=0

  while [ -d "$TEST_DIR" ] && ! rm -rf "$TEST_DIR" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 10 ]; then
      echo "# warning: could not remove $TEST_DIR, leaving it behind" >&3
      break
    fi
    sleep 0.1
  done

  return 0
}

# Create a nested clean repository and cd into it. The top-level TEST_DIR repo
# holds the untracked gh-signoff and gh mock binaries (still on PATH), which
# would trip is_clean's uncommitted-changes check before the paths under test.
make_nested_repo() {
  git init -q "$TEST_DIR/repo"
  cd "$TEST_DIR/repo"
  git config user.name "Test User"
  git commit --no-gpg-sign --allow-empty -m "Initial commit" >/dev/null
  [[ -z "$(git status --porcelain)" ]] || return 1
}

# Add a bare remote to the nested repository
add_bare_remote() {
  git init -q --bare "$TEST_DIR/remote.git"
  git remote add origin "$TEST_DIR/remote.git"
}

# Configure the current branch the way `gh pr checkout` configures a branch
# taken from a cross-repository (fork) pull request: no named remote, just a
# URL (git accepts a path here identically) and the head ref it tracks
track_url_remote() {
  local url="$1" ref="$2" branch
  branch=$(git symbolic-ref --short HEAD)
  git config "branch.${branch}.remote" "$url"
  git config "branch.${branch}.pushremote" "$url"
  git config "branch.${branch}.merge" "$ref"
}

# Stand up a bare repository playing the contributor's fork, with the pull
# request's head branch at HEAD, and track it by URL from the current branch
checkout_fork_pull_request() {
  git init -q --bare "$TEST_DIR/fork.git"
  git push -q "$TEST_DIR/fork.git" HEAD:refs/heads/their-branch
  git checkout -q -b their-branch
  track_url_remote "$TEST_DIR/fork.git" refs/heads/their-branch
}

# A nested repository with two commits, both on origin, so that HEAD and HEAD~1
# each satisfy the --commit remote check
make_pushed_repo() {
  make_nested_repo
  add_bare_remote
  git commit --no-gpg-sign --allow-empty -m "Second commit" >/dev/null
  git push -q origin HEAD:main
  git branch -q --set-upstream-to=origin/main
}

# Basic command tests
@test "shows help with -h" {
  run -0 gh-signoff -h
  [[ "$output" == *"USAGE"* ]] || return 1
  [[ "$output" == *"COMMANDS"* ]] || return 1
}

@test "shows version" {
  run -0 gh-signoff version
  [[ "$output" == "gh-signoff"* ]] || return 1
}

@test "create signs off on current commit" {
  run -0 gh-signoff create -f
  [[ "$output" == *"Signed off on"* ]] || return 1
}

@test "create signs off on the commit named by --commit" {
  make_pushed_repo
  sha=$(git rev-parse HEAD)
  export MOCK_EXPECT_COMMIT="$sha"

  run -0 gh-signoff create --commit "$sha"
  [[ "$output" == *"Signed off on $sha"* ]] || return 1
}

@test "direct signoff signs off on the commit named by --commit" {
  make_pushed_repo
  sha=$(git rev-parse HEAD)
  export MOCK_EXPECT_COMMIT="$sha"

  run -0 gh-signoff --commit "$sha"
  [[ "$output" == *"Signed off on $sha"* ]] || return 1
}

@test "direct partial signoff signs off on the commit named by --commit" {
  make_pushed_repo
  sha=$(git rev-parse HEAD)
  export MOCK_EXPECT_COMMIT="$sha"

  run -0 gh-signoff --commit "$sha" linux
  [[ "$output" == *"Signed off on $sha for linux"* ]] || return 1
}

@test "--commit takes any revision git resolves" {
  make_pushed_repo
  sha=$(git rev-parse HEAD~1)
  export MOCK_EXPECT_COMMIT="$sha"

  run -0 gh-signoff --commit HEAD~1
  [[ "$output" == *"Signed off on $sha"* ]] || return 1
}

@test "--commit expands a short sha to the full 40 hex" {
  make_pushed_repo
  sha=$(git rev-parse HEAD)
  export MOCK_EXPECT_COMMIT="$sha"

  run -0 gh-signoff --commit "${sha:0:8}"
  [[ "$output" == *"Signed off on $sha"* ]] || return 1
}

@test "--commit rejects a revision git cannot resolve" {
  run -1 gh-signoff create --commit 'abc/status'
  [[ "$output" == *"invalid commit: abc/status"* ]] || return 1
}

@test "--commit rejects a missing argument" {
  run -1 gh-signoff create --commit
  [[ "$output" == *"option --commit requires an argument"* ]] || return 1
}

@test "--commit rejects an object that is not a commit" {
  # A blob's sha is 40 hex and the object is right here, but it does not peel
  # to a commit. Without the local-object check it would pass for unfetched.
  make_pushed_repo
  echo contents > file
  git add file
  git commit --no-gpg-sign -q -m "Add file"
  blob=$(git rev-parse HEAD:file)

  run -1 gh-signoff --commit "$blob"
  [[ "$output" == *"not a commit: $blob"* ]] || return 1
}

@test "--commit refuses a sha with no local object to check" {
  make_pushed_repo
  unfetched=0123456789012345678901234567890123456789

  run -1 gh-signoff --commit "$unfetched"
  [[ "$output" == *"cannot verify ${unfetched} is on a remote"* ]] || return 1

  export MOCK_EXPECT_COMMIT="$unfetched"
  run -0 gh-signoff -f --commit "$unfetched"
  [[ "$output" == *"Signed off on $unfetched"* ]] || return 1
}

@test "--commit accepts a commit published to a URL-tracked remote" {
  # A branch checked out from a fork pull request has no remote-tracking refs,
  # so `git branch -r --contains` finds nothing. Plain signoff proves the
  # commit is on the fork over ls-remote; --commit must reach the same answer
  # rather than demanding -f for naming the very commit it just accepted.
  make_nested_repo
  checkout_fork_pull_request
  sha=$(git rev-parse HEAD)
  [[ -z "$(git branch -r --contains "$sha")" ]] || return 1

  export MOCK_EXPECT_COMMIT="$sha"
  run -0 gh-signoff --commit "$sha"
  [[ "$output" == *"Signed off on $sha"* ]] || return 1

  run -0 gh-signoff status --commit "$sha"
  [[ "$output" == *"signoff"* ]] || return 1
}

@test "--commit still refuses an unpushed commit on a URL-tracked remote" {
  make_nested_repo
  checkout_fork_pull_request
  git commit --no-gpg-sign --allow-empty -m "Unpushed commit" >/dev/null
  sha=$(git rev-parse HEAD)

  run -1 gh-signoff --commit "$sha"
  [[ "$output" == *"is not on any remote"* ]] || return 1

  export MOCK_EXPECT_COMMIT="$sha"
  run -0 gh-signoff -f --commit "$sha"
  [[ "$output" == *"Signed off on $sha"* ]] || return 1
}

@test "--commit refuses a commit that is on no remote" {
  make_pushed_repo
  git commit --no-gpg-sign --allow-empty -m "Unpushed commit" >/dev/null
  sha=$(git rev-parse HEAD)

  run -1 gh-signoff --commit "$sha"
  [[ "$output" == *"commit ${sha} is not on any remote"* ]] || return 1

  export MOCK_EXPECT_COMMIT="$sha"
  run -0 gh-signoff -f --commit "$sha"
  [[ "$output" == *"Signed off on $sha"* ]] || return 1
}

@test "--commit checks the named commit, not the worktree" {
  make_pushed_repo
  sha=$(git rev-parse HEAD)
  touch untracked-file
  export MOCK_EXPECT_COMMIT="$sha"

  run -0 gh-signoff --commit "$sha"
  [[ "$output" == *"Signed off on $sha"* ]] || return 1

  unset MOCK_EXPECT_COMMIT
  run -1 gh-signoff
  [[ "$output" == *"repository has uncommitted changes"* ]] || return 1
}

@test "check falls back to legacy branch protection" {
  # Simulate pre-migration protection requiring default signoff
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  run -0 gh-signoff check
  [[ "$output" == *"requires signoff"* ]] || return 1
}

@test "install requires signoff via a ruleset" {
  run -0 gh-signoff install
  [[ "$output" == *"now requires signoff"* ]] || return 1
}

@test "uninstall removes the signoff ruleset" {
  # Our ruleset exists; expect its DELETE to succeed
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_DELETE_RULESET_EXIT=0
  run -0 gh-signoff uninstall
  [[ "$output" == *"no longer requires signoff"* ]] || return 1
}

# Context support tests
@test "create signs off with positional argument" {
  # Expect POST status call to succeed
  export MOCK_POST_STATUS_EXIT=0
  run -0 gh-signoff create -f linux
  [[ "$output" == *"Signed off on"* ]] || return 1
  [[ "$output" == *"for linux"* ]] || return 1
}

@test "direct partial signoff" {
  # Expect POST status call to succeed
  export MOCK_POST_STATUS_EXIT=0
  run -0 gh-signoff linux -f
  [[ "$output" == *"Signed off on"* ]] || return 1
  [[ "$output" == *"for linux"* ]] || return 1
}

@test "direct multiple partial signoff" {
  # Expect POST status call to succeed
  export MOCK_POST_STATUS_EXIT=0
  run -0 gh-signoff linux macos windows -f
  [[ "$output" == *"for linux"* ]] || return 1
  [[ "$output" == *"for macos"* ]] || return 1
  [[ "$output" == *"for windows"* ]] || return 1
}

@test "install with context enables contextual requirement" {
  run -0 gh-signoff install windows
  [[ "$output" == *"now requires signoff on windows"* ]] || return 1
}

@test "check with context falls back to legacy branch protection" {
  # Simulate pre-migration protection requiring 'linux' signoff
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff/linux"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  run -0 gh-signoff check linux
  [[ "$output" == *"requires signoff on linux"* ]] || return 1
}

@test "check with missing context shows negative status" {
  # Simulate protection requiring only default signoff
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  run -0 gh-signoff check windows
  [[ "$output" == *"does not require signoff on windows"* ]] || return 1
}

# Exact output, not substring: bats folds stderr into $output, so a leaked
# internal diagnostic (e.g. the ERR trap firing on the command's own nonzero
# exit) is invisible to a substring assertion.
@test "check reports only the negative result for an unprotected branch" {
  # Mock: no protection at all (like a 404 from the protection API)
  export MOCK_BRANCH_PROTECTION_EXIT=1

  run -1 gh-signoff check
  [[ "$output" == "${STATUS_FAILURE} GitHub main branch does not require signoff" ]] || return 1

  run -1 gh-signoff check windows
  [[ "$output" == "${STATUS_FAILURE} GitHub main branch does not require signoff on windows" ]] || return 1
}

@test "uninstall with context removes contextual requirement" {
  # The ruleset requires only signoff/macos, so removing it deletes the ruleset
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff/macos"}]}}]}'
  export MOCK_DELETE_RULESET_EXIT=0
  run -0 gh-signoff uninstall macos
  [[ "$output" == *"no longer requires signoff on macos"* ]] || return 1
}

@test "install with branch and context arguments" {
  run -0 gh-signoff install --branch main linux
  [[ "$output" == *"now requires signoff on linux"* ]] || return 1
}

# Ruleset tests. The mock's ruleset list defaults to [] (how the API reports
# "no rulesets") and branch protection defaults to 404, so each test states
# only what exists. MOCK_CALL_LOG/MOCK_BODY_LOG record the requests the mock
# served, for asserting what was written where.

@test "check reads requirements from our ruleset" {
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"},{"context":"signoff/tests"}]}}]}'

  # Exact output: no legacy protection, so no upgrade hint may leak
  run -0 gh-signoff check
  [[ "$output" == "${STATUS_SUCCESS} GitHub main branch requires signoff" ]] || return 1

  run -0 gh-signoff check tests
  [[ "$output" == "${STATUS_SUCCESS} GitHub main branch requires signoff on tests" ]] || return 1

  run -0 gh-signoff check windows
  [[ "$output" == "${STATUS_FAILURE} GitHub main branch does not require signoff on windows" ]] || return 1
}

@test "status reads requirements from our ruleset" {
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"},{"context":"signoff/tests"}]}}]}'
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff","state":"success","description":"Test User signed off"}]}'

  run -0 gh-signoff status
  [[ "$output" == "${STATUS_SUCCESS} signoff"$'\n'"${STATUS_FAILURE} tests" ]] || return 1
}

@test "rulesets that are not ours are never read" {
  # Exact name match: neither someone else's ruleset nor our ruleset for a
  # different branch counts for main
  export MOCK_RULESETS_LIST_JSON='[{"id":7,"name":"org-policy"},{"id":8,"name":"signoff (other)"}]'

  run -1 gh-signoff check
  [[ "$output" == "${STATUS_FAILURE} GitHub main branch does not require signoff" ]] || return 1
}

@test "check merges ruleset and legacy contexts with an upgrade hint" {
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff/tests"}]}}]}'
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff/tests","signoff/lint"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0

  run -0 gh-signoff check tests lint
  [[ "$output" == *"requires signoff on tests"* ]] || return 1
  [[ "$output" == *"requires signoff on lint"* ]] || return 1
  [[ "$output" == *"legacy branch protection"* ]] || return 1
  [[ "$output" == *"gh signoff install"* ]] || return 1
}

@test "status dedupes contexts required by both sources and hints upgrade" {
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff/tests"}]}}]}'
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff/tests"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0

  run -0 gh-signoff status
  [[ "$output" == *"${STATUS_FAILURE} tests"* ]] || return 1
  # The overlapping context appears once, not once per source
  [[ "$output" != *"tests"*"tests"* ]] || return 1
  [[ "$output" == *"legacy branch protection"* ]] || return 1
}

@test "install creates our ruleset" {
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install
  [[ "$output" == *"now requires signoff"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"POST repos/:owner/:repo/rulesets"$'\n'* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'"name":"signoff"'* ]] || return 1
  [[ "$body" == *'"include":["~DEFAULT_BRANCH"]'* ]] || return 1
  [[ "$body" == *'{"context":"signoff"}'* ]] || return 1
  [[ "$body" == *'"bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]'* ]] || return 1
  [[ "$body" == *'"strict_required_status_checks_policy":false'* ]] || return 1
  # Legacy protection blocked branch deletion and force pushes by default,
  # so the ruleset must too — anything less weakens a migrated install
  [[ "$body" == *'{"type":"deletion"}'* ]] || return 1
  [[ "$body" == *'{"type":"non_fast_forward"}'* ]] || return 1
}

@test "install unions new contexts into the existing ruleset" {
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff/tests"}]}}]}'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install lint
  [[ "$output" == *"now requires signoff on lint"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"PUT repos/:owner/:repo/rulesets/42"$'\n'* ]] || return 1
  [[ "$calls" != *"POST repos/:owner/:repo/rulesets"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"context":"signoff/tests"}'* ]] || return 1
  [[ "$body" == *'{"context":"signoff/lint"}'* ]] || return 1
}

@test "install migrates signoff-shaped legacy protection" {
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":["signoff","signoff/tests"]},"enforce_admins":{"enabled":false},"required_pull_request_reviews":null,"restrictions":null}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install
  [[ "$output" == *"now requires signoff"* ]] || return 1
  [[ "$output" == *"Migrated legacy branch protection to a ruleset"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"POST repos/:owner/:repo/rulesets"$'\n'* ]] || return 1
  [[ $'\n'"$calls"$'\n' == *$'\n'"DELETE repos/:owner/:repo/branches/main/protection"$'\n'* ]] || return 1

  # The legacy contexts carry over into the ruleset
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"context":"signoff"}'* ]] || return 1
  [[ "$body" == *'{"context":"signoff/tests"}'* ]] || return 1
}

@test "install leaves non-signoff protection intact" {
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":["other-ci","signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install
  [[ "$output" == *"now requires signoff"* ]] || return 1
  [[ "$output" == *"Migrated legacy signoff contexts to a ruleset"* ]] || return 1
  [[ "$output" != *"Migrated legacy branch protection"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"POST repos/:owner/:repo/rulesets"$'\n'* ]] || return 1
  # No wholesale protection delete: only the signoff contexts are removed,
  # surgically, leaving other-ci and every other setting in place
  [[ $'\n'"$calls"$'\n' != *$'\n'"DELETE repos/:owner/:repo/branches/main/protection"$'\n'* ]] || return 1
  [[ "$calls" == *"DELETE repos/:owner/:repo/branches/main/protection/required_status_checks/contexts"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" != *"other-ci"* ]] || return 1
}

@test "install treats admin-enforced protection as not ours to delete" {
  # Old gh-signoff always wrote enforce_admins=null, so enabled enforcement
  # means someone tightened it on purpose
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":["signoff"]},"enforce_admins":{"enabled":true}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -0 gh-signoff install
  [[ "$output" != *"Migrated legacy branch protection"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' != *$'\n'"DELETE repos/:owner/:repo/branches/main/protection"$'\n'* ]] || return 1
  [[ "$calls" == *"DELETE repos/:owner/:repo/branches/main/protection/required_status_checks/contexts"* ]] || return 1
}

@test "install preserves protection features old installs never wrote" {
  # The classifier must read any enabled protection flag — linear history,
  # signatures, whatever GitHub adds next — as someone else's configuration,
  # never as signoff-shaped
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":["signoff"]},"enforce_admins":{"enabled":false},"required_linear_history":{"enabled":true}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -0 gh-signoff install
  [[ "$output" == *"Migrated legacy signoff contexts to a ruleset"* ]] || return 1
  [[ "$output" != *"Migrated legacy branch protection"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' != *$'\n'"DELETE repos/:owner/:repo/branches/main/protection"$'\n'* ]] || return 1
  [[ "$calls" == *"DELETE repos/:owner/:repo/branches/main/protection/required_status_checks/contexts"* ]] || return 1
}

@test "install migrates only exactly-named signoff contexts" {
  # signoff-security is a foreign context that happens to share the prefix:
  # it keeps the protection classified as not ours, never lands in the
  # ruleset, and is never removed from the protection
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":["signoff-security","signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install

  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' != *$'\n'"DELETE repos/:owner/:repo/branches/main/protection"$'\n'* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"context":"signoff"}'* ]] || return 1
  [[ "$body" != *"signoff-security"* ]] || return 1
}

@test "app-bound signoff checks are not ours to migrate or remove" {
  # A signoff check pinned to a GitHub App is a configuration this tool
  # never wrote: it stays exactly where it is — not unioned into the
  # ruleset, not removed from the protection, never deleted wholesale
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"checks":[{"context":"signoff","app_id":12345}],"contexts":["signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install tests
  [[ "$output" != *"Migrated"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" != *"DELETE "* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"context":"signoff/tests"}'* ]] || return 1
  [[ "$body" != *'{"context":"signoff"}'* ]] || return 1
}

@test "reads do not claim app-bound signoff checks" {
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"checks":[{"context":"signoff","app_id":12345}],"contexts":["signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0

  # Exact output: not required by anything of ours, and no upgrade hint,
  # because install would not migrate it
  run -1 gh-signoff check
  [[ "$output" == "${STATUS_FAILURE} GitHub main branch does not require signoff" ]] || return 1
}

@test "uninstall leaves protection with no signoff contexts untouched" {
  # An otherwise-empty protected branch still blocks force pushes and
  # deletion; a tool that never wrote it must not delete it
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":[]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  run -1 gh-signoff uninstall
  [[ "$output" == *"no signoff requirement installed on main"* ]] || return 1

  export MOCK_BRANCH_PROTECTION_JSON='{"enforce_admins":{"enabled":false}}'
  run -1 gh-signoff uninstall
  [[ "$output" == *"no signoff requirement installed on main"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" != *"DELETE "* ]] || return 1
}

@test "uninstall rejects an empty context name" {
  # '' would slip past the bare-vs-contextual split, subtract nothing, and
  # still claim the whole requirement was removed
  run -1 gh-signoff uninstall ''
  [[ "$output" == *"context name cannot be empty"* ]] || return 1

  run -1 gh-signoff uninstall tests ''
  [[ "$output" == *"context name cannot be empty"* ]] || return 1
}

@test "legacy checks with control characters are ours and migrate faithfully" {
  # This expectation is the reverse of what it was. The name was disowned on
  # the theory that install could not have written it — but 0.3.0 passed
  # context arguments straight through to the API, so it could have, and
  # disowning stranded a requirement no later version would migrate or
  # remove. What the clause was really standing in for was the injection such
  # a name enabled, and the record protocol has made that structural: one
  # record, one spliced token, removal by exactly the name it has. The
  # app-bound other-ci check is untouched either way.
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"checks":[{"context":"signoff/tests\nother-ci","app_id":null},{"context":"other-ci","app_id":777}]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install lint
  [[ "$output" == *"Migrated legacy signoff contexts to a ruleset"* ]] || return 1

  # Surgically removed, never a wholesale protection delete: other-ci is
  # someone else's requirement and its protection is not ours to drop
  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" == *"DELETE repos/:owner/:repo/branches/main/protection/required_status_checks/contexts"* ]] || return 1
  [[ $'\n'"$calls"$'\n' != *$'\n'"DELETE repos/:owner/:repo/branches/main/protection"$'\n'* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"context":"signoff/tests\nother-ci"}'* ]] || return 1
  [[ "$body" == *'{"context":"signoff/lint"}'* ]] || return 1
  # The removal asks for that one name, whole — never the app-bound other-ci
  [[ "$body" == *'{"contexts":["signoff/tests\nother-ci"]}'* ]] || return 1
  [[ "$body" != *'["other-ci"'* ]] || return 1
  [[ "$body" != *'{"context":"other-ci"}'* ]] || return 1
}

@test "a signoff check that also exists app-bound is not ours" {
  # The removal endpoint matches by name alone, so claiming the unbound twin
  # would strip the app-bound foreign requirement with it — the shared name
  # is disowned instead
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"checks":[{"context":"signoff","app_id":null},{"context":"signoff","app_id":777}]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install tests
  [[ "$output" != *"Migrated"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" != *"DELETE "* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"context":"signoff/tests"}'* ]] || return 1
  [[ "$body" != *'{"context":"signoff"}'* ]] || return 1
}

@test "every command holds a typed context to the identifier grammar" {
  # The grammar keeps the signoff namespace coherent: a context this tool
  # creates is one it can install, check and uninstall by name, and one whose
  # record and payload are built by quoting alone. install, check, uninstall
  # and create all take a context the user typed, so all four hold it to the
  # same rule.
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  for bad in '$(printf PWNED)' 'foo;touch /tmp/pwned' '`id`' 'foo bar' \
             '.hidden' 'has"quote' 'back\slash' 'a|b' 'a&b' \
             'star*' '~home' $'nl\nhere' $'esc\x1bhere' $'caf\xc3\xa9'; do
    run -1 gh-signoff install "$bad"
    [[ "$output" == *"may contain letters, digits"* ]] || return 1

    run -1 gh-signoff check "$bad"
    [[ "$output" == *"may contain letters, digits"* ]] || return 1

    run -1 gh-signoff uninstall "$bad"
    [[ "$output" == *"may contain letters, digits"* ]] || return 1

    run -1 gh-signoff create "$bad"
    [[ "$output" == *"may contain letters, digits"* ]] || return 1
  done

  # A leading dash never reaches the grammar: every command reads it as an
  # option first. Refused all the same, which is the point.
  for cmd in install check uninstall create; do
    run -1 gh-signoff "$cmd" -danger
    [[ "$output" == *"unknown option: -danger"* ]] || return 1
  done

  # Refused before anything is asked of the API
  [[ ! -s "$MOCK_CALL_LOG" ]] || return 1
}

@test "the identifier grammar accepts the names people actually use" {
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'

  for good in foo foo-bar foo.bar foo/bar foo_bar Lint bash-3 9lives; do
    run -0 gh-signoff install "$good"
    [[ "$output" == *"now requires signoff on ${good}"* ]] || return 1
  done
}

@test "reads do not claim foreign signoff-prefixed contexts" {
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff-security"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0

  # Exact output: no requirement found, and no upgrade hint either, because
  # the foreign context is not legacy signoff enforcement
  run -1 gh-signoff check
  [[ "$output" == "${STATUS_FAILURE} GitHub main branch does not require signoff" ]] || return 1
}

@test "reads tolerate an indeterminate legacy protection read" {
  export MOCK_BRANCH_PROTECTION_EXIT=1
  export MOCK_BRANCH_PROTECTION_ERROR_STATUS=500

  run -1 gh-signoff check
  [[ "$output" == "${STATUS_FAILURE} GitHub main branch does not require signoff" ]] || return 1
}

@test "writers fail on an indeterminate legacy protection read" {
  # A 403/500/timeout is not "no protection": acting on it could migrate
  # from or delete protection the writer never actually saw
  export MOCK_BRANCH_PROTECTION_EXIT=1
  export MOCK_BRANCH_PROTECTION_ERROR_STATUS=500
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -1 gh-signoff install
  [[ "$output" == *"failed to read branch protection"* ]] || return 1

  run -1 gh-signoff uninstall
  [[ "$output" == *"failed to read branch protection"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" != *"POST "* && "$calls" != *"PUT "* && "$calls" != *"DELETE "* ]] || return 1
}

@test "writers fail when the default branch cannot be resolved" {
  # Ruleset identity hinges on whether the branch is the default; guessing
  # would create 'signoff (main)' alongside 'signoff' on a transient failure
  export MOCK_DEFAULT_BRANCH_EXIT=1
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -1 gh-signoff install --branch main tests
  [[ "$output" == *"failed to get default branch"* ]] || return 1

  run -1 gh-signoff uninstall --branch main tests
  [[ "$output" == *"failed to get default branch"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" != *"POST "* && "$calls" != *"PUT "* && "$calls" != *"DELETE "* ]] || return 1
}

@test "ruleset listing excludes parent and non-branch rulesets" {
  # An org policy or tag ruleset that happens to be named 'signoff' is
  # another tenant's artifact; the query keeps them out server-side
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -1 gh-signoff check
  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" == *"GET repos/:owner/:repo/rulesets?includes_parents=false&targets=branch"* ]] || return 1
}

@test "install --branch other targets a branch-named ruleset" {
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install --branch other
  [[ "$output" == *"GitHub other branch now requires signoff"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'"name":"signoff (other)"'* ]] || return 1
  [[ "$body" == *'"include":["refs/heads/other"]'* ]] || return 1
}

@test "an API error body cannot repaint the terminal" {
  # gh prints the API error body to stdout and we forward it to stderr, so a
  # hostile message in a response is one more thing that reaches a terminal
  export MOCK_POST_RULESET_EXIT=1
  export MOCK_ERROR_MESSAGE=$'Validation ev\xe2\x80\xaeil failed'

  run -1 gh-signoff install
  [[ "$output" == *"failed to create signoff ruleset"* ]] || return 1
  [[ "$output" != *$'\xe2\x80\xae'* ]] || return 1
  [[ "$output" == *"ev???il"* ]] || return 1
}

@test "install reports a failed ruleset create" {
  export MOCK_POST_RULESET_EXIT=1

  run -1 gh-signoff install
  [[ "$output" == *"failed to create signoff ruleset"* ]] || return 1
}

@test "install reports a failed ruleset listing" {
  export MOCK_RULESETS_LIST_EXIT=1

  run -1 gh-signoff install
  [[ "$output" == *"failed to list rulesets"* ]] || return 1
}

@test "install fails rather than drop contexts it could not read" {
  # The union must be computed from the ruleset's real contents; an unreadable
  # ruleset must not be treated as an empty one
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_EXIT=1

  run -1 gh-signoff install lint
  [[ "$output" == *"failed to read signoff ruleset"* ]] || return 1
}

@test "contextual uninstall fails rather than subtract from contexts it could not read" {
  # An unreadable ruleset read as empty would make the remainder empty and
  # delete a ruleset that still holds other contexts
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_EXIT=1
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -1 gh-signoff uninstall tests
  [[ "$output" == *"failed to read signoff ruleset"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" != *"DELETE "* ]] || return 1
  [[ "$calls" != *"PUT "* ]] || return 1
}


# A ruleset we adopt by name holds whatever a repo admin put there, and the
# rules API does not exclude control characters from a context name.
# "foreign\nsignoff/tests" is ONE requirement that used to forge two records
# in the line-delimited streams — enough to make `check tests` claim success
# and to make `uninstall tests` write back a bare `foreign` requirement
# nobody asked for. As a JSON token it is one record that compares as itself
# and is written back byte for byte.
@test "a ruleset context with an embedded newline stays one context" {
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"foreign\nsignoff/tests"}]}}]}'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  # The forged half must not satisfy the check
  run -0 gh-signoff check tests
  [[ "$output" == "${STATUS_FAILURE} GitHub main branch does not require signoff on tests" ]] || return 1

  # ... nor be subtracted by it: the ruleset is rewritten unchanged
  run -0 gh-signoff uninstall tests
  [[ "$output" == *"no longer requires signoff on tests"* ]] || return 1

  # ... and a union keeps it intact alongside the new context
  run -0 gh-signoff install lint
  [[ "$output" == *"now requires signoff on lint"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" != *"DELETE "* ]] || return 1

  # The escaped token round-trips: one context, spelled exactly as it arrived,
  # and no bare "foreign" requirement ever materializes
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"context":"foreign\nsignoff/tests"}'* ]] || return 1
  [[ "$body" == *'{"context":"signoff/lint"}'* ]] || return 1
  [[ "$body" != *'{"context":"foreign"}'* ]] || return 1
  [[ "$body" != *'"context":"signoff/tests"'* ]] || return 1
}

@test "check refuses context arguments that could forge a lookup key" {
  # A read composes its lookup key by quoting, just as a write composes its
  # token, so check has to refuse the same names. An argument carrying a
  # quote and a tab spells a key that spans two whole fetched records —
  # matching them both and reporting a context as required that nobody ever
  # required.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff/foo"},{"context":"signoff/bar"}]}}]}'

  run -1 gh-signoff check $'foo"\t"signoff/foo"\n"signoff/bar'
  [[ "$output" == *"may contain letters, digits"* ]] || return 1
  [[ "$output" != *"requires signoff"* ]] || return 1

  # A plain quote is refused too, rather than quietly matching nothing
  run -1 gh-signoff check 'bad"context'
  [[ "$output" == *"may contain letters, digits"* ]] || return 1
}

@test "an empty ruleset context round-trips rather than vanishing" {
  # An empty context is not something install would write, but dropping one
  # silently on the next write is exactly the kind of edit this tool has no
  # business making to a ruleset it merely adopted
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":""},{"context":"signoff"}]}}]}'
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install lint
  [[ "$output" == *"now requires signoff on lint"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"context":""}'* ]] || return 1
  [[ "$body" == *'{"context":"signoff"}'* ]] || return 1
  [[ "$body" == *'{"context":"signoff/lint"}'* ]] || return 1
}

@test "records survive a shell whose echo expands escapes" {
  # bash -O xpg_echo makes echo decode backslash escapes. A token's two
  # characters \n would become a real newline: one record splitting into two,
  # and a PUT body quietly renaming the context. Every path that emits data
  # uses printf, so the token reaches GitHub exactly as it arrived.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff/we\nird"}]}}]}'
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 bash -O xpg_echo "$TEST_DIR/gh-signoff" install lint
  [[ "$output" == *"now requires signoff on lint"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"context":"signoff/we\nird"}'* ]] || return 1
  [[ "$body" == *'{"context":"signoff/lint"}'* ]] || return 1
}

@test "a hostile commit status state cannot forge a signoff record" {
  # The state rides beside the token as raw text, so it is held to GitHub's
  # documented enum first: this one spells out a whole extra record, which
  # would otherwise mark tests signed off on a commit that never was
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"},{"context":"signoff/tests"}]}}]}'
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff","state":"success\n\"signoff/tests\"\t\"signoff/tests\"\tsuccess"}]}'

  run -0 gh-signoff status
  [[ "$output" == "${STATUS_FAILURE} signoff"$'\n'"${STATUS_FAILURE} tests" ]] || return 1
}

# tojson escapes what JSON requires and nothing else, so a token still holds
# C1 controls and format characters verbatim. U+202E RIGHT-TO-LEFT OVERRIDE
# in an adopted context name would reorder the line it prints on — an
# adopted requirement made to read as a different one. The display field
# replaces those; the token, and so the payload, keeps them.
@test "status shows an out-of-charset name as question marks" {
  # Display is the name with everything outside printable ASCII shown as ?.
  # Lossy on purpose: the alternative is a Unicode escaping engine written in
  # bash, to tell apart names this tool refuses to create.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff/ev\u202eil"},{"context":"signoff/c1\u009bhere"}]}}]}'

  run -0 gh-signoff status
  # The override and the C1 control never reach the terminal
  [[ "$output" != *$'\xe2\x80\xae'* ]] || return 1
  [[ "$output" != *$'\xc2\x9b'* ]] || return 1
  # Shown as a question mark instead — one per character, since jq counts
  # characters where the bash scrubber counts bytes — name otherwise intact
  [[ "$output" == *"${STATUS_FAILURE} ev?il"* ]] || return 1
  [[ "$output" == *"${STATUS_FAILURE} c1?here"* ]] || return 1
}

@test "a rejected argument cannot repaint the terminal" {
  # The value we refuse still gets echoed back, so it is scrubbed on the way
  # out: an ESC here would clear the screen and take the error with it
  run -1 gh-signoff install $'bad\x1b[2Jclear'
  [[ "$output" == *"may contain letters, digits"* ]] || return 1
  [[ "$output" != *$'\x1b'* ]] || return 1
  [[ "$output" == *"bad?[2Jclear"* ]] || return 1
}

@test "install refuses a bidi override in a context argument" {
  # A name we would be creating has to be one we can show back. Refused
  # before any request, and the refusal itself carries no raw override.
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -1 gh-signoff install $'ev\xe2\x80\xaeil'
  [[ "$output" == *"may contain letters, digits"* ]] || return 1
  [[ "$output" != *$'\xe2\x80\xae'* ]] || return 1

  [[ ! -s "$MOCK_CALL_LOG" ]] || return 1
}

@test "debug shows an adopted name scrubbed while the payload keeps it" {
  # SIGNOFF_DEBUG prints the request JSON, which carries adopted names raw.
  # The debug line is scrubbed whole; what goes on the wire is not.
  export SIGNOFF_DEBUG=1
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff/ev\u202eil"},{"context":"signoff/c1\u009bhere"}]}}]}'
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install lint
  [[ "$output" == *"writing signoff ruleset"* ]] || return 1
  [[ "$output" != *$'\xe2\x80\xae'* ]] || return 1
  [[ "$output" != *$'\xc2\x9b'* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *$'\xe2\x80\xae'* ]] || return 1
  [[ "$body" == *$'\xc2\x9b'* ]] || return 1
}

@test "a hostile default branch name prints inert" {
  # The branch comes from the API, so it is scrubbed wherever it is shown
  export MOCK_DEFAULT_BRANCH_JSON='{"default_branch":"ma\u001bin"}'

  run -1 gh-signoff check
  [[ "$output" != *$'\x1b'* ]] || return 1
  [[ "$output" == "${STATUS_FAILURE} GitHub ma?in branch does not require signoff" ]] || return 1
}

@test "a branch name outside the charset still reaches the payload faithfully" {
  # Branches are named by the repository, not by us: they are held to the
  # JSON rule only, so this one is written as spelled while the message
  # showing it is scrubbed
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install --branch $'ev\xe2\x80\xaeil'
  [[ "$output" != *$'\xe2\x80\xae'* ]] || return 1
  [[ "$output" == *"GitHub ev???il branch now requires signoff"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *$'\xe2\x80\xae'* ]] || return 1
}

@test "Unicode line separators in an adopted context are shown as question marks" {
  # U+2028 and U+2029 are mandatory line breaks; outside the charset like
  # anything else, so they do not print
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff/foo\u2028bar"},{"context":"signoff/baz\u2029qux"}]}}]}'
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff status
  [[ "$output" != *$'\xe2\x80\xa8'* ]] || return 1
  [[ "$output" != *$'\xe2\x80\xa9'* ]] || return 1
  [[ "$output" == *"${STATUS_FAILURE} foo?bar"* ]] || return 1
  [[ "$output" == *"${STATUS_FAILURE} baz?qux"* ]] || return 1

  run -0 gh-signoff install lint
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *$'\xe2\x80\xa8'* ]] || return 1
  [[ "$body" == *$'\xe2\x80\xa9'* ]] || return 1
}

@test "display is lossy: two out-of-charset names can read alike" {
  # The documented cost of a dumb charset. These two names differ, are
  # enforced separately and are written back distinctly — but on screen they
  # both read a?b, and telling them apart would mean a Unicode escaping
  # engine written in bash, for names this tool refuses to create.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff/a\u202eb"},{"context":"signoff/a\ufffdb"}]}}]}'
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff status
  rows=$(printf '%s\n' "$output" | grep -c 'a?b') || rows=0
  [[ "$rows" -eq 2 ]] || return 1

  # Enforcement is not lossy: both names ride through the union intact
  run -0 gh-signoff install lint
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *$'\xe2\x80\xae'* ]] || return 1
  [[ "$body" == *$'\xef\xbf\xbd'* ]] || return 1
}

@test "sanitizing for display never reaches the payload" {
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff/ev\u202eil"}]}}]}'
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install lint
  [[ "$output" == *"now requires signoff on lint"* ]] || return 1

  # The union writes the name back exactly as GitHub spelled it
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *$'\xe2\x80\xae'* ]] || return 1
  [[ "$body" != *$'\xef\xbf\xbd'* ]] || return 1
  [[ "$body" == *'{"context":"signoff/lint"}'* ]] || return 1
}

@test "uninstall subtracts a context whose spelling differs in case" {
  # GitHub compares status check contexts case-insensitively, so
  # signoff/Tests IS the tests requirement. A case-sensitive subtraction
  # would remove nothing and PUT it straight back while reporting success.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff/Tests"}]}}]}'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff uninstall tests
  [[ "$output" == *"no longer requires signoff on tests"* ]] || return 1

  # Nothing remains, so the ruleset goes rather than being rewritten
  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"DELETE repos/:owner/:repo/rulesets/42"$'\n'* ]] || return 1
  [[ "$calls" != *"PUT "* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" != *"signoff/Tests"* ]] || return 1
}

@test "an app-bound twin disowns its unbound signoff check whatever its case" {
  # The removal endpoint matches contexts case-insensitively too, so a
  # name-based removal of the unbound signoff would take the app-bound
  # SignOff requirement with it. Fail closed: the name is not ours.
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"checks":[{"context":"signoff","app_id":null},{"context":"SignOff","app_id":777}]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install tests
  [[ "$output" != *"Migrated"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" != *"DELETE "* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"context":"signoff/tests"}'* ]] || return 1
  [[ "$body" != *'{"context":"signoff"}'* ]] || return 1

  # And a read does not count the disowned name as a requirement: exact
  # output, so no upgrade hint leaks either
  run -1 gh-signoff check
  [[ "$output" == "${STATUS_FAILURE} GitHub main branch does not require signoff" ]] || return 1
}

@test "contexts differing only in case are one requirement" {
  # The ruleset and legacy protection spell the same requirement two ways;
  # reads show it once, and the union writes back one — the first spelling
  # seen, which is the ruleset's
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff/Tests"}]}}]}'
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff/tests"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff check tests
  [[ "$output" == *"requires signoff on tests"* ]] || return 1

  run -0 gh-signoff status
  [[ "$output" == *"${STATUS_FAILURE} Tests"* ]] || return 1
  [[ "$output" != *"Tests"*"tests"* ]] || return 1
  [[ "$output" != *"tests"*"Tests"* ]] || return 1

  run -0 gh-signoff install
  [[ "$output" == *"now requires signoff"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"context":"signoff/Tests"}'* ]] || return 1
  [[ "$body" != *'{"context":"signoff/tests"}'* ]] || return 1
}

@test "a signoff status satisfies a requirement spelled in another case" {
  # The commit carries SignOff; the ruleset requires signoff. Same context
  # as far as GitHub is concerned, so the requirement is met.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"}]}}]}'
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"SignOff","state":"success","description":"Test User signed off"}]}'

  run -0 gh-signoff status
  [[ "$output" == "${STATUS_SUCCESS} signoff" ]] || return 1
}

@test "uninstall removes ruleset and signoff-shaped legacy protection" {
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":["signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -0 gh-signoff uninstall
  [[ "$output" == *"no longer requires signoff"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" == *"DELETE repos/:owner/:repo/rulesets/42"* ]] || return 1
  [[ $'\n'"$calls"$'\n' == *$'\n'"DELETE repos/:owner/:repo/branches/main/protection"$'\n'* ]] || return 1
}

@test "uninstall fails when nothing is installed" {
  run -1 gh-signoff uninstall
  [[ "$output" == *"no signoff requirement installed on main"* ]] || return 1
}

@test "bare uninstall removes signoff contexts from mixed legacy protection" {
  # The protection keeps other-ci and all its other settings; only the
  # signoff contexts are removed, so uninstall's claim is actually true
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":["other-ci","signoff","signoff/tests"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff uninstall
  [[ "$output" == *"no longer requires signoff"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" == *"DELETE repos/:owner/:repo/rulesets/42"* ]] || return 1
  [[ $'\n'"$calls"$'\n' != *$'\n'"DELETE repos/:owner/:repo/branches/main/protection"$'\n'* ]] || return 1
  [[ "$calls" == *"DELETE repos/:owner/:repo/branches/main/protection/required_status_checks/contexts"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"contexts":["signoff","signoff/tests"]}'* ]] || return 1
  [[ "$body" != *"other-ci"* ]] || return 1
}

@test "legacy removal asks for the spelling the protection actually uses" {
  # The context is matched case-insensitively but removed by the name the
  # protection carries: whether that endpoint folds case is undocumented, and
  # asking it to drop a spelling nobody configured is a question worth not
  # asking
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":["other-ci","signoff/Tests"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff uninstall tests
  [[ "$output" == *"no longer requires signoff on tests"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"contexts":["signoff/Tests"]}'* ]] || return 1
}

@test "contextual uninstall removes contexts from mixed legacy protection" {
  # The requested context lives only in mixed legacy protection: it must
  # actually stop being enforced, not survive behind a success message
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":["other-ci","signoff/tests"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff uninstall tests
  [[ "$output" == *"no longer requires signoff on tests"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" == *"DELETE repos/:owner/:repo/branches/main/protection/required_status_checks/contexts"* ]] || return 1
  [[ $'\n'"$calls"$'\n' != *$'\n'"DELETE repos/:owner/:repo/branches/main/protection"$'\n'* ]] || return 1
  # Nothing remains, so no ruleset gets created or updated
  [[ "$calls" != *"POST "* && "$calls" != *"PUT "* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"contexts":["signoff/tests"]}'* ]] || return 1
}

@test "uninstall fails when legacy protection cannot be deleted" {
  # Reporting the requirement removed while legacy protection still enforces
  # it would be a lie; rerunning uninstall retries idempotently
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":["signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_DELETE_PROTECTION_EXIT=1

  run -1 gh-signoff uninstall
  [[ "$output" == *"failed to remove signoff from legacy branch protection"* ]] || return 1
  [[ "$output" != *"no longer requires signoff"* ]] || return 1
}

@test "contextual uninstall fails when legacy contexts cannot be removed" {
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":["other-ci","signoff/tests"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_DELETE_PROTECTION_CONTEXTS_EXIT=1

  run -1 gh-signoff uninstall tests
  [[ "$output" == *"failed to remove signoff from legacy branch protection"* ]] || return 1
  [[ "$output" != *"no longer requires signoff"* ]] || return 1
}

@test "contextual uninstall keeps the remaining contexts" {
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"},{"context":"signoff/tests"},{"context":"signoff/lint"}]}}]}'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff uninstall tests
  [[ "$output" == *"no longer requires signoff on tests"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"PUT repos/:owner/:repo/rulesets/42"$'\n'* ]] || return 1
  [[ "$calls" != *"DELETE "* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"context":"signoff"}'* ]] || return 1
  [[ "$body" == *'{"context":"signoff/lint"}'* ]] || return 1
  [[ "$body" != *'"signoff/tests"'* ]] || return 1
}

@test "contextual uninstall migrates remaining legacy contexts" {
  # No ruleset yet: the contexts live only in legacy protection, so the
  # remainder lands in a fresh ruleset and the legacy protection goes away
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":["signoff","signoff/tests"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff uninstall tests
  [[ "$output" == *"no longer requires signoff on tests"* ]] || return 1
  [[ "$output" == *"Migrated legacy branch protection to a ruleset"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"POST repos/:owner/:repo/rulesets"$'\n'* ]] || return 1
  [[ $'\n'"$calls"$'\n' == *$'\n'"DELETE repos/:owner/:repo/branches/main/protection"$'\n'* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"context":"signoff"}'* ]] || return 1
  [[ "$body" != *'"signoff/tests"'* ]] || return 1
}

@test "contextual uninstall fails when nothing is installed" {
  run -1 gh-signoff uninstall tests
  [[ "$output" == *"no signoff requirement installed on main"* ]] || return 1
}

@test "status shows no signoff required when no protection exists" {
  # Mock: No protection (exit 1), No commit statuses
  export MOCK_BRANCH_PROTECTION_EXIT=1
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  [[ "$output" == *"${STATUS_FAILURE} signoff"* ]] || return 1
}

@test "status shows no signoff required when no signoff contexts exist" {
  # Mock: Protection exists but has no 'signoff/*' contexts, No commit statuses
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["other-ci"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  [[ "$output" == *"${STATUS_FAILURE} signoff"* ]] || return 1
}

@test "status shows successful default signoff" {
  # Mock: Protection requires 'signoff', Commit status has successful 'signoff'
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff","state":"success","description":"Test User signed off"}]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  [[ "$output" == *"${STATUS_SUCCESS} signoff"* ]] || return 1
}

@test "status checks the commit named by --commit" {
  # Mock: Protection requires 'signoff', Commit status has successful 'signoff'
  make_pushed_repo
  export MOCK_EXPECT_COMMIT=$(git rev-parse HEAD~1)
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff","state":"success","description":"Test User signed off"}]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status --commit HEAD~1
  [[ "$output" == *"${STATUS_SUCCESS} signoff"* ]] || return 1
}

@test "status shows missing default signoff" {
  # Mock: Protection requires 'signoff', Commit status is empty
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  [[ "$output" == *"${STATUS_FAILURE} signoff"* ]] || return 1
}

@test "status shows partial signoffs" {
  # Mock: Protection requires 'tests' and 'lint', Commit status only has 'tests'
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff/tests", "signoff/lint"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff/tests","state":"success","description":"Test User signed off"}]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  [[ "$output" == *"${STATUS_SUCCESS} tests"* ]] || return 1
  [[ "$output" == *"${STATUS_FAILURE} lint"* ]] || return 1
}

@test "status shows all signoffs complete with multiple contexts" {
  # Mock: Protection requires 'signoff', 'tests', 'lint'. Commit status has all successful.
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff", "signoff/tests", "signoff/lint"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff","state":"success","description":"Test User signed off"},{"context":"signoff/tests","state":"success","description":"Test User signed off"},{"context":"signoff/lint","state":"success","description":"Test User signed off"}]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  [[ "$output" == *"${STATUS_SUCCESS} signoff"* ]] || return 1
  [[ "$output" == *"${STATUS_SUCCESS} lint"* ]] || return 1
  [[ "$output" == *"${STATUS_SUCCESS} tests"* ]] || return 1
}

# MOCK_CRLF makes the gh mock terminate every line with \r\n, standing in for
# the CRLF a Windows toolchain can hand back. A stray \r turns "success" into a
# state that matches nothing and "signoff" into a second, distinct context, so
# these assert exact output rather than substrings.
@test "status tolerates CRLF from gh on Windows" {
  export MOCK_CRLF=1
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"},{"context":"signoff/tests"}]}}]}'
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff","state":"success","description":"Test User signed off"},{"context":"signoff/tests","state":"success","description":"Test User signed off"}]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  [[ "$output" == "${STATUS_SUCCESS} signoff"$'\n'"${STATUS_SUCCESS} tests" ]] || return 1
}

@test "check tolerates CRLF from gh on Windows" {
  export MOCK_CRLF=1
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"},{"context":"signoff/tests"}]}}]}'

  run -0 gh-signoff check
  [[ "$output" == "${STATUS_SUCCESS} GitHub main branch requires signoff" ]] || return 1
}

@test "check on a named context tolerates CRLF from gh on Windows" {
  export MOCK_CRLF=1
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"},{"context":"signoff/tests"}]}}]}'

  run -0 gh-signoff check tests
  [[ "$output" == "${STATUS_SUCCESS} GitHub main branch requires signoff on tests" ]] || return 1
}

@test "status matches signoff states by exact record, not substring" {
  # 'signoff/foosignoff/tests' succeeded, but that must not satisfy the
  # required 'signoff/tests'; likewise 'signoff/foo-signoff' must not
  # satisfy plain 'signoff'
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff/tests"}]}}]}'
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff/foosignoff/tests","state":"success","description":"x"},{"context":"signoff/foo-signoff","state":"success","description":"x"}]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  [[ $'\n'"$output"$'\n' == *$'\n'"${STATUS_FAILURE} signoff"$'\n'* ]] || return 1
  [[ $'\n'"$output"$'\n' == *$'\n'"${STATUS_FAILURE} tests"$'\n'* ]] || return 1
}

@test "status does not display foreign signoff-prefixed statuses" {
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff","state":"success","description":"Test User signed off"},{"context":"signoff-security","state":"success","description":"Some scanner"}]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  [[ "$output" == *"${STATUS_SUCCESS} signoff"* ]] || return 1
  [[ "$output" != *"signoff-security"* ]] || return 1
}

@test "status shows signoffs even without branch protection" {
  # Mock: No protection (exit 1), Commit status has 'tests' and 'lint' successful
  export MOCK_BRANCH_PROTECTION_EXIT=1
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff/tests","state":"success","description":"Test User signed off"},{"context":"signoff/lint","state":"success","description":"Test User signed off"}]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  # Check that both contexts appear in the output with success markers
  [[ "$output" == *"${STATUS_SUCCESS} tests"* ]] || return 1
  [[ "$output" == *"${STATUS_SUCCESS} lint"* ]] || return 1
}

@test "status shows partial complete signoffs without branch protection" {
  # Mock: No protection (exit 1), Commit status has 'tests' success but 'lint' failure
  export MOCK_BRANCH_PROTECTION_EXIT=1
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff/tests","state":"success","description":"Test User signed off"},{"context":"signoff/lint","state":"failure","description":"Lint checks failed"}]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  [[ "$output" == *"${STATUS_SUCCESS} tests"* ]] || return 1
  [[ "$output" == *"${STATUS_FAILURE} lint"* ]] || return 1
}

@test "status handles commit status API failure gracefully" {
  # Mock: Commit status API fails
  export MOCK_COMMIT_STATUS_EXIT=1

  run -1 gh-signoff status
  [[ "$output" == *"Could not get status for commit"* ]] || return 1
}

# Exact output, for the same reason as the check test above
@test "status reports only the negative result when the status API fails" {
  # Mock: Commit status API fails
  export MOCK_COMMIT_STATUS_EXIT=1
  local sha
  sha=$(git rev-parse HEAD)

  run -1 gh-signoff status
  [[ "$output" == "${STATUS_FAILURE} Could not get status for commit ${sha}" ]] || return 1
}

@test "direct signoff with unknown option shows help" {
  run -1 gh-signoff --unknown-option
  [[ "$output" == *"USAGE"* ]] || return 1
  [[ "$output" == *"COMMANDS"* ]] || return 1
}

@test "direct signoff with -f creates default signoff" {
  export MOCK_POST_STATUS_EXIT=0
  run -0 gh-signoff -f
  [[ "$output" == *"Signed off on"* ]] || return 1
  [[ ! "$output" == *"for"* ]] || return 1  # Should not have "for" in output
}

@test "direct signoff fails when commit status API fails" {
  export MOCK_POST_STATUS_EXIT=1
  run -1 gh-signoff tests -f
  [[ "$output" == *"Failed to sign off on"*"for tests"* ]] || return 1
}

# Cleanliness check tests (is_clean)
@test "signoff succeeds via upstream fallback when @{push} does not resolve" {
  # push.default=simple: @{push} fails for a branch whose name differs from
  # its upstream's, but @{upstream} still proves HEAD is on the remote
  make_nested_repo
  add_bare_remote
  git push -q origin HEAD:some-branch
  git checkout -q -b ci/gate
  git branch -q --set-upstream-to=origin/some-branch
  git config push.default simple

  run -0 gh-signoff
  [[ "$output" == *"Signed off on"* ]] || return 1
}

@test "signoff via upstream fallback still catches unpushed changes" {
  make_nested_repo
  add_bare_remote
  git push -q origin HEAD:some-branch
  git checkout -q -b ci/gate
  git branch -q --set-upstream-to=origin/some-branch
  git config push.default simple
  git commit --no-gpg-sign --allow-empty -m "Unpushed commit" >/dev/null

  run -1 gh-signoff
  [[ "$output" == *"unpushed changes"* ]] || return 1

  run -0 gh-signoff -f
  [[ "$output" == *"Signed off on"* ]] || return 1
}

@test "signoff fails with clear message when no push destination or upstream" {
  make_nested_repo

  run -1 gh-signoff
  [[ "$output" == *"cannot verify the current branch is pushed"* ]] || return 1

  run -0 gh-signoff -f
  [[ "$output" == *"Signed off on"* ]] || return 1
}

@test "upstream fallback refuses when pushes are rerouted to another remote" {
  # Triangular two-remote setup: upstream origin/main contains HEAD, but
  # remote.pushDefault sends pushes to fork, whose ci/gate is not up to date.
  # @{push} fails to resolve (fork/ci/gate was never fetched); falling back
  # to the upstream would approve a SHA absent from the real push destination.
  make_nested_repo
  add_bare_remote
  git push -q origin HEAD:main
  git init -q --bare "$TEST_DIR/fork.git"
  git remote add fork "$TEST_DIR/fork.git"
  git checkout -q -b ci/gate
  git branch -q --set-upstream-to=origin/main
  git config push.default simple

  git config remote.pushDefault fork
  ! git rev-parse --abbrev-ref "@{push}" >/dev/null 2>&1 || return 1
  run -1 gh-signoff
  [[ "$output" == *"cannot verify the current branch is pushed"* ]] || return 1
  git config --unset remote.pushDefault

  git config branch.ci/gate.pushRemote fork
  run -1 gh-signoff
  [[ "$output" == *"cannot verify the current branch is pushed"* ]] || return 1
  git config --unset branch.ci/gate.pushRemote

  git config remote.origin.push "refs/heads/*:refs/heads/qa/*"
  run -1 gh-signoff
  [[ "$output" == *"cannot verify the current branch is pushed"* ]] || return 1
  git config --unset remote.origin.push

  # With no rerouting config the fallback engages again
  run -0 gh-signoff
  [[ "$output" == *"Signed off on"* ]] || return 1
}

@test "upstream fallback refuses when fetch and push URLs differ" {
  # remote.<name>.pushurl and url.*.pushInsteadOf send pushes to a different
  # repository than fetches come from; multiple push URLs have no single
  # destination. The upstream ref proves nothing about any of them.
  make_nested_repo
  add_bare_remote
  git push -q origin HEAD:main
  git init -q --bare "$TEST_DIR/fork.git"
  git checkout -q -b ci/gate
  git branch -q --set-upstream-to=origin/main
  git config push.default simple

  git config remote.origin.pushurl "$TEST_DIR/fork.git"
  run -1 gh-signoff
  [[ "$output" == *"cannot verify the current branch is pushed"* ]] || return 1
  git config --unset remote.origin.pushurl

  git config "url.$TEST_DIR/fork.git.pushInsteadOf" "$TEST_DIR/remote.git"
  run -1 gh-signoff
  [[ "$output" == *"cannot verify the current branch is pushed"* ]] || return 1
  git config --remove-section "url.$TEST_DIR/fork.git"

  git config remote.origin.pushurl "$TEST_DIR/remote.git"
  git config --add remote.origin.pushurl "$TEST_DIR/fork.git"
  run -1 gh-signoff
  [[ "$output" == *"cannot verify the current branch is pushed"* ]] || return 1
  git config --unset-all remote.origin.pushurl

  # With fetch and push URLs identical again the fallback engages
  run -0 gh-signoff
  [[ "$output" == *"Signed off on"* ]] || return 1
}

@test "upstream fallback refuses unless effective push.default is simple" {
  # current would create the not-yet-existing origin/ci/gate; nothing and
  # matching have no single destination. In each, @{push} fails to resolve
  # and the upstream must not stand in for it.
  make_nested_repo
  add_bare_remote
  git push -q origin HEAD:main
  git checkout -q -b ci/gate
  git branch -q --set-upstream-to=origin/main

  for mode in current nothing matching; do
    git config push.default "$mode"
    ! git rev-parse --abbrev-ref "@{push}" >/dev/null 2>&1 || return 1
    run -1 gh-signoff
    [[ "$output" == *"cannot verify the current branch is pushed"* ]] || return 1
  done

  # The centralized renamed-branch case still succeeds
  git config push.default simple
  run -0 gh-signoff
  [[ "$output" == *"Signed off on"* ]] || return 1
}

@test "upstream fallback refuses a purely local upstream" {
  make_nested_repo
  git branch -q base
  git checkout -q -b ci/gate
  git branch -q --set-upstream-to=base
  git config push.default simple
  [[ "$(git config branch.ci/gate.remote)" == "." ]] || return 1

  run -1 gh-signoff
  [[ "$output" == *"cannot verify the current branch is pushed"* ]] || return 1

  run -0 gh-signoff -f
  [[ "$output" == *"Signed off on"* ]] || return 1
}

@test "signoff succeeds on a branch checked out from a fork pull request" {
  # A URL-valued remote has no remote-tracking ref, so neither @{push} nor
  # @{upstream} resolves and `git remote get-url` has no remote to look up.
  # The fork itself is the only witness that HEAD is published.
  make_nested_repo
  checkout_fork_pull_request

  ! git rev-parse --abbrev-ref "@{push}" >/dev/null 2>&1 || return 1
  ! git rev-parse --abbrev-ref "@{upstream}" >/dev/null 2>&1 || return 1
  ! git remote get-url --all "$TEST_DIR/fork.git" >/dev/null 2>&1 || return 1

  run -0 gh-signoff
  [[ "$output" == *"Signed off on"* ]] || return 1
}

@test "fork pull request signoff accepts a commit contained in the fork's tip" {
  # The tip object is here, so its ancestry is checkable locally, and a
  # repository holding a commit holds every ancestor of it
  make_nested_repo
  git checkout -q -b their-branch
  git commit --no-gpg-sign --allow-empty -m "Their newer commit" >/dev/null
  git init -q --bare "$TEST_DIR/fork.git"
  git push -q "$TEST_DIR/fork.git" HEAD:refs/heads/their-branch
  git reset -q --hard HEAD^
  track_url_remote "$TEST_DIR/fork.git" refs/heads/their-branch

  run -0 gh-signoff
  [[ "$output" == *"Signed off on"* ]] || return 1
}

@test "fork pull request signoff still catches unpushed changes" {
  make_nested_repo
  checkout_fork_pull_request
  git commit --no-gpg-sign --allow-empty -m "Unpushed commit" >/dev/null

  run -1 gh-signoff
  [[ "$output" == *"unpushed changes"* ]] || return 1

  run -0 gh-signoff -f
  [[ "$output" == *"Signed off on"* ]] || return 1
}

@test "fork pull request signoff refuses when the fork's tip is not in this repository" {
  # ls-remote advertises ref tips, not history: with the tip object absent
  # there is nothing to compute containment against, and proving HEAD is on
  # the fork would mean fetching
  make_nested_repo
  checkout_fork_pull_request
  git clone -q --branch their-branch "$TEST_DIR/fork.git" "$TEST_DIR/contributor"
  git -C "$TEST_DIR/contributor" config user.name "Contributor"
  git -C "$TEST_DIR/contributor" commit --no-gpg-sign --allow-empty -m "Their newer commit" >/dev/null
  git -C "$TEST_DIR/contributor" push -q origin HEAD:refs/heads/their-branch

  run -1 gh-signoff
  [[ "$output" == *"which is not in this repository"* ]] || return 1

  run -0 gh-signoff -f
  [[ "$output" == *"Signed off on"* ]] || return 1
}

@test "fork pull request signoff refuses when the tracked ref is absent from the fork" {
  make_nested_repo
  checkout_fork_pull_request
  git config branch.their-branch.merge refs/heads/never-pushed

  run -1 gh-signoff
  [[ "$output" == *"unpushed changes"* ]] || return 1
  [[ "$output" == *"refs/heads/never-pushed does not exist"* ]] || return 1
}

@test "fork pull request signoff refuses when the fork cannot be reached" {
  make_nested_repo
  checkout_fork_pull_request
  track_url_remote "$TEST_DIR/no-such-fork.git" refs/heads/their-branch

  run -1 gh-signoff
  [[ "$output" == *"could not be reached"* ]] || return 1

  run -0 gh-signoff -f
  [[ "$output" == *"Signed off on"* ]] || return 1
}

@test "fork pull request signoff refuses when the push destination is not that URL" {
  # Proving HEAD is on the fork says nothing if a push would land elsewhere,
  # so the same routing allowlist as the @{upstream} fallback applies
  make_nested_repo
  checkout_fork_pull_request
  git init -q --bare "$TEST_DIR/elsewhere.git"

  for mode in current nothing matching; do
    git config push.default "$mode"
    run -1 gh-signoff
    [[ "$output" == *"tracks $TEST_DIR/fork.git as a URL"* ]] || return 1
  done
  git config push.default simple

  git config branch.their-branch.pushremote "$TEST_DIR/elsewhere.git"
  run -1 gh-signoff
  [[ "$output" == *"tracks $TEST_DIR/fork.git as a URL"* ]] || return 1
  git config branch.their-branch.pushremote "$TEST_DIR/fork.git"

  git config remote.pushDefault "$TEST_DIR/elsewhere.git"
  git config --unset branch.their-branch.pushremote
  run -1 gh-signoff
  [[ "$output" == *"tracks $TEST_DIR/fork.git as a URL"* ]] || return 1
  git config --unset remote.pushDefault

  # url.*.pushInsteadOf rewrites push URLs, and git offers no way to expand
  # the push side of an anonymous remote to compare against
  git config "url.$TEST_DIR/elsewhere.git.pushInsteadOf" "$TEST_DIR/fork.git"
  run -1 gh-signoff
  [[ "$output" == *"tracks $TEST_DIR/fork.git as a URL"* ]] || return 1
  git config --remove-section "url.$TEST_DIR/elsewhere.git"

  git config --unset branch.their-branch.merge
  run -1 gh-signoff
  [[ "$output" == *"tracks $TEST_DIR/fork.git as a URL"* ]] || return 1
  git config branch.their-branch.merge refs/heads/their-branch

  # With nothing rerouting the push away from the tracked URL, the proof engages
  run -0 gh-signoff
  [[ "$output" == *"Signed off on"* ]] || return 1
}

@test "signoff fails with uncommitted changes message for dirty worktree" {
  make_nested_repo
  touch untracked-file

  run -1 gh-signoff
  [[ "$output" == *"repository has uncommitted changes"* ]] || return 1

  run -0 gh-signoff -f
  [[ "$output" == *"Signed off on"* ]] || return 1
}



# Leading -f dispatcher grammar tests
@test "an explicitly empty context is rejected, however it is spelled" {
  # `gh signoff -f '' good` once took the bare-default path — matching on the
  # first arg's VALUE conflated "no argument" with "an empty first argument",
  # so it silently dropped both `''` and `good` and signed off bare. An empty
  # positional is an invalid context, not an absent one, whichever entry point
  # reaches cmd_create.
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -1 gh-signoff -f '' good
  [[ "$output" == *"may contain letters, digits"* ]] || return 1

  run -1 gh-signoff '' good
  [[ "$output" == *"may contain letters, digits"* ]] || return 1

  run -1 gh-signoff create -f '' good
  [[ "$output" == *"may contain letters, digits"* ]] || return 1

  run -1 gh-signoff -f ''
  [[ "$output" == *"may contain letters, digits"* ]] || return 1

  # None of those reached the status API
  [[ ! -s "$MOCK_CALL_LOG" ]] || return 1
}

@test "bare signoff with no context still defaults" {
  # The other side of the fix: a genuinely empty argument list is the bare
  # default signoff and must keep working. `gh signoff -f` is exactly the
  # $# -eq 0 branch the fix added; a clean-tree plain `gh signoff` is covered
  # elsewhere, so -f and explicit create carry the defaulting here.
  run -0 gh-signoff -f
  [[ "$output" == *"Signed off on"* ]] || return 1
  [[ ! "$output" == *"for"* ]] || return 1

  run -0 gh-signoff create -f
  [[ "$output" == *"Signed off on"* ]] || return 1
  [[ ! "$output" == *"for"* ]] || return 1
}

@test "leading -f applies to contextual signoff" {
  run -0 gh-signoff -f linux
  [[ "$output" == *"Signed off on"* ]] || return 1
  [[ "$output" == *"for linux"* ]] || return 1
}

@test "leading -f with explicit create signs off on default context" {
  run -0 gh-signoff -f create
  [[ "$output" == *"Signed off on"* ]] || return 1
  [[ ! "$output" == *"for"* ]] || return 1
}

@test "leading -f is rejected for non-create commands" {
  run -1 gh-signoff -f status
  [[ "$output" == *"-f is only valid for create"* ]] || return 1
}

# Leading --commit dispatcher grammar tests
@test "leading --commit is rejected for commands that do not take it" {
  # Both orders must give the same answer. The leading form is also the
  # regression test against resolving the revision before the command is known.
  for args in "install --commit nope" "--commit nope install" \
              "uninstall --commit nope" "--commit nope uninstall" \
              "check --commit nope" "--commit nope check"; do
    run -1 gh-signoff $args
    [[ "$output" == *"--commit is only valid for create and status"* ]] || return 1
    [[ ! "$output" == *"invalid commit"* ]] || return 1
  done
}

@test "leading --commit requires an argument" {
  run -1 gh-signoff --commit
  [[ "$output" == *"option --commit requires an argument"* ]] || return 1

  run -1 gh-signoff --commit -f
  [[ "$output" == *"option --commit requires an argument"* ]] || return 1
}

@test "leading --commit passes its argument through as one word" {
  run -1 gh-signoff --commit "foo bar"
  [[ "$output" == *"invalid commit: foo bar"* ]] || return 1
}

@test "trailing arguments are reported rather than ignored" {
  run -1 gh-signoff version --commit nope
  [[ "$output" == *"unexpected argument: --commit"* ]] || return 1
}

@test "--branch with no argument reports the missing argument" {
  # $2 was read unguarded, so set -u killed the script before the check ran
  for command in install uninstall check status; do
    run -1 gh-signoff "$command" --branch
    [[ "$output" == *"option --branch requires an argument"* ]] || return 1
    [[ ! "$output" == *"unbound variable"* ]] || return 1
  done
}

@test "-f after a non-create command is rejected the same as before it" {
  for command in install uninstall check status; do
    run -1 gh-signoff "$command" -f
    [[ "$output" == *"-f is only valid for create"* ]] || return 1
  done
}

@test "@{push} stays authoritative over upstream when both resolve" {
  # Triangular setup: feature tracks origin/main (which contains HEAD), but
  # push.default=current resolves @{push} to origin/feature, which lacks HEAD.
  # The upstream fallback must not engage.
  make_nested_repo
  add_bare_remote
  git checkout -q -b feature
  git push -q origin feature
  git commit --no-gpg-sign --allow-empty -m "Second commit" >/dev/null
  git push -q origin HEAD:main
  git branch -q --set-upstream-to=origin/main
  git config push.default current

  run -1 gh-signoff
  [[ "$output" == *"unpushed changes"* ]] || return 1
}
