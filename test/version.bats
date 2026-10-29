#!/usr/bin/env bats
# titles -> version

load helpers/common

setup() { setup_fixture; }

cut_dry() { run "$RELEASE" cut --dry-run "$@"; }

# a released v0.1.0, the next range then landed on top
with_first_release() {
	land "feat: the first thing (#1)"
	run "$RELEASE" cut
	[ "$status" -eq 0 ]
	git pull -q --ff-only origin master
}

@test "the first release is v0.1.0, whatever the titles say" {
	land "fix: a fix (#1)"
	cut_dry
	[ "$status" -eq 0 ]
	[ "$(output version)" = 0.1.0 ]
	[[ $output == *"tag v0.1.0 (annotated)"* ]] || false
}

@test "fix, chore, docs only: patch" {
	with_first_release
	land "fix(api): a fix (T-1) (#2)"
	land "chore: tidy (#3)"
	land "docs: words (#4)"
	cut_dry
	[ "$(output version)" = 0.1.1 ]
}

@test "any feat: minor" {
	with_first_release
	land "fix: a fix (#2)"
	land "feat(ui): a thing (#3)"
	cut_dry
	[ "$(output version)" = 0.2.0 ]
}

@test "a ! while the major is 0: minor, under Breaking" {
	with_first_release
	land "fix(api)!: drop the old field (#2)"
	cut_dry
	[ "$(output version)" = 0.2.0 ]
	[[ $output == *"### Breaking"$'\n'"- fix(api)!: drop the old field ([#2](https://github.com/acme/widget/pull/2))"* ]] || false
	[[ $output != *"### Fixes"* ]] || false
}

@test "BREAKING CHANGE: in the squash body counts as a !" {
	with_first_release
	land "refactor: rename (#2)" $'* refactor: rename\n\nBREAKING CHANGE: the column is gone'
	cut_dry
	[ "$(output version)" = 0.2.0 ]
	[[ $output == *"### Breaking"* ]] || false
}

@test "a ! once the major is 1 or more: major" {
	land "feat: one (#1)"
	run "$RELEASE" cut --version 1.0.0
	[ "$status" -eq 0 ]
	git pull -q --ff-only origin master
	land "feat!: two (#2)"
	cut_dry
	[ "$(output version)" = 2.0.0 ]
}

@test "1.0.0 is cut by hand with --version, and must be above the last tag" {
	with_first_release
	land "fix: x (#2)"
	cut_dry --version 1.0.0
	[ "$status" -eq 0 ]
	[ "$(output version)" = 1.0.0 ]
	cut_dry --version 0.1.0
	[ "$status" -ne 0 ]
	[[ $output == *"is not above v0.1.0"* ]] || false
	cut_dry --version 1.0
	[ "$status" -ne 0 ]
}

@test "an unknown type is a patch, listed under Other; a title outside the grammar too" {
	with_first_release
	land "add: a new page (#2)"
	land "Merge something odd"
	cut_dry
	[ "$(output version)" = 0.1.1 ]
	[[ $output == *"### Other"$'\n'"- Merge something odd"$'\n'"- add: a new page ([#2]("* ]] || false
}

@test "release commits are not part of any range" {
	with_first_release
	run git log --format=%s -1 origin/master
	[[ $output == "chore(release): v0.1.0 [skip ci]" ]] || false
	land "fix: after (#2)"
	cut_dry
	[ "$(output version)" = 0.1.1 ]
	[[ $output != *"- chore(release)"* ]] || false
	[[ $output != *"• chore(release)"* ]] || false
	[[ $output == *"1 fix  ("* ]] || false
}

@test "the visual-review prefix moves to the end of the line" {
	land "[visual review missing] feat(ui): new table (T-9) (#5)"
	cut_dry
	[[ $output == *"- feat(ui): new table (T-9) ([#5](https://github.com/acme/widget/pull/5)) ⚠ visual review missing"* ]] || false
	[[ $output == *"• feat(ui): new table (T-9, #5) ⚠ visual review missing"* ]] || false
}
