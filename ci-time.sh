#!/usr/bin/env bash
# ci-time.sh: what this run cost — the CI time job's report.
#
# The CI time job (design T-1723 §6 item 2, standing rule S-37) is the last job of a CI
# workflow. It needs every other job, runs whatever they did (`if: always()`), and prints
# this run's wall: the time from the first job's start to the last job's end, with the queue
# before the first job excluded (design §2) and reported apart.
#
# The run's jobs, from the API, with the workflow's own GITHUB_TOKEN, inside the workflow (it
# reads again while the API lags): no seat's quota, no second tool. The arithmetic is jq's.
#
# It also checks its own `needs:` (design CI-TIME-SHARED): a job that began or ended after this
# job started, or is still running or waiting for a runner, is not in this job's `needs:`
# (every job that is has completed), and the wall it shortened silently is reported with the
# job's name on a ⚠ line.
#
# With CI_TIME_NEEDS set, the wall counts only the jobs it names (matched as the wait matches
# them), and the late-job check looks only at them: every other job is listed apart, under
# "outside this job's needs (not in the wall)", with its times (design ci-time-limits A6.1). Without
# CI_TIME_NEEDS every job that ran is in the wall.
#
# It does not trust the first read: the jobs API can lag the jobs it reports on (a job in this
# job's `needs:` still showing in_progress, or missing, a moment after it finished) and it can
# count a job it has not listed yet (the count runs ahead of the listing: this job's own record
# is counted when it is created and is listed a moment later). It re-reads the API, with backoff,
# until the listing holds every job the run counts and the jobs in `needs:` report completed,
# bounded at CI_TIME_WAIT_SECONDS (default 60). Only then does it judge the wall, and fail closed
# if the wall is still unreadable. Jobs outside `needs:` (stg, post-live) are never waited on.
# With a --jobs file it reads once.
#
# It measures the attempt it reports (ruling A17). A rerun (`gh run rerun`, `--failed` or not) is a new
# attempt of the same run: the jobs counted are the ones that ran in that attempt, the wall is that
# attempt's first job start to its last job end, and the queue is that first start minus the attempt's own
# run_started_at (read from the attempt's API, or given by CI_TIME_RUN_STARTED_AT / --run-started-at).
#
# A `--failed` rerun keeps the jobs an earlier attempt passed, and GitHub lists them again with the new
# attempt's number (run_attempt) and the earlier attempt's times: only their created_at is re-stamped to
# the new attempt. So the attempt number does not tell them apart; their times do: a job that ran before
# this attempt began is a job an earlier attempt ran. Those jobs are kept apart and named.
#
# Two walls, and the larger one is the run's wall: this attempt's own wall (its own jobs, from the first
# one's start to the last one's end) and the kept wall (the jobs it kept, from the first one's start to
# the last one's end, with their own times). An attempt that ran nothing of its own has the kept wall as
# its wall, never 0. A re-use is never a failure for the re-use itself: the report names both walls.
#
# The kept wall can over-read: jobs kept from two earlier attempts span the gap between them, so the
# wall of a run that was fine can read over the limit. The way out is a full re-run (`gh run rerun`, not
# `--failed`), which measures every job as one attempt.
#
# REPORT-ONLY by default: it prints its table and its ⚠ line and exits 0, whatever it reads.
# With --enforce (CI_TIME_ENFORCE=true; design ci-time-limits A4) the same script is the gate:
# it exits 1 when the wall is over the limit, and fails closed (exit 1) when the run's jobs
# could not be read, no job ran, or the API returned fewer jobs than the run has.
#
# Needs bash 3.2+, jq and curl. Usage:
#
#   ci-time.sh [--jobs FILE] [--limit MINUTES] [--enforce]
#
# The environment (set by the workflow):
#   GITHUB_TOKEN            the workflow's token (actions: read)
#   GITHUB_REPOSITORY       owner/repo
#   GITHUB_RUN_ID           the run to read
#   CI_TIME_LIMIT_MINUTES   the limit: 5 for a CI run, 20 for a prod CD run
#   CI_TIME_ENFORCE         "true" fails the run (see above); "false" or unset is report-only
#   GITHUB_STEP_SUMMARY     where the run's page gets the same report
#   CI_TIME_NEEDS           the names of the jobs in this job's needs:, comma-separated (the wait, and the wall)
#   CI_TIME_WAIT_SECONDS    how long to wait for the other jobs to report completed (default 60)
#   GITHUB_RUN_ATTEMPT      the attempt to measure (unset: every job counts, as before attempts)
#   CI_TIME_RUN_STARTED_AT  the attempt's own start (default: read from the API; else the first job's creation)
#   RUNNER_NAME             this job's runner: how it finds itself among the run's jobs
set -euo pipefail

LIMIT="${CI_TIME_LIMIT_MINUTES:-5}"
JOBS_FILE=""
REPOSITORY="${GITHUB_REPOSITORY:-}"
RUN_ID="${GITHUB_RUN_ID:-}"
RUNNER="${RUNNER_NAME:-}"
ENFORCE="${CI_TIME_ENFORCE:-false}"
WAIT="${CI_TIME_WAIT_SECONDS:-60}"
NEEDS="${CI_TIME_NEEDS:-}"
ATTEMPT="${GITHUB_RUN_ATTEMPT:-}"
RUN_STARTED="${CI_TIME_RUN_STARTED_AT:-}"

while [ $# -gt 0 ]; do
	case "$1" in
	--jobs)
		JOBS_FILE="$2"
		shift 2
		;;
	--limit)
		LIMIT="$2"
		shift 2
		;;
	--attempt)
		ATTEMPT="$2"
		shift 2
		;;
	--run-started-at)
		RUN_STARTED="$2"
		shift 2
		;;
	--enforce)
		ENFORCE=true
		shift
		;;
	-h | --help)
		sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		printf 'ci-time: error: unknown option %s\n' "$1" >&2
		exit 2
		;;
	esac
done

case "$LIMIT" in
'' | *[!0-9.]*) printf 'ci-time: error: the limit must be a number of minutes\n' >&2; exit 2 ;;
esac

case "$ENFORCE" in
true | false) ;;
*) printf 'ci-time: error: enforce must be "true" or "false"\n' >&2; exit 2 ;;
esac

case "$WAIT" in
'' | *[!0-9]*) printf 'ci-time: error: CI_TIME_WAIT_SECONDS must be a whole number of seconds\n' >&2; exit 2 ;;
esac

case "$ATTEMPT" in
*[!0-9]*) printf 'ci-time: error: the attempt must be a whole number\n' >&2; exit 2 ;;
esac

SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-}"

# The jobs API's page: one page holds the listing of one read.
PER_PAGE=100

# say LINE: the report's line, to the log and to the run's page.
say() { printf '%s\n' "$1"; }

# The jobs JSON: the file the test gives, or the run's own jobs from the API.
jobs_json() {
	if [ -n "$JOBS_FILE" ]; then
		cat "$JOBS_FILE"
		return 0
	fi
	[ -n "${GITHUB_TOKEN:-}" ] || return 2
	[ -n "$REPOSITORY" ] || return 2
	[ -n "$RUN_ID" ] || return 2
	curl -fsS --max-time 20 \
		-H "Authorization: Bearer $GITHUB_TOKEN" \
		-H "Accept: application/vnd.github+json" \
		-H "X-GitHub-Api-Version: 2022-11-28" \
		-H "User-Agent: dxb-ci-time" \
		"${GITHUB_API_URL:-https://api.github.com}/repos/$REPOSITORY/actions/runs/$RUN_ID/jobs?per_page=$PER_PAGE"
}

# The attempt's own start: run_started_at of the run's attempt (the run's first start is attempt 1's).
run_started_at() {
	[ -n "${GITHUB_TOKEN:-}" ] && [ -n "$REPOSITORY" ] && [ -n "$RUN_ID" ] && [ -n "$ATTEMPT" ] || return 1
	curl -fsS --max-time 20 \
		-H "Authorization: Bearer $GITHUB_TOKEN" \
		-H "Accept: application/vnd.github+json" \
		-H "X-GitHub-Api-Version: 2022-11-28" \
		-H "User-Agent: dxb-ci-time" \
		"${GITHUB_API_URL:-https://api.github.com}/repos/$REPOSITORY/actions/runs/$RUN_ID/attempts/$ATTEMPT" |
		jq -r '.run_started_at // empty'
}

# The report: the table, the wall and the verdict. jq reads the jobs JSON and prints the
# whole report; the arithmetic is here, not in the shell.
#
#   A job counts towards the wall only when it RAN to an end: a start and a completion, and
#   not a skip (GitHub stamps a skipped job with a start and a completion at the same
#   instant, so a skip would otherwise count as a zero-length job). A job that is still
#   queued, and this job itself (still running, so it has no completion yet), are reported
#   and left out.
report() {
	jq -r \
		--arg limit "$LIMIT" \
		--arg repo "$REPOSITORY" \
		--arg run "$RUN_ID" \
		--arg runner "$RUNNER" \
		--arg enforce "$ENFORCE" \
		--arg needs "$NEEDS" \
		--arg run_started "$RUN_STARTED" \
		--arg carried "${CARRIED_COUNT:-0}" \
		--arg carried_names "${CARRIED:-}" \
		--argjson kept "${KEPT:-[]}" \
		'
		def ts:
			if type == "string" and length > 0
			then (sub("\\.[0-9]+"; "") | (fromdateiso8601? // null))
			else null end;
		def dur:
			if . == null then "—"
			else (.|round) as $s
				| (($s%60)|tostring) as $sec
				| (($s%3600/60|floor)|tostring) as $min
				| (($s/3600|floor)|tostring) as $hour
				| ("0" + $sec)[-2:] as $sec2
				| ("0" + $min)[-2:] as $min2
				| (if $s >= 3600 then "\($hour)h \($min2)m \($sec2)s"
					elif $s >= 60 then "\($min)m \($sec2)s"
					else "\($s)s" end)
			end;
		def in_needs($names):
			. as $jn | any($names[]; . as $n | $jn == $n or ($jn | startswith($n + " (")) or ($jn | startswith($n + " / ")));
		def clock($iso):
			if ($iso|type) == "string" and ($iso|length) >= 19 then $iso[11:19] else "—" end;
		def row_text:
			"| \(.name) | \(.status)\(if .conclusion != "" then " (\(.conclusion))" else "" end) | \(clock(.start_iso)) | \(clock(.end_iso)) | \(.queue|dur) | \(.duration|dur) |";
		(.jobs // []) as $all
		| ($needs | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $names
		| ($all | map({
			id: ((.id // "") | tostring),
			name: (.name // "(unnamed)"),
			status: (.status // "unknown"),
			conclusion: (.conclusion // ""),
			start_iso: (if (.started_at|type) == "string" then .started_at else "" end),
			end_iso: (if (.completed_at|type) == "string" then .completed_at else "" end),
			runner: (.runner_name // ""),
			created: (.created_at | ts),
			start: (.started_at | ts),
			end: (.completed_at | ts)
		})) as $jobs
		| ($jobs | map(. + {
			ran: (.start != null and .end != null and .conclusion != "skipped"),
			# The own wait of the job. GitHub re-stamps a carried-over job creation to the
			# attempt that kept it, so its start can precede it: the wait is 0, never negative.
			queue: (if .start != null and .created != null then (if .start > .created then (.start - .created) else 0 end) else null end),
			duration: (if .start != null and .end != null then (if .end >= .start then (.end - .start) else 0 end) else null end)
		}) | sort_by([(.start // 99999999999), .name])) as $rows_all
		| ([$jobs[] | select(.status == "in_progress")]) as $running
		| (if ($running | length) == 1 then $running[0]
			else ([$running[] | select($runner != "" and .runner == $runner)]) as $mine
				| (if ($mine | length) == 1 then $mine[0] else null end)
			end) as $self
		| ($rows_all | map(select(($names | length) > 0 and (.name | in_needs($names) | not)
			and ($self == null or .name != $self.name)))) as $outside
		| ($rows_all - $outside) as $rows
		| ([$rows[] | select(.ran) | .start] | min) as $first
		| ([$rows[] | select(.ran) | .end] | max) as $last
		# The own wall of this attempt: its own jobs, from the first start to the last end.
		| (if $first == null then null
		   elif $last < $first then 0 else $last - $first end) as $own_wall
		| (if $first == null then null
		   else ($rows | map(select(.ran)) | sort_by(.start) | .[0] | clock(.start_iso)) end) as $own_first_clock
		| (if $last == null then null
		   else ($rows | map(select(.ran)) | sort_by(.end) | .[-1] | clock(.end_iso)) end) as $own_last_clock
		# The kept jobs: the jobs an earlier attempt ran and this attempt kept. They keep the
		# times of that earlier attempt, so the kept wall is their own span, among themselves.
		| ($kept | map({
			name: (.name // "(unnamed)"),
			conclusion: (.conclusion // ""),
			start_iso: (if (.started_at|type) == "string" then .started_at else "" end),
			end_iso: (if (.completed_at|type) == "string" then .completed_at else "" end),
			start: (.started_at | ts),
			end: (.completed_at | ts)
		})) as $kept_jobs
		| ($kept_jobs | map(select(($names | length) == 0 or (.name | in_needs($names)))
			| select(.start != null and .end != null and .conclusion != "skipped"))) as $kept_ran
		| ([$kept_ran[].start] | min) as $kept_first
		| ([$kept_ran[].end] | max) as $kept_last
		| (if $kept_first == null then null
		   elif $kept_last < $kept_first then 0 else $kept_last - $kept_first end) as $kept_wall
		| (if $kept_first == null then null
		   else ($kept_ran | sort_by(.start) | .[0] | clock(.start_iso)) end) as $kept_first_clock
		| (if $kept_last == null then null
		   else ($kept_ran | sort_by(.end) | .[-1] | clock(.end_iso)) end) as $kept_last_clock
		# A job of this attempt that has not finished yet means the wall is not final: it is
		# not known, and the reporter itself never counts (it reads the jobs while it runs).
		| ([$rows[] | select(.status != "completed"
			and ($self == null or ((.id + "/" + .name) != ($self.id + "/" + $self.name))))] | length) as $unfinished
		# The wall of the run: the larger of the own wall of this attempt and the kept wall.
		# An attempt that ran nothing of its own has the kept wall as its wall, never 0.
		| (if $own_wall == null and $unfinished > 0 and (($carried|tonumber) > 0)
			then null
			elif $own_wall == null and $kept_wall == null and (($carried|tonumber) > 0)
			then 0
			elif $own_wall == null then $kept_wall
			elif $kept_wall == null then $own_wall
			elif $kept_wall > $own_wall then $kept_wall
			else $own_wall end) as $wall
		| (if $own_wall == null then "kept"
			elif $kept_wall == null then "own"
			elif $kept_wall > $own_wall then "kept"
			else "own" end) as $wall_which
		| ([$rows[] | select(.created != null) | .created]|min) as $earliest
		| ($run_started | ts) as $attempt_start
		| (if $first == null then null
			elif $attempt_start != null and $attempt_start <= $first then $first - $attempt_start
			elif $earliest != null and $earliest <= $first then $first - $earliest
			else 0 end) as $queue_before
		| (if $self == null or $self.start == null then null else $self.start end) as $self_start
		| (if $self_start == null then []
			else [$rows[]
				| select(.name != $self.name and .conclusion != "skipped"
					and (.status != "completed" or .end == null or .end > $self_start))
				| .name] end) as $late
		| ($limit|tonumber) as $limit_min
		| ($limit_min * 60) as $limit_s
		| (if $wall != null and $wall > $limit_s then true else false end) as $over
		| (if (($carried|tonumber) > 0)
			then (if $wall_which == "kept" then " (the wall of the jobs kept from an earlier attempt)"
				else " (the wall of this attempt\u0027s own jobs)" end)
			else "" end) as $which_note
		| (if $wall == null
			then (if (($carried|tonumber) > 0)
				then "CI time (S-37): the wall of this attempt is not known: a job of it has not finished."
				else "CI time (S-37): no job ran in this run — there is no wall to report."
				end)
			elif $over
			then "⚠ CI time (S-37): the run\u0027s wall is \(($wall)|dur) — OVER the \($limit_min) min limit.\(if $enforce == "true" then " This run is failed." else " REPORT-ONLY: this run is not failed." end)\($which_note)"
			else "CI time (S-37): the run\u0027s wall is \(($wall)|dur) — under the \($limit_min) min limit.\($which_note)" end) as $verdict
		| (if $queue_before == null
			then ""
			elif $queue_before > 60
			then "⚠ the queue before the first job is \(($queue_before)|dur) (over 1 min — runner supply, not code; it is excluded from the wall)."
			else "Queue before the first job: \(($queue_before)|dur) (excluded from the wall)." end) as $queue_line
		| (if ($running | length) == 0 then ""
			elif $self == null
			then "⚠ not checked: which job is this one could not be told, so the jobs missing from its needs: were not looked for."
			elif ($late | length) > 0
			then "⚠ \($late | join(", ")) began, is still waiting, or ended after this job started, so \(if ($late|length) == 1 then "it is" else "they are" end) not in this job\u0027s needs: — add \(if ($late|length) == 1 then "it" else "them" end), or the wall is shortened silently."
			else "needs: every job that ran is in this job\u0027s needs:." end) as $needs_line
		| ([
			"### CI time (S-37) — \($repo) run \($run)",
			"",
			"| job | status | start (UTC) | end (UTC) | queue | duration |",
			"| --- | --- | --- | --- | --- | --- |"
		] + ($rows | map(row_text))
		+ (if ($outside | length) == 0 then []
			else ["", "outside this job\u0027s needs (not in the wall):", "",
				"| job | status | start (UTC) | end (UTC) | queue | duration |",
				"| --- | --- | --- | --- | --- | --- |"] + ($outside | map(row_text)) end)
		+ ["", $verdict]
		+ (if (($carried|tonumber) > 0) then [
			"This attempt\u0027s own jobs: \(if $own_wall == null then "none ran to an end" else (($own_wall)|dur) + " (" + $own_first_clock + " → " + $own_last_clock + ")" end).",
			"Kept from an earlier attempt: \(if $kept_wall == null then "none ran to an end" else (($kept_wall)|dur) + " (" + $kept_first_clock + " → " + $kept_last_clock + ")" end)\(if $carried_names != "" then " — " + $carried_names else "" end)."
		] else [] end)
		+ [$queue_line]
		+ (if $needs_line == "" then [] else [$needs_line] end)) | join("\n")
		'
}

# The report goes to the log and to the run's page (the same text).
write_summary() {
	[ -n "$SUMMARY_FILE" ] || return 0
	{
		printf '%s\n\n' "$1"
		printf 'The wall is from the first job\u0027s start to the last job\u0027s end; the queue before the\n'
		printf 'first job is excluded. A re-run reads the larger of that attempt\u0027s own wall and the\n'
		printf 'wall of the jobs it kept from an earlier attempt.\n'
		if [ "$ENFORCE" = true ]; then
			printf 'The limit is %s min, enforced: a wall over it fails this run.\n' "$LIMIT"
		else
			printf 'The limit is %s min. REPORT-ONLY — this run is not failed.\n' "$LIMIT"
		fi
	} >>"$SUMMARY_FILE"
}

# unreadable WHY: the wall could not be known. Report-only says so and exits 0; enforced, the
# run fails closed (no wall is not a pass).
unreadable() {
	if [ "$ENFORCE" = true ]; then
		say "::error::CI time (S-37): $1 The wall is unknown, so the run is failed (enforce is on)."
		write_summary "❌ CI time (S-37): $1 The wall is unknown, so the run is failed."
		exit 1
	fi
	say "⚠ CI time (S-37): $1 The wall is not reported; the run is not failed."
	write_summary "⚠ CI time (S-37): $1 The wall is not reported; the run is not failed."
	exit 0
}

# settled: the jobs JSON on stdin shows every job named in NEEDS completed. A name matches the
# job of that name, a matrix job "name (...)" and a reusable-workflow job "name / job"; a name with no job yet is not settled. Jobs
# outside NEEDS (a stg or post-live job that runs past this one) are never waited on.
settled() {
	jq -e --arg needs "$NEEDS" '
		(.jobs // []) as $all
		| ($needs | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $names
		| all($names[]; . as $n
			| ([$all[] | select((.name // "") as $jn | $jn == $n or ($jn | startswith($n + " (")) or ($jn | startswith($n + " / ")))]) as $m
			| ($m | length) > 0 and all($m[]; .status == "completed"))
	' >/dev/null 2>&1
}

# listed: the API listed every job the run counts. The count runs ahead of the listing for a
# moment: a job is counted when it is created and is listed a moment later (the reporter's own
# job is the last one). The wall is only known when the listing holds every job.
listed() {
	printf '%s' "$JOBS" | jq -e '((.total_count // 0) <= ((.jobs // []) | length))' >/dev/null 2>&1
}

# one_page: the run's jobs fit on one page of the API. More jobs than that is a truncated
# listing, not a lag: no re-read can complete it, so the wait ends at once.
one_page() {
	printf '%s' "$JOBS" | jq -e --argjson page "$PER_PAGE" '((.total_count // 0) <= $page)' >/dev/null 2>&1
}

# wait_reason: why the read is not the run's own yet, in words.
wait_reason() {
	if printf '%s' "$JOBS" | settled; then
		printf 'the jobs API counted a job it has not listed yet'
	else
		printf 'the other jobs have not all reported completed'
	fi
}

# final_read: the read is the run's own: every job in needs reports completed, and the listing
# holds every job the run counts (or the run has more jobs than one page of the API: no re-read
# can complete that listing, and the count check judges it).
final_read() {
	if ! printf '%s' "$JOBS" | settled; then
		return 1
	fi
	if printf '%s' "$JOBS" | listed; then
		return 0
	fi
	if printf '%s' "$JOBS" | one_page; then
		return 1
	fi
	return 0
}

JOBS=""
JOBS_RC=0
JOBS=$(jobs_json) || JOBS_RC=$?
if [ -z "$JOBS_FILE" ]; then
	# The API can lag twice over: a job it reports on may still show in_progress (or be
	# missing) a moment after it finished, and it can count a job it has not listed yet (the
	# reporter's own job is created last, so the count runs ahead of the listing). Read
	# again, backing off, until the listing holds every job the run counts and the other
	# jobs report completed.
	delay=1
	while ! final_read; do
		# 2 = no token, repository or run: nothing a re-read would change
		[ "$JOBS_RC" -ne 2 ] || break
		[ "$SECONDS" -lt "$WAIT" ] || break
		left=$((WAIT - SECONDS))
		[ "$delay" -le "$left" ] || delay=$left
		say "CI time (S-37): $(wait_reason); reading again in ${delay}s."
		sleep "$delay"
		delay=$((delay * 2))
		[ "$delay" -le 10 ] || delay=10
		JOBS_RC=0
		JOBS=$(jobs_json) || JOBS_RC=$?
	done
	if [ "$JOBS_RC" -eq 0 ] && ! printf '%s' "$JOBS" | settled; then
		say "⚠ CI time (S-37): after ${WAIT}s the jobs API still shows a job in needs ($NEEDS) unfinished or missing."
	fi
	if [ "$JOBS_RC" -eq 0 ] && ! printf '%s' "$JOBS" | listed; then
		if printf '%s' "$JOBS" | one_page; then
			say "⚠ CI time (S-37): after ${WAIT}s the jobs API still counts a job it has not listed."
		fi
	fi
fi
if [ "$JOBS_RC" -ne 0 ]; then
	unreadable "the run's jobs were not read (GITHUB_TOKEN, GITHUB_REPOSITORY or GITHUB_RUN_ID is not set, or the API refused)."
fi

# The attempt measured: the jobs that ran in it go to the report; the jobs an earlier attempt ran and
# this one kept are named apart (they were measured with their own attempt).
CARRIED=""
CARRIED_COUNT=0
KEPT="[]"
if [ -n "$ATTEMPT" ]; then
	if [ -z "$RUN_STARTED" ] && [ -z "$JOBS_FILE" ]; then
		RUN_STARTED=$(run_started_at 2>/dev/null) || RUN_STARTED=""
	fi
	# The split, in one pass: the jobs this attempt ran, and the jobs an earlier attempt ran and
	# this one kept.
	#
	# A --failed rerun keeps the jobs an earlier attempt passed, and GitHub lists them again:
	# under this attempt's number, with the earlier attempt's start and end (only the creation is
	# re-stamped to this attempt). So the attempt number alone cannot tell the two apart; the
	# job's own times can, and so can the attempt's own start.
	#
	# A job is this attempt's when the API labels it with this attempt's number AND:
	#   - it began after it was created: a job that began before it was created kept the
	#     earlier attempt's start (only the creation was re-stamped), and
	#   - it ended after it began: a job that ended before it began kept the earlier
	#     attempt's end (GitHub stamps a skipped job an end a second before its start), and
	#   - when the attempt's own start is known, it began and ended at or after it: a job
	#     that ran before the attempt began is an earlier attempt's job.
	# The attempt's own start counts only when a job of this attempt began after it, so a
	# hand-run with a wrong --run-started-at cannot drop every job.
	if ! SPLIT=$(printf '%s' "$JOBS" | jq -c --argjson a "$ATTEMPT" --arg base "$RUN_STARTED" '
		def ts: if type == "string" and length > 0 then (sub("\\.[0-9]+"; "") | (fromdateiso8601? // null)) else null end;
		# own_times: the job ran where it was created: it began after it was created and ended
		# after it began (a skipped job is stamped an end a second or two before its start).
		def own_times($c; $s; $e):
			if $s == null or $c == null then true
			elif $s < $c - 1 then false
			elif $e != null and $e < $s - 5 then false
			else true end;
		# before: the job ran before the attempt began: an earlier attempt ran it.
		def before($x; $b):
			if $b == null or $x == null then false
			elif $x < $b - 1 then true
			else false end;
		(.total_count // 0) as $total
		| ($base | ts) as $b
		| (.jobs // []) as $all
		| [ $all[] | . as $j
			| (($j.run_attempt // 1) == $a) as $mine
			| ($j.created_at | ts) as $c
			| ($j.started_at | ts) as $s
			| ($j.completed_at | ts) as $e
			| {j: $j, mine: $mine, s: $s, e: $e, times: own_times($c; $s; $e)} ] as $rows
		# The attempt start is worth something when a job of this attempt began after it.
		| ($b != null and ([$rows[] | select(.mine and .s != null and .s >= $b - 1)] | length) > 0) as $base_ok
		| ($rows | map(.own = (.mine and .times
			and (($base_ok | not)
				or ((before(.s; $b) | not) and (before(.e; $b) | not)))))) as $rows2
		| {total_count: $total,
		   jobs: [$rows2[] | select(.own) | .j],
		   carried: [$rows2[] | select(.own | not) | .j]}
	'); then
		unreadable "the run's jobs could not be read."
	fi
	JOBS_ALL="$JOBS"
	JOBS=$(printf '%s' "$SPLIT" | jq -c '{total_count: .total_count, jobs: .jobs}')
	CARRIED_COUNT=$(printf '%s' "$SPLIT" | jq -r '(.carried // []) | length')
	KEPT=$(printf '%s' "$SPLIT" | jq -c '(.carried // [])')
	CARRIED=$(printf '%s' "$SPLIT" | jq -r --argjson a "$ATTEMPT" '
		[.carried[]
			| "\(.name // "(unnamed)")\((if (.run_attempt // 1) != $a then " (attempt \(.run_attempt // 1))" else " (an earlier attempt)" end))"]
		| join(", ")')
fi

if ! REPORT=$(printf '%s' "$JOBS" | report); then
	unreadable "the run's jobs could not be read."
fi

say "$REPORT"
write_summary "$REPORT"

# The run has more jobs than the API returned (per_page): the wall covers what was read.
TOTAL=$(printf '%s' "${JOBS_ALL:-$JOBS}" | jq -r 'if (.total_count|type) == "number" then .total_count else 0 end' 2>/dev/null || echo 0)
READ=$(printf '%s' "${JOBS_ALL:-$JOBS}" | jq -r '(.jobs // []) | length' 2>/dev/null || echo 0)
TRUNCATED=false
if [ "${TOTAL:-0}" -gt "${READ:-0}" ] 2>/dev/null; then
	TRUNCATED=true
	say "⚠ the run has $TOTAL jobs and the API returned $READ; the wall covers the $READ read."
fi

if [ "$ENFORCE" = true ]; then
	if [ "$TRUNCATED" = true ]; then
		say "::error::CI time (S-37): the run has $TOTAL jobs and only $READ were read, so the wall is not known. The run is failed (enforce is on)."
		exit 1
	fi
	case "$REPORT" in
	*"the wall of this attempt is not known"*)
		# A job of this attempt has not finished: its wall is not known yet.
		say "::error::CI time (S-37): a job of this attempt has not finished, so its wall is not known. The run is failed (enforce is on)."
		exit 1
		;;
	*"no job ran in this run"*)
		# Only a skipped job is proof that another job came back: the time job itself is in progress.
		SKIPPED=$(printf '%s' "$JOBS" | jq -r '[(.jobs // [])[] | select(.status == "completed" and .conclusion == "skipped")] | length' 2>/dev/null || echo 0)
		if [ "${SKIPPED:-0}" -eq 0 ] 2>/dev/null; then
			say "::error::CI time (S-37): no job other than this one came back from the API, so the wall is not known. The run is failed (enforce is on)."
			exit 1
		fi
		# Another job came back and none ran to an end (every other job was skipped): a known wall of 0.
		say "CI time (S-37): every other job was skipped: wall 0, under the $LIMIT min limit."
		;;
	*"— OVER the "*)
		WALL=$(printf '%s\n' "$REPORT" | sed -n "s/.*the run's wall is \(.*\) — OVER the \(.*\) min limit\..*/\1/p" | head -n 1)
		# The error names the wall that failed: this attempt's own jobs, or the jobs it kept.
		case "$REPORT" in
		*"the wall of the jobs kept from an earlier attempt"*)
			say "::error::CI time (S-37): the run's wall is ${WALL:-over the limit}, over the $LIMIT min limit. It is the wall of the jobs kept from an earlier attempt; the way out is a full re-run (gh run rerun, not --failed), which measures every job as one attempt."
			;;
		*"the wall of this attempt's own jobs"*)
			say "::error::CI time (S-37): the run's wall is ${WALL:-over the limit}, over the $LIMIT min limit. It is the wall of this attempt's own jobs."
			;;
		*)
			say "::error::CI time (S-37): the run's wall is ${WALL:-over the limit}, over the $LIMIT min limit."
			;;
		esac
		exit 1
		;;
	esac
fi

exit 0
