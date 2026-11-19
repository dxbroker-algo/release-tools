#!/usr/bin/env bats
# post-merge: the line a merge posts to the merge channel, the ts it records, and what it must not do twice

load helpers/common

setup() {
	setup_fixture
	# the merge channel is not the releases channel
	export SLACK_MERGES_CHANNEL=C0MERGES SLACK_RELEASES_CHANNEL=C0RELEASES
}

# posted_channel N: the channel the Nth post went to
posted_channel() {
	local f
	f=$(find "$CURL_LOG" -name 'data.*' | sed 's/.*\.//' | sort -n | sed -n "$1p")
	jq -r .channel "$CURL_LOG/data.$f"
}

@test "a merge posts one line: the title linked, the task, the short sha" {
	land "feat(api): add the thing (T-12) (#4)"
	run "$RELEASE" post-merge
	[ "$status" -eq 0 ]
	[ "$(slack_posts)" = 1 ]
	short=$(git rev-parse --short=7 HEAD)
	[ "$(slack_text 1)" = "🔀 <https://github.com/acme/widget/pull/4|feat(api): add the thing (T-12)> — T-12 · \`$short\`" ]
}

@test "it posts to SLACK_MERGES_CHANNEL, and never falls back to the releases channel" {
	land "feat: one (#1)"
	run "$RELEASE" post-merge
	[ "$(posted_channel 1)" = C0MERGES ]

	unset SLACK_MERGES_CHANNEL
	find "$CURL_LOG" -type f -delete
	land "feat: two (#2)"
	run "$RELEASE" post-merge
	[ "$status" -eq 0 ]
	[ "$(slack_posts)" = 0 ]
	[[ $output == *"not posted: no channel"* ]] || false
	[ "$(output posted)" = 0 ]
}

@test "release:visual adds the screenshots flag; the label is read from the PR" {
	land "feat(ui): a screen (T-30) (#5)"
	pr 5 release:visual
	run "$RELEASE" post-merge
	[[ "$(slack_text 1)" == *" · 🖼 screenshots" ]] || false

	land "feat(ui): another (T-31) (#6)"
	pr 6 deploy:stg
	run "$RELEASE" post-merge
	[[ "$(slack_text 2)" != *"🖼"* ]] || false
}

@test "a migration the merge added is named by its revision, else its file name" {
	mkdir -p alembic/versions
	printf 'revision = "a1b2c3d4"\ndown_revision = "0000"\n' >alembic/versions/20261119_a1b2c3d4_add_x.py
	printf '# no revision here\n' >alembic/versions/20261119_plain.py
	git add alembic
	git commit -q -m "feat(db): add x (T-40) (#7)"
	git push -q origin HEAD:refs/heads/master
	run "$RELEASE" post-merge --migrations alembic/versions
	[[ "$(slack_text 1)" == *" · migrations \`a1b2c3d4\`, \`20261119_plain\`" ]] || false

	printf 'revision: str = "ffee0011"\n' >alembic/versions/20261120_ffee.py
	git add alembic
	git commit -q -m "feat(db): add y (T-41) (#8)"
	git push -q origin HEAD:refs/heads/master
	run "$RELEASE" post-merge --migrations alembic/versions
	[[ "$(slack_text 2)" == *" · migration \`ffee0011\`" ]] || false
}

@test "a merge that only edits a migration, or adds none, names none" {
	mkdir -p alembic/versions
	printf 'revision = "a1"\n' >alembic/versions/a1.py
	git add alembic
	git commit -q -m "feat(db): one (#1)"
	git push -q origin HEAD:refs/heads/master
	printf 'revision = "a1"\n# edited\n' >alembic/versions/a1.py
	git commit -q -am "fix(db): edit (#2)"
	git push -q origin HEAD:refs/heads/master
	run "$RELEASE" post-merge --migrations alembic/versions
	[[ "$(slack_text 1)" != *"migration"* ]] || false
	run "$RELEASE" post-merge
	[[ "$(slack_text 2)" != *"migration"* ]] || false
}

@test "a shallow checkout does not call every migration new" {
	mkdir -p alembic/versions
	printf 'revision = "a1"\n' >alembic/versions/a1.py
	git add alembic
	git commit -q -m "feat(db): one (#1)"
	git push -q origin HEAD:refs/heads/master
	land "fix: unrelated (#2)"
	git clone -q --depth 1 "file://$ORIGIN" "$FX/shallow"
	cd "$FX/shallow"
	run "$RELEASE" post-merge --migrations alembic/versions
	[ "$status" -eq 0 ]
	[[ $output == *"shallow checkout"* ]] || false
	[[ "$(slack_text 1)" != *"migration"* ]] || false
}

@test "the ts is recorded on the PR, and a re-run of the same merge does not post again" {
	land "feat: one (T-1) (#9)"
	run "$RELEASE" post-merge
	[ "$(slack_posts)" = 1 ]
	[ "$(output slack_ts)" = 1730000000.000100 ]
	[ "$(output posted)" = 1 ]
	grep -q "release-tools merge-post: sha=$(git rev-parse HEAD) ts=1730000000.000100 -->" "$GH_STATE"/comment-9-0
	grep -q 'https://acme.slack.com/archives/C0TEST/p1730000000000100' "$GH_STATE"/comment-9-0

	run "$RELEASE" post-merge
	[ "$status" -eq 0 ]
	[ "$(slack_posts)" = 1 ]
	[ "$(output posted)" = 0 ]
	[[ $output == *"already posted"* ]] || false
}

@test "a PR comment that cannot be written is a warning, the post stands" {
	land "feat: one (#9)"
	GH_FAIL_COMMENTS=1 run "$RELEASE" post-merge
	[ "$status" -eq 0 ]
	[ "$(slack_posts)" = 1 ]
	[[ $output == *"could not record the post's ts on PR #9"* ]] || false
}

@test "a push of several merges posts each, oldest first; release commits are skipped" {
	before=$(git rev-parse HEAD)
	land "feat: one (T-1) (#1)"
	land "chore(release): v0.1.0 [skip ci]"
	land "fix: two (T-2) (#2)"
	run "$RELEASE" post-merge --before "$before"
	[ "$status" -eq 0 ]
	[ "$(slack_posts)" = 2 ]
	[[ "$(slack_text 1)" == *"feat: one"* ]] || false
	[[ "$(slack_text 2)" == *"fix: two"* ]] || false
}

@test "an unusable --before (all zeros, unknown) posts the head alone" {
	land "feat: one (#1)"
	land "fix: two (#2)"
	run "$RELEASE" post-merge --before 0000000000000000000000000000000000000000
	[ "$(slack_posts)" = 1 ]
	[[ "$(slack_text 1)" == *"fix: two"* ]] || false
	land "fix: three (#3)"
	run "$RELEASE" post-merge --before deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
	[ "$(slack_posts)" = 2 ]
	[[ "$(slack_text 2)" == *"fix: three"* ]] || false
}

@test "a title with no PR number posts unlinked and records nothing" {
	land "fix: pushed straight to master (T-50)"
	run "$RELEASE" post-merge
	[ "$(slack_posts)" = 1 ]
	[[ "$(slack_text 1)" == "🔀 fix: pushed straight to master (T-50) — T-50 · "* ]] || false
	[[ "$(slack_text 1)" != *"<https"* ]] || false
	[ -z "$(find "$GH_STATE" -name 'comment-*')" ]
}

@test "the task is read from the squash body when the title has none" {
	land "fix: quiet (#3)" "Refs T-77"
	run "$RELEASE" post-merge
	[[ "$(slack_text 1)" == *" — T-77 · "* ]] || false
}

@test "the visual-review prefix moves to the end, and Slack markup in a title is escaped" {
	land "[visual review missing] feat(ui): a <b> & c (#3)"
	run "$RELEASE" post-merge
	[[ "$(slack_text 1)" == *"|feat(ui): a &lt;b&gt; &amp; c> ⚠ visual review missing"* ]] || false
}

@test "Slack failing is a warning: exit 0, nothing recorded, posted=0" {
	land "feat: one (#9)"
	CURL_FAIL=1 run "$RELEASE" post-merge
	[ "$status" -eq 0 ]
	[[ $output == *"not posted: request failed"* ]] || false
	[ "$(output posted)" = 0 ]
	[ -z "$(find "$GH_STATE" -name 'comment-*')" ]
}

@test "no token: nothing is posted, the step still exits 0" {
	land "feat: one (#9)"
	SLACK_RELEASES_BOT_TOKEN="" run "$RELEASE" post-merge
	[ "$status" -eq 0 ]
	[ "$(slack_posts)" = 0 ]
	[[ $output == *"not posted: no token"* ]] || false
}

@test "--dry-run prints the line and posts and records nothing" {
	land "feat: one (T-1) (#9)"
	run "$RELEASE" post-merge --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"== Slack =="* && $output == *"🔀 "* ]] || false
	[ "$(slack_posts)" = 0 ]
	[ -z "$(find "$GH_STATE" -name 'comment-*')" ]
}

@test "the token is never on a command line or in the output" {
	land "feat: one (#9)"
	run "$RELEASE" post-merge
	[[ $output != *"$TOKEN"* ]] || false
	! grep -rq "$TOKEN" "$CURL_LOG"/args.* "$CURL_LOG"/data.* || false
	grep -q "$TOKEN" "$CURL_LOG/stdin.1"
	! grep -q "$TOKEN" "$GITHUB_STEP_SUMMARY" || false
}
