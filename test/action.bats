#!/usr/bin/env bats
# the composite action's run block, fed its inputs the way the runner does

load helpers/common

setup() {
	setup_fixture
	# the step's script, as the runner would write it
	awk '/^      run: \|$/ { on = 1; next } on && /^        / { print substr($0, 9); next } on && /^[^ ]/ { exit }' \
		"$BATS_TEST_DIRNAME/../cut/action.yml" >"$FX/step.sh"
	! grep -q '\${{' "$FX/step.sh" || false
	export GITHUB_ACTION_PATH="$BATS_TEST_DIRNAME/../cut"
	export IN_KIND=deploy IN_SHA="" IN_SHA_GIVEN="" IN_VERSION="" IN_VERSION_FILE="" IN_NAME="" IN_BRANCH=""
	export IN_CHANGELOG=CHANGELOG.md IN_DRY_RUN=false IN_BACKFILL=false IN_BUMP_FILE=manifest.config.ts IN_RETRO_NOTE=""
}

@test "deploy: the sha, two version files, a name" {
	printf '{\n  "version": "0.0.0"\n}\n' >package.json
	git add package.json
	land "feat: one (#1)"
	IN_SHA=$(git rev-parse HEAD) IN_VERSION_FILE="package.json VERSION" IN_NAME="Widget web" run bash "$FX/step.sh"
	[ "$status" -eq 0 ]
	[ "$(origin_file package.json | jq -r .version)" = 0.1.0 ]
	[ "$(origin_file VERSION)" = 0.1.0 ]
	[[ "$(slack_text 1)" == "🚀 *Widget web v0.1.0* is on prod"* ]] || false
	[ "$(output tag)" = v0.1.0 ]
}

@test "dry run through the action writes nothing" {
	land "feat: one (#1)"
	IN_SHA=$(git rev-parse HEAD) IN_DRY_RUN=true run bash "$FX/step.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"== Slack =="* ]] || false
	[ -z "$(origin_tags)" ]
}

@test "store with backfill: retro tags, then the published version from its bump commit" {
	for v in 0.3.1 0.4.0; do
		printf "export default { version: '%s' }\n" "$v" >manifest.config.ts
		git add manifest.config.ts
		land "feat: $v (#${v//./})"
	done
	land "fix: after (#9)"
	IN_KIND=store IN_SHA=$(git rev-parse HEAD) IN_VERSION=0.4.0 IN_BACKFILL=true run bash "$FX/step.sh"
	[ "$status" -eq 0 ]
	[ "$(origin_tags | tr '\n' ' ')" = "v0.3.1 v0.4.0 " ]
	[ "$(git -C "$ORIGIN" log -1 --format=%s 'v0.4.0^{commit}')" = "feat: 0.4.0 (#040)" ]
	[ "$(slack_posts)" = 1 ]
}
