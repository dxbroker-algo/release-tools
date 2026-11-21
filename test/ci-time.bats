#!/usr/bin/env bats
# ci-time.sh: the CI time job's report — the wall of a run, over a fixed jobs list.
#
# No network: the jobs JSON is a fixture, and the report is read from it.

CI_TIME="$BATS_TEST_DIRNAME/../ci-time.sh"
JOBS="$BATS_TEST_DIRNAME/fixtures/ci-time-jobs.json"

# The report over the fixture, with the limit LIMIT
report() {
	local limit=${1:-5}
	run bash "$CI_TIME" --jobs "$JOBS" --limit "$limit"
}

@test "the wall runs from the first job's start to the last job's end" {
	report 5
	[ "$status" -eq 0 ]
	[[ $output == *"the run's wall is 3m 00s"* ]] || false
}

@test "a skipped job and the reporter's own job are not in the wall" {
	# The skipped job starts at 10:00:00, a second before the first real job: counting it
	# would make the wall 3m 05s.
	report 5
	[[ $output == *"3m 00s"* ]] || false
	[[ $output != *"3m 05s"* ]] || false
}

@test "every job is in the table, with its start, its end, its queue and its own time" {
	report 5
	[[ $output == *"| test | completed (success) | 10:00:05 | 10:01:05 | 5s | 1m 00s |"* ]] || false
	[[ $output == *"| lint | completed (success) | 10:00:10 | 10:00:40 | 10s | 30s |"* ]] || false
	[[ $output == *"| slow | completed (failure) | 10:00:05 | 10:03:05 | 5s | 3m 00s |"* ]] || false
	[[ $output == *"| CI time (S-37) | in_progress | 10:03:06 | — | 1s | — |"* ]] || false
}

@test "the queue before the first job is reported apart, never inside the wall" {
	report 5
	[[ $output == *"Queue before the first job: 5s (excluded from the wall)."* ]] || false
}

@test "a wall over the limit is a ⚠ line, and the run is not failed" {
	report 2
	[ "$status" -eq 0 ]
	[[ $output == *"⚠ CI time (S-37): the run's wall is 3m 00s — OVER the 2 min limit. REPORT-ONLY: this run is not failed."* ]] || false
}

@test "a wall under the limit says so" {
	report 5
	[[ $output == *"CI time (S-37): the run's wall is 3m 00s — under the 5 min limit."* ]] || false
}

@test "the report goes to the run's page as well as to the log" {
	export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary"
	report 5
	[ "$status" -eq 0 ]
	[ -s "$GITHUB_STEP_SUMMARY" ]
	grep -q "the run's wall is 3m 00s" "$GITHUB_STEP_SUMMARY" || false
}

@test "the jobs are not read without a token: the run is not failed" {
	unset GITHUB_TOKEN
	run bash "$CI_TIME"
	[ "$status" -eq 0 ]
	[[ $output == *"the run's jobs were not read"* ]] || false
}

# The self-check: a job that began or ended after this job started is not in its `needs:`.
LATE="$BATS_TEST_DIRNAME/fixtures/ci-time-jobs-late.json"

@test "a job that ended after this job started is named: it is missing from needs" {
	RUNNER_NAME=runner-3 run bash "$CI_TIME" --jobs "$LATE" --limit 5
	[ "$status" -eq 0 ]
	[[ $output == *"⚠ late, deploy-check, waiting began, is still waiting, or ended after this job started, so they are not in this job's needs:"* ]] || false
}

@test "a job still running, or still waiting for a runner, is named too" {
	RUNNER_NAME=runner-3 run bash "$CI_TIME" --jobs "$LATE" --limit 5
	[[ $output == *"deploy-check"* ]] || false
	[[ $output == *"waiting"* ]] || false
	# the jobs that ended before this one started are not named
	[[ $output != *"⚠ test"* ]] || false
	[[ $output != *"lint began"* ]] || false
}

@test "every job in needs: says so, and names no one" {
	report 5
	[[ $output == *"needs: every job that ran is in this job's needs:."* ]] || false
	[[ $output != *"began or ended after"* ]] || false
}

@test "a skipped job is not missing from needs, though GitHub stamps it after this job started" {
	RUNNER_NAME=runner-3 run bash "$CI_TIME" --jobs "$LATE" --limit 5
	[[ $output == *"⚠ late, deploy-check, waiting began"* ]] || false
}

@test "two running jobs and no runner to tell them apart: the self-check says it did not look" {
	run bash "$CI_TIME" --jobs "$LATE" --limit 5
	[ "$status" -eq 0 ]
	[[ $output == *"⚠ not checked: which job is this one could not be told"* ]] || false
}

@test "the action runs the shared script with its limit and token" {
	grep -q 'ci-time.sh' "$BATS_TEST_DIRNAME/../ci-time/action.yml"
	grep -q 'CI_TIME_LIMIT_MINUTES: ${{ inputs.limit }}' "$BATS_TEST_DIRNAME/../ci-time/action.yml"
	grep -q 'default: "5"' "$BATS_TEST_DIRNAME/../ci-time/action.yml"
}

# enforce (design ci-time-limits A4): the same script is the gate. Five proofs: under, over, a
# truncated jobs file, a refused read, a bad limit.
@test "enforce: a wall under the limit passes" {
	run bash "$CI_TIME" --jobs "$JOBS" --limit 5 --enforce
	[ "$status" -eq 0 ]
	[[ $output == *"the run's wall is 3m 00s — under the 5 min limit."* ]] || false
}

@test "enforce: a wall over the limit exits 1 with an error naming the wall and the limit" {
	run bash "$CI_TIME" --jobs "$JOBS" --limit 2 --enforce
	[ "$status" -eq 1 ]
	[[ $output == *"::error::CI time (S-37): the run's wall is 3m 00s, over the 2 min limit."* ]] || false
	[[ $output == *"This run is failed."* ]] || false
	[[ $output != *"REPORT-ONLY"* ]] || false
}

@test "enforce: a truncated jobs list fails closed" {
	local f="$BATS_TEST_TMPDIR/truncated.json"
	jq '.total_count = 101' "$JOBS" >"$f"
	run bash "$CI_TIME" --jobs "$f" --limit 5 --enforce
	[ "$status" -eq 1 ]
	[[ $output == *"::error::"*"only 5 were read"* ]] || false
	# report-only, the same file is a warning and exit 0
	run bash "$CI_TIME" --jobs "$f" --limit 5
	[ "$status" -eq 0 ]
}

@test "enforce: a refused read fails closed, report-only does not" {
	export GITHUB_TOKEN=t GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=1
	export GITHUB_API_URL="file:///nonexistent"
	run bash "$CI_TIME" --limit 5 --enforce
	[ "$status" -eq 1 ]
	[[ $output == *"::error::CI time (S-37): the run's jobs were not read"* ]] || false
	run bash "$CI_TIME" --limit 5
	[ "$status" -eq 0 ]
}

@test "enforce: a run with no jobs fails closed" {
	local f="$BATS_TEST_TMPDIR/empty.json"
	printf '{"total_count":0,"jobs":[]}' >"$f"
	run bash "$CI_TIME" --jobs "$f" --limit 5 --enforce
	[ "$status" -eq 1 ]
	[[ $output == *"::error::"*"no job ran"* ]] || false
}

@test "enforce: an unreadable jobs file fails closed" {
	local f="$BATS_TEST_TMPDIR/bad.json"
	printf 'not json' >"$f"
	run bash "$CI_TIME" --jobs "$f" --limit 5 --enforce
	[ "$status" -eq 1 ]
	[[ $output == *"::error::"*"could not be read"* ]] || false
}

@test "enforce: a bad limit is exit 2, enforced or not" {
	run bash "$CI_TIME" --jobs "$JOBS" --limit abc --enforce
	[ "$status" -eq 2 ]
	run bash "$CI_TIME" --jobs "$JOBS" --limit abc
	[ "$status" -eq 2 ]
}

@test "enforce: CI_TIME_ENFORCE=true is the same as --enforce; anything else is an error" {
	CI_TIME_ENFORCE=true run bash "$CI_TIME" --jobs "$JOBS" --limit 2
	[ "$status" -eq 1 ]
	CI_TIME_ENFORCE=false run bash "$CI_TIME" --jobs "$JOBS" --limit 2
	[ "$status" -eq 0 ]
	CI_TIME_ENFORCE=yes run bash "$CI_TIME" --jobs "$JOBS" --limit 2
	[ "$status" -eq 2 ]
}

@test "the action takes enforce, default false, and passes it to the script" {
	grep -q 'CI_TIME_ENFORCE: ${{ inputs.enforce }}' "$BATS_TEST_DIRNAME/../ci-time/action.yml"
	awk '/^  enforce:/{f=1} f&&/default:/{print; exit}' "$BATS_TEST_DIRNAME/../ci-time/action.yml" | grep -q 'default: "false"'
}
