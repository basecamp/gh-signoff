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

# Put a `gh` on PATH that routes the extension subcommand form
# (`gh signoff …`) to the gh-signoff under test, exactly as real gh runs an
# installed extension, and passes every other call (`gh api …`) through to the
# mock. Lets a test drive the literal published command — space and all —
# rather than the gh-signoff binary directly.
use_gh_subcommand_proxy() {
  mkdir -p "$TEST_DIR/proxy"
  cat >"$TEST_DIR/proxy/gh" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == signoff ]]; then
  shift
  exec gh-signoff "\$@"
fi
exec "$TEST_DIR/gh" "\$@"
EOF
  chmod +x "$TEST_DIR/proxy/gh"
  export PATH="$TEST_DIR/proxy:$PATH"
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

# fail posts a red signoff status so a failed CI run -- especially one
# detached on a runner -- leaves a visible mark instead of silence. A red
# status is a warning, not an attestation, so no cleanliness check applies:
# these tests run in the top-level TEST_DIR repo, which is always dirty with
# the untracked gh-signoff and gh mock binaries.
@test "fail reports a CI failure without any cleanliness check" {
  [[ -n "$(git status --porcelain)" ]] || return 1
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"
  sha=$(git rev-parse HEAD)

  run -0 gh-signoff fail
  [[ "$output" == *"${STATUS_FAILURE} Reported CI failure on $sha"* ]] || return 1

  # The mock accepts any status POST, so prove what this one carried: a red
  # state on the bare signoff context, described by whoever ran it
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == "POST repos/:owner/:repo/statuses/$sha state=failure context=signoff description=Test User: CI failed" ]] || return 1
}

@test "fail reports a CI failure for each named context" {
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff fail tests lint
  [[ "$output" == *"for tests"* ]] || return 1
  [[ "$output" == *"for lint"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *" state=failure context=signoff/tests description="* ]] || return 1
  [[ "$body" == *" state=failure context=signoff/lint description="* ]] || return 1
}

@test "fail sends a custom --description verbatim" {
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff fail --description "suite exploded on bash 3"
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *" state=failure context=signoff description=suite exploded on bash 3" ]] || return 1
}

# GitHub rejects a description over 140 characters; a red mark that fails to
# post is worse than a shortened one
@test "fail cuts a description to GitHub's 140-character cap" {
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"
  long=$(printf 'x%.0s' $(seq 1 150))

  run -0 gh-signoff fail --description "$long"
  body=$(cat "$MOCK_BODY_LOG")
  sent=${body##*description=}
  [[ ${#sent} -eq 140 ]] || return 1
}

# fail is a command word now, like create and check; a context literally
# named fail is still reachable the way every command-named context is
@test "create fail still signs off a context named fail" {
  make_pushed_repo
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff create fail
  [[ "$output" == *"Signed off on"*"for fail"* ]] || return 1
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *" state=success context=signoff/fail "* ]] || return 1
}

# A runner's checkout has no git identity. The only requirement fail states
# is that GitHub knows the commit, so identity must not be one in practice:
# it merely drops out of the default description.
@test "fail needs no git identity" {
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git config --unset user.name
  [[ -z "$(git config user.name)" ]] || return 1

  run -0 gh-signoff fail
  [[ "$output" == *"Reported CI failure on"* ]] || return 1
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *" description=CI failed" ]] || return 1

  run -0 gh-signoff fail --description "suite exploded"
  [[ "$output" == *"Reported CI failure on"* ]] || return 1
}

@test "fail targets the commit named by --commit" {
  sha=$(git rev-parse HEAD)
  export MOCK_EXPECT_COMMIT="$sha"

  run -0 gh-signoff fail --commit "${sha:0:8}"
  [[ "$output" == *"Reported CI failure on $sha"* ]] || return 1
}

@test "fail holds context names to the same rule as create" {
  run -1 gh-signoff fail ""
  [[ "$output" == *"context name cannot be empty"* ]] || return 1

  run -1 gh-signoff fail 'qa"review'
  [[ "$output" == *"context name contains characters unsafe for JSON"* ]] || return 1

  # -- ends options, as for create, so a leading-dash name is a context
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"
  run -0 gh-signoff fail -- -qa
  [[ "$output" == *"for -qa"* ]] || return 1
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *" context=signoff/-qa "* ]] || return 1
}

@test "fail --description requires an argument" {
  run -1 gh-signoff fail --description
  [[ "$output" == *"option --description requires an argument"* ]] || return 1
}

@test "fail rejects -f" {
  run -1 gh-signoff fail -f
  [[ "$output" == *"-f is only valid for create"* ]] || return 1

  run -1 gh-signoff -f fail
  [[ "$output" == *"-f is only valid for create"* ]] || return 1
}

@test "fail propagates a status API failure" {
  export MOCK_POST_STATUS_EXIT=1

  run -1 gh-signoff fail
  [[ "$output" == *"Failed to report CI failure"* ]] || return 1
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
  # Our ruleset exists and requires signoff; expect its DELETE to succeed
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"}]}}]}'
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

@test "a disabled signoff ruleset is not enforced, so reads report not-required" {
  # GitHub is not enforcing a disabled ruleset, so check/status must not claim
  # its contexts are required
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"disabled","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"},{"context":"signoff/tests"}]}}]}'

  run -1 gh-signoff check
  [[ "$output" == "${STATUS_FAILURE} GitHub main branch does not require signoff" ]] || return 1

  run -1 gh-signoff check tests
  [[ "$output" == "${STATUS_FAILURE} GitHub main branch does not require signoff on tests" ]] || return 1

  # status shows only the always-present bare signoff row, as a missing one;
  # the disabled ruleset's contexts do not appear as required
  run -0 gh-signoff status
  [[ "$output" == "${STATUS_FAILURE} signoff" ]] || return 1
}

@test "an evaluate-mode signoff ruleset is dry-run, so reads report not-required" {
  # evaluate is GitHub's non-enforcing dry-run mode; treated like disabled
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"evaluate","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"},{"context":"signoff/tests"}]}}]}'

  run -1 gh-signoff check tests
  [[ "$output" == "${STATUS_FAILURE} GitHub main branch does not require signoff on tests" ]] || return 1
}

@test "install arms the force-push and deletion guards on an adopted ruleset" {
  # Finding 749: an adopted reserved-name ruleset may have only a
  # required_status_checks rule. A fresh install carries deletion and
  # non_fast_forward too (legacy protection blocked those by default), so
  # install must add whichever guard is missing — before it retires the legacy
  # protection, or migration would leave the branch unguarded.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"}]}}]}'
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":["signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install
  [[ "$output" == *"now requires signoff"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"type":"deletion"}'* ]] || return 1
  [[ "$body" == *'{"type":"non_fast_forward"}'* ]] || return 1

  # And the legacy protection is still retired — the ruleset now carries the
  # guards, so the branch stays protected
  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"DELETE repos/:owner/:repo/branches/main/protection"$'\n'* ]] || return 1
}

@test "install does not duplicate guards already present on an adopted ruleset" {
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"}]}}]}'
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install lint
  [[ "$output" == *"now requires signoff on lint"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  # exactly one of each guard
  [[ "$(grep -o '{"type":"deletion"}' <<<"$body" | wc -l)" -eq 1 ]] || return 1
  [[ "$(grep -o '{"type":"non_fast_forward"}' <<<"$body" | wc -l)" -eq 1 ]] || return 1
}

@test "uninstall does not add guards to a ruleset lacking them" {
  # The split: install normalizes the skeleton, uninstall preserves it.
  # Trimming a context must not arm guards that were not there.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"},{"context":"signoff/tests"}]}}]}'
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff uninstall tests
  [[ "$output" == *"no longer requires signoff on tests"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" != *'{"type":"deletion"}'* ]] || return 1
  [[ "$body" != *'{"type":"non_fast_forward"}'* ]] || return 1
}

@test "install normalizes mismatched conditions to target the requested branch" {
  # Finding null: an admin retargeted the reserved-name ruleset to some other
  # ref. Our model is one ruleset per branch, so install reclaims it to the
  # canonical single-branch targeting — otherwise it would report success
  # while enforcing nothing on the requested branch.
  export MOCK_DEFAULT_BRANCH_JSON='{"default_branch":"main"}'
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff (develop)"}]'
  export MOCK_RULESET_JSON='{"name":"signoff (develop)","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["refs/heads/release"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"}]}}]}'
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install --branch develop
  [[ "$output" == *"now requires signoff"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'"include":["refs/heads/develop"]'* ]] || return 1
  [[ "$body" != *"refs/heads/release"* ]] || return 1
  [[ "$body" == *'"enforcement":"active"'* ]] || return 1
}

@test "install re-activates a disabled ruleset and preserves its contexts" {
  # Installing signoff means enforcing it: a disabled ruleset is flipped back
  # to active, its existing signoff AND foreign checks kept, our new one added.
  # The read-path enforcement gate must not make the union basis drop them.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"disabled","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff/tests"},{"context":"other-ci","integration_id":7}]}}]}'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install lint
  [[ "$output" == *"now requires signoff on lint"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"PUT repos/:owner/:repo/rulesets/42"$'\n'* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'"enforcement":"active"'* ]] || return 1
  [[ "$body" == *'{"context":"signoff/tests"}'* ]] || return 1
  [[ "$body" == *'"context":"other-ci"'* ]] || return 1
  [[ "$body" == *'"integration_id":7'* ]] || return 1
  [[ "$body" == *'{"context":"signoff/lint"}'* ]] || return 1
}

@test "uninstall still deletes a disabled ruleset that is wholly ours" {
  # Enforcement does not gate writes: uninstall finds and removes a disabled
  # ruleset like any other
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"disabled","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"}]}}]}'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -0 gh-signoff uninstall
  [[ "$output" == *"no longer requires signoff"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"DELETE repos/:owner/:repo/rulesets/42"$'\n'* ]] || return 1
}

@test "uninstall preserves the enforcement of a ruleset it only trims" {
  # Removing one context from a disabled ruleset that also holds a foreign
  # check keeps it disabled — trimming is no reason to start enforcing
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"disabled","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff/tests"},{"context":"other-ci"}]}}]}'
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff uninstall tests
  [[ "$output" == *"no longer requires signoff on tests"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'"enforcement":"disabled"'* ]] || return 1
  [[ "$body" == *'"context":"other-ci"'* ]] || return 1
}

@test "an active ruleset still contributes its contexts to reads" {
  # No regression: explicit active enforcement behaves exactly as before
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"},{"context":"signoff/tests"}]}}]}'

  run -0 gh-signoff check tests
  [[ "$output" == "${STATUS_SUCCESS} GitHub main branch requires signoff on tests" ]] || return 1
}

@test "a ruleset whose conditions exclude the branch is not counted by reads" {
  # Reads must honor conditions, not just enforcement. An active ruleset named
  # signoff (develop) that an admin retargeted to only refs/heads/release does
  # not apply to develop, so check/status must report not-required there.
  export MOCK_DEFAULT_BRANCH_JSON='{"default_branch":"main"}'
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff (develop)"}]'
  export MOCK_RULESET_JSON='{"name":"signoff (develop)","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["refs/heads/release"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"},{"context":"signoff/tests"}]}}]}'

  run -1 gh-signoff check --branch develop
  [[ "$output" == "${STATUS_FAILURE} GitHub develop branch does not require signoff" ]] || return 1

  run -1 gh-signoff check --branch develop tests
  [[ "$output" == "${STATUS_FAILURE} GitHub develop branch does not require signoff on tests" ]] || return 1

  run -0 gh-signoff status --branch develop
  [[ "$output" == "${STATUS_FAILURE} signoff" ]] || return 1
}

@test "a ruleset that lists the branch in exclude is not counted by reads" {
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":["refs/heads/main"]}},"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"}]}}]}'

  run -1 gh-signoff check
  [[ "$output" == "${STATUS_FAILURE} GitHub main branch does not require signoff" ]] || return 1
}

@test "the default branch accepts both the ~DEFAULT_BRANCH and refs/heads spellings" {
  export MOCK_DEFAULT_BRANCH_JSON='{"default_branch":"main"}'
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'

  # ~DEFAULT_BRANCH spelling
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"}]}}]}'
  run -0 gh-signoff check
  [[ "$output" == "${STATUS_SUCCESS} GitHub main branch requires signoff" ]] || return 1

  # explicit refs/heads/main spelling (as a pre-promotion install would leave)
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["refs/heads/main"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"}]}}]}'
  run -0 gh-signoff check
  [[ "$output" == "${STATUS_SUCCESS} GitHub main branch requires signoff" ]] || return 1
}

@test "a non-default ruleset correctly targeting its branch is counted" {
  export MOCK_DEFAULT_BRANCH_JSON='{"default_branch":"main"}'
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff (develop)"}]'
  export MOCK_RULESET_JSON='{"name":"signoff (develop)","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["refs/heads/develop"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"}]}}]}'

  run -0 gh-signoff check --branch develop
  [[ "$output" == "${STATUS_SUCCESS} GitHub develop branch requires signoff" ]] || return 1
}

@test "install reclaims a retargeted ruleset: conditions re-normalized, contexts preserved" {
  # Writes are NOT gated on conditions: install must read a retargeted
  # ruleset's contexts and re-normalize its targeting back to canonical.
  export MOCK_DEFAULT_BRANCH_JSON='{"default_branch":"main"}'
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff (develop)"}]'
  export MOCK_RULESET_JSON='{"name":"signoff (develop)","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["refs/heads/release"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"},{"context":"signoff/tests"}]}}]}'
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install --branch develop
  [[ "$output" == *"now requires signoff"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  # Targeting reclaimed to the requested branch; existing contexts preserved
  [[ "$body" == *'"include":["refs/heads/develop"]'* ]] || return 1
  [[ "$body" != *"refs/heads/release"* ]] || return 1
  [[ "$body" == *'{"context":"signoff/tests"}'* ]] || return 1
}

@test "a branch name with a C1 control is accepted and reaches the payload" {
  # Finding B: [[:cntrl:]] over-rejected C1 controls like U+0085 (NEL), whose
  # bytes are legal in a git ref and unescaped in a JSON string. The branch
  # contract allows non-ASCII; only C0, quote and backslash are unsafe.
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install --branch $'main\xc2\x85x'
  [[ "$output" == *"now requires signoff"* ]] || return 1

  # The ruleset name/ref carry the branch bytes verbatim into the JSON payload
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *$'\xc2\x85'* ]] || return 1
}

@test "a branch name with a C0 control is still rejected" {
  # A real newline (C0) would forge records and break JSON; still refused
  run -1 gh-signoff install --branch $'main\x0ax'
  [[ "$output" == *"unsafe for JSON"* ]] || return 1

  run -1 gh-signoff install --branch 'main"x'
  [[ "$output" == *"unsafe for JSON"* ]] || return 1

  run -1 gh-signoff install --branch 'main\x'
  [[ "$output" == *"unsafe for JSON"* ]] || return 1
}

@test "install preserves a signoff check's integration_id" {
  # An adopted required check may be pinned to a GitHub App via integration_id
  # ("only this app may satisfy it"). We manage the signoff namespace but must
  # not weaken it: a signoff check we keep keeps its integration_id.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff","integration_id":123}]}}]}'
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install lint
  [[ "$output" == *"now requires signoff on lint"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  # The existing signoff check keeps its integration_id; lint is added bare
  [[ "$body" == *'"context":"signoff"'*'"integration_id":123'* || "$body" == *'"integration_id":123'*'"context":"signoff"'* ]] || return 1
  [[ "$body" == *'{"context":"signoff/lint"}'* ]] || return 1
}

@test "check and status reject a branch name unsafe for JSON" {
  # The active read builds a jq conditions gate from the branch ref, so a
  # branch containing a quote would form an invalid filter whose failure would
  # be swallowed as "not required". Reject it cleanly, as the write path does,
  # rather than misreport. A regular branch is unaffected.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"id":42,"name":"signoff","enforcement":"active","target":"branch","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"signoff"}]}}]}'
  export MOCK_BRANCH_EXISTS=1

  run -1 gh-signoff check --branch 'a"b'
  [[ "$output" == *"unsafe for JSON"* ]] || return 1
  [[ "$output" != *"does not require signoff"* ]] || return 1

  run -1 gh-signoff status --branch 'a"b'
  [[ "$output" == *"unsafe for JSON"* ]] || return 1

  # A C0 control (here ESC) is unsafe too, and the error itself is scrubbed
  run -1 gh-signoff check --branch $'a\x1bb'
  [[ "$output" == *"unsafe for JSON"* ]] || return 1
  [[ "$output" != *$'\x1b'* ]] || return 1

  run -0 gh-signoff check
  [[ "$output" == *"requires signoff"* ]] || return 1
}

@test "a ruleset with do_not_enforce_on_create=true is not pristine" {
  # do_not_enforce_on_create is a mutable required-status-check parameter; an
  # admin setting it true is a customization, so bare uninstall must preserve
  # the ruleset (rewrite, drop signoff) rather than delete it.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"id":42,"name":"signoff","enforcement":"active","target":"branch","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"do_not_enforce_on_create":true,"required_status_checks":[{"context":"signoff"}]}}]}'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -0 gh-signoff uninstall
  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"PUT repos/:owner/:repo/rulesets/42"$'\n'* ]] || return 1
  [[ "$calls" != *"DELETE repos/:owner/:repo/rulesets/42"* ]] || return 1
}

@test "-- routes to implicit create for a leading-dash context" {
  # The implicit form must reach cmd_create's end-of-options handler too, so
  # `gh signoff -- -qa` works without the `create` workaround.
  run -0 gh-signoff -f -- -qa
  [[ "$output" == *"Signed off on"* ]] || return 1
  [[ "$output" == *"for -qa"* ]] || return 1

  # -- with nothing after is still a plain default signoff
  run -0 gh-signoff -f --
  [[ "$output" == *"Signed off on"* ]] || return 1
  [[ ! "$output" == *"for"* ]] || return 1
}

@test "-- ends options so a leading-dash context can be managed" {
  # A record/JSON-safe context may begin with a hyphen (e.g. -qa). The option
  # parser rejects it as an unknown option unless -- ends the options first.
  export MOCK_RULESETS_LIST_JSON='[]'
  export MOCK_BRANCH_EXISTS=1
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -1 gh-signoff install -qa
  [[ "$output" == *"unknown option: -qa"* ]] || return 1

  run -0 gh-signoff install -- -qa
  [[ "$output" == *"now requires signoff on -qa"* ]] || return 1
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"context":"signoff/-qa"}'* ]] || return 1

  run -0 gh-signoff create -f -- -qa
  [[ "$output" == *"for -qa"* ]] || return 1
}

@test "customized protection without signoff draws no duplicate warning" {
  # "other" protection that enforces no signoff (reviews, or a foreign check)
  # is unrelated: the ruleset is the sole signoff enforcement, so there is no
  # duplicate to warn about and nothing to remove.
  export MOCK_RULESETS_LIST_JSON='[]'
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":true,"contexts":["other-ci"]},"enforce_admins":{"enabled":true}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0

  run -0 gh-signoff install
  [[ "$output" == *"now requires signoff"* ]] || return 1
  [[ "$output" != *"also enforces signoff"* ]] || return 1
  [[ "$output" != *"harmless duplicate"* ]] || return 1
}

@test "install adds an unpinned signoff beside an app-pinned twin" {
  # When the only signoff check is app-pinned, reads exclude it (foreign), so
  # install wants an unpinned signoff. The pinned twin must not suppress that
  # addition — a gh-signoff status could never satisfy the pinned one — while
  # the pinned object is still preserved verbatim.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff","integration_id":12345}]}}]}'
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install
  [[ "$output" == *"now requires signoff"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  # The pinned check is preserved AND an unpinned signoff is added beside it
  [[ "$body" == *'"context":"signoff","integration_id":12345'* ]] || return 1
  [[ "$body" == *'{"context":"signoff"}'* ]] || return 1
}

@test "an adopted ruleset's foreign check is never surfaced but always preserved" {
  # An admin may have added a non-signoff check (other-ci) to a ruleset named
  # signoff. It is not a signoff requirement, so reads never show it — and it
  # is preserved verbatim (integration_id and all) on every write.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"},{"context":"other-ci","integration_id":999}]}}]}'
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff","state":"success"}]}'
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  # status shows only the signoff row, never a spurious failed "other-ci"
  run -0 gh-signoff status
  [[ "$output" == "${STATUS_SUCCESS} signoff" ]] || return 1

  # check does not report other-ci as a requirement either
  run -0 gh-signoff check
  [[ "$output" == "${STATUS_SUCCESS} GitHub main branch requires signoff" ]] || return 1

  # install preserves other-ci (with its integration_id) and adds lint
  run -0 gh-signoff install lint
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'"context":"other-ci"'* ]] || return 1
  [[ "$body" == *'"integration_id":999'* ]] || return 1
  [[ "$body" == *'{"context":"signoff/lint"}'* ]] || return 1
}

@test "bare uninstall keeps a ruleset with a custom bypass actor" {
  # The delete-vs-keep verdict is one holistic pristine test, not a list of
  # foreign-content flags. An admin-added bypass actor makes the ruleset
  # non-pristine, so bare uninstall rewrites (dropping our signoff checks) and
  # preserves the custom bypass rather than deleting the whole thing.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"},{"actor_id":99,"actor_type":"Team","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"}]}}]}'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff uninstall
  [[ "$output" == *"no longer requires signoff"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"PUT repos/:owner/:repo/rulesets/42"$'\n'* ]] || return 1
  [[ "$calls" != *"DELETE repos/:owner/:repo/rulesets/42"* ]] || return 1

  # The custom bypass is preserved; our signoff check is gone
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'"actor_id":99'* ]] || return 1
  [[ "$body" != *'{"context":"signoff"}'* ]] || return 1
}

@test "bare uninstall keeps a ruleset with custom conditions" {
  # Same holistic test for conditions: an added exclude makes it non-pristine
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":["refs/heads/release/*"]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"}]}}]}'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff uninstall
  [[ "$output" == *"no longer requires signoff"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"PUT repos/:owner/:repo/rulesets/42"$'\n'* ]] || return 1
  [[ "$calls" != *"DELETE repos/:owner/:repo/rulesets/42"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'refs/heads/release/*'* ]] || return 1
}

@test "bare uninstall keeps a ruleset that still holds a foreign check" {
  # Deleting the ruleset would drop the admin's other-ci config. So a bare
  # uninstall removes only our signoff checks and rewrites, keeping other-ci;
  # it deletes the ruleset only when nothing foreign remains.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"},{"context":"other-ci","integration_id":999}]}}]}'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff uninstall
  [[ "$output" == *"no longer requires signoff"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"PUT repos/:owner/:repo/rulesets/42"$'\n'* ]] || return 1
  [[ "$calls" != *"DELETE repos/:owner/:repo/rulesets/42"* ]] || return 1

  # The rewrite drops our signoff check but keeps other-ci verbatim
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'"context":"other-ci"'* ]] || return 1
  [[ "$body" == *'"integration_id":999'* ]] || return 1
  [[ "$body" != *'{"context":"signoff"}'* ]] || return 1
}

@test "a ruleset with strict policy set is not pristine" {
  # F3: pristine must compare the known mutable parameter, not just rule types.
  # An admin who set strict_required_status_checks_policy=true customized the
  # ruleset, so bare uninstall must rewrite (keep it, drop our signoff checks),
  # not delete the whole thing including guards.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"signoff"}]}}]}'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -0 gh-signoff uninstall
  [[ "$output" == *"no longer requires signoff"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"PUT repos/:owner/:repo/rulesets/42"$'\n'* ]] || return 1
  [[ "$calls" != *"DELETE repos/:owner/:repo/rulesets/42"* ]] || return 1
}

@test "an app-pinned signoff check is foreign to reads but preserved on writes" {
  # F4: consistent with legacy (which excludes app-bound signoff checks). A
  # signoff check pinned to a GitHub App via integration_id is not one
  # gh-signoff created with the user token, and a plain user status can't
  # satisfy it — so reads do not count it, though writes preserve it verbatim.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"},{"context":"signoff/tests","integration_id":123}]}}]}'
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[]}'
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  # Reads: the pinned signoff/tests is not counted, so status shows only the
  # baseline signoff row and check does not report it required
  run -0 gh-signoff status
  [[ "$output" == "${STATUS_FAILURE} signoff" ]] || return 1

  run -0 gh-signoff check tests
  [[ "$output" == *"does not require signoff on tests"* ]] || return 1

  # Writes: install lint preserves the pinned check verbatim (integration_id)
  run -0 gh-signoff install lint
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'"context":"signoff/tests"'* ]] || return 1
  [[ "$body" == *'"integration_id":123'* ]] || return 1
}

@test "bare uninstall of a ruleset holding only foreign checks reports nothing installed" {
  # F2: a reserved-name ruleset with only foreign (or app-pinned) checks is
  # not a signoff requirement we can remove. Bare uninstall must report "no
  # signoff requirement installed" and make no write — like the no-ruleset
  # path — not a needless PUT that removes nothing while claiming success.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"other-ci"}]}}]}'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -1 gh-signoff uninstall
  [[ "$output" == *"no signoff requirement installed on main"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" != *"PUT repos/:owner/:repo/rulesets"* ]] || return 1
  [[ "$calls" != *"DELETE repos/:owner/:repo/rulesets"* ]] || return 1
}

@test "bare uninstall still deletes a ruleset that is wholly ours" {
  # The other side: only signoff checks and our own rules means delete it.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"},{"context":"signoff/tests"}]}}]}'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -0 gh-signoff uninstall
  [[ "$output" == *"no longer requires signoff"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"DELETE repos/:owner/:repo/rulesets/42"$'\n'* ]] || return 1
  [[ "$calls" != *"PUT repos/:owner/:repo/rulesets/42"* ]] || return 1
}

@test "a branch name with a URL metacharacter is percent-encoded in protection paths" {
  # gh api treats the path as a URL: an unencoded '#' would truncate it and
  # target the wrong branch. The branch-protection routes must see feat%23123.
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -0 gh-signoff install --branch 'feat#123'
  [[ "$output" == *"now requires signoff"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" == *"branches/feat%23123/protection"* ]] || return 1
  [[ "$calls" != *"branches/feat#123/protection"* ]] || return 1
}

# Finding 313: signoff was installed on develop while develop was non-default
# (ruleset "signoff (develop)"), then develop became the default branch. Its
# canonical name is now the bare "signoff", so default-branch identity must
# still recognize the old spelling or management is orphaned.
@test "a promoted default branch still finds its pre-promotion ruleset" {
  export MOCK_DEFAULT_BRANCH_JSON='{"default_branch":"develop"}'
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff (develop)"}]'
  export MOCK_RULESET_JSON='{"name":"signoff (develop)","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["refs/heads/develop"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"}]}}]}'

  # Reads find it under the old spelling
  run -0 gh-signoff check
  [[ "$output" == "${STATUS_SUCCESS} GitHub develop branch requires signoff" ]] || return 1
}

@test "install rewrites a promoted branch-specific ruleset to canonical shape" {
  export MOCK_DEFAULT_BRANCH_JSON='{"default_branch":"develop"}'
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff (develop)"}]'
  export MOCK_RULESET_JSON='{"name":"signoff (develop)","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["refs/heads/develop"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"}]}}]}'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install
  [[ "$output" == *"now requires signoff"* ]] || return 1

  # Adopted in place (PUT on the found id), renamed to canonical and re-targeted
  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"PUT repos/:owner/:repo/rulesets/42"$'\n'* ]] || return 1
  [[ "$calls" != *"POST repos/:owner/:repo/rulesets"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'"name":"signoff"'* ]] || return 1
  [[ "$body" != *'"name":"signoff (develop)"'* ]] || return 1
  [[ "$body" == *'"include":["~DEFAULT_BRANCH"]'* ]] || return 1
}

@test "uninstall removes a promoted branch-specific ruleset" {
  export MOCK_DEFAULT_BRANCH_JSON='{"default_branch":"develop"}'
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff (develop)"}]'
  export MOCK_RULESET_JSON='{"name":"signoff (develop)","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["refs/heads/develop"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"}]}}]}'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -0 gh-signoff uninstall
  [[ "$output" == *"no longer requires signoff"* ]] || return 1

  # Pristine (its refs/heads/develop condition is accepted for the default
  # branch), so it is deleted rather than orphaned
  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"DELETE repos/:owner/:repo/rulesets/42"$'\n'* ]] || return 1
}

@test "both default-branch spellings present fails closed" {
  export MOCK_DEFAULT_BRANCH_JSON='{"default_branch":"develop"}'
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"},{"id":43,"name":"signoff (develop)"}]'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -1 gh-signoff check
  [[ "$output" == *"multiple signoff rulesets"* ]] || return 1

  run -1 gh-signoff uninstall
  [[ "$output" == *"multiple signoff rulesets"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" != *"PUT "* ]] || return 1
  [[ "$calls" != *"DELETE "* ]] || return 1
  [[ "$calls" != *"POST "* ]] || return 1
}

# A non-default branch keeps single-name matching: the bare "signoff" (the
# default branch's ruleset) is not adopted for a non-default branch.
@test "a non-default branch does not adopt the bare signoff ruleset" {
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'

  run -1 gh-signoff check --branch other
  [[ "$output" == "${STATUS_FAILURE} GitHub other branch does not require signoff" ]] || return 1
}

@test "duplicate reserved-name rulesets fail closed everywhere" {
  # Two rulesets share our name: which we adopt would be arbitrary and a bare
  # uninstall would delete one while the other kept enforcing. Fail closed on
  # reads and writes alike, and touch nothing.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"},{"id":43,"name":"signoff"}]'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -1 gh-signoff check
  [[ "$output" == *"multiple signoff rulesets"* ]] || return 1

  run -1 gh-signoff install lint
  [[ "$output" == *"multiple signoff rulesets"* ]] || return 1

  run -1 gh-signoff uninstall
  [[ "$output" == *"multiple signoff rulesets"* ]] || return 1

  # No mutation of any kind was attempted
  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" != *"POST "* ]] || return 1
  [[ "$calls" != *"PUT "* ]] || return 1
  [[ "$calls" != *"DELETE "* ]] || return 1
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

@test "install on force-push-allowing protection imposes no guards" {
  # An admin who explicitly allowed force pushes has customized protection
  # ("other"); leaving it intact means our ruleset must not re-block force
  # pushes or deletions on top of the admin's allowance.
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":["signoff"]},"allow_force_pushes":{"enabled":true}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install
  [[ "$output" == *"customized branch protection"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" != *'{"type":"non_fast_forward"}'* ]] || return 1
  [[ "$body" != *'{"type":"deletion"}'* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" != *"DELETE repos/:owner/:repo/branches/main/protection"* ]] || return 1
}

@test "bare uninstall deletes a guard-less ruleset since guards are optional to pristine" {
  # An "other"-legacy install leaves our ruleset without the guard rules. A
  # later bare uninstall must still see it as pristine and delete it, not
  # rewrite it — guards are optional to the pristine test.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"}]}}]}'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -0 gh-signoff uninstall
  [[ "$output" == *"no longer requires signoff"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"DELETE repos/:owner/:repo/rulesets/42"$'\n'* ]] || return 1
  [[ "$calls" != *"PUT repos/:owner/:repo/rulesets/42"* ]] || return 1
}

@test "install leaves customized (non-signoff) protection intact" {
  # Customized ("other") legacy protection is left completely untouched: no
  # surgical removal, no wholesale delete. The ruleset also enforces signoff
  # (a harmless duplicate) and a warning points at the intact protection.
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":["other-ci","signoff"]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install
  [[ "$output" == *"now requires signoff"* ]] || return 1
  [[ "$output" != *"Migrated"* ]] || return 1
  [[ "$output" == *"customized branch protection"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"POST repos/:owner/:repo/rulesets"$'\n'* ]] || return 1
  # Legacy protection is not modified at all — no DELETE of any protection path
  [[ "$calls" != *"DELETE repos/:owner/:repo/branches/main/protection"* ]] || return 1

  # No guards imposed: the intact legacy protection governs force pushes/deletions
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" != *'{"type":"deletion"}'* ]] || return 1
  [[ "$body" != *'{"type":"non_fast_forward"}'* ]] || return 1
  [[ "$body" == *'{"context":"signoff"}'* ]] || return 1
}

@test "install leaves admin-enforced protection intact" {
  # enforce_admins=true makes it "other"; leave it entirely alone
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":["signoff"]},"enforce_admins":{"enabled":true}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -0 gh-signoff install
  [[ "$output" != *"Migrated"* ]] || return 1
  [[ "$output" == *"customized branch protection"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" != *"DELETE repos/:owner/:repo/branches/main/protection"* ]] || return 1
}

@test "install leaves protection with extra features intact" {
  # Any enabled protection flag — linear history, signatures, whatever GitHub
  # adds next — makes it "other", so install leaves the whole thing untouched
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":["signoff"]},"enforce_admins":{"enabled":false},"required_linear_history":{"enabled":true}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -0 gh-signoff install
  [[ "$output" != *"Migrated"* ]] || return 1
  [[ "$output" == *"customized branch protection"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" != *"DELETE repos/:owner/:repo/branches/main/protection"* ]] || return 1
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

@test "a quote-bearing legacy signoff check is not recognized, but a safe one is" {
  # F1: legacy recognition matches CLI input safety. signoff/qa"review holds a
  # quote (record-unsafe), so it is left in the legacy protection untouched;
  # signoff/tests is migrated as usual. The space case (record-safe) stays
  # recognized — no regression to the round-5 loosening.
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":["signoff/tests","signoff/qa\"review","signoff/qa review"]},"enforce_admins":null,"required_pull_request_reviews":null,"restrictions":null}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install
  [[ "$output" == *"now requires signoff"* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  # The safe contexts are migrated into the ruleset
  [[ "$body" == *'{"context":"signoff/tests"}'* ]] || return 1
  [[ "$body" == *'{"context":"signoff/qa review"}'* ]] || return 1
  # The quote-bearing one is never claimed
  [[ "$body" != *'qa\"review'* ]] || return 1

  # And it is left in the legacy protection, not surgically removed
  calls=$(cat "$MOCK_CALL_LOG")
  if [[ "$calls" == *"required_status_checks/contexts"* ]]; then
    removed=$(cat "$MOCK_BODY_LOG")
    [[ "$removed" != *'qa\"review'* ]] || return 1
  fi
}

@test "a control-char legacy signoff check is not recognized or migrated" {
  # A legacy check named "signoff/tests\nother-ci" (embedded newline, a C0
  # control) is not record/JSON-safe, so it is NOT ours — recognition matches
  # what the CLI can operate. It is left in the legacy protection untouched;
  # install neither migrates it nor adds it to the ruleset. The app-bound
  # other-ci is foreign too, so the protection is "other" and left intact.
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"checks":[{"context":"signoff/tests\nother-ci","app_id":null},{"context":"other-ci","app_id":777}]}}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install lint
  [[ "$output" != *"Migrated"* ]] || return 1
  # No recognized signoff context lives in this protection (the unsafe one is
  # not ours, other-ci is app-bound), so there is no signoff duplicate to warn
  # about even though the protection is left intact.
  [[ "$output" != *"also enforces signoff"* ]] || return 1

  # Legacy protection is untouched — no removal of any kind
  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" != *"DELETE repos/:owner/:repo/branches/main/protection"* ]] || return 1

  # The ruleset carries only our new lint; the unsafe legacy context is left
  # where it is, never migrated
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"context":"signoff/lint"}'* ]] || return 1
  [[ "$body" != *'other-ci'* ]] || return 1
  [[ "$body" != *'tests\nother-ci'* ]] || return 1
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

@test "every command refuses a context with a quote, backslash or control char" {
  # Contexts are held to record/JSON safety, not the old identifier grammar
  # (which was completion-injection armor, removed with completion). Only the
  # characters that would break the bash-composed token or forge a record —
  # quote, backslash, C0 controls — are refused. install, check, uninstall
  # and create all apply it, before touching the API.
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  for bad in 'has"quote' 'back\slash' $'nl\nhere' $'tab\there' $'esc\x1bhere'; do
    run -1 gh-signoff install "$bad"
    [[ "$output" == *"unsafe for JSON"* ]] || return 1

    run -1 gh-signoff check "$bad"
    [[ "$output" == *"unsafe for JSON"* ]] || return 1

    run -1 gh-signoff uninstall "$bad"
    [[ "$output" == *"unsafe for JSON"* ]] || return 1

    run -1 gh-signoff create "$bad"
    [[ "$output" == *"unsafe for JSON"* ]] || return 1
  done

  # A leading dash is read as an option before validation
  for cmd in install check uninstall create; do
    run -1 gh-signoff "$cmd" -danger
    [[ "$output" == *"unknown option: -danger"* ]] || return 1
  done

  [[ ! -s "$MOCK_CALL_LOG" ]] || return 1
}

@test "context names with spaces, symbols and non-ASCII are accepted" {
  # The loosening: a space, shell metacharacters and non-ASCII are inert in a
  # context name — never shell-evaluated, carried as JSON tokens — so they are
  # allowed. A migrated legacy context like "qa review" must stay usable.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  for ok in 'qa review' 'a;b' 'a|b' 'a&b' 'star*' '~home' '$(printf X)' $'caf\xc3\xa9'; do
    run -0 gh-signoff install "$ok"
    [[ "$output" == *"now requires signoff"* ]] || return 1
  done
}

@test "ordinary context names are accepted" {
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'

  for good in foo foo-bar foo.bar foo/bar foo_bar Lint bash-3 9lives; do
    run -0 gh-signoff install "$good"
    [[ "$output" == *"now requires signoff on ${good}"* ]] || return 1
  done
}

@test "a legacy context outside the old grammar round-trips" {
  # Finding D: a migrated legacy context like "qa review" must be signable,
  # checkable and removable — not trapped by a grammar that once rejected it.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"},{"context":"signoff/qa review"}]}}]}'
  export MOCK_COMMIT_STATUS_JSON='{"statuses":[{"context":"signoff/qa review","state":"success"}]}'
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  # check finds it
  run -0 gh-signoff check 'qa review'
  [[ "$output" == *"requires signoff on qa review"* ]] || return 1

  # status shows it satisfied
  run -0 gh-signoff status
  [[ "$output" == *"${STATUS_SUCCESS} qa review"* ]] || return 1

  # uninstall removes just it, keeping the bare signoff
  run -0 gh-signoff uninstall 'qa review'
  [[ "$output" == *"no longer requires signoff on qa review"* ]] || return 1
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"context":"signoff"}'* ]] || return 1
  [[ "$body" != *"qa review"* ]] || return 1
}

@test "a context that looks like a command substitution is an inert name" {
  # The crux of why loosening is safe: a context is never shell-evaluated.
  # `$(touch FILE)` is accepted as a NAME and signed, and no file appears.
  make_pushed_repo
  rm -f "$TEST_DIR/PWNED"

  run -0 gh-signoff "\$(touch $TEST_DIR/PWNED)"
  [[ "$output" == *"Signed off on"* ]] || return 1
  [[ ! -e "$TEST_DIR/PWNED" ]] || return 1
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

@test "install --branch fails when the branch does not exist" {
  # F3: a typo'd branch would otherwise silently install an unused ruleset,
  # because the rulesets API accepts a ref-name pattern with no matching
  # branch. Verify existence first, and make no write on a 404.
  export MOCK_BRANCH_EXISTS=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -1 gh-signoff install --branch nonexistent
  [[ "$output" == *"branch nonexistent not found on this repository"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" != *"POST repos/:owner/:repo/rulesets"* ]] || return 1
  [[ "$calls" != *"PUT repos/:owner/:repo/rulesets"* ]] || return 1
}

@test "install --branch surfaces a non-404 branch-check failure" {
  # A 403/500 is not "not found" — do not silently proceed
  export MOCK_BRANCH_EXISTS=0
  export MOCK_BRANCH_EXISTS_ERROR_STATUS=500
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -1 gh-signoff install --branch other
  [[ "$output" == *"failed to check whether branch other exists"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" != *"POST repos/:owner/:repo/rulesets"* ]] || return 1
}

@test "default-branch install does not check branch existence" {
  # The default branch comes from default_branch, so it is known to exist and
  # never round-tripped — even with the branch-existence mock forced to 404
  export MOCK_BRANCH_EXISTS=0

  run -0 gh-signoff install
  [[ "$output" == *"GitHub main branch now requires signoff"* ]] || return 1
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
@test "an adopted check with an embedded newline is foreign and preserved" {
  # A check named "foreign\nsignoff/tests" (one real newline) is not in the
  # signoff namespace — it does not start with signoff/ — so it is foreign:
  # never counted as a signoff requirement, never split into a forged
  # "foreign" plus "signoff/tests", and preserved verbatim on every write.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"foreign\nsignoff/tests"}]}}]}'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  # Not a signoff requirement: reads never surface it
  run -1 gh-signoff check tests
  [[ "$output" == "${STATUS_FAILURE} GitHub main branch does not require signoff on tests" ]] || return 1

  # install adds our lint and preserves the foreign check verbatim alongside it
  run -0 gh-signoff install lint
  [[ "$output" == *"now requires signoff on lint"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" != *"DELETE "* ]] || return 1

  # One context, spelled exactly as it arrived; no bare "foreign" ever splits out
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
  [[ "$output" == *"unsafe for JSON"* ]] || return 1
  [[ "$output" != *"requires signoff"* ]] || return 1

  # A plain quote is refused too, rather than quietly matching nothing
  run -1 gh-signoff check 'bad"context'
  [[ "$output" == *"unsafe for JSON"* ]] || return 1
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
  [[ "$output" == *"unsafe for JSON"* ]] || return 1
  [[ "$output" != *$'\x1b'* ]] || return 1
  [[ "$output" == *"bad?[2Jclear"* ]] || return 1
}

@test "a bidi override in a context is accepted but scrubbed for display" {
  # U+202E is a format character, not a C0 control, so record/JSON safety
  # allows it (like a branch name). It rides into the payload as a token but
  # is scrubbed wherever it reaches the terminal.
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install $'ev\xe2\x80\xaeil'
  [[ "$output" == *"now requires signoff"* ]] || return 1
  # The success message scrubs the override rather than printing it raw
  [[ "$output" != *$'\xe2\x80\xae'* ]] || return 1

  # The payload keeps the original bytes (as a token)
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *$'\xe2\x80\xae'* ]] || return 1
}

@test "debug shows an adopted name scrubbed while the payload keeps it" {
  # SIGNOFF_DEBUG prints the request JSON, which carries adopted names raw.
  # The debug line is scrubbed whole; what goes on the wire is not.
  export SIGNOFF_DEBUG=1
  export MOCK_RULESETS_LIST_JSON='[{"id":42,"name":"signoff"}]'
  export MOCK_RULESET_JSON='{"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff/ev\u202eil"},{"context":"signoff/c1\u009bhere"}]}}]}'
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff install lint
  [[ "$output" == *"updating signoff ruleset"* ]] || return 1
  [[ "$output" != *$'\xe2\x80\xae'* ]] || return 1
  [[ "$output" != *$'\xc2\x9b'* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *$'\xe2\x80\xae'* ]] || return 1
  [[ "$body" == *$'\xc2\x9b'* ]] || return 1
}

@test "a display-hostile default branch name prints inert" {
  # A JSON-safe but display-hostile branch name (here U+202E, a bidi override)
  # comes from the API and is scrubbed wherever it is shown. Unlike a
  # JSON-unsafe name (quote/backslash/C0, which is rejected outright), this one
  # is representable, so check runs and simply renders it inert.
  export MOCK_DEFAULT_BRANCH_JSON='{"default_branch":"ma\u202ein"}'

  run -1 gh-signoff check
  [[ "$output" != *$'\xe2\x80\xae'* ]] || return 1
  [[ "$output" == "${STATUS_FAILURE} GitHub ma???in branch does not require signoff" ]] || return 1
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
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff/Tests"}]}}]}'
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff uninstall tests
  [[ "$output" == *"no longer requires signoff on tests"* ]] || return 1

  # Nothing remains and the ruleset is pristine, so it goes rather than being rewritten
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
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"}]}}]}'
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
  export MOCK_RULESET_JSON='{"name":"signoff","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"signoff"}]}}]}'
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

@test "contextual uninstall of signoff-shaped legacy arms guards on the remainder" {
  # F1: consistent with install-migrate. Signoff-shaped legacy holding
  # signoff/tests + signoff/lint; `uninstall tests` migrates lint into a
  # ruleset and deletes the legacy protection — so the ruleset must carry the
  # deletion/non_fast_forward guards that protection provided by default, or
  # force pushes and deletions are silently enabled.
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":false,"contexts":["signoff/tests","signoff/lint"]},"enforce_admins":null,"required_pull_request_reviews":null,"restrictions":null}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff uninstall tests
  [[ "$output" == *"no longer requires signoff on tests"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ $'\n'"$calls"$'\n' == *$'\n'"POST repos/:owner/:repo/rulesets"$'\n'* ]] || return 1
  [[ $'\n'"$calls"$'\n' == *$'\n'"DELETE repos/:owner/:repo/branches/main/protection"$'\n'* ]] || return 1

  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"type":"deletion"}'* ]] || return 1
  [[ "$body" == *'{"type":"non_fast_forward"}'* ]] || return 1
  [[ "$body" == *'{"context":"signoff/lint"}'* ]] || return 1
  [[ "$body" != *"signoff/tests"* ]] || return 1
}

@test "contextual uninstall of customized legacy removes only the requested context" {
  # F2: consistent with the leave-customized-intact install decision. Strict,
  # admin-enforced protection holds signoff/tests + signoff/lint; `uninstall
  # tests` removes ONLY signoff/tests from it, surgically, and leaves
  # signoff/lint enforced under the intact customized protection — never
  # migrating the remainder into a canonical ruleset (that would drop the
  # admin's strict/enforce_admins policy).
  export MOCK_BRANCH_PROTECTION_JSON='{"required_status_checks":{"strict":true,"contexts":["signoff/tests","signoff/lint"]},"enforce_admins":{"enabled":true},"required_pull_request_reviews":null,"restrictions":null}'
  export MOCK_BRANCH_PROTECTION_EXIT=0
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"
  export MOCK_BODY_LOG="$TEST_DIR/bodies.log"

  run -0 gh-signoff uninstall tests
  [[ "$output" == *"no longer requires signoff on tests"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  # Only a surgical context removal; no ruleset created/updated, no wholesale delete
  [[ "$calls" == *"DELETE repos/:owner/:repo/branches/main/protection/required_status_checks/contexts"* ]] || return 1
  [[ $'\n'"$calls"$'\n' != *$'\n'"DELETE repos/:owner/:repo/branches/main/protection"$'\n'* ]] || return 1
  [[ "$calls" != *"POST repos/:owner/:repo/rulesets"* ]] || return 1
  [[ "$calls" != *"PUT repos/:owner/:repo/rulesets"* ]] || return 1

  # Exactly the requested context is removed; signoff/lint is left behind
  body=$(cat "$MOCK_BODY_LOG")
  [[ "$body" == *'{"contexts":["signoff/tests"]}'* ]] || return 1
  [[ "$body" != *"signoff/lint"* ]] || return 1
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

# A CI runner's slot -- or any second machine -- can hold the pushed commit
# while its remote-tracking ref is stale or absent. Signoff refreshes the
# branch's tracking ref and rechecks before declaring work unpushed.
@test "signoff refreshes a stale remote-tracking ref before declaring work unpushed" {
  make_pushed_repo
  git commit --no-gpg-sign --allow-empty -m "Pushed from elsewhere" >/dev/null
  # The remote holds the commit, but origin/main was never updated locally
  git push -q "$TEST_DIR/remote.git" HEAD:main

  run -0 gh-signoff
  [[ "$output" == *"Signed off on"* ]] || return 1
}

@test "signoff fetches a never-fetched tracking ref before refusing" {
  make_nested_repo
  add_bare_remote
  # Objects reach the remote without creating refs/remotes/origin/main
  git push -q "$TEST_DIR/remote.git" HEAD:main
  git config branch.main.remote origin
  git config branch.main.merge refs/heads/main

  run -0 gh-signoff
  [[ "$output" == *"Signed off on"* ]] || return 1
}

@test "signoff still catches unpushed work after refreshing a stale tracking ref" {
  make_nested_repo
  add_bare_remote
  git push -q "$TEST_DIR/remote.git" HEAD:main
  git config branch.main.remote origin
  git config branch.main.merge refs/heads/main
  git commit --no-gpg-sign --allow-empty -m "Unpushed commit" >/dev/null

  run -1 gh-signoff
  [[ "$output" == *"unpushed changes"* ]] || return 1
  # The refresh happened (the tracking ref now exists) and the recheck held
  git rev-parse --verify -q refs/remotes/origin/main >/dev/null || return 1
}

# The ref to refresh is the one check_clean judges: @{push}, which routing
# config can point at a remote other than the upstream. Refreshing the
# upstream there would land on a ref the check never reads.
@test "signoff refreshes the effective push remote, not the upstream" {
  make_pushed_repo
  git init -q --bare "$TEST_DIR/pushes.git"
  git remote add pushes "$TEST_DIR/pushes.git"
  git config branch.main.pushRemote pushes
  git config push.default current
  git commit --no-gpg-sign --allow-empty -m "Pushed to the push remote" >/dev/null
  # The push remote holds the commit; neither tracking ref knows yet, and
  # the upstream (origin) never will
  git push -q "$TEST_DIR/pushes.git" HEAD:main
  [[ "$(git for-each-ref --format='%(push)' refs/heads/main)" == "refs/remotes/pushes/main" ]] || return 1

  run -0 gh-signoff
  [[ "$output" == *"Signed off on"* ]] || return 1
  git rev-parse --verify -q refs/remotes/pushes/main >/dev/null || return 1
}

# With no upstream, push.default=current still pushes to origin by git's own
# default -- which for-each-ref reports as an empty remote name, since it
# names only an explicitly configured one
@test "signoff refreshes the implicit origin for a branch with no upstream" {
  make_nested_repo
  add_bare_remote
  git push -q origin HEAD:main
  git update-ref -d refs/remotes/origin/main
  git config push.default current
  [[ "$(git for-each-ref --format='%(push)' refs/heads/main)" == "refs/remotes/origin/main" ]] || return 1
  [[ -z "$(git for-each-ref --format='%(push:remotename)' refs/heads/main)" ]] || return 1

  run -0 gh-signoff
  [[ "$output" == *"Signed off on"* ]] || return 1
}

# With a single remote that isn't origin, git's implicit default is that
# remote, not origin
@test "signoff refreshes the sole remote when it isn't named origin" {
  make_nested_repo
  git init -q --bare "$TEST_DIR/upstream.git"
  git remote add upstream "$TEST_DIR/upstream.git"
  git push -q upstream HEAD:main
  git update-ref -d refs/remotes/upstream/main
  git config push.default current
  [[ "$(git for-each-ref --format='%(push)' refs/heads/main)" == "refs/remotes/upstream/main" ]] || return 1
  [[ -z "$(git for-each-ref --format='%(push:remotename)' refs/heads/main)" ]] || return 1

  run -0 gh-signoff
  [[ "$output" == *"Signed off on"* ]] || return 1
}

# A fetch is not atomic: it can update the judged ref and still exit nonzero
# over something else (a rejected refspec, a submodule that won't fetch --
# which cases git applies partially varies by version). The recheck must
# happen regardless, so simulate the contract directly: a git on PATH that
# does the fetch and then reports failure.
@test "signoff rechecks after a fetch that updated the tracking ref but failed" {
  make_nested_repo
  add_bare_remote
  git push -q origin HEAD:main
  git update-ref -d refs/remotes/origin/main
  git config branch.main.remote origin
  git config branch.main.merge refs/heads/main
  cat > "$TEST_DIR/git" <<'SHIM'
#!/usr/bin/env bash
# Pass through to the real git; fetch does its work, then reports failure
PATH="${PATH#*:}"
if [[ "$1" == fetch ]]; then git "$@"; exit 1; fi
exec git "$@"
SHIM
  chmod +x "$TEST_DIR/git"
  hash -r
  ! git fetch --quiet origin || return 1
  git rev-parse --verify -q refs/remotes/origin/main >/dev/null || return 1
  git update-ref -d refs/remotes/origin/main

  run -0 gh-signoff
  [[ "$output" == *"Signed off on"* ]] || return 1
}

# A custom fetch mapping puts the tracking ref somewhere the remote branch
# name cannot be read back from. The refresh fetches the whole remote, so the
# user's own mapping lands the ref where check_clean looks.
@test "signoff refreshes through a custom fetch refspec" {
  make_nested_repo
  add_bare_remote
  git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/custom/*'
  git push -q "$TEST_DIR/remote.git" HEAD:main
  git config branch.main.remote origin
  git config branch.main.merge refs/heads/main
  [[ "$(git for-each-ref --format='%(push)' refs/heads/main)" == "refs/remotes/origin/custom/main" ]] || return 1

  run -0 gh-signoff
  [[ "$output" == *"Signed off on"* ]] || return 1
  git rev-parse --verify -q refs/remotes/origin/custom/main >/dev/null || return 1
}

# The same runner slot signs off with --commit HEAD, the documented CI form,
# and must not be refused for the stale tracking ref that plain signoff just
# looked past
@test "--commit refreshes a stale tracking ref before refusing the commit" {
  make_nested_repo
  add_bare_remote
  git push -q "$TEST_DIR/remote.git" HEAD:main
  git config branch.main.remote origin
  git config branch.main.merge refs/heads/main
  sha=$(git rev-parse HEAD)

  run -0 gh-signoff --commit HEAD
  [[ "$output" == *"Signed off on $sha"* ]] || return 1

  # Still refused when the refresh shows the commit was never pushed
  git commit --no-gpg-sign --allow-empty -m "Unpushed commit" >/dev/null
  run -1 gh-signoff --commit HEAD
  [[ "$output" == *"is not on any remote"* ]] || return 1
}

# An explicit commit counts as published on any remote, so every remote is
# refreshed -- not just the current branch's
@test "--commit refreshes a remote other than the branch's own" {
  make_pushed_repo
  git init -q --bare "$TEST_DIR/elsewhere.git"
  git remote add elsewhere "$TEST_DIR/elsewhere.git"
  git commit --no-gpg-sign --allow-empty -m "Published elsewhere" >/dev/null
  git push -q "$TEST_DIR/elsewhere.git" HEAD:refs/heads/topic
  sha=$(git rev-parse HEAD)
  [[ -z "$(git branch -r --contains "$sha")" ]] || return 1

  run -0 gh-signoff --commit HEAD
  [[ "$output" == *"Signed off on $sha"* ]] || return 1
}

# A detached checkout -- the common CI shape -- has no branch at all, and
# still gets every remote fetched before the commit is refused
@test "--commit refreshes all remotes on a detached HEAD" {
  make_nested_repo
  add_bare_remote
  git push -q "$TEST_DIR/remote.git" HEAD:main
  git checkout -q --detach
  sha=$(git rev-parse HEAD)
  [[ -z "$(git branch -r)" ]] || return 1

  run -0 gh-signoff --commit HEAD
  [[ "$output" == *"Signed off on $sha"* ]] || return 1

  # Plain signoff has no branch to judge and still refuses, as before --
  # without fetching, since no refresh can make a detached HEAD judgeable
  git update-ref -d refs/remotes/origin/main
  run -1 gh-signoff
  [[ "$output" == *"cannot verify the current branch is pushed"* ]] || return 1
  [[ -z "$(git branch -r)" ]] || return 1
}

# One dead remote must not defeat the refresh for the others
@test "--commit on a detached HEAD refreshes past an unreachable remote" {
  make_nested_repo
  add_bare_remote
  git remote add gone "$TEST_DIR/no-such-remote.git"
  git push -q "$TEST_DIR/remote.git" HEAD:main
  git checkout -q --detach
  sha=$(git rev-parse HEAD)

  run -0 gh-signoff --commit HEAD
  [[ "$output" == *"Signed off on $sha"* ]] || return 1
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
  [[ "$output" == *"cannot be empty"* ]] || return 1

  run -1 gh-signoff '' good
  [[ "$output" == *"cannot be empty"* ]] || return 1

  run -1 gh-signoff create -f '' good
  [[ "$output" == *"cannot be empty"* ]] || return 1

  run -1 gh-signoff -f ''
  [[ "$output" == *"cannot be empty"* ]] || return 1

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

# The completion command was removed, but `eval "$(gh signoff completion)"`
# lives in users' shell startup files. With `completion` now an ordinary
# context word, that stale line would fall through to direct signoff and POST
# a false signoff/completion status in a clean, pushed repo, then eval the
# "✓ Signed off" sentence it captured. A tombstone arm intercepts it: no API
# call, nothing on stdout (so the captured eval is a safe no-op), a message
# on stderr, nonzero exit.
@test "the completion tombstone makes no API call and prints nothing on stdout" {
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run --separate-stderr -1 gh-signoff completion
  [[ -z "$output" ]] || return 1
  [[ "$stderr" == *"shell completion has been removed"* ]] || return 1
  [[ -f "$MOCK_CALL_LOG" && -s "$MOCK_CALL_LOG" ]] && return 1
  return 0
}

@test "the completion tombstone ignores trailing arguments like --contexts" {
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run --separate-stderr -1 gh-signoff completion --contexts
  [[ -z "$output" ]] || return 1
  [[ "$stderr" == *"shell completion has been removed"* ]] || return 1
  [[ -f "$MOCK_CALL_LOG" && -s "$MOCK_CALL_LOG" ]] && return 1
  return 0
}

@test "the completion tombstone catches a leading -f in a clean pushed repo" {
  # The core regression: -f plus a clean pushed repo would otherwise force a
  # POST. The leading option loop consumes -f, so $1 is still 'completion'
  # and the tombstone fires before any signoff happens.
  make_pushed_repo
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run --separate-stderr -1 gh-signoff -f completion
  [[ -z "$output" ]] || return 1
  [[ "$stderr" == *"shell completion has been removed"* ]] || return 1
  [[ -f "$MOCK_CALL_LOG" && -s "$MOCK_CALL_LOG" ]] && return 1
  return 0
}

@test "the completion tombstone catches a leading --commit in a clean pushed repo" {
  make_pushed_repo
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run --separate-stderr -1 gh-signoff --commit HEAD completion
  [[ -z "$output" ]] || return 1
  [[ "$stderr" == *"shell completion has been removed"* ]] || return 1
  [[ -f "$MOCK_CALL_LOG" && -s "$MOCK_CALL_LOG" ]] && return 1
  return 0
}

@test "create completion still signs off the literal context" {
  # The escape hatch: `create` takes its own arm before the tombstone, so a
  # context genuinely named 'completion' is still reachable
  make_pushed_repo
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run -0 gh-signoff create completion
  [[ "$output" == *"Signed off on"* ]] || return 1
  [[ "$output" == *"for completion"* ]] || return 1

  calls=$(cat "$MOCK_CALL_LOG")
  [[ "$calls" == *"POST repos/:owner/:repo/statuses/"* ]] || return 1
}

@test "the exact old initializer line signs nothing and errors cleanly" {
  # Headline regression: the literal line users were told to add to ~/.bashrc,
  #   eval "$(gh signoff completion)"
  # driven through a proxy that routes the `gh signoff` subcommand form to the
  # extension the way real gh does — the space form, not the gh-signoff binary
  # directly. In a clean pushed repo it must POST no status, and eval of the
  # (empty) stdout must not surface a "✓: command not found" or a "Signed off".
  make_pushed_repo
  use_gh_subcommand_proxy
  export MOCK_CALL_LOG="$TEST_DIR/calls.log"

  run eval "$(gh signoff completion)"
  [[ "$output" != *"command not found"* ]] || return 1
  [[ "$output" != *"Signed off"* ]] || return 1

  [[ -f "$MOCK_CALL_LOG" && -s "$MOCK_CALL_LOG" ]] && return 1
  return 0
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
    [[ "$output" == *"--commit is only valid for create, fail, and status"* ]] || return 1
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
