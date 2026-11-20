#!/usr/bin/env bats
# cut --kind hotfix: the base release plus cherry-picks, tagged and posted, no
# CHANGELOG commit; and the daily release after it: its version, its range, and
# the "already in prod" marking

load helpers/common

setup() { setup_fixture; }

# forget the Slack calls so far: the next slack_text 1 is the next post
clear_slack() { rm -f "${CURL_LOG:?}"/*; }

# a released v0.1.0 with the CHANGELOG commit pulled; a fix merged on master
# afterwards (FIX); the hotfix branch hotfix/v0.1.1 = v0.1.0 + that fix picked
# the way git cherry-pick -x writes it (HF). The commits are empty, so the pick is
# a commit with the same title and the -x trailer.
with_hotfix() { # [title]
	land "feat(api): the first thing (#1)"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	git pull -q --ff-only origin master
	BASE=$(git rev-parse v0.1.0)
	land "${1:-fix(auth): password reset sign-in (T-1710) (#931)}"
	FIX=$(git rev-parse HEAD)
	pick "$FIX" hotfix/v0.1.1 v0.1.0
	HF=$(git rev-parse HEAD)
	git checkout -q master
	: >"$GITHUB_OUTPUT"
	: >"$GITHUB_STEP_SUMMARY"
	clear_slack
}

# pick SHA BRANCH FROM: a commit on a new branch off FROM, as cherry-pick -x leaves it
pick() {
	git checkout -q -b "$2" "$3"
	git commit -q --allow-empty -m "$(git log -1 --format=%s "$1")" -m "(cherry picked from commit $1)"
	git push -q origin "$2"
}

hotfix() { run "$RELEASE" cut --kind hotfix --sha "$HF" --reason "https://acme.slack.com/archives/C0CKNJZ0022/p1" "$@"; }

@test "hotfix: an annotated tag on the hotfix sha, a titled Release, one post, nothing on master" {
	with_hotfix
	pr 931 -- $'## Release note\nusers: Brokers can sign in again after a password reset.\nasked-by: Max'
	before=$(git -C "$ORIGIN" rev-parse master)
	hotfix --by "the PM under S-34's standing yes" --suite "affected areas green, 5 min; full suite running after the deploy"
	[ "$status" -eq 0 ]

	[ "$(git -C "$ORIGIN" rev-parse 'v0.1.1^{commit}')" = "$HF" ]
	[ "$(git -C "$ORIGIN" cat-file -t v0.1.1)" = tag ]
	[ "$(git -C "$ORIGIN" tag -l --format='%(contents:subject)' v0.1.1)" = "hotfix on v0.1.0: #931" ]
	grep -q 'release create v0.1.1 --repo acme/widget --verify-tag --target '"$HF"' --title v0.1.1 (hotfix on v0.1.0)' "$GH_STATE/calls.log"
	release_of v0.1.1 >"$FX/rel"
	grep -q '^Hotfix on v0.1.0 · reason: https://acme.slack.com/archives/C0CKNJZ0022/p1$' "$FX/rel"
	grep -q '^Suite: affected areas green' "$FX/rel"
	grep -q '^Slack: https://acme.slack.com/archives/C0TEST/p1730000000000100$' "$FX/rel"

	[ "$(slack_posts)" = 1 ]
	expected="🩹 *widget v0.1.1* — hotfix on v0.1.0 (<https://github.com/acme/widget/releases/tag/v0.1.1|Release> · <https://github.com/acme/widget/actions/runs/111|CD run #7> · \`${HF:0:7}\`)
• Brokers can sign in again after a password reset. (#931, T-1710) · asked by Max
reason: https://acme.slack.com/archives/C0CKNJZ0022/p1 · by the PM under S-34's standing yes
suite: affected areas green, 5 min; full suite running after the deploy"
	[ "$(slack_text 1)" = "$expected" ]

	# no CHANGELOG commit, no commit of any kind on master
	[ "$(git -C "$ORIGIN" rev-parse master)" = "$before" ]
	[ "$(output version)" = 0.1.1 ]
	[ "$(output tag)" = v0.1.1 ]
	[ "$(output released)" = true ]
	[ "$(output action)" = release ]
}

@test "hotfix: a PR without a release note reads as its title; the actor is the default 'by'; no suite line" {
	with_hotfix
	hotfix
	[ "$status" -eq 0 ]
	expected="🩹 *widget v0.1.1* — hotfix on v0.1.0 (<https://github.com/acme/widget/releases/tag/v0.1.1|Release> · <https://github.com/acme/widget/actions/runs/111|CD run #7> · \`${HF:0:7}\`)
• fix(auth): password reset sign-in (T-1710, #931)
reason: https://acme.slack.com/archives/C0CKNJZ0022/p1 · by octocat"
	[ "$(slack_text 1)" = "$expected" ]
}

@test "hotfix: --reason is required" {
	with_hotfix
	run "$RELEASE" cut --kind hotfix --sha "$HF"
	[ "$status" -ne 0 ]
	[[ $output == *"--kind hotfix needs --reason"* ]] || false
	[ "$(origin_tags)" = v0.1.0 ]
}

@test "hotfix: a sha that is on master is a release, not a hotfix" {
	with_hotfix
	run "$RELEASE" cut --kind hotfix --sha "$FIX" --reason r
	[ "$status" -ne 0 ]
	[[ $output == *"is on master: that is a release, not a hotfix"* ]] || false
	[ "$(origin_tags)" = v0.1.0 ]
}

@test "hotfix: a stale base is refused when a release was cut since" {
	with_hotfix
	land "feat(api): another thing (#940)"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[ "$(origin_tags | sort | tr '\n' ' ')" = "v0.1.0 v0.2.0 " ]
	hotfix
	[ "$status" -ne 0 ]
	[[ $output == *"v0.2.0 was cut after the base v0.1.0"* ]] || false
	[ "$(origin_tags | sort | tr '\n' ' ')" = "v0.1.0 v0.2.0 " ]
}

@test "hotfix: --base must be the release the sha sits on" {
	with_hotfix
	hotfix --base v0.0.9
	[ "$status" -ne 0 ]
	[[ $output == *"sits on v0.1.0, not on v0.0.9"* ]] || false
	hotfix --base 0.1.0 --dry-run
	[ "$status" -eq 0 ]
}

@test "hotfix: the base release's own sha is a re-deploy, not a hotfix" {
	with_hotfix
	run "$RELEASE" cut --kind hotfix --sha "$BASE" --reason r
	[ "$status" -eq 0 ]
	[ "$(output action)" = redeploy ]
	[ "$(origin_tags)" = v0.1.0 ]
}

@test "hotfix: --dry-run prints the plan and the post, writes nothing" {
	with_hotfix
	hotfix --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *'tag v0.1.1 (annotated, "hotfix on v0.1.0: #931")'* ]] || false
	[[ $output == *"GitHub Release v0.1.1 (hotfix on v0.1.0) on acme/widget"* ]] || false
	[[ $output == *"no CHANGELOG commit"* ]] || false
	[[ $output == *"🩹 *widget v0.1.1* — hotfix on v0.1.0"* ]] || false
	[ "$(origin_tags)" = v0.1.0 ]
	[ "$(slack_posts)" = 0 ]
	[ "$(output action)" = dry-run ]
}

@test "hotfix: a second run at the same sha posts the re-deploy line and cuts nothing" {
	with_hotfix
	hotfix
	[ "$status" -eq 0 ]
	hotfix
	[ "$status" -eq 0 ]
	[ "$(origin_tags | sort | tr '\n' ' ')" = "v0.1.0 v0.1.1 " ]
	[ "$(slack_posts)" = 2 ]
	[[ "$(slack_text 2)" == *"widget v0.1.1* re-deployed to prod"* ]] || false
	[ "$(output action)" = redeploy ]
	[ "$(git -C "$ORIGIN" log --format=%s master | grep -c 'chore(release): v0.1.1')" = 0 ]
}

@test "hotfix: a run that finds the Release without its post finishes it, still as a hotfix" {
	with_hotfix
	SLACK_POST_RESPONSE='{"ok":false,"error":"ratelimited"}' hotfix
	[ "$status" -eq 0 ]
	release_of v0.1.1 | grep -q '^Slack: not posted (ratelimited)$'
	grep -q 'release create v0.1.1 .*--title v0.1.1 (hotfix on v0.1.0)' "$GH_STATE/calls.log"
	# a Release left with "Slack: pending" is announced on the next run
	sed 's/^Slack: not posted.*/Slack: pending/' "$GH_STATE/release-v0.1.1.md" >"$FX/rel.new"
	cp "$FX/rel.new" "$GH_STATE/release-v0.1.1.md"
	clear_slack
	hotfix
	[ "$status" -eq 0 ]
	[ "$(output action)" = recovered ]
	[[ "$(slack_text 1)" == "🩹 *widget v0.1.1* — hotfix on v0.1.0"* ]] || false
}

@test "hotfix on a hotfix: the base is the hotfix tag, the version is its patch + 1" {
	with_hotfix
	hotfix
	[ "$status" -eq 0 ]
	land "fix(auth): second urgent fix (#935)"
	second=$(git rev-parse HEAD)
	pick "$second" hotfix/v0.1.2 v0.1.1
	HF2=$(git rev-parse HEAD)
	git checkout -q master
	clear_slack
	run "$RELEASE" cut --kind hotfix --sha "$HF2" --reason r
	[ "$status" -eq 0 ]
	[ "$(output version)" = 0.1.2 ]
	[ "$(git -C "$ORIGIN" tag -l --format='%(contents:subject)' v0.1.2)" = "hotfix on v0.1.1: #935" ]
	# only the new pick is in this one
	[[ "$(slack_text 1)" != *"#931"* ]] || false
	[[ "$(slack_text 1)" == *"#935"* ]] || false
}

@test "hotfix: --version must be above the newest tag" {
	with_hotfix
	hotfix --version 0.1.0
	[ "$status" -ne 0 ]
	[[ $output == *"--version 0.1.0 is not above v0.1.0"* ]] || false
	hotfix --version 0.1.7
	[ "$status" -eq 0 ]
	[ "$(output tag)" = v0.1.7 ]
}

# ------------------------------------------------ the daily after a hotfix --

@test "the daily after a hotfix: bumps from the hotfix tag, ranges from it, marks the fix 'already in prod'" {
	with_hotfix
	pr 931 -- $'## Release note\nusers: Brokers can sign in again.'
	hotfix
	[ "$status" -eq 0 ]
	land "feat(contacts): call log tab (T-1698) (#940)"
	land "fix(bot): a thing (#941)"
	deployed=$(git rev-parse HEAD)
	clear_slack
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	# the highest tag is v0.1.1 (the hotfix): a feat on top is a minor
	[ "$(output version)" = 0.2.0 ]
	[ "$(git -C "$ORIGIN" rev-parse 'v0.2.0^{commit}')" = "$deployed" ]

	# the range holds every merge since the base, the fix's own merge included, marked
	release_of v0.2.0 >"$FX/rel"
	grep -q '^- fix(auth): password reset sign-in (T-1710) (\[#931\](https://github.com/acme/widget/pull/931)) (already in prod as v0.1.1)$' "$FX/rel"
	grep -q '^- feat(contacts): call log tab (T-1698) (\[#940\](https://github.com/acme/widget/pull/940))$' "$FX/rel"
	grep -q '^- fix(bot): a thing (\[#941\](https://github.com/acme/widget/pull/941))$' "$FX/rel"
	[ "$(grep -c 'already in prod' "$FX/rel")" = 1 ]

	text=$(slack_text 1)
	[[ $text == *"• fix(auth): password reset sign-in (T-1710, #931) (already in prod as v0.1.1)"* ]] || false
	[[ $text == *"• feat(contacts): call log tab (T-1698, #940)"$'\n'* ]] || false

	# the CHANGELOG: the hotfix is its own section, written by this cut
	origin_file CHANGELOG.md >"$FX/cl"
	grep -q '^## \[0.2.0\] — 2026-10-29$' "$FX/cl"
	grep -q '^## \[0.1.1\] — 2026-10-29$' "$FX/cl"
	grep -q "^Hotfix on v0.1.0, deployed \`${HF:0:7}\`" "$FX/cl"
	grep -q '^## \[0.1.0\] — 2026-10-29$' "$FX/cl"
	grep -q '(already in prod as v0.1.1)$' "$FX/cl"
	# newest version first
	[ "$(grep '^## \[' "$FX/cl" | cut -c1-9 | tr '\n' ' ')" = "## [0.2.0 ## [0.1.1 ## [0.1.0 " ]
	# the hotfix's own section lists the pick, unmarked
	awk '/^## \[0.1.1\]/ { on = 1; next } /^## \[/ { on = 0 } on' "$FX/cl" >"$FX/hf-section"
	grep -q '^- fix(auth): password reset sign-in (T-1710) (\[#931\]' "$FX/hf-section"
	! grep -q 'already in prod' "$FX/hf-section"
}

@test "the daily after a hotfix does not refuse for a newest tag that is not on master" {
	with_hotfix
	hotfix
	[ "$status" -eq 0 ]
	land "fix(bot): a thing (#941)"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[ "$(output released)" = true ]
	# a fix on top of a hotfix tag: a patch from the highest tag
	[ "$(output version)" = 0.1.2 ]
}

@test "the daily still refuses a sha that does not descend from what master released" {
	with_hotfix
	hotfix
	[ "$status" -eq 0 ]
	git checkout -q -b side "$(git rev-list --max-parents=0 HEAD)"
	git commit -q --allow-empty -m "feat: elsewhere (#9)"
	run "$RELEASE" cut
	[ "$status" -ne 0 ]
	[[ $output == *"does not descend from v0.1.0"* ]] || false
}

@test "the daily after two hotfixes marks each change with the tag that carried it" {
	with_hotfix
	hotfix
	[ "$status" -eq 0 ]
	land "fix(auth): second urgent fix (#935)"
	second=$(git rev-parse HEAD)
	pick "$second" hotfix/v0.1.2 v0.1.1
	HF2=$(git rev-parse HEAD)
	git checkout -q master
	run "$RELEASE" cut --kind hotfix --sha "$HF2" --reason r
	[ "$status" -eq 0 ]
	land "feat: a new thing (#950)"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	release_of v0.2.0 >"$FX/rel"
	grep -q '(\[#931\](https://github.com/acme/widget/pull/931)) (already in prod as v0.1.1)$' "$FX/rel"
	grep -q '(\[#935\](https://github.com/acme/widget/pull/935)) (already in prod as v0.1.2)$' "$FX/rel"
	[ "$(grep -c 'already in prod' "$FX/rel")" = 2 ]
}

@test "the release after that daily has no marking: the fix is behind its range" {
	with_hotfix
	hotfix
	[ "$status" -eq 0 ]
	land "feat: a new thing (#950)"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	git pull -q --ff-only origin master
	land "fix: later (#960)"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	release_of v0.2.1 >"$FX/rel"
	! grep -q 'already in prod' "$FX/rel"
}

@test "render: a range with a hotfixed merge carries the marking" {
	with_hotfix
	hotfix
	[ "$status" -eq 0 ]
	run "$RELEASE" render v0.1.1 master
	[ "$status" -eq 0 ]
	[[ $output == *"(already in prod as v0.1.1)"* ]] || false
}

@test "post --kind hotfix re-posts the hotfix text for an existing Release" {
	with_hotfix
	SLACK_POST_RESPONSE='{"ok":false,"error":"ratelimited"}' hotfix --by octocat
	[ "$status" -eq 0 ]
	clear_slack
	run "$RELEASE" post v0.1.1 --kind hotfix --reason "the thread"
	[ "$status" -eq 0 ]
	[[ "$(slack_text 1)" == "🩹 *widget v0.1.1* — hotfix on v0.1.0 ("*$'\nreason: the thread · by octocat' ]] || false
}
