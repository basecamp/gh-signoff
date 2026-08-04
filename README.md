# gh-signoff

A GitHub CLI extension for local CI. Run your tests on your own machine and sign off when they pass.

Remote CI runners are fantastic for repeatable builds, comprehensive test suites, and parallelized execution. But many apps don't need all that. Maybe yours doesn't either.

Dev laptops are super fast these days. They're chronically underutilized. And you already own them. Cloud CI services are typically slow, expensive, and rented.

You already trusted your team with good test/push/deploy discipline. Merge queues, deployment pipelines, and high ceremony CI is … all too much.

A green GitHub commit status is just the ticket, but it's quite a hassle to get one WITHOUT renting cloud CI.

So let's do it ourselves. Bring CI back in-house.

Run your test suite (`rails test`) and sign off on your work when it passes (`gh signoff`).

You're the CI now. ✌️👀


## How to sign off

```bash
# Install the extension
gh extension install basecamp/gh-signoff

# When your tests pass, sign off on your PR
gh signoff
```

Without `-f`, signoff requires HEAD to be contained in `@{push}`. When `@{push}` doesn't resolve, signoff falls back to `@{upstream}` only in the narrow centralized case — `push.default` simple (or unset), an upstream on a real remote whose single push URL matches its fetch URL, and no `pushRemote`/`pushDefault`/push-refspec rerouting — and otherwise refuses. CI worktrees that check out a differently-named tracking branch may want `git config push.default upstream`.

A branch checked out from a cross-repository pull request (`gh pr checkout` on a fork PR) tracks a bare URL rather than a named remote, so it has no tracking ref for either `@{push}` or `@{upstream}` to resolve. Signoff asks that repository directly instead — one `git ls-remote` for the tracked ref — and accepts HEAD when it's contained in the advertised tip. If that tip isn't already in your repository, or a push wouldn't provably land on the same URL, it refuses rather than guess.

### To require signoff for PR merges

```bash
# Require signoff to merge PRs
gh signoff install
```

## Advanced usage: Partial signoff

A single signoff is all you need for most projects. If you're feeling extra fancy, picky, or organized, you can use *partial* signoff to reflect each CI step, each build platform (e.g. linux, macos, windows), each signoff role (e.g. qa, dev, ops), etc.

```bash
# Sign off on CI steps
gh signoff tests      # Tests are green
gh signoff lint       # Linting checks pass
gh signoff security   # Security scan is happy

# Or all at once
gh signoff tests lint security
```

To require partial signoff:

```bash
# Require partial signoff for the default branch
gh signoff install security

# Require multiple signoffs at once
gh signoff install tests lint security

# With a specific branch
gh signoff install --branch main tests lint security

# Check if partial signoff is required
gh signoff check tests
gh signoff check --branch main tests lint security
```

### Checking signoff status

Check whether you've signed off on the current commit:

```bash
gh signoff status
✓ signoff
```

With partial signoff:

```bash
gh signoff status
✓ signoff
✓ tests
✗ lint
✗ security
```

### Bash completion

```bash
# Add to ~/.bashrc:
eval "$(gh signoff completion)"
```


## License
The tool is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
