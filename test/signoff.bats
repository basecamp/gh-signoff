#!/usr/bin/env bats

# Require minimum bats version for run -N syntax
bats_require_minimum_version 1.5.0

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
  [[ -z "$(git status --porcelain)" ]]
}

# Add a bare remote to the nested repository
add_bare_remote() {
  git init -q --bare "$TEST_DIR/remote.git"
  git remote add origin "$TEST_DIR/remote.git"
}

# Basic command tests
@test "shows help with -h" {
  run -0 gh-signoff -h
  [[ "$output" == *"USAGE"* ]]
  [[ "$output" == *"COMMANDS"* ]]
}

@test "shows version" {
  run -0 gh-signoff version
  [[ "$output" == "gh-signoff"* ]]
}

@test "create signs off on current commit" {
  run -0 gh-signoff create -f
  [[ "$output" == *"Signed off on"* ]]
}

@test "check shows status for protected branch" {
  # Simulate protection requiring default signoff
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  run -0 gh-signoff check
  [[ "$output" == *"requires signoff"* ]]
  # Unset for subsequent tests (though subshell isolation should handle this)
  unset MOCK_BRANCH_PROTECTION_JSON MOCK_BRANCH_PROTECTION_EXIT
}

@test "install enables protection" {
  # Expect PUT protection call to succeed
  export MOCK_PUT_PROTECTION_EXIT=0
  run -0 gh-signoff install
  [[ "$output" == *"now requires signoff"* ]]
  unset MOCK_PUT_PROTECTION_EXIT
}

@test "uninstall removes protection" {
  # Expect DELETE protection call to succeed
  export MOCK_DELETE_PROTECTION_EXIT=0
  run -0 gh-signoff uninstall
  [[ "$output" == *"no longer requires signoff"* ]]
  unset MOCK_DELETE_PROTECTION_EXIT
}

# Context support tests
@test "create signs off with positional argument" {
  # Expect POST status call to succeed
  export MOCK_POST_STATUS_EXIT=0
  run -0 gh-signoff create -f linux
  [[ "$output" == *"Signed off on"* ]]
  [[ "$output" == *"for linux"* ]]
  unset MOCK_POST_STATUS_EXIT
}

@test "direct partial signoff" {
  # Expect POST status call to succeed
  export MOCK_POST_STATUS_EXIT=0
  run -0 gh-signoff linux -f
  [[ "$output" == *"Signed off on"* ]]
  [[ "$output" == *"for linux"* ]]
  unset MOCK_POST_STATUS_EXIT
}

@test "direct multiple partial signoff" {
  # Expect POST status call to succeed
  export MOCK_POST_STATUS_EXIT=0
  run -0 gh-signoff linux macos windows -f
  [[ "$output" == *"for linux"* ]]
  [[ "$output" == *"for macos"* ]]
  [[ "$output" == *"for windows"* ]]
  unset MOCK_POST_STATUS_EXIT
}

@test "install with context enables contextual protection" {
  # Expect PUT protection call to succeed
  export MOCK_PUT_PROTECTION_EXIT=0
  run -0 gh-signoff install windows
  [[ "$output" == *"now requires signoff on windows"* ]]
  unset MOCK_PUT_PROTECTION_EXIT
}

@test "check with context shows contextual status" {
  # Simulate protection requiring 'linux' signoff
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff/linux"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  run -0 gh-signoff check linux
  [[ "$output" == *"requires signoff on linux"* ]]
  unset MOCK_BRANCH_PROTECTION_JSON MOCK_BRANCH_PROTECTION_EXIT
}

@test "check with missing context shows negative status" {
  # Simulate protection requiring only default signoff
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  run -0 gh-signoff check windows
  [[ "$output" == *"does not require signoff on windows"* ]]
  unset MOCK_BRANCH_PROTECTION_JSON MOCK_BRANCH_PROTECTION_EXIT
}

@test "uninstall with context removes contextual protection" {
  # Expect DELETE protection call to succeed
  export MOCK_DELETE_PROTECTION_EXIT=0
  run -0 gh-signoff uninstall macos
  [[ "$output" == *"no longer requires signoff on macos"* ]]
  unset MOCK_DELETE_PROTECTION_EXIT
}

@test "install with branch and context arguments" {
  # Expect PUT protection call to succeed
  export MOCK_PUT_PROTECTION_EXIT=0
  run -0 gh-signoff install --branch main linux
  [[ "$output" == *"now requires signoff on linux"* ]]
  unset MOCK_PUT_PROTECTION_EXIT
}

@test "status shows no signoff required when no protection exists" {
  # Mock: No protection (exit 1), No commit statuses
  export MOCK_BRANCH_PROTECTION_EXIT=1
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  [[ "$output" == *"${STATUS_FAILURE} signoff"* ]]

  unset MOCK_BRANCH_PROTECTION_EXIT MOCK_COMMIT_STATUS_JSON MOCK_COMMIT_STATUS_EXIT
}

@test "status shows no signoff required when no signoff contexts exist" {
  # Mock: Protection exists but has no 'signoff/*' contexts, No commit statuses
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["other-ci"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  [[ "$output" == *"${STATUS_FAILURE} signoff"* ]]

  unset MOCK_BRANCH_PROTECTION_JSON MOCK_BRANCH_PROTECTION_EXIT MOCK_COMMIT_STATUS_JSON MOCK_COMMIT_STATUS_EXIT
}

@test "status shows successful default signoff" {
  # Mock: Protection requires 'signoff', Commit status has successful 'signoff'
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff","state":"success","description":"Test User signed off"}]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  [[ "$output" == *"${STATUS_SUCCESS} signoff"* ]]

  unset MOCK_BRANCH_PROTECTION_JSON MOCK_BRANCH_PROTECTION_EXIT MOCK_COMMIT_STATUS_JSON MOCK_COMMIT_STATUS_EXIT
}

@test "status shows missing default signoff" {
  # Mock: Protection requires 'signoff', Commit status is empty
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  [[ "$output" == *"${STATUS_FAILURE} signoff"* ]]

  unset MOCK_BRANCH_PROTECTION_JSON MOCK_BRANCH_PROTECTION_EXIT MOCK_COMMIT_STATUS_JSON MOCK_COMMIT_STATUS_EXIT
}

@test "status shows partial signoffs" {
  # Mock: Protection requires 'tests' and 'lint', Commit status only has 'tests'
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff/tests", "signoff/lint"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff/tests","state":"success","description":"Test User signed off"}]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  [[ "$output" == *"${STATUS_SUCCESS} tests"* ]]
  [[ "$output" == *"${STATUS_FAILURE} lint"* ]]

  unset MOCK_BRANCH_PROTECTION_JSON MOCK_BRANCH_PROTECTION_EXIT MOCK_COMMIT_STATUS_JSON MOCK_COMMIT_STATUS_EXIT
}

@test "status shows all signoffs complete with multiple contexts" {
  # Mock: Protection requires 'signoff', 'tests', 'lint'. Commit status has all successful.
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff", "signoff/tests", "signoff/lint"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff","state":"success","description":"Test User signed off"},{"context":"signoff/tests","state":"success","description":"Test User signed off"},{"context":"signoff/lint","state":"success","description":"Test User signed off"}]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  [[ "$output" == *"${STATUS_SUCCESS} signoff"* ]]
  [[ "$output" == *"${STATUS_SUCCESS} lint"* ]]
  [[ "$output" == *"${STATUS_SUCCESS} tests"* ]]

  unset MOCK_BRANCH_PROTECTION_JSON MOCK_BRANCH_PROTECTION_EXIT MOCK_COMMIT_STATUS_JSON MOCK_COMMIT_STATUS_EXIT
}

@test "status shows signoffs even without branch protection" {
  # Mock: No protection (exit 1), Commit status has 'tests' and 'lint' successful
  export MOCK_BRANCH_PROTECTION_EXIT=1
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff/tests","state":"success","description":"Test User signed off"},{"context":"signoff/lint","state":"success","description":"Test User signed off"}]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  # Check that both contexts appear in the output with success markers
  [[ "$output" == *"${STATUS_SUCCESS} tests"* ]]
  [[ "$output" == *"${STATUS_SUCCESS} lint"* ]]

  unset MOCK_BRANCH_PROTECTION_EXIT MOCK_COMMIT_STATUS_JSON MOCK_COMMIT_STATUS_EXIT
}

@test "status shows partial complete signoffs without branch protection" {
  # Mock: No protection (exit 1), Commit status has 'tests' success but 'lint' failure
  export MOCK_BRANCH_PROTECTION_EXIT=1
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff/tests","state":"success","description":"Test User signed off"},{"context":"signoff/lint","state":"failure","description":"Lint checks failed"}]}'
  export MOCK_COMMIT_STATUS_EXIT=0

  run -0 gh-signoff status
  [[ "$output" == *"${STATUS_SUCCESS} tests"* ]]
  [[ "$output" == *"${STATUS_FAILURE} lint"* ]]

  unset MOCK_BRANCH_PROTECTION_EXIT MOCK_COMMIT_STATUS_JSON MOCK_COMMIT_STATUS_EXIT
}

@test "status handles commit status API failure gracefully" {
  # Mock: Commit status API fails
  export MOCK_COMMIT_STATUS_EXIT=1

  run -1 gh-signoff status
  [[ "$output" == *"Could not get status for commit"* ]]

  unset MOCK_COMMIT_STATUS_EXIT
}

@test "completion --contexts returns signoff contexts" {
  # Mock: Branch protection has signoff contexts
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff", "signoff/tests", "signoff/lint"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0

  run -0 gh-signoff completion --contexts
  [[ "$output" == *"tests"* ]]
  [[ "$output" == *"lint"* ]]

  unset MOCK_BRANCH_PROTECTION_JSON MOCK_BRANCH_PROTECTION_EXIT
}

@test "direct signoff with unknown option shows help" {
  run -1 gh-signoff --unknown-option
  [[ "$output" == *"USAGE"* ]]
  [[ "$output" == *"COMMANDS"* ]]
}

@test "direct signoff with -f creates default signoff" {
  export MOCK_POST_STATUS_EXIT=0
  run -0 gh-signoff -f
  [[ "$output" == *"Signed off on"* ]]
  [[ ! "$output" == *"for"* ]]  # Should not have "for" in output
  unset MOCK_POST_STATUS_EXIT
}

@test "direct signoff fails when commit status API fails" {
  export MOCK_POST_STATUS_EXIT=1
  run -1 gh-signoff tests -f
  [[ "$output" == *"Failed to sign off on"*"for tests"* ]]
  unset MOCK_POST_STATUS_EXIT
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
  [[ "$output" == *"Signed off on"* ]]
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
  [[ "$output" == *"unpushed changes"* ]]

  run -0 gh-signoff -f
  [[ "$output" == *"Signed off on"* ]]
}

@test "signoff fails with clear message when no push destination or upstream" {
  make_nested_repo

  run -1 gh-signoff
  [[ "$output" == *"cannot verify the current branch is pushed"* ]]

  run -0 gh-signoff -f
  [[ "$output" == *"Signed off on"* ]]
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
  ! git rev-parse --abbrev-ref "@{push}" >/dev/null 2>&1
  run -1 gh-signoff
  [[ "$output" == *"cannot verify the current branch is pushed"* ]]
  git config --unset remote.pushDefault

  git config branch.ci/gate.pushRemote fork
  run -1 gh-signoff
  [[ "$output" == *"cannot verify the current branch is pushed"* ]]
  git config --unset branch.ci/gate.pushRemote

  git config remote.origin.push "refs/heads/*:refs/heads/qa/*"
  run -1 gh-signoff
  [[ "$output" == *"cannot verify the current branch is pushed"* ]]
  git config --unset remote.origin.push

  # With no rerouting config the fallback engages again
  run -0 gh-signoff
  [[ "$output" == *"Signed off on"* ]]
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
  [[ "$output" == *"cannot verify the current branch is pushed"* ]]
  git config --unset remote.origin.pushurl

  git config "url.$TEST_DIR/fork.git.pushInsteadOf" "$TEST_DIR/remote.git"
  run -1 gh-signoff
  [[ "$output" == *"cannot verify the current branch is pushed"* ]]
  git config --remove-section "url.$TEST_DIR/fork.git"

  git config remote.origin.pushurl "$TEST_DIR/remote.git"
  git config --add remote.origin.pushurl "$TEST_DIR/fork.git"
  run -1 gh-signoff
  [[ "$output" == *"cannot verify the current branch is pushed"* ]]
  git config --unset-all remote.origin.pushurl

  # With fetch and push URLs identical again the fallback engages
  run -0 gh-signoff
  [[ "$output" == *"Signed off on"* ]]
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
    ! git rev-parse --abbrev-ref "@{push}" >/dev/null 2>&1
    run -1 gh-signoff
    [[ "$output" == *"cannot verify the current branch is pushed"* ]]
  done

  # The centralized renamed-branch case still succeeds
  git config push.default simple
  run -0 gh-signoff
  [[ "$output" == *"Signed off on"* ]]
}

@test "upstream fallback refuses a purely local upstream" {
  make_nested_repo
  git branch -q base
  git checkout -q -b ci/gate
  git branch -q --set-upstream-to=base
  git config push.default simple
  [[ "$(git config branch.ci/gate.remote)" == "." ]]

  run -1 gh-signoff
  [[ "$output" == *"cannot verify the current branch is pushed"* ]]

  run -0 gh-signoff -f
  [[ "$output" == *"Signed off on"* ]]
}

@test "signoff fails with uncommitted changes message for dirty worktree" {
  make_nested_repo
  touch untracked-file

  run -1 gh-signoff
  [[ "$output" == *"repository has uncommitted changes"* ]]

  run -0 gh-signoff -f
  [[ "$output" == *"Signed off on"* ]]
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
  [[ " ${COMPREPLY[*]-} " == *" create "* ]]
  [[ " ${COMPREPLY[*]-} " == *" linux "* ]]
  [[ ! " ${COMPREPLY[*]-} " == *" status "* ]]
  [[ ! " ${COMPREPLY[*]-} " == *" install "* ]]

  unset MOCK_BRANCH_PROTECTION_JSON MOCK_BRANCH_PROTECTION_EXIT
}

@test "completion after -f create offers contexts only" {
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff/linux"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0

  complete_words gh-signoff -f create
  [[ " ${COMPREPLY[*]-} " == *" linux "* ]]
  [[ ! " ${COMPREPLY[*]-} " == *" create "* ]]
  [[ ! " ${COMPREPLY[*]-} " == *" --branch "* ]]

  unset MOCK_BRANCH_PROTECTION_JSON MOCK_BRANCH_PROTECTION_EXIT
}

@test "completion after trailing -f offers contexts without create" {
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"contexts":["signoff/linux"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0

  complete_words gh-signoff linux -f
  [[ " ${COMPREPLY[*]-} " == *" linux "* ]]
  [[ ! " ${COMPREPLY[*]-} " == *" create "* ]]

  unset MOCK_BRANCH_PROTECTION_JSON MOCK_BRANCH_PROTECTION_EXIT
}

# Leading -f dispatcher grammar tests
@test "leading -f applies to contextual signoff" {
  run -0 gh-signoff -f linux
  [[ "$output" == *"Signed off on"* ]]
  [[ "$output" == *"for linux"* ]]
}

@test "leading -f with explicit create signs off on default context" {
  run -0 gh-signoff -f create
  [[ "$output" == *"Signed off on"* ]]
  [[ ! "$output" == *"for"* ]]
}

@test "leading -f is rejected for non-create commands" {
  run -1 gh-signoff -f status
  [[ "$output" == *"-f is only valid for create"* ]]
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
  [[ "$output" == *"unpushed changes"* ]]
}
