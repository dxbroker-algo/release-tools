#!/usr/bin/env bats
# the cut marks the merge posts of the PRs it ships as in prod: the daily release says
# "prod ✅ vX.Y.Z, <time>", a hotfix says "prod 🩹 vX.Y.Z", the post is edited in place and
# the PR's handle records it

load helpers/common

setup() {
	setup_fixture
	export SLACK_MERGES_CHANNEL=C0MERGES SLACK_RELEASES_CHANNEL=C0RELEASES
	export RELEASE_NOW=2026-11-21T04:22:00Z
}

slack_line() { slack_text "$1" | sed -n "$2p"; }

slack_json() {
	local f
	f=$(find "$CURL_LOG" -name 'data.*' | sed 's/.*\.//' | sort -n | sed -n "$1p")
	cat "$CURL_LOG/data.$f"
}

slack_method() {
	local f
	f=$(find "$CURL_LOG" -name 'data.*' | sed 's/.*\.//' | sort -n | sed -n "$1p")
	tail -1 "$CURL_LOG/args.$f"
}

note_body() {
	printf '## Release note\n'
	printf '%s\n' "$@"
}

CALL_LOG_NOTE="users: Brokers see a Call log tab in Contacts, with missed calls and voicemails (CRM look, staging only)"

# a merge on master with its post (the stub's ts is 1730000000.000100 + the post's number)
merged() { # title pr note...
	local title=$1 n=$2
	shift 2
	land "$title"
	pr "$n" -- "$(note_body "$@")"
	GITHUB_RUN_ID=111 run "$RELEASE" post-merge
	[ "$status" -eq 0 ]
}

@test "the daily cut edits the merge post in place: ✅ in prod, the version and the time" {
	merged "feat(contact-modal): the CRM look's context column (T-1698) (#786)" 786 "$CALL_LOG_NOTE" "asked-by: Leon"
	[ "$(slack_posts)" = 1 ]
	GITHUB_RUN_ID=222 run "$RELEASE" cut
	[ "$status" -eq 0 ]
	# the merge post, the release post, then the edit
	[ "$(slack_posts)" = 3 ]
	[ "$(slack_method 3)" = "https://slack.com/api/chat.update" ]
	[ "$(slack_json 3 | jq -r .ts)" = 1730000000.000100 ]
	[ "$(slack_json 3 | jq -r .channel)" = C0TEST ]
	[ "$(slack_line 3 1)" = "✅ *Contacts* · for users — Brokers see a Call log tab in Contacts, with missed calls and voicemails (CRM look, staging only)" ]
	# staging keeps its own run, not the release's; the next release time gives way to prod's
	[ "$(slack_line 3 2)" = "widget <https://github.com/acme/widget/pull/786|#786> · T-1698 · asked by Leon · staging ✅ <https://github.com/acme/widget/actions/runs/111|deployed> · prod ✅ v0.1.0, Sat 21 Nov 04:22Z" ]
	[[ "$(slack_text 3)" != *"next release"* ]] || false
}

@test "the PR's handle records it: state=prod, what staging did, the staging run, the tag" {
	merged "feat(bot): one (T-5) (#1)" 1 "users: The bot answers clients in Hebrew when they write in Hebrew."
	GITHUB_RUN_ID=222 run "$RELEASE" cut
	[ "$status" -eq 0 ]
	grep -q "release-tools merge-post: sha=$(git rev-parse HEAD) ts=1730000000.000100 channel=C0TEST state=prod form=top run=https://github.com/acme/widget/actions/runs/111 stg=success tag=v0.1.0 -->" "$GH_STATE"/comment-1-1
}

@test "a red staging deploy keeps its 🟥 in the staging field; the merge is in prod all the same" {
	land "feat(bot): one (T-5) (#1)"
	pr 1 -- "$(note_body "users: The bot answers clients in Hebrew when they write in Hebrew.")"
	run "$RELEASE" post-merge --staging failure
	GITHUB_RUN_ID=222 run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[ "$(slack_line 3 1)" = "✅ *Bot* · for users — The bot answers clients in Hebrew when they write in Hebrew." ]
	[[ "$(slack_line 3 2)" == *" · staging 🟥 <https://github.com/acme/widget/actions/runs/111|not updated> · prod ✅ v0.1.0, Sat 21 Nov 04:22Z" ]] || false
}

@test "an internal merge's reply line gets the prod field and stays a reply" {
	merged "test(calls): halve the suite (T-1650) (#914)" 914 "tests: The calls area's tests were cut from 2,448 to 1,232."
	# the parent, then the reply
	[ "$(slack_posts)" = 2 ]
	GITHUB_RUN_ID=222 run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[ "$(slack_method 4)" = "https://slack.com/api/chat.update" ]
	[ "$(slack_json 4 | jq -r .ts)" = 1730000000.000101 ]
	[ "$(slack_text 4)" = "tests · widget <https://github.com/acme/widget/pull/914|#914> · T-1650 — The calls area's tests were cut from 2,448 to 1,232. · <https://github.com/acme/widget/actions/runs/111|staging ✅> · prod ✅ v0.1.0, Sat 21 Nov 04:22Z" ]
	grep -q 'state=prod form=reply ' "$GH_STATE"/comment-914-1
}

@test "the migration and the screenshots stay on the edited post when the cut is told where migrations live" {
	mkdir -p alembic/versions
	printf 'revision = "0161_template_texts"\n' >alembic/versions/0161_template_texts.py
	git add alembic
	land "feat(calls): the call log (T-7) (#7)"
	pr 7 release:visual -- "$(note_body "users: Brokers see a Call log tab in Contacts, with missed calls and voicemails.")"
	run "$RELEASE" post-merge --migrations alembic/versions
	[[ "$(slack_line 1 2)" == *" · migration \`0161_template_texts\` · 🖼 screenshots in thread" ]] || false
	run "$RELEASE" cut --migrations alembic/versions
	[ "$status" -eq 0 ]
	[[ "$(slack_line 3 2)" == *" · prod ✅ v0.1.0, Sat 21 Nov 04:22Z · migration \`0161_template_texts\` · 🖼 screenshots in thread" ]] || false
}

@test "a PR with no handle is skipped, and so is a commit with no PR" {
	land "feat(bot): never posted (T-5) (#1)"
	land "chore: no pull request number"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	# the release post, nothing else
	[ "$(slack_posts)" = 1 ]
	[ "$(slack_method 1)" = "https://slack.com/api/chat.postMessage" ]
}

@test "every merge of the range is marked, each once; the next release marks only its own" {
	merged "feat(bot): one (T-5) (#1)" 1 "users: The bot answers clients in Hebrew when they write in Hebrew."
	merged "fix(bot): two (T-6) (#2)" 2 "users: The bot greets returning clients by their first name."
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	# two merge posts, the release, two edits
	[ "$(slack_posts)" = 5 ]
	[ "$(slack_method 4)" = "https://slack.com/api/chat.update" ]
	[ "$(slack_method 5)" = "https://slack.com/api/chat.update" ]
	[ "$(slack_json 4 | jq -r .ts)" != "$(slack_json 5 | jq -r .ts)" ]

	git pull -q --ff-only origin master
	merged "fix(bot): three (T-8) (#3)" 3 "users: The bot no longer repeats its greeting twice."
	RELEASE_NOW=2026-11-22T04:22:00Z run "$RELEASE" cut
	[ "$status" -eq 0 ]
	# the third merge post, the release, one edit
	[ "$(slack_posts)" = 8 ]
	[[ "$(slack_line 8 2)" == *"#3|#3> "* ]] || [[ "$(slack_line 8 2)" == *"/pull/3|"* ]] || false
	[[ "$(slack_line 8 2)" == *" · prod ✅ v0.1.1, Sun 22 Nov 04:22Z" ]] || false
}

@test "a re-run of a cut that already marked a post edits nothing more" {
	merged "feat(bot): one (T-5) (#1)" 1 "users: The bot answers clients in Hebrew when they write in Hebrew."
	run "$RELEASE" cut
	[ "$(slack_posts)" = 3 ]
	# the same sha again is a re-deploy: no release, no marking
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[ "$(slack_posts)" = 4 ]
	[ "$(slack_method 4)" = "https://slack.com/api/chat.postMessage" ]
	[ "$(find "$GH_STATE" -name 'comment-1-*' | wc -l | tr -d ' ')" = 2 ]
}

@test "a release a crash left half-done is finished with its marks" {
	merged "feat(bot): one (T-5) (#1)" 1 "users: The bot answers clients in Hebrew when they write in Hebrew."
	# the tag made it, nothing else
	git tag -a v0.1.0 -m v0.1.0
	git push -q origin refs/tags/v0.1.0
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[ "$(output action)" = recovered ]
	[ "$(find "$GH_STATE" -name 'comment-1-*' | wc -l | tr -d ' ')" = 2 ]
	grep -q 'state=prod' "$GH_STATE"/comment-1-1
}

@test "a dry run edits nothing" {
	merged "feat(bot): one (T-5) (#1)" 1 "users: The bot answers clients in Hebrew when they write in Hebrew."
	run "$RELEASE" cut --dry-run
	[ "$status" -eq 0 ]
	[ "$(slack_posts)" = 1 ]
	[ "$(find "$GH_STATE" -name 'comment-1-*' | wc -l | tr -d ' ')" = 1 ]
}

@test "no Slack token: the release is cut, nothing is marked, and the cut says so" {
	merged "feat(bot): one (T-5) (#1)" 1 "users: The bot answers clients in Hebrew when they write in Hebrew."
	SLACK_RELEASES_BOT_TOKEN="" run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[ "$(output released)" = true ]
	[ "$(slack_posts)" = 1 ]
	[[ $output == *"no merge posts marked"* ]] || false
}

@test "Slack refusing an edit is a warning: the release is cut, the handle is not rewritten" {
	merged "feat(bot): one (T-5) (#1)" 1 "users: The bot answers clients in Hebrew when they write in Hebrew."
	cat >"$FX/curl-wrapper" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
	case \$a in *chat.update) cat >/dev/null; echo '{"ok":false,"error":"message_not_found"}'; exit 0 ;; esac
done
exec "$BATS_TEST_DIRNAME/helpers/bin/curl" "\$@"
EOF
	chmod +x "$FX/curl-wrapper"
	mkdir -p "$FX/bin"
	cp "$FX/curl-wrapper" "$FX/bin/curl"
	PATH="$FX/bin:$PATH" run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[ "$(output released)" = true ]
	[[ $output == *"merge post of #1 not marked: message_not_found"* ]] || false
	[ "$(find "$GH_STATE" -name 'comment-1-*' | wc -l | tr -d ' ')" = 1 ]
}

@test "gh unable to read the comments is a warning and stops asking; the release is cut" {
	merged "feat(bot): one (T-5) (#1)" 1 "users: The bot answers clients in Hebrew when they write in Hebrew."
	merged "fix(bot): two (T-6) (#2)" 2 "users: The bot greets returning clients by their first name."
	GH_FAIL_COMMENTS=1 run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[ "$(output released)" = true ]
	[ "$(grep -c 'cannot tell whether this merge was posted' <<<"$output")" = 1 ]
	[ "$(slack_posts)" = 3 ]
}

@test "kinds store and apply do not touch merge posts" {
	merged "feat(bot): one (T-5) (#1)" 1 "users: The bot answers clients in Hebrew when they write in Hebrew."
	run "$RELEASE" cut --kind apply
	[ "$status" -eq 0 ]
	[ "$(slack_posts)" = 2 ]
	[ "$(slack_method 2)" = "https://slack.com/api/chat.postMessage" ]
}

# ------------------------------------------------------------------ hotfix --

# v0.1.0 released, a fix merged on master with its merge post, and the hotfix branch
# hotfix/v0.1.1 = v0.1.0 + that fix picked the way git cherry-pick -x writes it
with_hotfix() {
	land "feat(api): the first thing (#1)"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	git pull -q --ff-only origin master
	merged "fix(auth): password reset sign-in (T-1710) (#931)" 931 "users: Brokers can sign in again after a password reset."
	FIX=$(git rev-parse HEAD)
	git checkout -q -b hotfix/v0.1.1 v0.1.0
	git commit -q --allow-empty -m "$(git log -1 --format=%s "$FIX")" -m "(cherry picked from commit $FIX)"
	git push -q origin hotfix/v0.1.1
	HF=$(git rev-parse HEAD)
	git checkout -q master
	: >"$GITHUB_OUTPUT"
	rm -f "${CURL_LOG:?}"/*
}

@test "a hotfix marks the post of the fix it picked: 🩹 and the patch's version, no time" {
	with_hotfix
	run "$RELEASE" cut --kind hotfix --sha "$HF" --reason "https://acme.slack.com/archives/C0CKNJZ0022/p1"
	[ "$status" -eq 0 ]
	# the hotfix post, then the edit
	[ "$(slack_posts)" = 2 ]
	[ "$(slack_method 2)" = "https://slack.com/api/chat.update" ]
	[ "$(slack_json 2 | jq -r .ts)" = 1730000000.000101 ]
	[ "$(slack_line 2 1)" = "✅ *Auth* · for users — Brokers can sign in again after a password reset." ]
	[[ "$(slack_line 2 2)" == *" · staging ✅ <https://github.com/acme/widget/actions/runs/111|deployed> · prod 🩹 v0.1.1" ]] || false
	grep -q 'state=prod .*stg=success tag=v0.1.1 -->' "$GH_STATE"/comment-931-1
}

@test "the daily release after a hotfix leaves that post as the hotfix wrote it, and marks the rest" {
	with_hotfix
	run "$RELEASE" cut --kind hotfix --sha "$HF" --reason "https://acme.slack.com/archives/C0CKNJZ0022/p1"
	[ "$status" -eq 0 ]
	merged "feat(bot): later (T-9) (#932)" 932 "users: The bot answers clients in Hebrew when they write in Hebrew."
	rm -f "${CURL_LOG:?}"/*
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[ "$(output tag)" = v0.2.0 ]
	# the release post, then one edit: the later merge's, not the fix's
	[ "$(slack_posts)" = 2 ]
	[[ "$(slack_line 2 2)" == *"/pull/932|"*" · prod ✅ v0.2.0, Sat 21 Nov 04:22Z" ]] || false
	[ "$(find "$GH_STATE" -name 'comment-931-*' | wc -l | tr -d ' ')" = 2 ]
}

@test "a hotfix pick with no trailer is left alone" {
	with_hotfix
	git checkout -q -b hotfix/odd v0.1.0
	git commit -q --allow-empty -m "fix(auth): password reset sign-in (T-1710) (#931)"
	git push -q origin hotfix/odd
	run "$RELEASE" cut --kind hotfix --sha "$(git rev-parse HEAD)" --reason "https://acme.slack.com/archives/C0CKNJZ0022/p1"
	[ "$status" -eq 0 ]
	[ "$(slack_posts)" = 1 ]
}
