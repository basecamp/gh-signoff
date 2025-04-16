#!/usr/bin/env bats

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
  run gh-signoff -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"USAGE"* ]]
  [[ "$output" == *"COMMANDS"* ]]
}

@test "shows version" {
  run gh-signoff version
  [ "$status" -eq 0 ]
  [[ "$output" == "gh-signoff"* ]]
}

@test "create signs off on current commit" {
  run gh-signoff create -f
  [ "$status" -eq 0 ]
  [[ "$output" == *"Signed off on"* ]]
}

@test "check shows status for protected branch" {
  export GH_MOCK_OUTPUT='{"required_status_checks":{"contexts":["signoff"]}}'
  run gh-signoff check
  [ "$status" -eq 0 ]
  [[ "$output" == *"requires signoff"* ]]
}

@test "install enables protection" {
  run gh-signoff install
  [ "$status" -eq 0 ]
  [[ "$output" == *"now requires signoff"* ]]
}

@test "uninstall removes protection" {
  run gh-signoff uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"no longer requires signoff"* ]]
}

# Context support tests
@test "create signs off with positional argument" {
  run gh-signoff create -f linux
  [ "$status" -eq 0 ]
  [[ "$output" == *"Signed off on"* ]]
  [[ "$output" == *"for linux"* ]]
}

@test "install with context enables contextual protection" {
  run gh-signoff install windows
  [ "$status" -eq 0 ]
  [[ "$output" == *"now requires signoff on windows"* ]]
}

@test "check with context shows contextual status" {
  export GH_MOCK_OUTPUT='{"required_status_checks":{"contexts":["signoff/linux"]}}'
  run gh-signoff check linux
  [ "$status" -eq 0 ]
  [[ "$output" == *"requires signoff on linux"* ]]
}

@test "check with missing context shows negative status" {
  export GH_MOCK_OUTPUT='{"required_status_checks":{"contexts":["signoff"]}}'
  run gh-signoff check windows
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not require signoff on windows"* ]]
}

@test "uninstall with context removes contextual protection" {
  run gh-signoff uninstall macos
  [ "$status" -eq 0 ]
  [[ "$output" == *"no longer requires signoff on macos"* ]]
}

@test "install with branch and context arguments" {
  run gh-signoff install --branch main linux
  [ "$status" -eq 0 ]
  [[ "$output" == *"now requires signoff on linux"* ]]
}
