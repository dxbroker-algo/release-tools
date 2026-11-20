# release-tools

One script and three composite actions (`cut`, `pr-title`, `post-merge`) that turn a production deploy into a release:

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
users: Brokers can now export their contacts as a CSV file.
```

The line has a shape of its own: [the release-note check](#the-release-note-check-every-repository).

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

### The merge post (a repository that deploys staging on merge)

`post-merge` is the last job of the workflow that deploys master to staging. It posts **one message per
merge** to the merge channel, in plain words, and **edits it in place** as its state changes. It is not a
release: nothing is tagged.

```
🟢 *Contacts* · for users — Brokers see a Call log tab in Contacts, with missed calls and voicemails (CRM look, staging only)
frontend <PR link|#786> · T-1698 · asked by Leon · staging ✅ <run|deployed> · prod ⏳ next release Sat 21 Nov 03:47Z · 🖼 screenshots in thread
```

| Field | Where it comes from |
|---|---|
| the icon | the staging deploy's outcome, the `staging` input: 🟢 `success`, 🟥 `failure` (staging not updated), 🟨 `held` |
| the area | the title's conventional-commit scope, through the map in `area_map` in `release.sh` (`contacts`, `contact-modal` → Contacts; `crm-shell` → CRM look; `bot`; `broadcast` → Broadcasts; `listing-send` → Listings; `calls`; `agreements`; `release`, `ci` → Release & CI). An unmapped scope shows capitalised as it is, and `pr-title` warns. No scope: no area |
| the audience and the line | the PR's `## Release note` ([below](#the-release-note-check-every-repository)): `users:` → "for users"; `internal:` and `tests:` show as they are |
| the repo | the repository's name, without a `dxb-` prefix |
| the PR | the title's `(#N)`, linked; a commit without one shows its short sha |
| the task | the first `T-NNN` of the title, else of the squash body |
| asked by | the note's `asked-by:` line, left out without one |
| staging | the run's link, and `deployed`, `not updated` or `held` |
| prod | `next release <day> <time>Z`, computed from the first `cron: 'M H * * *'` in `.github/workflows/release.yml` **at the merged commit**; `next release` with no time when that file has no daily cron; `releases paused` when the `release_paused` input is `true` |
| `migration <id>` | the files the merge **added** under `migrations` (`alembic/versions`): the file's `revision = "…"`, else its name without the extension. An edited migration is not named. A **shallow checkout** has no parent to compare with, so it names none and warns: check out with `fetch-depth: 2` |
| `🖼 screenshots in thread` | the PR carries `release:visual`; the screenshots go in this post's thread |

- **A PR with no valid note** posts the squash title and ends it with `(no release note)`, at the top level.
  `[visual review missing]` moves to the end as `⚠ visual review missing`.
- **Internal and tests merges** are not top-level posts. Each is **a reply in a daily thread**, whose parent,
  `🧰 Internal and test changes, Fri 20 Nov (UTC)`, the first such merge of the UTC day creates:

  ```
  tests · backend <PR link|#914> · T-1650 — The calls area's tests were cut from 2,448 to 1,232. · <run|staging ✅>
  ```

  The parent is found by reading the channel's recent history for the bot's own message with that first
  line, which takes the `channels:history` scope (`groups:history` in a private channel). **Without it**
  (or when the bot is not in the channel) the merge is posted as the same line at the top level, prefixed
  `🧰`, with a warning. **A merge that adds a migration or carries `release:visual` is always top level**,
  whatever its audience.
- **`before`** is the push's previous head (`github.event.before`). Every merge in `before..sha` is
  posted, oldest first, at most 20, so a train landed in one push is not reduced to its last commit.
  A zero, unknown or non-ancestor `before` posts `sha` alone.
- **The channel** is `SLACK_MERGES_CHANNEL`, **never** `SLACK_RELEASES_CHANNEL`: once `#releases` is
  renamed, that variable names the other channel. The token is the same bot's `SLACK_RELEASES_BOT_TOKEN`.

**One message per merge, edited in place.** Run the job whatever the deploy's outcome and say how it ended
with `staging` (`success`, `failure` or `held`), so a red deploy is a 🟥 message and not a silence. **A merge
posted 🟥 or 🟨 is edited to 🟢 by a later green run**: a re-run of the same workflow, or the next push, which
also looks at the ten merges before its own (they need to be in the checkout: `fetch-depth` deep enough)
and edits those whose message still says staging lacks them. A message that says 🟢 is never edited back,
and a re-run with the same state posts and edits nothing.

**Where the `ts` lives:** a PR comment, the merge's handle:

```
Posted to the merge channel: <permalink>

<!-- release-tools merge-post: sha=<full sha> ts=1730000000.000100 channel=C0… state=success form=top -->
```

`state` is `success`, `failure` or `held`; `form` is `top`, `reply` (in the daily thread) or `compact`. The
last such comment for a sha is the handle: a state change writes a new one. A comment with no `state` or
`form` (an earlier version's) reads as `success` and `top`. To thread the screenshots:

```sh
gh pr view N -R OWNER/REPO --json comments -q '.comments[].body' | grep merge-post
```

Reply with `thread_ts` set to that `ts`.

**It is best effort,** like the release post. Slack refusing, a missing token or channel, or a comment
that cannot be written is a warning on a step that exits 0, and the `posted` and `updated` outputs say how
many went out. It never fails the staging deploy.

```yaml
  merge-post:
    needs: deploy                    # the job that deploys staging and smoke-tests it
    if: always() && needs.deploy.result != 'cancelled'
    continue-on-error: true
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write           # the handle is a PR comment
    steps:
      - uses: actions/checkout@08eba0b27e820071cde6df949e0beb9ba4906955 # v4.3.0
        with:
          fetch-depth: 12            # the push's merges, and the ten before it
      - uses: dxbroker-algo/release-tools/post-merge@<sha>
        with:
          staging: ${{ needs.deploy.result }}   # success; any other result is "not updated"
          release_paused: ${{ vars.RELEASE_PAUSED }}
          migrations: alembic/versions         # backend only
          slack_token: ${{ secrets.SLACK_RELEASES_BOT_TOKEN }}
          slack_channel: ${{ vars.SLACK_MERGES_CHANNEL }}
```

With a `before` that is more than a few commits back, check out `fetch-depth: 0` (a train's commits must be
present to be read). A held deploy passes `staging: held`.

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

### The release-note check (every repository)

The `## Release note` section of a PR body is the line the merge post says in plain words. It holds **one
line** (and optionally a second, `asked-by:`):

```markdown
## Release note
users: Brokers see a Call log tab in Contacts, with missed calls and voicemails (CRM look, staging only).
asked-by: Leon
```

1. **The prefix is the audience:** `users:` (a broker or client sees or feels it, a bug fix they would notice
   included), `internal:` (the team sees it: admin, ops, CI, the release flow), `tests:` (tests or tooling
   only; no user-facing or runtime change). It is lowercase, then a colon and a space.
2. **After it, 20 to 200 characters** of plain English for Stas, Leon or Max: what a person can now do, or what
   is fixed. **No `T-` id** (the post adds the task itself), **no file name** (a word ending in `.py`, `.ts`,
   `.tsx`, `.js`, `.jsx`, `.yml`, `.yaml`, `.sh`, `.json`, `.md`, `.sql` or `.toml`), **not the PR title**
   (whole, or after its `type(scope):`), and **no Hebrew or Arabic letters**.
3. **`asked-by: <name>`**, up to 40 characters, when a person asked for the change.

HTML comments in the section are ignored, so a template can carry its guidance there. The `tests:` prefix is
not checked against the diff: the reviewer reads the note.

```yaml
name: pr-note
on:
  pull_request:
    types: [opened, edited, synchronize, reopened]   # `edited`: fixing the body re-runs it, no push needed
permissions: {}
jobs:
  pr-note:
    runs-on: ubuntu-latest
    steps:
      - uses: dxbroker-algo/release-tools/pr-note@<sha>
```

When it fails, the step prints the section it read and the first rule broken. Without branch protection the
check is advisory, like `pr-title`. A PR that merges without a valid note is posted with its title and
`(no release note)`. The note is read at merge time, and a body edited after the merge does not change
the post.

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
release.sh check-note      ['PR title'] < pr-body
release.sh post-merge      [--sha SHA] [--before SHA] [--migrations PATH]... [--staging success|failure|held] [--dry-run]
release.sh --help
```

Environment: `SLACK_RELEASES_BOT_TOKEN`, `SLACK_RELEASES_CHANNEL` (`post-merge` reads
`SLACK_MERGES_CHANNEL` instead), `GH_TOKEN` (for `gh`),
`RELEASE_PAUSED` (`post-merge`: `true` says "releases paused" in place of the next release time),
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
