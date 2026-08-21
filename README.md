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

### Signing off on a specific commit

`gh signoff` targets `HEAD`. To sign off on a different commit — handy with stacked or virtual branches (e.g. GitButler), where the commit under test isn't what's checked out:

```bash
gh signoff --commit abc1234
gh signoff --commit HEAD~1 tests
gh signoff status --commit abc1234
```

`--commit` takes anything `git rev-parse` resolves. The commit still has to be on a remote — a commit you haven't fetched can't be checked, so it needs `-f`, same as any other override.

A branch checked out from a cross-repository pull request (`gh pr checkout` on a fork PR) tracks a bare URL rather than a named remote, so it has no tracking ref for either `@{push}` or `@{upstream}` to resolve. Signoff asks that repository directly instead — one `git ls-remote` for the tracked ref — and accepts HEAD when it's contained in the advertised tip. If that tip isn't already in your repository, or a push wouldn't provably land on the same URL, it refuses rather than guess.

### To require signoff for PR merges

```bash
# Require signoff to merge PRs
gh signoff install
```

`install` creates a repository ruleset named `signoff` (or `signoff (<branch>)` for a non-default branch) that requires the signoff commit status and — like the branch protection it replaces — blocks force pushes and branch deletion. Repository admins can bypass it, matching how signoff has always behaved. The ruleset layers alongside any other rulesets your repo or org defines; gh-signoff only ever touches its own.

Those ruleset names are reserved: gh-signoff treats a repository branch ruleset named `signoff` or `signoff (<branch>)` as its own. But it manages only the signoff namespace inside it — the `signoff` and `signoff/<context>` checks. If you've added anything else to such a ruleset (a non-signoff status check, a check pinned to a GitHub App via its integration ID, an extra rule, admin-bypass or enforcement settings), all of it is preserved exactly across install and uninstall; only the signoff checks are added or removed. A bare `uninstall` deletes the ruleset only when it holds nothing but signoff checks and gh-signoff's own guards; if anything foreign remains, the ruleset is kept with just the signoff checks removed. And if two rulesets somehow share the reserved name, gh-signoff refuses to act until you remove the duplicate, rather than guess which one is real.

### Context names

A context name you give gh-signoff — the part after `signoff/` — must be an **identifier**: letters, digits, `.` `_` `/` `-`, starting with a letter or a digit. `tests`, `bash-3`, `build/linux` and `Lint` are all fine; `foo bar`, `-danger` and `café` are not.

The grammar is narrow on purpose. It keeps the signoff namespace coherent — a context you create is one you can also `install`, `check` and `uninstall` by exactly that name — and it keeps names free of the shell metacharacters and quoting hazards that have no place in a status-check context. The same grammar governs `install`, `check`, `uninstall` and `gh signoff <context>` alike.

Two other rules sit alongside it, and they are deliberately different:

- **Enforcement is faithful, whatever the name.** Contexts already in an adopted ruleset are carried along untouched and written back exactly as GitHub spells them, identifier or not. gh-signoff does not edit a requirement it merely adopted.
- **Display is lossy.** Anything outside printable ASCII is shown as `?`, so a name can never reorder or repaint the line it appears on. This is *not* reversible or unique: two different names can display identically while staying entirely distinct in what they enforce. Distinguishing them on screen would mean a Unicode escaping engine written in bash, for names the tool refuses to create in the first place.

Branch names are held to neither — `feature/x` and worse are legitimate refs, and a branch is named by your repository rather than by gh-signoff. They are only checked for what would break a request body, and shown through the same `?` display.

Installing is additive: running `install` again with new contexts adds them to whatever the ruleset already requires. Uninstalling subtracts:

```bash
gh signoff uninstall tests   # stop requiring signoff on tests, keep the rest
gh signoff uninstall         # remove the signoff requirement entirely
```

GitHub treats status check contexts as case-insensitive, and so does gh-signoff: `uninstall tests` removes a `signoff/Tests` requirement, `check tests` finds it, and a `SignOff` status satisfies a required `signoff`. Whatever spelling is already configured is the one kept.

### Upgrading from branch protection

Versions before 0.4.0 enforced signoff with legacy branch protection. Everything keeps working on those repos — `check` and `status` read both — but to move onto a ruleset, run once per protected branch:

```bash
gh signoff install
gh signoff install --branch other
```

Existing signoff contexts carry over into the ruleset. If the branch protection held nothing but what old gh-signoff installs wrote, it's deleted; if you've layered other settings onto it (required reviews, other status checks, linear history, admin enforcement), those all stay — only the signoff status-check contexts are removed from it, since the ruleset enforces them now.

Only checks gh-signoff itself could have written count as its own: named exactly `signoff` or `signoff/<context>` and bound to no particular GitHub App. A signoff-named check you've pinned to an app is deliberately treated as foreign — it is never migrated, removed, or reported by `check`/`status`, and protection containing one is left alone. An app-bound check disowns its unbound twin as well, and it does so case-insensitively, the way GitHub compares status check contexts: an app-bound `SignOff` makes a plain `signoff` foreign too. The endpoint that removes a context matches by name alone, so a removal aimed at the twin could take the app-bound requirement with it.

### Shell completion has been removed

0.4.0 removes the `completion` command. It never actually worked through `gh signoff` — `gh` doesn't route tab-completion to extensions — so nothing was lost, but if you followed the old setup instructions you have a stale line to delete. **Remove this from your shell startup file (e.g. `~/.bashrc`):**

```bash
eval "$(gh signoff completion)"
```

Leaving it in is harmless — `gh signoff completion` now just prints a reminder to stderr and exits without signing anything — but it does nothing useful.

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

# Stop requiring a context without touching the others
gh signoff uninstall lint
```

### Checking signoff status

Check whether you've signed off on the current commit:

```bash
gh signoff status
✓ signoff
```

Check a specific commit:

```bash
gh signoff status --commit abc1234
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

## License
The tool is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
