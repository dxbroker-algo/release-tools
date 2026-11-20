#!/usr/bin/env bats
# the post-merge and pr-note actions' run blocks, fed their inputs the way the runner does

load helpers/common

# step_of DIR: the run block of DIR/action.yml, as the runner would write it
step_of() {
	awk '/^      run: \|$/ { on = 1; next } on && /^        / { print substr($0, 9); next } on && /^[^ ]/ { exit }' \
		"$BATS_TEST_DIRNAME/../$1/action.yml" >"$FX/step.sh"
	! grep -q '\${{' "$FX/step.sh" || false
}

setup() {
	setup_fixture
	export SLACK_MERGES_CHANNEL=C0MERGES
	export IN_BEFORE="" IN_MIGRATIONS="" IN_STAGING=success IN_DEPLOYED="" IN_DRY_RUN=false
	export RELEASE_NOW=2026-11-20T12:00:00Z
}

@test "post-merge: the staging input is passed on, and an empty one means success" {
	step_of post-merge
	export GITHUB_ACTION_PATH="$BATS_TEST_DIRNAME/../post-merge"
	land "feat(bot): one (#1)"
	IN_SHA=$(git rev-parse HEAD) IN_STAGING=failure run bash "$FX/step.sh"
	[ "$status" -eq 0 ]
	[[ "$(slack_text 1)" == "🟥 *Bot* — "* ]] || false

	land "feat(bot): two (#2)"
	IN_SHA=$(git rev-parse HEAD) IN_STAGING="" run bash "$FX/step.sh"
	[ "$status" -eq 0 ]
	[[ "$(slack_text 2)" == "🟢 *Bot* — "* ]] || false
	[ "$(output posted)" = 1 ]
	[ "$(output updated)" = 0 ]

	# any other job result is staging not updated
	land "feat(bot): three (#3)"
	IN_SHA=$(git rev-parse HEAD) IN_STAGING=skipped run bash "$FX/step.sh"
	[ "$status" -eq 0 ]
	[[ "$(slack_text 3)" == "🟥 *Bot* — "* ]] || false
}

@test "post-merge: a green job that deployed nothing is held; an empty deployed leaves success alone" {
	step_of post-merge
	export GITHUB_ACTION_PATH="$BATS_TEST_DIRNAME/../post-merge"
	land "feat(bot): one (#1)"
	IN_SHA=$(git rev-parse HEAD) IN_STAGING=success IN_DEPLOYED=false run bash "$FX/step.sh"
	[ "$status" -eq 0 ]
	[[ "$(slack_text 1)" == "🟨 *Bot* — "* ]] || false
	[[ "$(slack_text 1)" == *"|held>"* ]] || false

	land "feat(bot): two (#2)"
	IN_SHA=$(git rev-parse HEAD) IN_STAGING=success IN_DEPLOYED=true run bash "$FX/step.sh"
	[[ "$(slack_text 2)" == "🟢 *Bot* — "* ]] || false

	land "feat(bot): three (#3)"
	IN_SHA=$(git rev-parse HEAD) IN_STAGING=success IN_DEPLOYED="" run bash "$FX/step.sh"
	[[ "$(slack_text 3)" == "🟢 *Bot* — "* ]] || false

	# a failed job is red whatever its deployed output says
	land "feat(bot): four (#4)"
	IN_SHA=$(git rev-parse HEAD) IN_STAGING=failure IN_DEPLOYED=true run bash "$FX/step.sh"
	[[ "$(slack_text 4)" == "🟥 *Bot* — "* ]] || false
}

@test "post-merge: release_cron reaches the post when release.yml has no schedule" {
	step_of post-merge
	export GITHUB_ACTION_PATH="$BATS_TEST_DIRNAME/../post-merge"
	land "feat(bot): one (#1)"
	IN_SHA=$(git rev-parse HEAD) RELEASE_CRON="47 3 * * *" run bash "$FX/step.sh"
	[[ "$(slack_text 1)" == *"prod ⏳ next release Sat 21 Nov 03:47Z" ]] || false
}

@test "post-merge: release_paused reaches the post" {
	step_of post-merge
	export GITHUB_ACTION_PATH="$BATS_TEST_DIRNAME/../post-merge"
	land "feat(bot): one (#1)"
	IN_SHA=$(git rev-parse HEAD) RELEASE_PAUSED=true run bash "$FX/step.sh"
	[[ "$(slack_text 1)" == *"prod ⏸ releases paused" ]] || false
}

@test "pr-note: a valid note passes, a bad one fails the step" {
	step_of pr-note
	export GITHUB_ACTION_PATH="$BATS_TEST_DIRNAME/../pr-note"
	TITLE="feat(bot): greet by name (#2)" BODY=$'text\n\n## Release note\nusers: The bot greets returning clients by their first name.\n' \
		run bash "$FX/step.sh"
	[ "$status" -eq 0 ]
	TITLE="feat(bot): greet by name (#2)" BODY=$'text\n\n## Release note\nusers: greets\n' run bash "$FX/step.sh"
	[ "$status" -eq 1 ]
	TITLE="feat(bot): greet by name (#2)" BODY="" run bash "$FX/step.sh"
	[ "$status" -eq 1 ]
}

@test "the actions declare the inputs the workflows will pass" {
	grep -q '^  staging:' "$BATS_TEST_DIRNAME/../post-merge/action.yml"
	grep -q '^  deployed:' "$BATS_TEST_DIRNAME/../post-merge/action.yml"
	grep -q '^  release_cron:' "$BATS_TEST_DIRNAME/../post-merge/action.yml"
	grep -q '^  release_paused:' "$BATS_TEST_DIRNAME/../post-merge/action.yml"
	grep -q '^  updated:' "$BATS_TEST_DIRNAME/../post-merge/action.yml"
	grep -q 'github.event.pull_request.body' "$BATS_TEST_DIRNAME/../pr-note/action.yml"
	grep -q 'github.event.pull_request.title' "$BATS_TEST_DIRNAME/../pr-note/action.yml"
}
