# Shared fixture: a bare "origin", a clone the release runs in (the job's
# checkout), gh and curl replaced by the stubs in helpers/bin.

RELEASE="$BATS_TEST_DIRNAME/../release.sh"
TOKEN=xoxb-test-SECRET-0123456789

setup_fixture() {
	FX=$(mktemp -d "$BATS_TEST_TMPDIR/fx.XXXXXX")
	ORIGIN="$FX/origin.git"
	CHECKOUT="$FX/work"
	git init -q --bare "$ORIGIN"
	git -C "$ORIGIN" symbolic-ref HEAD refs/heads/master
	git init -q "$CHECKOUT"
	cd "$CHECKOUT"
	git symbolic-ref HEAD refs/heads/master
	git config user.name dev
	git config user.email dev@example.com
	git config commit.gpgsign false
	git config tag.gpgsign false
	git remote add origin "$ORIGIN"

	export GH_STATE="$FX/gh" CURL_LOG="$FX/curl"
	mkdir -p "$GH_STATE" "$CURL_LOG"
	export PATH="$BATS_TEST_DIRNAME/helpers/bin:$PATH"

	export GITHUB_REPOSITORY=acme/widget GITHUB_SERVER_URL=https://github.com
	export GITHUB_RUN_ID=111 GITHUB_RUN_NUMBER=7 GITHUB_ACTOR=octocat
	export RELEASE_NOW=2026-10-29T12:00:00Z
	export SLACK_RELEASES_BOT_TOKEN=$TOKEN SLACK_RELEASES_CHANNEL=C0TEST
	export GITHUB_OUTPUT="$FX/output" GITHUB_STEP_SUMMARY="$FX/summary"
	unset GH_FAIL_PR CURL_FAIL SLACK_POST_RESPONSE SLACK_API_URL
	export GIT_AUTHOR_DATE=2026-06-01T10:00:00Z GIT_COMMITTER_DATE=2026-06-01T10:00:00Z

	land "Initial commit"
}

# land TITLE [BODY]: a squash merge on master, pushed
land() {
	if [ $# -ge 2 ]; then
		git commit -q --allow-empty -m "$1" -m "$2"
	else
		git commit -q --allow-empty -m "$1"
	fi
	git push -q origin HEAD:refs/heads/master
}

# land_on DATE TITLE: the same, dated
land_on() {
	GIT_AUTHOR_DATE="$1T10:00:00Z" GIT_COMMITTER_DATE="$1T10:00:00Z" land "$2"
}

# pr N LABEL... [-- BODY]: what gh pr view N returns
pr() {
	local n=$1 labels="" body=""
	shift
	while [ $# -gt 0 ]; do
		if [ "$1" = -- ]; then
			body=$2
			break
		fi
		labels="$labels $1"
		shift
	done
	jq -n --arg b "$body" --arg l "$labels" '{labels: ($l | split(" ") | map(select(. != "")) | map({name: .})), body: $b}' \
		>"$GH_STATE/pr-$n.json"
}

origin_log() { git -C "$ORIGIN" log --format='%s' master; }
origin_file() { git -C "$ORIGIN" show "master:$1"; }
origin_tags() { git -C "$ORIGIN" for-each-ref --format='%(refname:strip=2)' refs/tags; }
release_of() { cat "$GH_STATE/release-$1.md"; }
slack_posts() { find "$CURL_LOG" -name 'data.*' | wc -l | tr -d ' '; }
# slack_text N: the text of the Nth post (getPermalink calls carry no data file)
slack_text() {
	local f
	f=$(find "$CURL_LOG" -name 'data.*' | sed 's/.*\.//' | sort -n | sed -n "$1p")
	jq -r .text "$CURL_LOG/data.$f"
}
output() { sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -1; }

# reject the next N pushes to master; with SIDE, a merge "lands" on master as the
# push is refused
reject_master_pushes() {
	local n=$1 side=${2:-}
	cat >"$ORIGIN/hooks/pre-receive" <<EOF
#!/usr/bin/env bash
c=\$(cat "$FX/rejects" 2>/dev/null || echo 0)
while read -r old new ref; do
	if [ "\$ref" = refs/heads/master ] && [ "\$c" -lt $n ]; then
		echo \$((c + 1)) >"$FX/rejects"
		if [ -n "$side" ] && [ "\$c" = 0 ]; then
			env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \\
				git update-ref refs/heads/master "$side"
		fi
		echo "rejected by the test" >&2
		exit 1
	fi
done
exit 0
EOF
	chmod +x "$ORIGIN/hooks/pre-receive"
}
