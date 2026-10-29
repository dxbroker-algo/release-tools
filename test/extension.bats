#!/usr/bin/env bats
# a browser extension: the manifest's version, tags at the bump commits,
# released when the store shows it PUBLISHED

load helpers/common

setup() { setup_fixture; }

# bump DATE VERSION TITLE: a squash merge that sets the manifest's version
bump() {
	printf "export default {\n  manifest_version: 3,\n  version: '%s',\n}\n" "$2" >manifest.config.ts
	git add manifest.config.ts
	land_on "$1" "$3"
}

history() {
	bump 2026-07-10 0.3.1 "feat: first public build (#1)"
	land_on 2026-07-12 "fix: popup (#2)"
	bump 2026-07-20 0.4.0 "feat: the sidebar; 0.4.0 (#3)"
	land_on 2026-08-01 "docs: readme (#4)"
	bump 2026-09-01 0.5.0 "feat: sync; 0.5.0 (#5)"
	land_on 2026-09-02 "fix: after the bump (#6)"
	bump 2026-10-27 0.6.0 "feat: 0.6.0 (#7)"
}

@test "backfill-ext: a tag per bump commit, dated with it, no Slack, the current version left" {
	history
	run "$RELEASE" backfill-ext --kind store
	[ "$status" -eq 0 ]
	[ "$(origin_tags | tr '\n' ' ')" = "v0.3.1 v0.4.0 v0.5.0 " ]
	[ "$(git -C "$ORIGIN" log -1 --format=%s 'v0.4.0^{commit}')" = "feat: the sidebar; 0.4.0 (#3)" ]
	[ "$(TZ=UTC git -C "$ORIGIN" for-each-ref --format='%(taggerdate:format-local:%Y-%m-%d)' refs/tags/v0.4.0)" = 2026-07-20 ]
	[ "$(slack_posts)" = 0 ]
	grep -q 'release create v0.3.1 .*--latest=false' "$GH_STATE/calls.log"
	grep -q '^<!-- release-tools retro -->$' "$GH_STATE/release-v0.4.0.md"
	grep -q '^retro — cut on 2026-10-29 from the bump commit' "$GH_STATE/release-v0.4.0.md"

	# entries: from the previous bump (exclusive) to this one (inclusive)
	origin_file CHANGELOG.md >"$FX/cl"
	[ "$(grep '^## ' "$FX/cl" | tr '\n' '|')" = "## [0.5.0] — 2026-09-01|## [0.4.0] — 2026-07-20|## [0.3.1] — 2026-07-10|" ]
	sed -n '/^## \[0.4.0\]/,/^## \[0.3.1\]/p' "$FX/cl" >"$FX/e"
	grep -q '^Published `[0-9a-f]\{7\}` · retro$' "$FX/e"
	grep -q '^- fix: popup' "$FX/e"
	grep -q '^- feat: the sidebar' "$FX/e"
	! grep -q 'first public build' "$FX/e" || false
	! grep -q 'docs: readme' "$FX/e" || false
	[ "$(origin_file manifest.config.ts | grep -c "version: '0.6.0'")" = 1 ]

	# a second backfill does nothing
	run "$RELEASE" backfill-ext --kind store
	[ "$status" -eq 0 ]
	[ "$(grep -c 'release create' "$GH_STATE/calls.log")" = 3 ]
}

@test "backfill-ext --dry-run lists what it would tag" {
	history
	run "$RELEASE" backfill-ext --kind store --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"would tag v0.3.1 on "*"would tag v0.5.0 on "* ]] || false
	[ -z "$(origin_tags)" ]
}

@test "store: PUBLISHED cuts the manifest's version at its bump commit; the daily re-run is a no-op" {
	history
	run "$RELEASE" backfill-ext --kind store
	git pull -q --ff-only origin master
	land_on 2026-10-28 "fix: lands after the bump, ships with the next version (#8)"

	run "$RELEASE" cut --kind store --version 0.6.0
	[ "$status" -eq 0 ]
	bump_sha=$(git log --format=%H -1 --grep='^feat: 0.6.0')
	[ "$(git -C "$ORIGIN" rev-parse 'v0.6.0^{commit}')" = "$bump_sha" ]
	[[ "$(slack_text 1)" == "🚀 *widget v0.6.0* is live on the Chrome Web Store — 1 feature, 1 fix  ("* ]] || false
	[[ "$(slack_text 1)" != *"lands after the bump"* ]] || false
	grep -q '^Published `' "$GH_STATE/release-v0.6.0.md"
	origin_file CHANGELOG.md | grep -q '^## \[0.6.0\] — 2026-10-29$'
	# the version files are the PR's, not the job's
	[ "$(origin_file manifest.config.ts | grep -c "version: '0.6.0'")" = 1 ]

	run "$RELEASE" cut --kind store --version 0.6.0
	[ "$status" -eq 0 ]
	[ "$(output action)" = noop ]
	[ "$(slack_posts)" = 1 ]
}

@test "store: a version no commit sets is refused" {
	history
	run "$RELEASE" cut --kind store --version 0.7.0
	[ "$status" -ne 0 ]
	[[ $output == *"no commit sets version 0.7.0"* ]] || false
}

@test "backfill-ext after the retro section landed: the first tag starts at its marker" {
	history
	first_bump=$(git log --format=%H -1 --grep='^feat: first public build')
	# the retro section arrives in a PR long after the first bump commits
	run "$RELEASE" render-history --write --through "$first_bump~1" --heading "Before 0.3.1"
	[ "$status" -eq 0 ]
	git add CHANGELOG.md
	land "docs(changelog): the retro section (#10)"

	run "$RELEASE" backfill-ext --kind store
	[ "$status" -eq 0 ]
	release_of v0.3.1 >"$FX/rel"
	grep -q '^- feat: first public build' "$FX/rel"
	! grep -q 'Initial commit' "$FX/rel" || false

	git pull -q --ff-only origin master
	run "$RELEASE" render '' v0.3.1
	[ "$status" -eq 0 ]
	[[ $output == *"- feat: first public build"* ]] || false
	[[ $output != *"Initial commit"* ]] || false

	# the entries above the retro section, which stays as written
	[ "$(grep '^## ' CHANGELOG.md | tr '\n' '|')" = "## [0.5.0] — 2026-09-01|## [0.4.0] — 2026-07-20|## [0.3.1] — 2026-07-10|## Before 0.3.1|" ]
	sed -n '/^## \[0.3.1\]/,/^## Before/p' CHANGELOG.md >"$FX/e"
	! grep -q 'Initial commit' "$FX/e" || false
	[ "$(sed -n '/^## Before/,$p' CHANGELOG.md | grep -c '^- ')" = 1 ]
}
