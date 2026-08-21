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

Without `-f`, signoff requires HEAD to be contained in `@{push}`. When `@{push}` doesn't resolve, signoff falls back to `@{upstream}` only in the narrow centralized case — `push.default` simple (or unset), an upstream on a real remote whose single push URL matches its fetch URL, and no `pushRemote`/`pushDefault`/push-refspec rerouting — and otherwise refuses. CI worktrees that check out a differently-named tracking branch may want `git config push.default upstream`. When the check would report published work as unpushed only because the tracking ref is stale or absent -- a CI runner's slot, or any second machine -- signoff fetches the branch's tracking ref once and rechecks.

### Signing off on a specific commit

`gh signoff` targets `HEAD`. To sign off on a different commit — handy with stacked or virtual branches (e.g. GitButler), where the commit under test isn't what's checked out:

```bash
gh signoff --commit abc1234
gh signoff --commit HEAD~1 tests
gh signoff status --commit abc1234
```

`--commit` takes anything `git rev-parse` resolves. The commit still has to be on a remote — a commit you haven't fetched can't be checked, so it needs `-f`, same as any other override.

A branch checked out from a cross-repository pull request (`gh pr checkout` on a fork PR) tracks a bare URL rather than a named remote, so it has no tracking ref for either `@{push}` or `@{upstream}` to resolve. Signoff asks that repository directly instead — one `git ls-remote` for the tracked ref — and accepts HEAD when it's contained in the advertised tip. If that tip isn't already in your repository, or a push wouldn't provably land on the same URL, it refuses rather than guess.

### Reporting a failure

When a run fails -- especially one detached on a CI runner, where silence
is indistinguishable from "never ran" -- leave a visible red mark:

```bash
gh signoff fail
gh signoff fail tests                      # a partial context
gh signoff fail --commit abc1234 --description "suite exploded"
```

A red status is a warning, not an attestation, so no cleanliness check
applies: the only requirement is that GitHub knows the commit.

### To require signoff for PR merges

```bash
# Require signoff to merge PRs
gh signoff install
```

`install` creates a repository ruleset named `signoff` (or `signoff (<branch>)` for a non-default branch) that requires the signoff commit status and — like the branch protection it replaces — blocks force pushes and branch deletion. Repository admins can bypass it, matching how signoff has always behaved. The ruleset layers alongside any other rulesets your repo or org defines; gh-signoff only ever touches its own.

Those ruleset names are reserved: gh-signoff treats a repository branch ruleset named `signoff` or `signoff (<branch>)` as its own. But it manages only the signoff namespace inside it — the `signoff` and `signoff/<context>` checks that aren't pinned to a GitHub App. Anything else (a non-signoff status check, a signoff check pinned to an App via its integration ID, an extra rule, admin-bypass or enforcement settings) is preserved exactly across install and uninstall; only your own signoff checks are added or removed. An App-pinned signoff check is treated the way legacy branch protection treats an App-bound one: preserved on writes, but not counted by `check`/`status` as a requirement a plain `gh signoff` could satisfy. A bare `uninstall` deletes the ruleset only when it is *pristine* — nothing but the shape gh-signoff writes: only unpinned signoff checks, no rule types other than its own, a non-strict policy, its default admin bypass, and its canonical targeting. If you've customized anything — a foreign check or rule, a strict policy, an extra bypass actor, a narrowed condition — it is not pristine, so uninstall keeps the ruleset and removes only the signoff checks. A contextual `uninstall <context>` likewise removes just that context, leaving any customized protection or other checks in place. And if two rulesets somehow share the reserved name, gh-signoff refuses to act until you remove the duplicate, rather than guess which one is real.

If you installed signoff on a branch that later *became* your default branch, gh-signoff still recognizes the older `signoff (<branch>)` ruleset as its own; running `install` again rewrites it to the canonical `signoff` shape.

`check` and `status` report a signoff requirement only when the ruleset is actively enforced **and** actually targets the branch. If you disable the ruleset, set it to evaluate (dry-run) mode, or retarget its conditions away from the branch (say to `refs/heads/release` only) in GitHub settings, `check` reports signoff as not required — because GitHub isn't enforcing it there. Running `gh signoff install` again re-activates the ruleset and reclaims its targeting to the branch, keeping its existing contexts. (The targeting check compares canonical single-branch refs, not wildcard patterns; a ruleset you've hand-retargeted with a wildcard that happens to cover the branch reads as not-required — the safe direction.)

### Context names

A context name you give gh-signoff — the part after `signoff/` — may contain anything except an unescaped quote, backslash, or control character. `tests`, `build/linux`, `qa review` and `déploiement` are all fine; only names that would break the request body or a record are refused, and an empty name is rejected. A space, `$` or `;` is allowed: a context name is never run by a shell — `create` sends it as an API field, and reads carry it as a data token — so it is inert. (An earlier release held context names to a strict identifier grammar; that existed only to make shell-completion candidates safe, and completion has since been removed, so the boundary is now simply record/JSON safety — which also keeps a migrated legacy context like `signoff/qa review` signable and removable.)

Two rules sit alongside naming, and they are deliberately different:

- **Enforcement is faithful, whatever the name.** Contexts already in an adopted ruleset are carried along untouched and written back exactly as GitHub spells them. gh-signoff does not edit a requirement it merely adopted.
- **Display is lossy.** Anything outside printable ASCII is shown as `?`, so a name can never reorder or repaint the line it appears on. This is *not* reversible or unique: two different names can display identically while staying entirely distinct in what they enforce.

Branch names follow the same record/JSON-safety rule — `feature/x` and worse are legitimate refs, named by your repository rather than by gh-signoff — and are shown through the same `?` display.

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

Existing signoff contexts carry over into the ruleset. If the branch protection held nothing but what old gh-signoff installs wrote, it's deleted and the ruleset takes over (carrying the same force-push and deletion guards the protection blocked by default). If you've customized it in any way — required reviews, other status checks, linear history, admin enforcement, explicit force-push or deletion allowances — install leaves it **completely intact** and does not impose its own guards; the ruleset simply enforces signoff alongside it (a harmless duplicate), and a warning points at the customized protection so you can clean it up by hand if you want a single source.

Only checks gh-signoff itself could have written count as its own: named exactly `signoff` or `signoff/<context>`, bound to no particular GitHub App, and containing nothing gh-signoff couldn't accept as a typed context (no quote, backslash, or control character). A signoff-named check you've pinned to an app is deliberately treated as foreign — it is never migrated, removed, or reported by `check`/`status`, and protection containing one is left alone. A signoff check whose name carries a quote, backslash, or control character (a 0.3.0 install could write one) is likewise left in place: gh-signoff only claims contexts it could also sign and remove from the command line, so it leaves that one for you to manage in repo settings rather than migrating it into a form you couldn't operate. An app-bound check disowns its unbound twin as well, and it does so case-insensitively, the way GitHub compares status check contexts: an app-bound `SignOff` makes a plain `signoff` foreign too. The endpoint that removes a context matches by name alone, so a removal aimed at the twin could take the app-bound requirement with it.

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
