#!/usr/bin/env bats
# check-note: the PR body must hold one release line a broker-side reader understands

RELEASE="$BATS_TEST_DIRNAME/../release.sh"

TITLE="feat(contacts): add a call log tab (T-1698) (#786)"
GOOD="users: Brokers see a Call log tab in Contacts, with missed calls and voicemails."

# body LINE...: a PR body whose release note is those lines
body() {
	printf 'What changed\n\n- some detail\n\n## Release note\n'
	printf '%s\n' "$@"
	printf '\n## Test plan\n- [x] ran it\n'
}

# check TITLE LINE...: run check-note on such a body
check() {
	local title=$1
	shift
	run bash -c '"$0" check-note "$1" 2>&1' "$RELEASE" "$title" < <(body "$@")
}

@test "a users line passes, with its audience and sentence echoed" {
	check "$TITLE" "$GOOD"
	[ "$status" -eq 0 ]
	[ "$output" = "ok: users: Brokers see a Call log tab in Contacts, with missed calls and voicemails." ]
}

@test "internal and tests lines pass; asked-by is optional" {
	check "$TITLE" "internal: The release flow now keeps its own log of every deploy."
	[ "$status" -eq 0 ]
	check "$TITLE" "tests: The calls area's tests were cut from 2,448 to 1,232." "asked-by: Leon"
	[ "$status" -eq 0 ]
	[[ $output == *"(asked by Leon)" ]] || false
}

@test "the title is optional" {
	check "" "$GOOD"
	[ "$status" -eq 0 ]
}

@test "the note is read from a CRLF body, and HTML comments in the section are ignored" {
	run bash -c 'printf "## Release note\r\n<!-- one line: users:, internal: or tests: -->\r\n%s\r\n" "$1" | "$0" check-note' "$RELEASE" "$GOOD"
	[ "$status" -eq 0 ]
	run bash -c 'printf "## Release note\n<!--\nusers: a long example in a comment, which is not the note\n-->\n%s\n" "$1" | "$0" check-note' "$RELEASE" "$GOOD"
	[ "$status" -eq 0 ]
}

@test "blank lines in the section are not lines" {
	run bash -c 'printf "## Release note\n\n%s\n\nasked-by: Max\n\n" "$1" | "$0" check-note' "$RELEASE" "$GOOD"
	[ "$status" -eq 0 ]
}

@test "no section, or an empty one, fails" {
	run bash -c 'printf "just a body\n" | "$0" check-note 2>&1' "$RELEASE"
	[ "$status" -eq 1 ]
	[[ $output == *'no "## Release note" line'* ]] || false
	run bash -c 'printf "## Release note\n\n## Test plan\n- x\n" | "$0" check-note 2>&1' "$RELEASE"
	[ "$status" -eq 1 ]
	[[ $output == *"(empty, or no such section)"* ]] || false
}

@test "a failure prints the section it read and the first rule broken" {
	check "$TITLE" "fixed the thing"
	[ "$status" -eq 1 ]
	[[ $output == *'Release note check failed: the line must start with "users: ", "internal: " or "tests: "'* ]] || false
	[[ $output == *'    | fixed the thing'* ]] || false
	[[ $output == *'It reads one line'* ]] || false
}

@test "the prefix is lowercase, followed by a colon and a space, one of three" {
	for l in "Users: Brokers see a Call log tab in Contacts." "user: Brokers see a Call log tab in Contacts." \
		"users:Brokers see a Call log tab in Contacts." "- users: Brokers see a Call log tab in Contacts." \
		"fix: Brokers see a Call log tab in Contacts."; do
		check "$TITLE" "$l"
		[ "$status" -eq 1 ] || {
			echo "accepted: $l"
			return 1
		}
	done
}

@test "the sentence is 20 to 200 characters, counted as characters, not bytes" {
	check "$TITLE" "users: 12345678901234567890"
	[ "$status" -eq 0 ]
	check "$TITLE" "users: 1234567890123456789"
	[ "$status" -eq 1 ]
	[[ $output == *"is 19 characters: it is 20 to 200"* ]] || false
	# 19 letters and a dash that is three bytes
	check "$TITLE" "users: abcdefghijklmnopqrs—"
	[ "$status" -eq 0 ]
	check "$TITLE" "users: abcdefghijklmnopqr—"
	[ "$status" -eq 1 ]
	long=$(printf 'a%.0s' $(seq 1 200))
	check "$TITLE" "users: $long"
	[ "$status" -eq 0 ]
	check "$TITLE" "users: ${long}a"
	[ "$status" -eq 1 ]
	[[ $output == *"is 201 characters"* ]] || false
}

@test "a T- id is refused: the post adds the task itself" {
	check "$TITLE" "users: Brokers see a Call log tab in Contacts (T-1698)."
	[ "$status" -eq 1 ]
	[[ $output == *"has a T- id"* ]] || false
	check "$TITLE" "users: Brokers see the new BAT-11 pill on every contact card."
	[ "$status" -eq 0 ]
}

@test "a file name is refused" {
	check "$TITLE" "users: The contact modal reads its layout from contact_modal.tsx now."
	[ "$status" -eq 1 ]
	[[ $output == *"names a file"* ]] || false
}

@test "the PR title, as a sentence, is refused: whole or after its type and scope" {
	check "feat(contacts): add a call log tab (#786)" "users: feat(contacts): add a call log tab"
	[ "$status" -eq 1 ]
	check "feat(contacts): Brokers see a call log tab in Contacts (#786)" "users: Brokers see a call log tab in contacts."
	[ "$status" -eq 1 ]
	[[ $output == *"repeats the PR title"* ]] || false
	check "[visual review missing] feat(contacts): Brokers see a call log tab in Contacts (#786)" "users: brokers see a call log tab in contacts"
	[ "$status" -eq 1 ]
}

@test "Hebrew and Arabic letters are refused" {
	check "$TITLE" "users: Brokers see a Call log tab, שיחות, in Contacts."
	[ "$status" -eq 1 ]
	[[ $output == *"Hebrew or Arabic"* ]] || false
	check "$TITLE" "users: Brokers see a Call log tab, المكالمات, in Contacts."
	[ "$status" -eq 1 ]
}

@test "more than a note and an asked-by line is refused" {
	check "$TITLE" "$GOOD" "asked-by: Leon" "and more words"
	[ "$status" -eq 1 ]
	[[ $output == *"holds 3 lines"* ]] || false
	check "$TITLE" "$GOOD" "$GOOD"
	[ "$status" -eq 1 ]
	[[ $output == *'must read "asked-by: <name>"'* ]] || false
}

@test "asked-by takes a name of up to 40 characters" {
	check "$TITLE" "$GOOD" "asked-by: Leon"
	[ "$status" -eq 0 ]
	check "$TITLE" "$GOOD" "asked-by: $(printf 'x%.0s' $(seq 1 40))"
	[ "$status" -eq 0 ]
	check "$TITLE" "$GOOD" "asked-by: $(printf 'x%.0s' $(seq 1 41))"
	[ "$status" -eq 1 ]
	[[ $output == *"up to 40 characters"* ]] || false
	check "$TITLE" "$GOOD" "asked-by:"
	[ "$status" -eq 1 ]
}

@test "the heading may read 'Release notes', in any case of its words" {
	run bash -c 'printf "## release Notes\n%s\n" "$1" | "$0" check-note' "$RELEASE" "$GOOD"
	[ "$status" -eq 0 ]
}

@test "pr-title warns, and still passes, on a scope the area map does not know" {
	run "$RELEASE" check-title "feat(lead-score): rank leads"
	[ "$status" -eq 0 ]
	[[ $output == *'the scope "lead-score" is not in the area map'* ]] || false
	for t in "feat(contacts): a" "fix(crm-shell): a" "chore(ci): a" "feat: a" "fix(release)!: a"; do
		run "$RELEASE" check-title "$t"
		[ "$status" -eq 0 ]
		[[ $output != *"area map"* ]] || {
			echo "warned for $t"
			return 1
		}
	done
}

@test "in Actions, the area warning is an annotation" {
	GITHUB_ACTIONS=true run "$RELEASE" check-title "feat(lead-score): rank leads (#4)"
	[ "$status" -eq 0 ]
	[[ $output == *"::warning::the scope"* ]] || false
}
