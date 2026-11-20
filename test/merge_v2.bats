#!/usr/bin/env bats
# post-merge v2: the plain-words post, one message per merge edited in place as its state changes,
# the daily thread for internal and test merges, and the next release time

load helpers/common

setup() {
	setup_fixture
	export SLACK_MERGES_CHANNEL=C0MERGES SLACK_RELEASES_CHANNEL=C0RELEASES
	export RELEASE_NOW=2026-11-20T12:00:00Z
}

slack_line() { slack_text "$1" | sed -n "$2p"; }

slack_json() {
	local f
	f=$(find "$CURL_LOG" -name 'data.*' | sed 's/.*\.//' | sort -n | sed -n "$1p")
	cat "$CURL_LOG/data.$f"
}

# the method of the Nth post or update (the Nth call that carried a body)
slack_method() {
	local f
	f=$(find "$CURL_LOG" -name 'data.*' | sed 's/.*\.//' | sort -n | sed -n "$1p")
	tail -1 "$CURL_LOG/args.$f"
}

note_body() {
	printf '## Release note\n'
	printf '%s\n' "$@"
}

# a release workflow with a daily cron, committed with the next merge
cron_workflow() {
	mkdir -p .github/workflows
	printf 'on:\n  schedule:\n    - cron: %s\n  workflow_dispatch:\n' "$1" >.github/workflows/release.yml
	git add .github
}

CALL_LOG_NOTE="users: Brokers see a Call log tab in Contacts, with missed calls and voicemails (CRM look, staging only)"

@test "the post reads as the design's example: area, audience, the plain line, then where it is" {
	cron_workflow "'47 3 * * *'"
	git commit -q -m "feat(contact-modal): the CRM look's context column (T-1698) (#786)"
	git push -q origin HEAD:refs/heads/master
	pr 786 release:visual -- "$(note_body "$CALL_LOG_NOTE" "asked-by: Leon")"
	run "$RELEASE" post-merge
	[ "$status" -eq 0 ]
	[ "$(slack_posts)" = 1 ]
	[ "$(slack_line 1 1)" = "🟢 *Contacts* · for users — Brokers see a Call log tab in Contacts, with missed calls and voicemails (CRM look, staging only)" ]
	[ "$(slack_line 1 2)" = "widget <https://github.com/acme/widget/pull/786|#786> · T-1698 · asked by Leon · staging ✅ <https://github.com/acme/widget/actions/runs/111|deployed> · prod ⏳ next release Sat 21 Nov 03:47Z · 🖼 screenshots in thread" ]
}

@test "the next release is read from the cron at the merged commit: today's slot when it is still ahead" {
	cron_workflow "47 3 * * *"
	git commit -q -m "fix: early (#1)"
	git push -q origin HEAD:refs/heads/master
	RELEASE_NOW=2026-11-20T02:00:00Z run "$RELEASE" post-merge
	[[ "$(slack_line 1 2)" == *"prod ⏳ next release Fri 20 Nov 03:47Z" ]] || false
}

@test "a changed cron changes the post; a repository with no cron says next release, with no time" {
	cron_workflow "'5 14 * * *'"
	git commit -q -m "fix: one (#1)"
	git push -q origin HEAD:refs/heads/master
	run "$RELEASE" post-merge
	[[ "$(slack_line 1 2)" == *"prod ⏳ next release Fri 20 Nov 14:05Z" ]] || false

	cron_workflow "'0 4 * * 1'"
	git commit -q -m "fix: two (#2)"
	git push -q origin HEAD:refs/heads/master
	run "$RELEASE" post-merge
	[[ "$(slack_line 2 2)" == *"prod ⏳ next release" ]] || false
}

@test "RELEASE_PAUSED=true says releases are paused" {
	cron_workflow "'47 3 * * *'"
	git commit -q -m "fix: one (#1)"
	git push -q origin HEAD:refs/heads/master
	RELEASE_PAUSED=true run "$RELEASE" post-merge
	[[ "$(slack_line 1 2)" == *" · prod ⏸ releases paused" ]] || false
	[[ "$(slack_text 1)" != *"next release"* ]] || false
}

@test "the scope maps to an area; an unmapped scope shows as it is, capitalised" {
	for t in "feat(crm-shell): a (#1)|CRM look" "fix(bot): b (#2)|Bot" "feat(broadcast): c (#3)|Broadcasts" \
		"feat(listing-send): d (#4)|Listings" "fix(calls): e (#5)|Calls" "fix(agreements): f (#6)|Agreements" \
		"chore(ci): g (#7)|Release &amp; CI" "feat(release): h (#8)|Release &amp; CI" "feat(lead-score): i (#9)|Lead-score" "feat(contacts): j (#10)|Contacts"; do
		land "${t%|*}"
		run "$RELEASE" post-merge --dry-run
		[[ "$(sed -n 2p <<<"$output")" == "🟢 *${t#*|}* — "* ]] || {
			echo "wrong area for ${t%|*}: $output"
			return 1
		}
	done
}

@test "a title with no scope has no area" {
	land "fix: a thing (#1)"
	pr 1 -- "$(note_body "users: Brokers can sign in again after a password reset.")"
	run "$RELEASE" post-merge
	[ "$(slack_line 1 1)" = "🟢 · for users — Brokers can sign in again after a password reset." ]
}

@test "a red deploy posts 🟥 and a held one 🟨, each with the run link" {
	land "feat(bot): one (T-5) (#1)"
	pr 1 -- "$(note_body "users: The bot answers clients in Hebrew when they write in Hebrew.")"
	run "$RELEASE" post-merge --staging failure
	[ "$status" -eq 0 ]
	[ "$(slack_line 1 1)" = "🟥 *Bot* · for users — The bot answers clients in Hebrew when they write in Hebrew." ]
	[[ "$(slack_line 1 2)" == *" · staging 🟥 <https://github.com/acme/widget/actions/runs/111|not updated> · "* ]] || false

	land "feat(bot): two (T-6) (#2)"
	pr 2 -- "$(note_body "users: The bot greets returning clients by their first name.")"
	run "$RELEASE" post-merge --staging held
	[[ "$(slack_line 2 1)" == "🟨 *Bot* · for users"* ]] || false
	[[ "$(slack_line 2 2)" == *" · staging 🟨 <https://github.com/acme/widget/actions/runs/111|held> · "* ]] || false
	grep -q 'state=held' "$GH_STATE"/comment-2-0
}

@test "an unknown --staging is refused" {
	land "fix: one (#1)"
	run "$RELEASE" post-merge --staging green
	[ "$status" -ne 0 ]
	[[ $output == *"--staging must be"* ]] || false
}

@test "a later green run edits the red message in place, once" {
	land "feat(bot): one (T-5) (#1)"
	pr 1 -- "$(note_body "users: The bot answers clients in Hebrew when they write in Hebrew.")"
	run "$RELEASE" post-merge --staging failure
	[ "$(slack_posts)" = 1 ]
	[ "$(output posted)" = 1 ]

	# the same red again changes nothing
	run "$RELEASE" post-merge --staging failure
	[ "$(slack_posts)" = 1 ]
	[[ $output == *"already posted"* ]] || false

	run "$RELEASE" post-merge --staging success
	[ "$status" -eq 0 ]
	[ "$(slack_posts)" = 2 ]
	[ "$(slack_method 2)" = "https://slack.com/api/chat.update" ]
	[ "$(slack_json 2 | jq -r .ts)" = 1730000000.000100 ]
	[ "$(slack_json 2 | jq -r .channel)" = C0TEST ]
	[ "$(slack_line 2 1)" = "🟢 *Bot* · for users — The bot answers clients in Hebrew when they write in Hebrew." ]
	[[ "$(slack_line 2 2)" == *" · staging ✅ <"*"|deployed> · "* ]] || false
	[ "$(output posted)" = 0 ]
	[ "$(output updated)" = 1 ]
	grep -q 'state=success' "$GH_STATE"/comment-1-1

	# green stays green: neither a red nor a green re-run touches it
	run "$RELEASE" post-merge --staging failure
	run "$RELEASE" post-merge --staging success
	[ "$(slack_posts)" = 2 ]
}

@test "red, then held, edits too" {
	land "fix: one (#1)"
	run "$RELEASE" post-merge --staging failure
	run "$RELEASE" post-merge --staging held
	[ "$(slack_posts)" = 2 ]
	[ "$(slack_method 2)" = "https://slack.com/api/chat.update" ]
	[[ "$(slack_line 2 1)" == "🟨 "* ]] || false
}

@test "the next push that carries a red merge edits its message to green; it does not post it again" {
	land "feat(bot): one (T-5) (#1)"
	pr 1 -- "$(note_body "users: The bot answers clients in Hebrew when they write in Hebrew.")"
	run "$RELEASE" post-merge --staging failure
	before=$(git rev-parse HEAD)
	land "feat(bot): two (T-6) (#2)"
	pr 2 -- "$(note_body "users: The bot greets returning clients by their first name.")"
	run "$RELEASE" post-merge --before "$before" --staging success
	[ "$status" -eq 0 ]
	# posts: one (red), two (green), then one edited to green
	[ "$(slack_posts)" = 3 ]
	[ "$(slack_method 2)" = "https://slack.com/api/chat.postMessage" ]
	[[ "$(slack_line 2 1)" == "🟢 *Bot* · for users — The bot greets"* ]] || false
	[ "$(slack_method 3)" = "https://slack.com/api/chat.update" ]
	[ "$(slack_json 3 | jq -r .ts)" = 1730000000.000100 ]
	[[ "$(slack_line 3 1)" == "🟢 *Bot* · for users — The bot answers"* ]] || false
	[ "$(output posted)" = 1 ]
	[ "$(output updated)" = 1 ]
}

@test "the catch-up leaves green merges and merges it never posted alone" {
	land "fix: quiet (#1)"
	run "$RELEASE" post-merge --staging success
	before=$(git rev-parse HEAD)
	land "fix: unposted (#2)"
	land "fix: head (#3)"
	run "$RELEASE" post-merge --before "$before" --staging success
	# #2 and #3 are new; #1 is green; nothing is edited
	[ "$(slack_posts)" = 3 ]
	[ "$(output updated)" = 0 ]
}

@test "an internal or tests merge is a reply in a daily thread, whose parent the first one creates" {
	land "test(calls): halve the suite (T-1650) (#914)"
	pr 914 -- "$(note_body "tests: The calls area's tests were cut from 2,448 to 1,232.")"
	run "$RELEASE" post-merge
	[ "$status" -eq 0 ]
	[ "$(slack_posts)" = 2 ]
	[ "$(slack_text 1)" = "🧰 Internal and test changes, Fri 20 Nov (UTC)" ]
	[ "$(slack_json 1 | jq -r '.thread_ts // ""')" = "" ]
	[ "$(slack_text 2)" = "tests · widget <https://github.com/acme/widget/pull/914|#914> · T-1650 — The calls area's tests were cut from 2,448 to 1,232. · <https://github.com/acme/widget/actions/runs/111|staging ✅>" ]
	[ "$(slack_json 2 | jq -r .thread_ts)" = 1730000000.000100 ]
	grep -q 'ts=1730000000.000101 channel=C0TEST state=success form=reply -->' "$GH_STATE"/comment-914-0

	# the second one finds today's parent and only replies
	land "chore(ci): cache the install (T-1651) (#915)"
	pr 915 -- "$(note_body "internal: CI installs the app's packages from a cache, so it starts sooner." "asked-by: Leon")"
	run "$RELEASE" post-merge
	[ "$(slack_posts)" = 3 ]
	[ "$(slack_json 3 | jq -r .thread_ts)" = 1730000000.000100 ]
	[ "$(slack_text 3)" = "internal · widget <https://github.com/acme/widget/pull/915|#915> · T-1651 — CI installs the app's packages from a cache, so it starts sooner. (asked by Leon) · <https://github.com/acme/widget/actions/runs/111|staging ✅>" ]
}

@test "two internal merges in one push share one parent" {
	before=$(git rev-parse HEAD)
	land "chore: one (#1)"
	land "chore: two (#2)"
	pr 1 -- "$(note_body "internal: The release flow keeps its own log of every deploy.")"
	pr 2 -- "$(note_body "internal: The admin page lists the people who may release.")"
	run "$RELEASE" post-merge --before "$before"
	[ "$(slack_posts)" = 3 ]
	[ "$(slack_json 2 | jq -r .thread_ts)" = 1730000000.000100 ]
	[ "$(slack_json 3 | jq -r .thread_ts)" = 1730000000.000100 ]
}

@test "yesterday's daily thread is not today's" {
	land "chore: one (#1)"
	pr 1 -- "$(note_body "internal: The release flow keeps its own log of every deploy.")"
	RELEASE_NOW=2026-11-19T12:00:00Z run "$RELEASE" post-merge
	land "chore: two (#2)"
	pr 2 -- "$(note_body "internal: The admin page lists the people who may release.")"
	run "$RELEASE" post-merge
	[ "$(slack_posts)" = 4 ]
	[ "$(slack_text 1)" = "🧰 Internal and test changes, Thu 19 Nov (UTC)" ]
	[ "$(slack_text 3)" = "🧰 Internal and test changes, Fri 20 Nov (UTC)" ]
}

@test "without channels:history the daily thread falls back to a compact top-level line" {
	land "test(calls): halve the suite (T-1650) (#914)"
	pr 914 -- "$(note_body "tests: The calls area's tests were cut from 2,448 to 1,232.")"
	SLACK_HISTORY_ERROR=missing_scope run "$RELEASE" post-merge
	[ "$status" -eq 0 ]
	[[ $output == *"missing_scope"* && $output == *"compact"* ]] || false
	[ "$(slack_posts)" = 1 ]
	[ "$(slack_json 1 | jq -r '.thread_ts // ""')" = "" ]
	[[ "$(slack_text 1)" == "🧰 tests · widget <"*"|#914> · T-1650 — The calls area's tests"* ]] || false
	grep -q 'form=compact' "$GH_STATE"/comment-914-0
	[ "$(output posted)" = 1 ]
}

@test "a red internal merge edits its reply in place and keeps its form" {
	land "chore: one (T-9) (#1)"
	pr 1 -- "$(note_body "internal: The release flow keeps its own log of every deploy.")"
	run "$RELEASE" post-merge --staging failure
	[[ "$(slack_text 2)" == *"|staging 🟥 not updated>" ]] || false
	run "$RELEASE" post-merge --staging success
	[ "$(slack_posts)" = 3 ]
	[ "$(slack_method 3)" = "https://slack.com/api/chat.update" ]
	[ "$(slack_json 3 | jq -r .ts)" = 1730000000.000101 ]
	[[ "$(slack_text 3)" == "internal · widget "*"|staging ✅>" ]] || false
	grep -q 'form=reply' "$GH_STATE"/comment-1-1
}

@test "a compact line, edited, keeps its 🧰" {
	land "chore: one (T-9) (#1)"
	pr 1 -- "$(note_body "internal: The release flow keeps its own log of every deploy.")"
	SLACK_HISTORY_ERROR=missing_scope run "$RELEASE" post-merge --staging held
	SLACK_HISTORY_ERROR=missing_scope run "$RELEASE" post-merge --staging success
	[ "$(slack_method 2)" = "https://slack.com/api/chat.update" ]
	[[ "$(slack_text 2)" == "🧰 internal · "* ]] || false
}

@test "visual and migration merges are always top level, whatever their audience" {
	land "chore(ci): a screen (#1)"
	pr 1 release:visual -- "$(note_body "internal: The admin page now shows who may start a release.")"
	run "$RELEASE" post-merge
	[ "$(slack_posts)" = 1 ]
	[ "$(slack_line 1 1)" = "🟢 *Release &amp; CI* · internal — The admin page now shows who may start a release." ]
	[[ "$(slack_line 1 2)" == *" · 🖼 screenshots in thread" ]] || false

	mkdir -p alembic/versions
	printf 'revision = "0161_x"\n' >alembic/versions/0161_x.py
	git add alembic
	git commit -q -m "chore(db): a column (#2)"
	git push -q origin HEAD:refs/heads/master
	pr 2 -- "$(note_body "tests: The migration tests now replay every revision from the start.")"
	run "$RELEASE" post-merge --migrations alembic/versions
	[ "$(slack_posts)" = 2 ]
	[[ "$(slack_line 2 1)" == "🟢 *Db* · tests — The migration tests"* ]] || false
	[[ "$(slack_line 2 2)" == *" · migration \`0161_x\`" ]] || false
}

@test "a note that breaks a rule posts the title, marked, at the top level" {
	land "feat(bot): the bot greets by name (T-6) (#2)"
	pr 2 -- "$(note_body "users: fixed")"
	run "$RELEASE" post-merge
	[ "$(slack_posts)" = 1 ]
	[ "$(slack_line 1 1)" = "🟢 *Bot* — feat(bot): the bot greets by name (T-6) (no release note)" ]
}

@test "a note that repeats the title is no note" {
	land "feat(bot): the bot greets clients by name (#2)"
	pr 2 -- "$(note_body "users: The bot greets clients by name.")"
	run "$RELEASE" post-merge
	[[ "$(slack_line 1 1)" == *"(no release note)" ]] || false
}

@test "the note's text is escaped for Slack" {
	land "feat(bot): a (#2)"
	pr 2 -- "$(note_body "users: Brokers see <b>Q&A</b> threads for every contact they own.")"
	run "$RELEASE" post-merge
	[[ "$(slack_line 1 1)" == *"Brokers see &lt;b&gt;Q&amp;A&lt;/b&gt; threads"* ]] || false
}

@test "a PR whose comments gh cannot read is posted, with a warning, and not edited" {
	land "fix: one (#1)"
	GH_FAIL_COMMENTS=1 run "$RELEASE" post-merge
	[ "$status" -eq 0 ]
	[ "$(slack_posts)" = 1 ]
	[[ $output == *"cannot tell whether this merge was posted"* ]] || false
}

@test "a comment written before state and form were recorded reads as a green top-level message" {
	land "fix: one (#1)"
	printf 'Posted to the merge channel: x\n\n<!-- release-tools merge-post: sha=%s ts=1730000000.000100 -->\n' "$(git rev-parse HEAD)" >"$GH_STATE/comment-1-0"
	run "$RELEASE" post-merge --staging failure
	[ "$(slack_posts)" = 0 ]
	[[ $output == *"already posted"* ]] || false
}

@test "--dry-run says where a reply would go, and edits nothing" {
	land "chore: one (#1)"
	pr 1 -- "$(note_body "internal: The release flow keeps its own log of every deploy.")"
	run "$RELEASE" post-merge --dry-run
	[[ $output == *"== Slack (daily thread) =="* ]] || false
	[ "$(slack_posts)" = 0 ]
}
