#!/usr/bin/env bats
# render (the regeneration rule), render-history (the retro section), the post's shape

load helpers/common

setup() { setup_fixture; }

@test "render A B is a pure function of titles, labels and release notes" {
	land "feat: one (#1)"
	run "$RELEASE" cut
	git pull -q --ff-only origin master
	land "fix: two (#2)"
	run "$RELEASE" cut
	git pull -q --ff-only origin master

	run "$RELEASE" render v0.1.0 v0.1.1
	[ "$status" -eq 0 ]
	first=$output
	run "$RELEASE" render v0.1.0 v0.1.1
	[ "$output" = "$first" ]
	# it is the committed entry
	sed -n '/^## \[0.1.1\]/,/^## \[0.1.0\]/p' CHANGELOG.md | sed '$d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' >"$FX/committed"
	[ "$first" = "$(cat "$FX/committed")" ]

	# someone labels the PR after the cut: render reports it, the file does not move
	pr 2 -- $'## Release note\nMended.'
	run "$RELEASE" render v0.1.0 v0.1.1
	[ "$output" != "$first" ]
	[[ $output == *"Mended. ([#2]"* ]] || false
	git pull -q --ff-only origin master
	[ "$first" = "$(sed -n '/^## \[0.1.1\]/,/^## \[0.1.0\]/p' CHANGELOG.md | sed '$d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')" ]
}

@test "render of an untagged range reads Unreleased" {
	land "feat: one (#1)"
	run "$RELEASE" render HEAD~1 HEAD
	[ "$status" -eq 0 ]
	[[ ${lines[0]} == "## [Unreleased] — 2026-10-29" ]] || false
	[[ $output == *"- feat: one ([#1]("* ]] || false
	[[ $output != *"Initial commit"* ]] || false
}

@test "render-history: by month, newest first, dated lines, release commits left out" {
	land_on 2026-06-07 "feat: start (#1)"
	land_on 2026-06-20 "[visual review missing] fix(ui): button (#2)"
	land_on 2026-07-02 "chore(release): v9.9.9 [skip ci]"
	land_on 2026-09-15 "infra: bucket (#3)"
	run "$RELEASE" render-history --through master
	[ "$status" -eq 0 ]
	expected="## Before v0.1.0
<!-- release-tools history-through: $(git rev-parse HEAD) -->

### 2026-09
- 2026-09-15 infra: bucket ([#3](https://github.com/acme/widget/pull/3))

### 2026-06
- 2026-06-20 fix(ui): button ([#2](https://github.com/acme/widget/pull/2)) ⚠ visual review missing
- 2026-06-07 feat: start ([#1](https://github.com/acme/widget/pull/1))
- 2026-06-01 Initial commit"
	[ "$output" = "$expected" ]
}

@test "render-history --write; the first release then starts where the retro section ends" {
	land "feat: old (#1)"
	run "$RELEASE" render-history --write --heading "Before 0.3.1"
	[ "$status" -eq 0 ]
	head -1 CHANGELOG.md | grep -q '^# Changelog$'
	grep -q '^## Before 0.3.1$' CHANGELOG.md
	git add CHANGELOG.md
	land "docs(changelog): the retro section (#2)"
	land "feat: new (#3)"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[[ "$(slack_text 1)" == *"— 1 feature, 1 other change  ("* ]] || false
	[[ "$(slack_text 1)" != *"feat: old"* ]] || false
	origin_file CHANGELOG.md >"$FX/cl"
	[ "$(grep '^## ' "$FX/cl" | tr '\n' '|')" = "## [0.1.0] — 2026-10-29|## Before 0.3.1|" ]
	# the retro section is untouched by the release
	[ "$(sed -n '/^## Before/,$p' "$FX/cl")" = "$(git show HEAD:CHANGELOG.md | sed -n '/^## Before/,$p')" ]
}

@test "render-history --write keeps the release entries above it" {
	land "feat: one (#1)"
	run "$RELEASE" cut
	git pull -q --ff-only origin master
	run "$RELEASE" render-history --write --through master~1
	[ "$status" -eq 0 ]
	[ "$(grep '^## ' CHANGELOG.md | tr '\n' '|')" = "## [0.1.0] — 2026-10-29|## Before v0.1.0|" ]
}

@test "the post: at most eight bullets, breaking first, then + n more" {
	land "feat: one (#1)"
	run "$RELEASE" cut
	git pull -q --ff-only origin master
	for i in 2 3 4 5 6 7 8 9 10; do land "fix: f$i (#$i)"; done
	land "feat!: big (#11)"
	run "$RELEASE" cut --dry-run
	[ "$status" -eq 0 ]
	slack=$(printf '%s\n' "$output" | sed -n '/^== Slack ==$/,$p')
	[[ $slack == *"— 1 breaking change, 9 fixes  ("* ]] || false
	[ "$(printf '%s\n' "$slack" | grep -c '^• ')" = 8 ]
	[ "$(printf '%s\n' "$slack" | sed -n 3p)" = "• feat!: big (#11)" ]
	[ "$(printf '%s\n' "$slack" | tail -1)" = "+ 2 more in the Release" ]
}

@test "the post escapes mrkdwn control characters in titles" {
	land "fix: a < b & c > d (#1)"
	run "$RELEASE" cut --dry-run
	[[ $output == *"• fix: a &lt; b &amp; c &gt; d (#1)"* ]] || false
	[[ $output == *"- fix: a < b & c > d ([#1]("* ]] || false
}

@test "release:visual on several PRs; screenshots pending in the Release" {
	pr 1 release:visual
	pr 3 bug release:visual
	land "feat: a (#1)"
	land "fix: b (#2)"
	land "fix: c (#3)"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[[ "$(slack_text 1)" == *$'\n'"📸 screenshots follow in this thread (release:visual on #3, #1)" ]] || false
	grep -q '^Screenshots: pending (release:visual on #3, #1)$' "$GH_STATE/release-v0.1.0.md"
}

@test "gh cannot read PRs: one warning per PR, three at most, the render goes on" {
	export GH_FAIL_PR=1
	for i in 1 2 3 4 5; do land "fix: f$i (#$i)"; done
	run "$RELEASE" cut --dry-run
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | grep -c 'warning: gh pr view')" = 3 ]
	[[ $output == *"not reading PR metadata for the rest of this run"* ]] || false
	[[ $output == *"5 fixes, 1 other change"* ]] || false
}
