# gh-signoff

A GitHub CLI extension for local CI. Run your tests on your own machine and sign off when they pass.

Remote CI runners are fantastic for repeatable builds, comprehensive test suites, and parallelized execution. But many apps don't need all that. Maybe yours doesn't either.

Dev laptops are super fast these days. They're chronically underutilized. And you already own them. Cloud CI services are typically slow, expensive, and rented.

You already trusted your team with good test/push/deploy discipline. Merge queues, deployment pipelines, and high ceremony CI is … all too much.

A green GitHub commit status is just the ticket, but it's quite a hassle to get one WITHOUT renting cloud CI.

So let's do it ourselves. Bring CI back in-house.

Run your test suite (`rails test`) and sign off on your work when it passes (`signoff`).

You're the CI now. ✌️👀


## How to set up your app

```bash
# Install the extension
gh extension install basecamp/gh-signoff

# Require signoff to merge PRs
gh signoff install

# When your tests pass, sign off on your PR
gh signoff
```


### Bash completion

```bash
# Add to ~/.bashrc:
eval "$(gh signoff completion)"
```


## License
The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
