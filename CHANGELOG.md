# Changelog

## 0.4.1 — 2026-08-22

### Added

- **Statuses can carry a `target_url`**, so the Details link GitHub renders on every status goes somewhere useful. Pass `--url` to `create` or `fail` — a CI runner passes its run URL: `gh signoff fail --commit "$SHA" --url "$RUN_URL"` — or set a repo-wide default with `git config signoff.url`. With neither set, the status carries no `target_url` at all: a boilerplate link would dead-end people expecting CI results. Only `http(s)` URLs are accepted, refused before anything is posted. (#7, #25)
- **`gh signoff contexts`** lists the exact status-check contexts a branch requires, one full name per line on stdout — the shell-agnostic data source behind tab completion, and an answer to "what does this branch require?" that `check` only gives per named context. Takes `--branch`. A required name this CLI could not itself operate (quote, backslash, control character) is skipped with a count on stderr. `contexts` is a command word now, like `fail`: a context literally named `contexts` is reached with `gh signoff create contexts`. (#26)
- **Shell completion is back, and works this time.** 0.4.0 removed the `completion` command because `gh` doesn't route tab-completion to extensions; the command now emits a bash adapter that wraps `gh`'s *own* completion instead — so the line 0.4.0 told you to delete is once again the setup line, and you can put it back:

  ```bash
  eval "$(gh signoff completion)"
  ```

  Put it after gh's own completion line if you have one. `gh signoff <Tab>` completes commands, options, branches, and the branch's required contexts; everything else still reaches gh's completion, loaded on demand. Names from the API and from git are treated as data: candidates are inserted shell-escaped, or omitted when the quote context you're typing in has no safe spelling (non-ASCII names among them) — nothing API-derived is ever shell-evaluated. bash only for now; zsh and fish can build on `gh signoff contexts`. (#26)
- The recipe for letting a GitHub App, team, or role merge **without** signoff is documented: add it as a bypass actor on the `signoff` ruleset in repo settings. gh-signoff preserves `bypass_actors` across installs and uninstalls, so the grant sticks. Only possible on rulesets — one more reason for the 0.4.0 migration. (#10, #25)

## 0.4.0 — 2026-08-21

The first tagged release. Signoff enforcement moves from legacy branch protection to a repository ruleset.

### Changed

- **Enforcement is now a repository ruleset** named `signoff` (or `signoff (<branch>)` for a non-default branch) instead of legacy branch protection. Rulesets are visible to non-admins, can be toggled in the GitHub UI, and layer alongside any other rulesets your repository or organization defines — gh-signoff manages only its own. The ruleset still blocks force-pushes and branch deletion, and repository admins bypass it, preserving the old `enforce_admins` behavior. (#22)
- **`install` is additive; `uninstall <context>` is subtractive.** `gh signoff install lint` adds `signoff/lint` to whatever the ruleset already requires; `gh signoff uninstall lint` removes just that context. Previously a contextual uninstall removed *all* branch protection. A bare `gh signoff uninstall` deletes the ruleset only when it is pristine — exactly what gh-signoff writes — and otherwise removes only the signoff checks, leaving anything you've customized in place. (#22)
- **Context names accept any record/JSON-safe string.** The old identifier grammar existed only to make shell-completion candidates safe; with completion gone, a context may contain anything but a quote, backslash, or control character (`build/linux`, `qa review`, `déploiement`). Context identity is case-insensitive, matching how GitHub compares status check contexts: `uninstall tests` removes `signoff/Tests`, and a `SignOff` status satisfies a required `signoff`. (#22)
- **Stale tracking refs are refreshed before work is declared unpushed.** A CI runner's checkout (or any second machine) can hold the pushed commit while its remote-tracking ref is stale or absent. Signoff now fetches the ref it actually judges — the effective `@{push}`, or the upstream when falling back to it — once and rechecks, for both plain `gh signoff` and `--commit`. (#23)

### Added

- **`gh signoff fail`** posts a failing signoff status so a failed CI run — especially one detached on a runner — leaves a visible red mark instead of silence. Takes an optional context, `--commit`, and `--description`. A red status is a warning, not an attestation, so no cleanliness check or git identity is required. (#23)
- **Seamless upgrade from branch protection.** `check` and `status` still read legacy protection, with a hint to run `gh signoff install`. `install` migrates signoff-shaped protection into the ruleset and deletes it; protection you've customized (required reviews, other checks, admin enforcement, …) is left completely intact with a warning, and the ruleset enforces signoff alongside it. Only checks gh-signoff itself could have written are migrated — a signoff check pinned to a GitHub App is treated as foreign and never touched. (#22)

### Removed

- **The `completion` command.** It never worked through `gh signoff` — `gh` doesn't route tab-completion to extensions — so nothing is lost. **Remove `eval "$(gh signoff completion)"` from your shell startup file.** Leaving it in is harmless: the command now prints a reminder to stderr and exits. (#22)

### Known limitations

- `check`/`status` report a requirement only when the `signoff` ruleset is active and targets the branch by its canonical single-branch ref. A ruleset you've hand-retargeted with a wildcard (`refs/heads/*`, `~ALL`) reads as not required — the safe direction. Running `gh signoff install` reclaims canonical targeting.

## Earlier versions

Never tagged; versions as recorded in the script at the time.

- **0.3.0** — `--commit` to sign off on (or read the status of) an explicit commit. (#11)
- **0.2.2** — Handle CRLF status output on Windows and drop the external `jq` dependency; don't leak an internal error when `check` finds no requirement (#18); sign off on a branch checked out from a fork pull request (#21); test-harness fixes (#17, #19, #20).
- **0.2.1** — Bash 3 back-compat; fall back to `@{upstream}` when `@{push}` does not resolve (#16).
- **0.2.0** — Partial signoffs, `gh signoff <context>` (#3); `gh signoff status` (#4); Bash 3 compatibility (#6).
- **0.1.0** — Initial release: `gh signoff`, `install`, `uninstall`, `check`.
