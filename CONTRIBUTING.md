# Contributing

Pull requests are welcome. Run `./tests/run-tests.sh` before opening one; CI
runs the same suite.

## Release-note trailers

Every pull request description ends with one or more
[git trailers](https://git-scm.com/docs/git-interpret-trailers) that the
release notes are written from. A check on each pull request reads them, and
fails until they are there. To fix a failing check, edit the description; you
do not need to change or force-push any commits.

```
Changelog: Secrets under the stack directory are private before every start.
Upgrade-Action: Run utilities/migrate-to-data-disk.sh once on an existing deployment.
```

- **`Changelog:`** (required) is one line for the release notes, written for
  someone running the stack: what changes for them, not how the code changed.
  Use `Changelog: none` when a user would not notice the change, such as a
  test, CI or comment change. Repeat the line for a pull request with several
  user-facing changes.
- **`Upgrade-Action:`** (optional) is something an existing deployment must do
  after updating to this change: run a script, edit `.env`, recreate a
  container. Leave it out when updating is enough on its own. A pull request
  with an Upgrade-Action cannot also say `Changelog: none`.

The trailers must be the **last paragraph** of the description, with a blank
line above them and nothing after them, because that is where git looks for
trailers. The pull request template puts them there for you. Pull requests
opened by Renovate or Dependabot are not checked.

## Versioning

Releases are git tags named `vMAJOR.MINOR.PATCH`. The repository is the
release: there is nothing to build, and a deployment updates by checking out
a tag. The number says what updating costs an existing deployment:

- **Major**: at least one change in the release has an `Upgrade-Action`, so
  updating takes more than pulling the new code.
- **Minor**: something new, and updating needs no action.
- **Patch**: fixes only, and updating needs no action.

A tag fixes the configuration and scripts in this repository, not the
container images. The stack runs floating image tags (`:latest`, `:master`),
which change whenever the host pulls them: by Watchtower, if its opt-in
profile is enabled, or by `docker-compose pull`.

## Cutting a release

1. Preview the notes from `master`:
   `./.github/scripts/release-notes.sh` (from the latest tag to `HEAD`).
   Choose the version from them, as above.
2. Tag `master` and push the tag:
   `git tag -a v3.1.0 -m v3.1.0 && git push origin v3.1.0`.
3. The **Draft a release** workflow creates a draft GitHub Release with those
   notes. Read it over, edit it if needed, and publish it.

## Repository settings this relies on

These are set once, in the repository's settings on GitHub:

- **Pull requests → Allow merge commits → Default commit message: "Pull
  request title and description".** This carries each description's trailers
  into its merge commit on `master`, where the release-notes script reads
  them. Without it, the merge commit holds only the title and the notes come
  out empty.
- **Rules → require the "Release-note trailers" status check** on
  pull requests to `master`, if the check should block merging rather than
  only warn.
