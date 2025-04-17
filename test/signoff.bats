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

teardown() {
  [ -d "$TEST_DIR" ] && rm -rf "$TEST_DIR"
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
