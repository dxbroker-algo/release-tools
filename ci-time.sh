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
# It also checks its own `needs:` (design CI-TIME-SHARED): a job that began or ended after this
# job started, or is still running or waiting for a runner, is not in this job's `needs:`
# (every job that is has completed), and the wall it shortened silently is reported with the
# job's name on a ⚠ line.
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
#   RUNNER_NAME             this job's runner: how it finds itself among the run's jobs
set -euo pipefail

LIMIT="${CI_TIME_LIMIT_MINUTES:-5}"
JOBS_FILE=""
REPOSITORY="${GITHUB_REPOSITORY:-}"
RUN_ID="${GITHUB_RUN_ID:-}"
RUNNER="${RUNNER_NAME:-}"
ENFORCE="${CI_TIME_ENFORCE:-false}"

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
	--enforce)
		ENFORCE=true
		shift
		;;
	-h | --help)
		sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
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
		--arg runner "$RUNNER" \
		--arg enforce "$ENFORCE" \
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
			runner: (.runner_name // ""),
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
		| ([$jobs[] | select(.status == "in_progress")]) as $running
		| (if ($running | length) == 1 then $running[0]
			else ([$running[] | select($runner != "" and .runner == $runner)]) as $mine
				| (if ($mine | length) == 1 then $mine[0] else null end)
			end) as $self
		| (if $self == null or $self.start == null then null else $self.start end) as $self_start
		| (if $self_start == null then []
			else [$rows[]
				| select(.name != $self.name and .conclusion != "skipped"
					and (.status != "completed" or .end == null or .end > $self_start))
				| .name] end) as $late
		| ($limit|tonumber) as $limit_min
		| ($limit_min * 60) as $limit_s
		| (if $wall != null and $wall > $limit_s then true else false end) as $over
		| (if $wall == null
			then "CI time (S-37): no job ran in this run — there is no wall to report."
			elif $over
			then "⚠ CI time (S-37): the run\u0027s wall is \(($wall)|dur) — OVER the \($limit_min) min limit.\(if $enforce == "true" then " This run is failed." else " REPORT-ONLY: this run is not failed." end)"
			else "CI time (S-37): the run\u0027s wall is \(($wall)|dur) — under the \($limit_min) min limit." end) as $verdict
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
		] + ($rows | map(row_text)) + ["", $verdict, $queue_line] + (if $needs_line == "" then [] else [$needs_line] end)) | join("\n")
		'
}

# The report goes to the log and to the run's page (the same text).
write_summary() {
	[ -n "$SUMMARY_FILE" ] || return 0
	{
		printf '%s\n\n' "$1"
		printf 'The wall is from the first job\u0027s start to the last job\u0027s end; the queue before the\n'
		if [ "$ENFORCE" = true ]; then
			printf 'first job is excluded. The limit is %s min, enforced: a wall over it fails this run.\n' "$LIMIT"
		else
			printf 'first job is excluded. The limit is %s min. REPORT-ONLY — this run is not failed.\n' "$LIMIT"
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

if ! JOBS=$(jobs_json); then
	unreadable "the run's jobs were not read (GITHUB_TOKEN, GITHUB_REPOSITORY or GITHUB_RUN_ID is not set, or the API refused)."
fi

if ! REPORT=$(printf '%s' "$JOBS" | report); then
	unreadable "the run's jobs could not be read."
fi

say "$REPORT"
write_summary "$REPORT"

# The run has more jobs than the API returned (per_page): the wall covers what was read.
TOTAL=$(printf '%s' "$JOBS" | jq -r 'if (.total_count|type) == "number" then .total_count else 0 end' 2>/dev/null || echo 0)
READ=$(printf '%s' "$JOBS" | jq -r '(.jobs // []) | length' 2>/dev/null || echo 0)
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
		say "::error::CI time (S-37): the run's wall is ${WALL:-over the limit}, over the $LIMIT min limit."
		exit 1
		;;
	esac
fi

exit 0
