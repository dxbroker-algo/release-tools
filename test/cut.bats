#!/usr/bin/env bats
# the whole chain: tag, Release, Slack, CHANGELOG commit; idempotence,
# re-deploys, the refused push, Slack failures, the token

load helpers/common

setup() { setup_fixture; }

@test "cut: annotated tag on the deployed sha, Release, post, CHANGELOG commit" {
	printf '[project]\nname = "widget"\nversion = "0.0.0"\n\n[tool.x]\nversion = "9"\n' >pyproject.toml
	git add pyproject.toml
	land "feat(api): add the thing (T-12) (#4)"
	land "fix: mend the other thing (#5)"
	deployed=$(git rev-parse HEAD)

	run "$RELEASE" cut --version-file pyproject.toml
	[ "$status" -eq 0 ]

	# the tag: annotated, on the deployed sha, by the bot
	[ "$(git -C "$ORIGIN" rev-parse 'v0.1.0^{commit}')" = "$deployed" ]
	[ "$(git -C "$ORIGIN" cat-file -t v0.1.0)" = tag ]
	[[ "$(git -C "$ORIGIN" for-each-ref --format='%(taggername)' refs/tags/v0.1.0)" == "github-actions[bot]" ]] || false

	# the Release: notes, facts, the Slack line and the ts
	release_of v0.1.0 >"$FX/rel"
	grep -q '^### Features$' "$FX/rel"
	grep -q "^Deployed \`$deployed\` · \[CD run #7\](https://github.com/acme/widget/actions/runs/111) · 2026-10-29T12:00:00Z$" "$FX/rel"
	grep -q '^Slack: https://acme.slack.com/archives/C0TEST/p1730000000000100$' "$FX/rel"
	grep -q '^<!-- slack_ts: 1730000000.000100 -->$' "$FX/rel"
	grep -q 'release create v0.1.0 --repo acme/widget --verify-tag' "$GH_STATE/calls.log"

	# one post, the expected text, links not unfurled
	[ "$(slack_posts)" = 1 ]
	[ "$(jq -r .channel "$CURL_LOG/data.1")" = C0TEST ]
	[ "$(jq -r .unfurl_links "$CURL_LOG/data.1")" = false ]
	# no retro section: the first release reaches back to the root commit
	expected="🚀 *widget v0.1.0* is on prod — 1 feature, 1 fix, 1 other change  (<https://github.com/acme/widget/releases/tag/v0.1.0|Release> · <https://github.com/acme/widget/actions/runs/111|CD run #7> · \`${deployed:0:7}\`)
• feat(api): add the thing (T-12, #4)
• fix: mend the other thing (#5)
• Initial commit"
	[ "$(slack_text 1)" = "$expected" ]

	# the commit after the deploy: CHANGELOG + version file, by the bot, [skip ci]
	[ "$(git -C "$ORIGIN" log -1 --format='%s|%an' master)" = "chore(release): v0.1.0 [skip ci]|github-actions[bot]" ]
	[ "$(git -C "$ORIGIN" rev-parse master^)" = "$deployed" ]
	origin_file pyproject.toml >"$FX/py"
	grep -q '^version = "0.1.0"$' "$FX/py"
	grep -q '^version = "9"$' "$FX/py"
	origin_file CHANGELOG.md >"$FX/cl"
	grep -q '^# Changelog$' "$FX/cl"
	grep -q "^## \[0.1.0\] — 2026-10-29$" "$FX/cl"
	grep -q "^Deployed \`${deployed:0:7}\` · \[CD run #7\](https://github.com/acme/widget/actions/runs/111) · \[Slack thread\](https://acme.slack.com/archives/C0TEST/p1730000000000100)$" "$FX/cl"
	grep -q '^- feat(api): add the thing (T-12) (\[#4\](https://github.com/acme/widget/pull/4))$' "$FX/cl"

	[ "$(output version)" = 0.1.0 ]
	[ "$(output released)" = true ]
	[ "$(output slack_ts)" = 1730000000.000100 ]
	grep -q '^### widget v0.1.0$' "$GITHUB_STEP_SUMMARY"
}

@test "version files: package.json, package-lock.json and a plain VERSION" {
	printf '{\n  "name": "w",\n  "version": "0.0.0",\n  "dependencies": {\n    "x": {\n      "version": "1.2.3"\n    }\n  }\n}\n' >package.json
	printf '{\n  "name": "w",\n  "version": "0.0.0",\n  "lockfileVersion": 3,\n  "packages": {\n    "": {\n      "name": "w",\n      "version": "0.0.0"\n    }\n  }\n}\n' >package-lock.json
	git add package.json package-lock.json
	land "feat: x (#1)"
	run "$RELEASE" cut --version-file package.json --version-file package-lock.json --version-file VERSION
	[ "$status" -eq 0 ]
	[ "$(origin_file package.json | jq -r .version)" = 0.1.0 ]
	[ "$(origin_file package.json | jq -r .dependencies.x.version)" = 1.2.3 ]
	[ "$(origin_file package-lock.json | jq -r '.version + " " + .packages[""].version')" = "0.1.0 0.1.0" ]
	[ "$(origin_file VERSION)" = 0.1.0 ]
}

@test "a second run at the same sha cuts nothing and posts the re-deploy line" {
	land "feat: x (#1)"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	before=$(git -C "$ORIGIN" rev-parse master)
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[ "$(origin_tags)" = v0.1.0 ]
	[ "$(git -C "$ORIGIN" rev-parse master)" = "$before" ]
	[ "$(grep -c 'release create' "$GH_STATE/calls.log")" = 1 ]
	[ "$(slack_posts)" = 2 ]
	[[ "$(slack_text 2)" == "♻️ *widget v0.1.0* re-deployed to prod (sha \`"*"\`) by octocat  (<https://github.com/acme/widget/actions/runs/111|CD run #7>)" ]] || false
	[ "$(output action)" = redeploy ]
	[ "$(output released)" = false ]
}

@test "--kind apply: a second run is a no-op, nothing posted" {
	land "feat: x (#1)"
	run "$RELEASE" cut --kind apply --version-file VERSION
	[ "$status" -eq 0 ]
	[[ "$(slack_text 1)" == "🚀 *widget v0.1.0* is applied — 1 feature"* ]] || false
	run "$RELEASE" cut --kind apply --version-file VERSION
	[ "$status" -eq 0 ]
	[ "$(slack_posts)" = 1 ]
	[ "$(output action)" = noop ]
}

@test "rollback to an older tagged sha: the rollback line, nothing cut" {
	land "feat: one (#1)"
	run "$RELEASE" cut
	old=$(git rev-parse HEAD)
	git pull -q --ff-only origin master
	land "feat: two (#2)"
	run "$RELEASE" cut
	[ "$(output version)" = 0.2.0 ]
	git checkout -q "$old"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[ "$(origin_tags | tr '\n' ' ')" = "v0.1.0 v0.2.0 " ]
	[[ "$(slack_text 3)" == "♻️ *widget v0.1.0* re-deployed to prod (rollback from v0.2.0, sha \`${old:0:7}\`) by octocat"* ]] || false
}

@test "rollback to an untagged older sha: the rollback line, nothing cut" {
	land "feat: one (#1)"
	run "$RELEASE" cut
	git pull -q --ff-only origin master
	land "fix: a (#2)"
	mid=$(git rev-parse HEAD)
	land "fix: b (#3)"
	run "$RELEASE" cut
	[ "$(output version)" = 0.1.1 ]
	git checkout -q "$mid"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[ "$(origin_tags | tr '\n' ' ')" = "v0.1.0 v0.1.1 " ]
	[[ "$(slack_text 3)" == "♻️ *widget ${mid:0:7}* re-deployed to prod (rollback from v0.1.1, after v0.1.0) by octocat"* ]] || false
}

@test "a deploy with nothing but release commits since the tag is a re-deploy" {
	land "feat: one (#1)"
	run "$RELEASE" cut
	git pull -q --ff-only origin master
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[ "$(origin_tags)" = v0.1.0 ]
	[[ "$(slack_text 2)" == *"no changes since v0.1.0"* ]] || false
}

@test "a sha that does not descend from the last tag is refused" {
	land "feat: one (#1)"
	run "$RELEASE" cut
	git checkout -q -b side HEAD~1
	git commit -q --allow-empty -m "feat: elsewhere (#9)"
	run "$RELEASE" cut
	[ "$status" -ne 0 ]
	[[ $output == *"does not descend from v0.1.0"* ]] || false
	[ "$(origin_tags)" = v0.1.0 ]
}

@test "a refused push is retried on the new head, keeping the merge that landed meanwhile" {
	land "feat: one (#1)"
	deployed=$(git rev-parse HEAD)
	git commit -q --allow-empty -m "fix: landed meanwhile (#2)"
	git push -q origin HEAD:refs/heads/side
	side=$(git rev-parse HEAD)
	git checkout -q "$deployed"
	reject_master_pushes 1 "$side"

	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[[ $output == *"push to master refused (attempt 1)"* ]] || false
	[ "$(cat "$FX/rejects")" = 1 ]
	[ "$(git -C "$ORIGIN" log --format=%s -3 master | tr '\n' '|')" = "chore(release): v0.1.0 [skip ci]|fix: landed meanwhile (#2)|feat: one (#1)|" ]
	# the release is still what was deployed
	[ "$(git -C "$ORIGIN" rev-parse 'v0.1.0^{commit}')" = "$deployed" ]
	origin_file CHANGELOG.md >"$FX/cl"
	! grep -q 'landed meanwhile' "$FX/cl" || false
}

@test "three refusals: the job gives up, and the next release writes both entries" {
	land "feat: one (#1)"
	reject_master_pushes 3
	run "$RELEASE" cut
	[ "$status" -ne 0 ]
	[[ $output == *"gave up on the CHANGELOG commit"* ]] || false
	[ "$(origin_tags)" = v0.1.0 ]
	[ -f "$GH_STATE/release-v0.1.0.md" ]
	! git -C "$ORIGIN" show master:CHANGELOG.md 2>/dev/null || false

	rm "$ORIGIN/hooks/pre-receive"
	land "fix: two (#2)"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	origin_file CHANGELOG.md >"$FX/cl"
	[ "$(grep '^## ' "$FX/cl" | tr '\n' '|')" = "## [0.1.1] — 2026-10-29|## [0.1.0] — 2026-10-29|" ]
	grep -q '^- feat: one (\[#1\]' "$FX/cl"
	grep -q '^- fix: two (\[#2\]' "$FX/cl"
}

@test "an existing entry is kept byte for byte when another is added" {
	land "feat: one (#1)"
	run "$RELEASE" cut
	git pull -q --ff-only origin master
	# a PR label changes after the cut: the old entry must not move
	pr 1 release:visual
	land "fix: two (#2)"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	origin_file CHANGELOG.md >"$FX/cl"
	git -C "$ORIGIN" show master~2:CHANGELOG.md >"$FX/cl.before"
	sed -n '/^## \[0.1.0\]/,$p' "$FX/cl" >"$FX/a"
	sed -n '/^## \[0.1.0\]/,$p' "$FX/cl.before" >"$FX/b"
	diff "$FX/a" "$FX/b"
}

@test "Slack refuses: the release stands, the Release says why, exit 0" {
	export SLACK_POST_RESPONSE='{"ok":false,"error":"not_in_channel"}'
	land "feat: one (#1)"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[[ $output == *"Slack not posted: not_in_channel. Re-post with: release.sh post v0.1.0"* ]] || false
	grep -q '^Slack: not posted (not_in_channel)$' "$GH_STATE/release-v0.1.0.md"
	! grep -q slack_ts "$GH_STATE/release-v0.1.0.md" || false
	origin_file CHANGELOG.md >"$FX/cl"
	! grep -q 'Slack thread' "$FX/cl" || false
	[ "$(output released)" = true ]
}

@test "Slack unreachable or no token: the release stands" {
	export CURL_FAIL=1
	land "feat: one (#1)"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	grep -q '^Slack: not posted (request failed)$' "$GH_STATE/release-v0.1.0.md"

	unset CURL_FAIL SLACK_RELEASES_BOT_TOKEN
	git pull -q --ff-only origin master
	land "fix: two (#2)"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	grep -q '^Slack: not posted (no token)$' "$GH_STATE/release-v0.1.1.md"
}

@test "post: the PM re-posts after a failure; the Release records it once" {
	export SLACK_POST_RESPONSE='{"ok":false,"error":"channel_not_found"}'
	land "feat: one (#1)"
	run "$RELEASE" cut
	unset SLACK_POST_RESPONSE
	run "$RELEASE" post v0.1.0
	[ "$status" -eq 0 ]
	grep -q '^Slack: https://acme.slack.com/archives/C0TEST/p1730000000000100$' "$GH_STATE/release-v0.1.0.md"
	grep -q '^<!-- slack_ts: 1730000000.000100 -->$' "$GH_STATE/release-v0.1.0.md"
	[ "$(grep -c '^Slack: ' "$GH_STATE/release-v0.1.0.md")" = 1 ]
	[ "$(slack_text 1)" = "$(slack_text 2)" ]
	run "$RELEASE" post v0.1.0
	[ "$status" -ne 0 ]
	[[ $output == *"already records a post"* ]] || false
}

@test "a crash between the tag and the Release: the next run finishes it" {
	land "feat: one (#1)"
	# the tag made it, nothing else
	git tag -a v0.1.0 -m v0.1.0
	git push -q origin refs/tags/v0.1.0
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[ "$(output action)" = recovered ]
	grep -q '^Slack: https://' "$GH_STATE/release-v0.1.0.md"
	[ "$(slack_posts)" = 1 ]
	[[ "$(slack_text 1)" == "🚀 *widget v0.1.0* is on prod"* ]] || false
	origin_file CHANGELOG.md | grep -q '^## \[0.1.0\]'
}

@test "the token never reaches the output, the summary or curl's command line" {
	land "feat: one (#1)"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[[ $output != *"$TOKEN"* ]] || false
	! grep -rq "$TOKEN" "$CURL_LOG"/args.* "$GITHUB_OUTPUT" "$GITHUB_STEP_SUMMARY" "$GH_STATE" || false
	# it travels on curl's stdin, as a config header
	grep -q "^header = \"Authorization: Bearer $TOKEN\"$" "$CURL_LOG/stdin.1"
}

@test "dry run: renders the entry and the Slack text, writes nothing anywhere" {
	pr 4 release:visual -- $'Intro\n\n## Release note\n<!-- one line for #releases -->\nBrokers can now export contacts.\n\n## Testing\nnone'
	land "feat(contacts): export (T-3) (#4)"
	before=$(git -C "$ORIGIN" rev-parse master)
	run "$RELEASE" cut --dry-run --version-file VERSION
	[ "$status" -eq 0 ]
	[[ $output == *"== CHANGELOG entry =="$'\n'"## [0.1.0] — 2026-10-29"* ]] || false
	[[ $output == *"### Release notes"$'\n'"Brokers can now export contacts. ([#4](https://github.com/acme/widget/pull/4))"* ]] || false
	[[ $output == *"== Slack =="$'\n'"🚀 *widget v0.1.0* is on prod — 1 feature"* ]] || false
	[[ $output == *"📸 screenshots follow in this thread (release:visual on #4)"* ]] || false
	[[ $output == *"CHANGELOG.md + VERSION, committed"* ]] || false
	[ -z "$(origin_tags)" ]
	[ -z "$(git for-each-ref refs/tags)" ]
	[ "$(git -C "$ORIGIN" rev-parse master)" = "$before" ]
	[ "$(slack_posts)" = 0 ]
	[ -z "$(find "$CURL_LOG" -type f)" ]
	! grep -q '^release ' "$GH_STATE/calls.log" || false
}
