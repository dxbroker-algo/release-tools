#!/usr/bin/env bats
# a reader that stops early must not fail a release: under pipefail, its writer's
# SIGPIPE (or EPIPE, where SIGPIPE is ignored, as on Actions) is the script's exit

load helpers/common

setup() { setup_fixture; }

# pr_body_file N FILE: gh pr view N returns FILE as the body. A big one does not
# fit in an argument, which is how pr() takes it.
pr_body_file() {
	jq -n --rawfile b "$2" '{labels: [], body: $b}' >"$GH_STATE/pr-$1.json"
}

# body_of_size BYTES: a release note, the next heading straight after it (where the
# parser stops reading), then padding up to BYTES
body_of_size() {
	printf '## Release note\nThe note itself.\n\n## What changed\n'
	awk -v n="$1" 'BEGIN { for (i = 50; i < n; i += 64) print "padding padding padding padding padding padding padding padding" }'
}

@test "a body far over any pipe's capacity: the writer has to outlive the parser, and the release is cut" {
	body_of_size 2097152 >"$FX/body"
	pr_body_file 1 "$FX/body"
	land "fix: long body (#1)"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	[ "$(origin_tags)" = v0.1.0 ]
	grep -q '^The note itself\. (\[#1\]' "$GH_STATE/release-v0.1.0.md"
	[ "$(slack_posts)" = 1 ]
	! grep -q padding "$GH_STATE/release-v0.1.0.md"
}

@test "the same body with SIGPIPE ignored, as on Actions: no write error either" {
	body_of_size 2097152 >"$FX/body"
	pr_body_file 1 "$FX/body"
	land "fix: long body (#1)"
	run bash -c 'trap "" PIPE; exec "$1" cut --dry-run' _ "$RELEASE"
	[ "$status" -eq 0 ]
	[[ $output == *"The note itself. ([#1]("* ]] || false
	[[ $output != *"roken pipe"* ]] || false
}

# dxb-backend #343, CD run 41170069974: 5,268 bytes, far under a pipe's capacity,
# with the next heading in the first 4 KB. The body reached awk in two writes and
# awk had left before the second. A tr that waits between them makes that certain.
@test "a body under a pipe's capacity, written in two chunks with the parser gone in between" {
	body_of_size 5268 >"$FX/body"
	pr_body_file 1 "$FX/body"
	land "fix: mid-size body (#1)"
	mkdir "$FX/slow"
	cat >"$FX/slow/tr" <<EOF
#!/usr/bin/env bash
"$(command -v tr)" "\$@" >"$FX/tr.out"
head -c 4096 "$FX/tr.out"
sleep 1
tail -c +4097 "$FX/tr.out"
EOF
	chmod +x "$FX/slow/tr"
	run env PATH="$FX/slow:$PATH" "$RELEASE" cut --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"The note itself. ([#1]("* ]] || false
}

@test "the note is what it was: CRs gone, comments gone, the next heading ends it" {
	pr 1 -- $'intro\r\n## Release note\r\n\r\nFirst <!-- hidden --> line.\r\n\r\nSecond line.\r\n\r\n## What changed\r\nNot this.\r\n'
	land "fix: a note (#1)"
	run "$RELEASE" cut --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *$'First  line.\n\nSecond line. ([#1]('* ]] || false
	[[ $output != *"Not this."* ]] || false
	[[ $output != *"hidden"* ]] || false
	[[ $output != *$'\r'* ]] || false
}
