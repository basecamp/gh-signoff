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

@test "create signs off on specified sha" {
  export MOCK_EXPECT_STATUS_SHA=abc123
  run -0 gh-signoff create --sha abc123
  [[ "$output" == *"Signed off on abc123"* ]]
  unset MOCK_EXPECT_STATUS_SHA
}

@test "direct signoff signs off on specified sha" {
  export MOCK_EXPECT_STATUS_SHA=def456
  run -0 gh-signoff --sha def456
  [[ "$output" == *"Signed off on def456"* ]]
  unset MOCK_EXPECT_STATUS_SHA
}

@test "direct partial signoff signs off on specified sha" {
  export MOCK_EXPECT_STATUS_SHA=def456
  run -0 gh-signoff --sha def456 linux
  [[ "$output" == *"Signed off on def456 for linux"* ]]
  unset MOCK_EXPECT_STATUS_SHA
}

@test "check shows status for protected branch" {
  # Simulate protection requiring default signoff
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  run -0 gh-signoff check
  [[ "$output" == *"requires signoff"* ]] || return 1
}

@test "install enables protection" {
  # Expect PUT protection call to succeed
  export MOCK_PUT_PROTECTION_EXIT=0
  run -0 gh-signoff install
  [[ "$output" == *"now requires signoff"* ]] || return 1
}

@test "uninstall removes protection" {
  # Expect DELETE protection call to succeed
  export MOCK_DELETE_PROTECTION_EXIT=0
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

@test "install with context enables contextual protection" {
  # Expect PUT protection call to succeed
  export MOCK_PUT_PROTECTION_EXIT=0
  run -0 gh-signoff install windows
  [[ "$output" == *"now requires signoff on windows"* ]] || return 1
}

@test "check with context shows contextual status" {
  # Simulate protection requiring 'linux' signoff
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

@test "uninstall with context removes contextual protection" {
  # Expect DELETE protection call to succeed
  export MOCK_DELETE_PROTECTION_EXIT=0
  run -0 gh-signoff uninstall macos
  [[ "$output" == *"no longer requires signoff on macos"* ]] || return 1
}

@test "install with branch and context arguments" {
  # Expect PUT protection call to succeed
  export MOCK_PUT_PROTECTION_EXIT=0
  run -0 gh-signoff install --branch main linux
  [[ "$output" == *"now requires signoff on linux"* ]] || return 1
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

@test "status checks specified sha" {
  # Mock: Protection requires 'signoff', Commit status has successful 'signoff'
  export MOCK_EXPECT_STATUS_SHA=abc123
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff","state":"success","description":"Test User signed off"}]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status --sha abc123
  [[ "$output" == *"${STATUS_SUCCESS} signoff"* ]]

  unset MOCK_EXPECT_STATUS_SHA MOCK_BRANCH_PROTECTION_JSON MOCK_BRANCH_PROTECTION_EXIT MOCK_COMMIT_STATUS_JSON MOCK_COMMIT_STATUS_EXIT
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
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff", "signoff/tests"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff","state":"success","description":"Test User signed off"},{"context":"signoff/tests","state":"success","description":"Test User signed off"}]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  [[ "$output" == "${STATUS_SUCCESS} signoff"$'\n'"${STATUS_SUCCESS} tests" ]] || return 1
}

@test "check tolerates CRLF from gh on Windows" {
  export MOCK_CRLF=1
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff", "signoff/tests"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0

  run -0 gh-signoff check
  [[ "$output" == "${STATUS_SUCCESS} GitHub main branch requires signoff" ]] || return 1
}

@test "check on a named context tolerates CRLF from gh on Windows" {
  export MOCK_CRLF=1
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff", "signoff/tests"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0

  run -0 gh-signoff check tests
  [[ "$output" == "${STATUS_SUCCESS} GitHub main branch requires signoff on tests" ]] || return 1
}

@test "completion contexts tolerate CRLF from gh on Windows" {
  export MOCK_CRLF=1
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff", "signoff/tests", "signoff/lint"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0

  run -0 gh-signoff completion --contexts
  [[ "$output" == "tests"$'\n'"lint" ]] || return 1
}

@test "completion contexts are empty when only plain signoff is required" {
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0

  run -0 gh-signoff completion --contexts
  [[ -z "$output" ]] || return 1
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

@test "completion --contexts returns signoff contexts" {
  # Mock: Branch protection has signoff contexts
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff", "signoff/tests", "signoff/lint"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0

  run -0 gh-signoff completion --contexts
  [[ "$output" == *"tests"* ]] || return 1
  [[ "$output" == *"lint"* ]] || return 1
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

# Completion tests for the leading -f grammar. Loads the generated completion
# function and invokes it directly with a simulated command line.
complete_words() {
  eval "$(gh-signoff completion)"
  COMP_WORDS=("$@" "")
  COMP_CWORD=$#
  COMPREPLY=()
  _gh_signoff
}

@test "completion after leading -f offers create plus contexts" {
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff/linux"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0

  complete_words gh-signoff -f
  [[ " ${COMPREPLY[*]-} " == *" create "* ]] || return 1
  [[ " ${COMPREPLY[*]-} " == *" linux "* ]] || return 1
  [[ ! " ${COMPREPLY[*]-} " == *" status "* ]] || return 1
  [[ ! " ${COMPREPLY[*]-} " == *" install "* ]] || return 1
}

@test "completion after -f create offers contexts only" {
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff/linux"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0

  complete_words gh-signoff -f create
  [[ " ${COMPREPLY[*]-} " == *" linux "* ]] || return 1
  [[ ! " ${COMPREPLY[*]-} " == *" create "* ]] || return 1
  [[ ! " ${COMPREPLY[*]-} " == *" --branch "* ]] || return 1
}

@test "completion after trailing -f offers contexts without create" {
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff/linux"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0

  complete_words gh-signoff linux -f
  [[ " ${COMPREPLY[*]-} " == *" linux "* ]] || return 1
  [[ ! " ${COMPREPLY[*]-} " == *" create "* ]] || return 1
}

# Leading -f dispatcher grammar tests
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
