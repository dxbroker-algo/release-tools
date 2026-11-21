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

@test "a skipped job, a queued job and the reporter's own job are not in the wall" {
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
	[[ $output == *"| queued | queued | — | — | — | — |"* ]] || false
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
