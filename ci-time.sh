#!/usr/bin/env bash
# ci-time.sh: what this run cost — the CI time job's report.
#
# The CI time job (design T-1723 §6 item 2, standing rule S-37) is the last job of a CI
# workflow. It needs every other job, runs whatever they did (`if: always()`), and prints
# this run's wall: the time from the first job's start to the last job's end, with the queue
# before the first job excluded (design §2) and reported apart.
#
# One API call — the run's jobs — with the workflow's own GITHUB_TOKEN, inside the workflow:
# no seat's quota, no second tool. The arithmetic is jq's; this file only reads and prints.
#
# REPORT-ONLY: it prints its table and its ⚠ line and exits 0, whatever it reads. Card H (at
# T-1576's close) turns the verdict into a gate.
#
# Needs bash 3.2+, jq and curl. Usage:
#
#   ci-time.sh [--jobs FILE] [--limit MINUTES]
#
# The environment (set by the workflow):
#   GITHUB_TOKEN            the workflow's token (actions: read)
#   GITHUB_REPOSITORY       owner/repo
#   GITHUB_RUN_ID           the run to read
#   CI_TIME_LIMIT_MINUTES   the limit: 5 for a CI run, 20 for a prod CD run
#   GITHUB_STEP_SUMMARY     where the run's page gets the same report
set -euo pipefail

LIMIT="${CI_TIME_LIMIT_MINUTES:-5}"
JOBS_FILE=""
REPOSITORY="${GITHUB_REPOSITORY:-}"
RUN_ID="${GITHUB_RUN_ID:-}"

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
	-h | --help)
		sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
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

SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-}"

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
		"${GITHUB_API_URL:-https://api.github.com}/repos/$REPOSITORY/actions/runs/$RUN_ID/jobs?per_page=100"
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
		def clock($iso):
			if ($iso|type) == "string" and ($iso|length) >= 19 then $iso[11:19] else "—" end;
		def row_text:
			"| \(.name) | \(.status)\(if .conclusion != "" then " (\(.conclusion))" else "" end) | \(clock(.start_iso)) | \(clock(.end_iso)) | \(.queue|dur) | \(.duration|dur) |";
		(.jobs // []) as $all
		| ($all | map({
			name: (.name // "(unnamed)"),
			status: (.status // "unknown"),
			conclusion: (.conclusion // ""),
			start_iso: (if (.started_at|type) == "string" then .started_at else "" end),
			end_iso: (if (.completed_at|type) == "string" then .completed_at else "" end),
			created: (.created_at | ts),
			start: (.started_at | ts),
			end: (.completed_at | ts)
		})) as $jobs
		| ($jobs | map(. + {
			ran: (.start != null and .end != null and .conclusion != "skipped"),
			queue: (if .start != null and .created != null then (.start - .created) else null end),
			duration: (if .start != null and .end != null then (.end - .start) else null end)
		}) | sort_by([(.start // 99999999999), .name])) as $rows
		| ([$rows[] | select(.ran) | .start] | min) as $first
		| ([$rows[] | select(.ran) | .end] | max) as $last
		| (if $first == null then null else $last - $first end) as $wall
		| ([$rows[] | select(.created != null) | .created]|min) as $earliest
		| (if $first == null or $earliest == null then null else $first - $earliest end) as $queue_before
		| ($limit|tonumber) as $limit_min
		| ($limit_min * 60) as $limit_s
		| (if $wall != null and $wall > $limit_s then true else false end) as $over
		| (if $wall == null
			then "CI time (S-37): no job ran in this run — there is no wall to report."
			elif $over
			then "⚠ CI time (S-37): the run\u0027s wall is \(($wall)|dur) — OVER the \($limit_min) min limit. REPORT-ONLY: this run is not failed."
			else "CI time (S-37): the run\u0027s wall is \(($wall)|dur) — under the \($limit_min) min limit." end) as $verdict
		| (if $queue_before == null
			then ""
			elif $queue_before > 60
			then "⚠ the queue before the first job is \(($queue_before)|dur) (over 1 min — runner supply, not code; it is excluded from the wall)."
			else "Queue before the first job: \(($queue_before)|dur) (excluded from the wall)." end) as $queue_line
		| ([
			"### CI time (S-37) — \($repo) run \($run)",
			"",
			"| job | status | start (UTC) | end (UTC) | queue | duration |",
			"| --- | --- | --- | --- | --- | --- |"
		] + ($rows | map(row_text)) + ["", $verdict, $queue_line]) | join("\n")
		'
}

# The report goes to the log and to the run's page (the same text).
write_summary() {
	[ -n "$SUMMARY_FILE" ] || return 0
	{
		printf '%s\n\n' "$1"
		printf 'The wall is from the first job\u0027s start to the last job\u0027s end; the queue before the\n'
		printf 'first job is excluded. The limit is %s min. REPORT-ONLY — this run is not failed.\n' "$LIMIT"
	} >>"$SUMMARY_FILE"
}

if ! JOBS=$(jobs_json); then
	say "⚠ CI time (S-37): the run's jobs were not read (GITHUB_TOKEN, GITHUB_REPOSITORY or GITHUB_RUN_ID is not set, or the API refused). The wall is not reported; the run is not failed."
	write_summary "⚠ CI time (S-37): the run's jobs were not read. The wall is not reported; the run is not failed."
	exit 0
fi

if ! REPORT=$(printf '%s' "$JOBS" | report); then
	say "⚠ CI time (S-37): the run's jobs could not be read. The wall is not reported; the run is not failed."
	write_summary "⚠ CI time (S-37): the run's jobs could not be read. The wall is not reported; the run is not failed."
	exit 0
fi

say "$REPORT"
write_summary "$REPORT"

# The run has more jobs than the API returned (per_page): the wall covers what was read.
TOTAL=$(printf '%s' "$JOBS" | jq -r 'if (.total_count|type) == "number" then .total_count else 0 end' 2>/dev/null || echo 0)
READ=$(printf '%s' "$JOBS" | jq -r '(.jobs // []) | length' 2>/dev/null || echo 0)
if [ "${TOTAL:-0}" -gt "${READ:-0}" ] 2>/dev/null; then
	say "⚠ the run has $TOTAL jobs and the API returned $READ; the wall covers the $READ read."
fi

exit 0
