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

### To require sign-off for PR merges

```bash
# Require sign-off to merge PRs
gh signoff install
```

## Advanced usage: Partial sign-off

A single sign-off is all you need for most projects. If you're feeling extra fancy, picky, or organized, you can use *partial* sign-off to reflect each CI step, each build platform (e.g. linux, macos, windows), each sign-off role (e.g. qa, dev, ops), etc.

```bash
# Sign off on CI steps
gh signoff tests      # Tests are green
gh signoff lint       # Linting checks pass
gh signoff security   # Security scan is happy

# Or all at once
gh signoff tests lint security
```

To require partial sign-off:

```bash
# Require partial sign-off for the default branch
gh signoff install security

# Require multiple sign-offs at once
gh signoff install tests lint security

# With a specific branch
gh signoff install --branch main tests lint security

# Check if partial sign-off is required
gh signoff check tests
gh signoff check --branch main tests lint security
```

### Bash completion

```bash
# Add to ~/.bashrc:
eval "$(gh signoff completion)"
```


## License
The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
