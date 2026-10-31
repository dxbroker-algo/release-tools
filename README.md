# release-tools

One script and two composite actions that turn a production deploy into a release:

- **the version**, from the squash-merge titles since the last tag;
- **an annotated tag `vX.Y.Z` on the commit that shipped**;
- **a GitHub Release** with the notes and the facts (sha, run, time, the Slack link);
- **one Slack post** per release, whose `ts` is recorded in the Release so screenshots can go in its thread;
- **`CHANGELOG.md` and the version file**, committed after the deploy as `chore(release): vX.Y.Z [skip ci]`.

The release job runs **after** the deploy and can only read it. It holds `contents: write`,
`pull-requests: read` and a Slack token, nothing else. When it fails, the deploy has already happened
and stays green.

Nothing about a calling repository is stored here. Titles, labels and PR bodies are read from it at
run time. Needs `bash`, `git`, `gh`, `jq` and `curl`, which every `ubuntu-latest` runner has.

## The rules

**A title** is read as

```
[visual review missing] type(scope)!: subject (#N)
└──── optional ───────┘     └opt┘└┘          └ added by the squash merge
```

Known types: `feat fix chore docs refactor test ci perf infra build style revert`.

| In the range | Bump |
|---|---|
| a `!`, or `BREAKING CHANGE:` at the start of a line in the squash body | **major**, but **minor while the major is 0**; listed under *Breaking* |
| otherwise any `feat` | **minor** |
| anything else, unknown types and free-form titles included | **patch** |

- The **first** release is `v0.1.0`. `1.0.0`, or any other version, is cut by hand with `version: 1.0.0`.
- **The range** is the first-parent commits from the last `v*` tag (exclusive) to the shipped sha
  (inclusive), with the `chore(release):` commits left out. With no tag yet, it starts where the
  retro section ends ([below](#the-retro-section)), or at the root commit.
- A sha that is **already tagged**, is **older than the last tag** (a rollback), or brings **nothing
  new** is a re-deploy. Nothing is cut. Kind `deploy` posts one `♻️ … re-deployed to prod` line, and
  the other kinds do nothing.
- **Every step is idempotent.** An existing tag is not cut again and an existing Release is not created
  again. An existing CHANGELOG entry is kept byte for byte. A Release that already records a post is
  not posted again. A run that crashed between the tag and the post is finished by the next run. One
  edge: if the post succeeds but `gh release edit` then fails, the Release still reads `Slack: pending`,
  and the next run at that sha posts a second time.
- **The CHANGELOG commit** is made on the remote branch's head, never on the deployed sha. When a
  merge lands in between and the push is refused, the job fetches, regenerates on the new head and
  pushes again, three times. After that it gives up (the step goes red) and **the next release writes
  every missing entry**, because the generator writes an entry for every tag that has none.

The CHANGELOG entry:

```
## [0.42.0] — 2026-10-29
Deployed `c7d34ad` · [CD run #292](…) · [Slack thread](…)

### Breaking
### Features
- feat(api): add the thing (T-12) ([#4](…))
### Fixes
- fix(ui): mend the other thing (T-13) ([#5](…)) ⚠ visual review missing
### Other
### Release notes
The `## Release note` section of a PR body, verbatim, one paragraph per PR ([#4](…))
```

An empty section is left out. **The CHANGELOG is generated, so never edit it by hand.** A human-facing
line goes in the PR body:

```markdown
## Release note
Users can now export their data as CSV.
```

**The Slack post**, `chat.postMessage` (mrkdwn, unfurling off):

```
🚀 *widget v0.42.0* is on prod — 1 feature, 1 fix  (<Release> · <CD run #292> · `c7d34ad`)
• feat(api): add the thing (T-12, #4)
• fix(ui): mend the other thing (T-13, #5)
📸 screenshots follow in this thread (release:visual on #5)
```

It shows at most eight bullets and then `+ n more in the Release`. Kind `store` reads *is live on the
Chrome Web Store* and kind `apply` reads *is applied*. The 📸 line, and `Screenshots: pending` in the
Release, appear when a PR in the range carries the label **`release:visual`**. Create that label once
per repository:

```sh
gh label create release:visual -c 7057ff -d "Screenshots go in the #releases thread" -R OWNER/REPO
```

**The post is best effort.** When Slack refuses or cannot be reached, or the token is missing, the
release still stands, the step still exits 0, and the Release says `Slack: not posted (<error>)`. To
post it again by hand, from a checkout of the repository:

```sh
SLACK_RELEASES_BOT_TOKEN=xoxb-… SLACK_RELEASES_CHANNEL=C… path/to/release.sh post v0.42.0
```

This posts the same text and then rewrites the Release's `Slack:` line. That line is the only edit a
Release ever gets.

**Where the `ts` lives:** the Release body (`Slack: <permalink>` and `<!-- slack_ts: 1730000000.000100 -->`),
the job's `slack_ts` output and summary, and the CHANGELOG entry's facts line (as the permalink). To reply
in the thread:

```sh
gh release view v0.42.0 -R OWNER/REPO --json body -q .body | grep slack_ts
```

Reply with `thread_ts` set to that value.

**The token** goes to `curl` on stdin as a config header. It is never on a command line and never in
the log, the outputs or the summary. A test holds this.

## Setup, once per repository

- Create a Slack app with the bot scope **`chat:write`** only, install it, and invite the bot to the
  channel (`/invite @<bot>`).
- Add a repository **secret `SLACK_RELEASES_BOT_TOKEN`** (`xoxb-…`) and a repository **variable
  `SLACK_RELEASES_CHANNEL`** (the channel id). On GitHub Free, organisation secrets do not reach
  private repositories, so each repository needs its own copy.
- Create the `release:visual` label (above).
- Commit the retro section ([below](#the-retro-section)) in the PR that adds the workflow.
- **Pin the actions by commit sha** (`@<sha>` in the examples), never by a branch.

## Consumers

The checkout must be full (`fetch-depth: 0`), and its token must be allowed to push the tag and the
release commit (`permissions: contents: write`; `actions/checkout` keeps the credentials by default).
It also needs `pull-requests: read`, because it reads each PR's labels and `## Release note` with
`gh pr view`. Without it, a private repository's release is still cut, with a warning, but without
the release notes and the `release:visual` line.
A push made with `GITHUB_TOKEN` starts no workflow, and `[skip ci]` is a second guard, so the release
commit cannot trigger the deploy again.

### A service deployed by CD (kind `deploy`)

The `release` job comes after the job that deploys and smoke-tests prod:

```yaml
  release:
    needs: deploy
    if: needs.deploy.result == 'success'
    continue-on-error: true          # a red release never fails the deploy run
    runs-on: ubuntu-latest
    permissions:
      contents: write                # the tag, the Release, the CHANGELOG commit
      pull-requests: read            # the labels and the release notes
    steps:
      - uses: actions/checkout@08eba0b27e820071cde6df949e0beb9ba4906955 # v4.3.0
        with:
          ref: ${{ github.sha }}
          fetch-depth: 0
      - uses: dxbroker-algo/release-tools/cut@<sha>
        with:
          kind: deploy
          version_file: pyproject.toml          # or package.json; "package.json package-lock.json"
          version: ${{ inputs.version }}        # a workflow_dispatch input, for 1.0.0; empty otherwise
          slack_token: ${{ secrets.SLACK_RELEASES_BOT_TOKEN }}
          slack_channel: ${{ vars.SLACK_RELEASES_CHANNEL }}
```

The version file is bumped by the release commit. It therefore reads the **last released** version,
while the tag on the sha says exactly what is running. When CD is re-run at an older sha (a rollback
by dispatch), the job posts `♻️ v0.41.0 re-deployed to prod (rollback from v0.42.0, …)` and cuts
nothing. A rollback done outside CD (traffic moved by hand) posts nothing, so post the `♻️` line in
the channel yourself.

### A browser extension published to the Chrome Web Store (kind `store`)

The version is the manifest's, bumped in the PR. It is released when the store shows it
**PUBLISHED**. The job tags **the bump commit**, which `release.sh` finds as the first-parent commit
that set `version: 'X.Y.Z'` in `bump_file`. The entry runs from the previous bump (exclusive) to this
bump (inclusive). The version files are not touched.

```yaml
  release:
    needs: publish
    if: needs.publish.outputs.state == 'PUBLISHED' && !inputs.dry_run
    continue-on-error: true
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: read
    steps:
      - uses: actions/checkout@08eba0b27e820071cde6df949e0beb9ba4906955 # v4.3.0
        with:
          fetch-depth: 0
      - uses: dxbroker-algo/release-tools/cut@<sha>
        with:
          kind: store
          version: ${{ needs.publish.outputs.version }}
          bump_file: manifest.config.ts
          backfill: true          # tags every earlier bump commit once (retro: no Slack); then a no-op
          slack_token: ${{ secrets.SLACK_RELEASES_BOT_TOKEN }}
          slack_channel: ${{ vars.SLACK_RELEASES_CHANNEL }}
```

When the tag already exists (the daily run), the step does nothing. `backfill` tags each earlier
version at its bump commit, dated with that commit's date. Each gets a Release marked *retro* and set
`--latest=false`, and no post. The version the manifest carries now is left for `cut`. To see the
plan first, run `release.sh backfill-ext --kind store --dry-run`.

### A Terraform repository applied by CD (kind `apply`)

Here the unit of release is the apply. CD applies master on merge, and a successful `apply` job is
a release. Even a no-op apply, such as a docs merge, is one. The `release` job has the deploy
section's shape. It holds no cloud credential, and nothing of Terraform runs in it.

```yaml
  release:
    needs: apply
    if: needs.apply.result == 'success'
    continue-on-error: true
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: read
    steps:
      - uses: actions/checkout@08eba0b27e820071cde6df949e0beb9ba4906955 # v4.3.0
        with:
          ref: ${{ github.sha }}
          fetch-depth: 0
      - uses: dxbroker-algo/release-tools/cut@<sha>
        with:
          kind: apply
          version_file: VERSION
          slack_token: ${{ secrets.SLACK_RELEASES_BOT_TOKEN }}
          slack_channel: ${{ vars.SLACK_RELEASES_CHANNEL }}
```

The tag goes on `github.sha`, the squash commit that was applied, and the post reads *is applied*.
A failed apply cuts nothing.

### The PR-title check (every repository)

The PR title becomes the squash title, which in turn becomes the version bump and the release note:

```yaml
name: pr-title
on:
  pull_request:
    types: [opened, edited, synchronize, reopened]
permissions: {}
jobs:
  pr-title:
    runs-on: ubuntu-latest
    steps:
      - uses: dxbroker-algo/release-tools/pr-title@<sha>
```

Without branch protection the check is advisory. The rule that a red `pr-title` check is not merged
is a team rule.

### Action outputs

`cut` sets `action` (`release`, `recovered`, `redeploy`, `noop` or `dry-run`), `released` (`true` when
a new version was cut), `version`, `tag`, `release_url` and `slack_ts`. It also writes a job summary.

## The retro section

The history before the first release is one section at the bottom of the CHANGELOG. It holds every
first-parent commit, `- YYYY-MM-DD title (#N)`, grouped by month, newest first. It is rendered once and
committed in the PR that adds the release job, so it is reviewed before it lands:

```sh
release.sh render-history --write                    # "## Before v0.1.0", through origin's default branch
release.sh render-history --write --through fd336e9~1 --heading "Before 0.3.1"   # an extension
```

The section records the commit it ends at (`<!-- release-tools history-through: <sha> -->`), and the
first release's range starts there. Releases never rewrite the section, and a correction to it is a
`docs(changelog):` PR.

## Dry run and the regeneration rule

```sh
release.sh cut --dry-run --version-file pyproject.toml   # the plan, the entry, the Slack text; writes nothing
release.sh render v0.41.0 v0.42.0                        # the entry that range gives today
```

`render A B` is a pure function of three inputs, read at render time: the first-parent squash titles in
`A..B`, the `release:visual` labels on those PRs, and the `## Release note` sections of their bodies.
A committed entry is valid while those three are unchanged. If `render` prints something different
today, someone edited a PR body or label after the cut: that is worth reporting, and it is not a defect.

## Subcommands

```
release.sh cut             [--kind deploy|store|apply] [--sha SHA] [--version X.Y.Z]
                           [--version-file PATH]... [--name NAME] [--dry-run]
release.sh render          FROM TO          (FROM '' : from the retro marker or the root)
release.sh render-history  [--through REF] [--heading TEXT] [--write]
release.sh post            vX.Y.Z [--kind …] [--force] [--dry-run]
release.sh backfill-ext    [--bump-file manifest.config.ts] [--retro-note TEXT] [--dry-run]
release.sh check-title     'feat(scope): subject'
release.sh --help
```

Environment: `SLACK_RELEASES_BOT_TOKEN`, `SLACK_RELEASES_CHANNEL`, `GH_TOKEN` (for `gh`),
`SLACK_API_URL` (tests), `RELEASE_NOW` (tests), `RELEASE_GIT_NAME` / `RELEASE_GIT_EMAIL` (the release
commit's author, `github-actions[bot]` by default).

## Development

```sh
make check        # shellcheck + bats
```

The tests build a throw-away origin and checkout per test. `gh` and `curl` are replaced by stubs in
`test/helpers/bin`, so nothing reaches GitHub or Slack. The suite runs under bash 3.2 (macOS) and
bash 5. On 3.2 a failing `[[ … ]]` or `! cmd` that is not a test's last line does not fail the test,
so every such assertion ends in `|| false`.

A change to the version rule, the message shapes or the file names is a change for every consumer.
Make it in a PR here, then move each consumer's pinned sha.

## Licence

MIT
