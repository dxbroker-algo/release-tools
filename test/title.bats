#!/usr/bin/env bats
# check-title: the PR title is the squash title, so it must read as one

RELEASE="$BATS_TEST_DIRNAME/../release.sh"

@test "conventional titles pass" {
	for t in "feat: x" "fix(api): y (T-12)" "feat(ui)!: z" "chore!: drop" \
		"[visual review missing] feat(ui): table" "revert: feat: x" "infra(dns): records"; do
		run "$RELEASE" check-title "$t"
		[ "$status" -eq 0 ] || {
			echo "refused: $t"
			return 1
		}
	done
}

@test "unknown types and free-form titles fail, saying why" {
	run "$RELEASE" check-title "add: a page"
	[ "$status" -eq 1 ]
	[[ $output == *'type "add" is not one of'* ]] || false
	for t in "Update README" "feat:x" "feat: " "Feat: x" "feat(): x" "[visual review missing]feat: x"; do
		run "$RELEASE" check-title "$t"
		[ "$status" -eq 1 ] || {
			echo "accepted: $t"
			return 1
		}
	done
}
