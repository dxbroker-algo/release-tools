#!/usr/bin/env bats
# ci-time.sh: the CI time job's report — the wall of a run, over a fixed jobs list.
#
# No network: the jobs JSON is a fixture, and the report is read from it.

CI_TIME="$BATS_TEST_DIRNAME/../ci-time.sh"
JOBS="$BATS_TEST_DIRNAME/fixtures/ci-time-jobs.json"

# The suite is deterministic: the attempt comes from --attempt, never from the environment.
# Actions sets GITHUB_RUN_ATTEMPT for the job that runs these tests, and the script then
# measures an attempt nobody asked for: the fixture's jobs land in another attempt, and the
# attempt's own start costs the API stub one more read.
setup() {
	unset GITHUB_RUN_ATTEMPT
}

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
	export CI_TIME_WAIT_SECONDS=1
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
	[[ $output == *"::error::"*"no job other than this one"* ]] || false
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

@test "the action takes needs and passes it to the script" {
	grep -q 'CI_TIME_NEEDS: ${{ inputs.needs }}' "$BATS_TEST_DIRNAME/../ci-time/action.yml"
}

@test "the action takes enforce, default false, and passes it to the script" {
	grep -q 'CI_TIME_ENFORCE: ${{ inputs.enforce }}' "$BATS_TEST_DIRNAME/../ci-time/action.yml"
	awk '/^  enforce:/{f=1} f&&/default:/{print; exit}' "$BATS_TEST_DIRNAME/../ci-time/action.yml" | grep -q 'default: "false"'
}

@test "enforce: every other job skipped is a known wall of 0 and passes" {
	local f="$BATS_TEST_TMPDIR/skipped.json"
	cat >"$f" <<'JSON'
{"total_count":2,"jobs":[
{"name":"test","status":"completed","conclusion":"skipped","created_at":"2026-11-21T10:00:00Z","started_at":"2026-11-21T10:00:01Z","completed_at":"2026-11-21T10:00:01Z"},
{"name":"CI time (S-37)","status":"in_progress","conclusion":null,"created_at":"2026-11-21T10:00:02Z","started_at":"2026-11-21T10:00:03Z","completed_at":null,"runner_name":"runner-1"}
]}
JSON
	RUNNER_NAME=runner-1 run bash "$CI_TIME" --jobs "$f" --limit 5 --enforce
	[ "$status" -eq 0 ]
	[[ $output == *"every other job was skipped: wall 0"* ]] || false
	[[ $output != *"::error::"* ]] || false
}

@test "enforce: a list holding only this job fails closed (a re-run that lost the other jobs)" {
	local f="$BATS_TEST_TMPDIR/self-only.json"
	cat >"$f" <<'JSON'
{"total_count":1,"jobs":[
{"name":"CI time (S-37)","status":"in_progress","conclusion":null,"created_at":"2026-11-21T10:00:02Z","started_at":"2026-11-21T10:00:03Z","completed_at":null,"runner_name":"runner-1"}
]}
JSON
	RUNNER_NAME=runner-1 run bash "$CI_TIME" --jobs "$f" --limit 5 --enforce
	[ "$status" -eq 1 ]
	[[ $output == *"::error::"*"no job other than this one"* ]] || false
}

# The jobs API can lag (design tests-5x A10.2): the script re-reads until the other jobs report
# completed, bounded by CI_TIME_WAIT_SECONDS. A stub curl answers read N with the Nth file of
# $SEQ (the last one again after that); the reads are counted in $SEQ/count.
api_stub() {
	mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/seq"
	cat >"$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
seq_dir="$SEQ"
n=$(($(cat "$seq_dir/count" 2>/dev/null || echo 0) + 1))
echo "$n" >"$seq_dir/count"
f="$seq_dir/$n.json"
[ -f "$f" ] || f=$(find "$seq_dir" -name '*.json' | sort | tail -n 1)
cat "$f"
STUB
	chmod +x "$BATS_TEST_TMPDIR/bin/curl"
	export SEQ="$BATS_TEST_TMPDIR/seq"
	export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
	export GITHUB_TOKEN=t GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=1 RUNNER_NAME=runner-1
	export CI_TIME_NEEDS="test,lint,slow"
}

@test "lag: the API shows a needs job in_progress, then completed: the wall is measured, no failure" {
	api_stub
	# first read: "slow" is still in_progress (the API lags)
	jq '(.jobs[] | select(.name == "slow")) |= (.status = "in_progress" | .conclusion = null | .completed_at = null)' \
		"$JOBS" >"$SEQ/1.json"
	cp "$JOBS" "$SEQ/2.json"
	CI_TIME_WAIT_SECONDS=20 run bash "$CI_TIME" --limit 5 --enforce
	[ "$status" -eq 0 ]
	[[ $output == *"reading again"* ]] || false
	[[ $output == *"the run's wall is 3m 00s — under the 5 min limit."* ]] || false
	[[ $output != *"::error::"* ]] || false
	[ "$(cat "$SEQ/count")" -eq 2 ]
}

@test "lag: the API first shows no job but this one, then the rest: measured, no failure" {
	api_stub
	jq '.jobs |= map(select(.name == "CI time (S-37)")) | .total_count = 1' "$JOBS" >"$SEQ/1.json"
	cp "$JOBS" "$SEQ/2.json"
	CI_TIME_WAIT_SECONDS=20 run bash "$CI_TIME" --limit 5 --enforce
	[ "$status" -eq 0 ]
	[[ $output == *"the run's wall is 3m 00s"* ]] || false
}

@test "lag: the API never completes the job: after the wait the run fails closed, with a clear message" {
	api_stub
	jq '.jobs |= map(select(.name == "CI time (S-37)")) | .total_count = 1' "$JOBS" >"$SEQ/1.json"
	CI_TIME_WAIT_SECONDS=2 run bash "$CI_TIME" --limit 5 --enforce
	[ "$status" -eq 1 ]
	[[ $output == *"after 2s the jobs API still shows a job in needs (test,lint,slow) unfinished or missing"* ]] || false
	[[ $output == *"::error::"*"no job other than this one"* ]] || false
	[ "$(cat "$SEQ/count")" -ge 2 ]
}

@test "lag: the normal case is read once, with no wait" {
	api_stub
	cp "$JOBS" "$SEQ/1.json"
	CI_TIME_WAIT_SECONDS=20 run bash "$CI_TIME" --limit 5 --enforce
	[ "$status" -eq 0 ]
	[[ $output != *"reading again"* ]] || false
	[[ $output == *"the run's wall is 3m 00s — under the 5 min limit."* ]] || false
	[ "$(cat "$SEQ/count")" -eq 1 ]
}

@test "lag: a job outside needs that is still running is not waited on" {
	api_stub
	jq '.jobs += [{"name":"stg","status":"in_progress","conclusion":null,"created_at":"2026-11-21T10:00:00Z","started_at":"2026-11-21T10:00:20Z","completed_at":null,"runner_name":"runner-9"}] | .total_count = 6' \
		"$JOBS" >"$SEQ/1.json"
	CI_TIME_WAIT_SECONDS=20 run bash "$CI_TIME" --limit 5
	[ "$status" -eq 0 ]
	[[ $output != *"reading again"* ]] || false
	[ "$(cat "$SEQ/count")" -eq 1 ]
}

@test "lag: a reusable-workflow job named 'caller / job' is matched by its caller's name" {
	api_stub
	jq '(.jobs[] | select(.name == "slow") | .name) = "slow / inner" | (.jobs[] | select(.name == "slow / inner")) |= (.status = "in_progress" | .conclusion = null | .completed_at = null)' \
		"$JOBS" >"$SEQ/1.json"
	jq '(.jobs[] | select(.name == "slow") | .name) = "slow / inner"' "$JOBS" >"$SEQ/2.json"
	CI_TIME_WAIT_SECONDS=3 run bash "$CI_TIME" --limit 5
	[ "$status" -eq 0 ]
	[[ $output == *"reading again"* ]] || false
	[[ $output != *"unfinished or missing"* ]] || false
}

@test "lag: report-only never fails on a job that stays unfinished" {
	api_stub
	jq '.jobs |= map(select(.name == "CI time (S-37)"))' "$JOBS" >"$SEQ/1.json"
	CI_TIME_WAIT_SECONDS=1 run bash "$CI_TIME" --limit 5
	[ "$status" -eq 0 ]
}

@test "lag: the wait is a whole number of seconds" {
	CI_TIME_WAIT_SECONDS=soon run bash "$CI_TIME" --jobs "$JOBS"
	[ "$status" -eq 2 ]
}

# The count runs ahead of the listing (S-17): the API counts a job it has not listed yet — the
# reporter's own job is created last, and the count is updated at once — so the wall is not
# known until the listing holds every job the run counts. The recorded payload of a
# phase=deploy release run: 19 jobs counted, 18 listed (the reporter's own job is the one
# missing).
DEPLOY="$BATS_TEST_DIRNAME/fixtures/ci-time-jobs-deploy.json"

@test "lag: a job the API counts but has not listed is read again until it is listed" {
	api_stub
	cp "$DEPLOY" "$SEQ/1.json"
	# the second read lists the reporter's own job: the listing holds every job the run counts
	jq '.jobs += [{"id":900010019,"name":"CI time (S-37)","status":"in_progress","conclusion":null,"created_at":"2026-11-26T13:24:38Z","started_at":"2026-11-26T13:24:40Z","completed_at":null,"runner_name":"runner-1"}]' \
		"$DEPLOY" >"$SEQ/2.json"
	CI_TIME_NEEDS="" CI_TIME_WAIT_SECONDS=20 run bash "$CI_TIME" --limit 20 --enforce
	[ "$status" -eq 0 ]
	[[ $output == *"reading again"* ]] || false
	# the wall is the jobs that ran: Authorize 13:21:15 to the Cut 13:24:30. The skipped jobs
	# are not in it.
	[[ $output == *"the run's wall is 3m 15s"* ]] || false
	[[ $output != *"::error::"* ]] || false
	[ "$(cat "$SEQ/count")" -eq 2 ]
}

@test "lag: a job the API never lists fails the run closed, with the count named" {
	api_stub
	cp "$DEPLOY" "$SEQ/1.json"
	CI_TIME_NEEDS="" CI_TIME_WAIT_SECONDS=1 run bash "$CI_TIME" --limit 20 --enforce
	[ "$status" -eq 1 ]
	[[ $output == *"reading again"* ]] || false
	[[ $output == *"::error::CI time (S-37): the run has 19 jobs and only 18 were read"* ]] || false
}

@test "lag: a run with more jobs than one page is not waited on: the listing is truncated, not lagging" {
	api_stub
	jq '.total_count = 150' "$JOBS" >"$SEQ/1.json"
	CI_TIME_WAIT_SECONDS=20 run bash "$CI_TIME" --limit 5 --enforce
	[ "$status" -eq 1 ]
	[[ $output == *"only 5 were read"* ]] || false
	[ "$(cat "$SEQ/count")" -eq 1 ]
}

# needs scopes the wall (design ci-time-limits A6.1): with CI_TIME_NEEDS set, only the jobs it
# names are in the wall; every other job is listed apart. Without it, every job that ran counts.
@test "needs: a job outside needs is listed apart and the wall is unchanged by it" {
	# "slow" ends at 10:03:05; without it the wall is test's 10:00:05 to 10:01:05, with it 3m 00s.
	CI_TIME_NEEDS="test,lint" run bash "$CI_TIME" --jobs "$JOBS" --limit 5
	[ "$status" -eq 0 ]
	[[ $output == *"the run's wall is 1m 00s — under the 5 min limit."* ]] || false
	[[ $output == *"outside this job's needs (not in the wall):"* ]] || false
	local outside=${output#*"outside this job's needs (not in the wall):"}
	[[ $outside == *"| slow | completed (failure) | 10:00:05 | 10:03:05 | 5s | 3m 00s |"* ]] || false
	[[ ${output%%"outside this job's needs"*} != *"| slow |"* ]] || false
}

@test "needs: the same job is counted when needs is unset" {
	run bash "$CI_TIME" --jobs "$JOBS" --limit 5
	[[ $output == *"the run's wall is 3m 00s"* ]] || false
	[[ $output != *"outside this job's needs"* ]] || false
}

@test "needs: a late job outside needs is not warned about; one inside needs still is" {
	RUNNER_NAME=runner-3 CI_TIME_NEEDS="test,lint,late,deploy-check,waiting" run bash "$CI_TIME" --jobs "$LATE" --limit 5
	[[ $output == *"⚠ late, deploy-check, waiting began"* ]] || false
	RUNNER_NAME=runner-3 CI_TIME_NEEDS="test,lint" run bash "$CI_TIME" --jobs "$LATE" --limit 5
	[[ $output != *"began, is still waiting"* ]] || false
	[[ $output == *"outside this job's needs (not in the wall):"* ]] || false
}

@test "needs: a needs job missing from the read still warns" {
	api_stub
	jq '.jobs |= map(select(.name != "slow"))' "$JOBS" >"$SEQ/1.json"
	CI_TIME_WAIT_SECONDS=1 run bash "$CI_TIME" --limit 5
	[ "$status" -eq 0 ]
	[[ $output == *"after 1s the jobs API still shows a job in needs (test,lint,slow) unfinished or missing"* ]] || false
}

# A rerun is measured on its own attempt (ruling A17): GITHUB_RUN_ATTEMPT picks the jobs, and the
# queue is from the attempt's own run_started_at.

# rerun_jobs: attempt 1 ran 10:00-10:03 (build 10:00:05-10:02:00, test 10:00:10-10:03:00, both with
# run_attempt 1); a --failed rerun at 15:20 re-ran only test (attempt 2, 15:20:30-15:21:30) and
# carried build over.
rerun_jobs() {
	cat >"$BATS_TEST_TMPDIR/jobs.json" <<'JSON'
{"total_count": 3, "jobs": [
 {"name": "build", "run_attempt": 1, "status": "completed", "conclusion": "success",
  "created_at": "2026-11-24T10:00:00Z", "started_at": "2026-11-24T10:00:05Z", "completed_at": "2026-11-24T10:02:00Z"},
 {"name": "test", "run_attempt": 2, "status": "completed", "conclusion": "success",
  "created_at": "2026-11-24T15:20:20Z", "started_at": "2026-11-24T15:20:30Z", "completed_at": "2026-11-24T15:21:30Z"},
 {"name": "CI time (S-37)", "run_attempt": 2, "status": "in_progress", "conclusion": null,
  "created_at": "2026-11-24T15:21:30Z", "started_at": "2026-11-24T15:21:32Z", "completed_at": null}
]}
JSON
}

@test "a --failed rerun reads the larger of the attempt's own wall and the kept jobs' wall" {
	rerun_jobs
	run bash "$CI_TIME" --jobs "$BATS_TEST_TMPDIR/jobs.json" --attempt 2 --run-started-at 2026-11-24T15:20:15Z
	[ "$status" -eq 0 ]
	# The attempt's own jobs ran 15:20:30-15:21:30 (1m 00s); the job it kept ran 10:00:05-10:02:00
	# (1m 55s). The wall of the run is the larger of the two.
	[[ $output == *"the run's wall is 1m 55s"* ]] || false
	[[ $output == *"This attempt's own jobs: 1m 00s (15:20:30 → 15:21:30)."* ]] || false
	[[ $output == *"Kept from an earlier attempt: 1m 55s (10:00:05 → 10:02:00) — build (attempt 1)."* ]] || false
	[[ $output == *"Queue before the first job: 15s (excluded from the wall)."* ]] || false
	[[ $output != *"| build |"* ]] || false
}

@test "a full rerun measures attempt 2 only" {
	cat >"$BATS_TEST_TMPDIR/jobs.json" <<'JSON'
{"total_count": 3, "jobs": [
 {"name": "build", "run_attempt": 2, "status": "completed", "conclusion": "success",
  "created_at": "2026-11-24T15:20:20Z", "started_at": "2026-11-24T15:20:30Z", "completed_at": "2026-11-24T15:22:00Z"},
 {"name": "test", "run_attempt": 2, "status": "completed", "conclusion": "success",
  "created_at": "2026-11-24T15:20:20Z", "started_at": "2026-11-24T15:20:40Z", "completed_at": "2026-11-24T15:23:30Z"},
 {"name": "CI time (S-37)", "run_attempt": 2, "status": "in_progress", "conclusion": null,
  "created_at": "2026-11-24T15:23:30Z", "started_at": "2026-11-24T15:23:32Z", "completed_at": null}
]}
JSON
	run bash "$CI_TIME" --jobs "$BATS_TEST_TMPDIR/jobs.json" --attempt 2 --run-started-at 2026-11-24T15:20:15Z
	[ "$status" -eq 0 ]
	[[ $output == *"the run's wall is 3m 00s"* ]] || false
	[[ $output == *"Queue before the first job: 15s"* ]] || false
	[[ $output != *"Kept from an earlier attempt"* ]] || false
}

@test "attempt 1 is unchanged: the same wall with or without the attempt" {
	run bash "$CI_TIME" --jobs "$JOBS" --limit 5
	without=$output
	run bash "$CI_TIME" --jobs "$JOBS" --attempt 1 --limit 5
	[ "$status" -eq 0 ]
	[ "$output" = "$without" ]
}

@test "a job of another attempt is left out of this attempt's own wall, and read as a kept job" {
	# attempt 1's job overlaps attempt 2's window: it is not this attempt's job, so it is
	# kept apart and measured with its own times. The attempt's own wall is unchanged; the
	# kept wall is that job's own span, and it is read.
	rerun_jobs
	jq '.jobs[0].completed_at = "2026-11-24T15:21:00Z"' "$BATS_TEST_TMPDIR/jobs.json" >"$BATS_TEST_TMPDIR/mixed.json"
	run bash "$CI_TIME" --jobs "$BATS_TEST_TMPDIR/mixed.json" --attempt 2 --run-started-at 2026-11-24T15:20:15Z --enforce
	[ "$status" -eq 1 ]
	[[ $output == *"This attempt's own jobs: 1m 00s (15:20:30 → 15:21:30)."* ]] || false
	[[ $output == *"Kept from an earlier attempt: 5h 20m 55s (10:00:05 → 15:21:00) — build (attempt 1)."* ]] || false
	[[ $output == *"::error::CI time (S-37): the run's wall is 5h 20m 55s, over the 5 min limit. It is the wall of the jobs kept from an earlier attempt"* ]] || false
	[[ $output != *"mixed attempts"* ]] || false
}

@test "a queue that would be negative is measured from the jobs' own creation, and the run goes on" {
	# a start later than the jobs (a hand-run with a wrong --run-started-at): the queue is
	# never negative and the run is not failed.
	rerun_jobs
	run bash "$CI_TIME" --jobs "$BATS_TEST_TMPDIR/jobs.json" --attempt 2 --run-started-at 2026-11-24T15:25:00Z --enforce
	[ "$status" -eq 0 ]
	# The kept job's own span (1m 55s) is the larger of the two walls.
	[[ $output == *"the run's wall is 1m 55s"* ]] || false
	[[ $output == *"Queue before the first job: 10s (excluded from the wall)."* ]] || false
	[[ $output != *"-270s"* ]] || false
	[[ $output != *"mixed attempts"* ]] || false
}

# The recorded payload of a --failed rerun (invented ids): GitHub lists the jobs an earlier
# attempt passed again under the new attempt's number, with the earlier attempt's start and end
# (only the creation is re-stamped to the new attempt). The attempt number cannot tell them
# apart; their times can.
RERUN="$BATS_TEST_DIRNAME/fixtures/ci-time-jobs-rerun.json"
# The same two-attempt payload, with the kept jobs spanning past the limit: the attempt ran
# nothing of its own, and the jobs it kept ran 02:43:32-02:56:30 (12m 58s).
LAUNDER="$BATS_TEST_DIRNAME/fixtures/ci-time-jobs-rerun-launder.json"

@test "a --failed rerun: the wall is the attempt's own jobs, the kept ones are named apart" {
	run bash "$CI_TIME" --jobs "$RERUN" --attempt 2 --run-started-at 2026-11-26T02:53:27Z
	[ "$status" -eq 0 ]
	# The attempt's own jobs ran 02:53:52 (Select tests) to 02:59:28 (Staging gate): 5m 36s.
	# The six jobs the earlier attempt passed kept their times: their own span is 1m 01s.
	[[ $output == *"the run's wall is 5m 36s"* ]] || false
	[[ $output == *"This attempt's own jobs: 5m 36s (02:53:52 → 02:59:28)."* ]] || false
	[[ $output == *"Kept from an earlier attempt: 1m 01s (02:43:32 → 02:44:33) — Terraform plan (prod, read-only) (an earlier attempt), Terraform test (stack module) (an earlier attempt), Twilio config (dry-run, stg and prod) (an earlier attempt), Infra change gate (an earlier attempt), Type check (mypy) (an earlier attempt), Static checks (an earlier attempt)."* ]] || false
	[[ $output == *"Queue before the first job: 25s (excluded from the wall)."* ]] || false
	[[ $output != *"| Static checks |"* ]] || false
	[[ $output != *"| Type check (mypy) |"* ]] || false
	[[ $output != *"| Terraform test (stack module) |"* ]] || false
	[[ $output != *"| Twilio config (dry-run, stg and prod) |"* ]] || false
	[[ $output != *"| Infra change gate |"* ]] || false
	[[ $output != *"| Terraform plan (prod, read-only) |"* ]] || false
}

@test "a --failed rerun is never a failure for the re-use: the run goes on and the gate reads the attempt's wall" {
	run bash "$CI_TIME" --jobs "$RERUN" --attempt 2 --run-started-at 2026-11-26T02:53:27Z --limit 10 --enforce
	[ "$status" -eq 0 ]
	[[ $output == *"the run's wall is 5m 36s — under the 10 min limit."* ]] || false
	[[ $output != *"::error::"* ]] || false
	[[ $output != *"mixed attempts"* ]] || false
}

@test "a --failed rerun over the limit fails the run on the attempt's own wall" {
	run bash "$CI_TIME" --jobs "$RERUN" --attempt 2 --run-started-at 2026-11-26T02:53:27Z --limit 5 --enforce
	[ "$status" -eq 1 ]
	[[ $output == *"::error::CI time (S-37): the run's wall is 5m 36s, over the 5 min limit."* ]] || false
	[[ $output != *"mixed attempts"* ]] || false
}

@test "without an attempt, every job counts, as before" {
	run bash "$CI_TIME" --jobs "$RERUN" --limit 5
	[ "$status" -eq 0 ]
	# The whole listing, the earliest job (02:43:32, an earlier attempt's) to the last end.
	[[ $output == *"the run's wall is 15m 56s"* ]] || false
	[[ $output == *"Queue before the first job: 0s (excluded from the wall)."* ]] || false
	[[ $output != *"Carried over"* ]] || false
}

@test "a rerun that ran nothing of its own reads the kept jobs' wall" {
	# The re-run kept every other job from the earlier attempt and ran nothing of its own:
	# the kept jobs' wall is the wall of the run (never 0), and it is under the limit.
	local f="$BATS_TEST_TMPDIR/rerun-only-self.json"
	jq '{total_count: 4, jobs: [.jobs[] | select(.name == "CI time (S-37)" or .id == 900004 or .id == 900007 or .id == 900008)]}' \
		"$RERUN" >"$f"
	run bash "$CI_TIME" --jobs "$f" --attempt 2 --run-started-at 2026-11-26T02:53:27Z --limit 5 --enforce
	[ "$status" -eq 0 ]
	[[ $output == *"the run's wall is 1m 01s"* ]] || false
	[[ $output == *"This attempt's own jobs: none ran to an end."* ]] || false
	[[ $output == *"Kept from an earlier attempt: 1m 01s (02:43:32 → 02:44:33)"* ]] || false
	[[ $output != *"::error::"* ]] || false
	[[ $output != *"no job ran in this run"* ]] || false
}

@test "a rerun whose kept jobs span past the limit fails the run on the kept wall" {
	# The re-use is not the failure: the kept jobs' own span is, and the error says so.
	run bash "$CI_TIME" --jobs "$LAUNDER" --attempt 2 --run-started-at 2026-11-26T02:59:00Z --limit 5 --enforce
	[ "$status" -eq 1 ]
	[[ $output == *"the run's wall is 12m 58s"* ]] || false
	[[ $output == *"This attempt's own jobs: none ran to an end."* ]] || false
	[[ $output == *"Kept from an earlier attempt: 12m 58s (02:43:32 → 02:56:30)"* ]] || false
	[[ $output == *"::error::CI time (S-37): the run's wall is 12m 58s, over the 5 min limit. It is the wall of the jobs kept from an earlier attempt; the way out is a full re-run (gh run rerun, not --failed)"* ]] || false
	[[ $output != *"mixed attempts"* ]] || false
}
