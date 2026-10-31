#!/usr/bin/env bash
# release.sh: cut a release from the squash-merge titles.
#
#   cut             the version, an annotated tag on the shipped sha, a GitHub
#                   Release, one Slack post, then CHANGELOG.md and the version
#                   file committed to the default branch
#   render A B      print the CHANGELOG entry the range A..B gives today
#   render-history  print (or --write) the retro section: every first-parent
#                   commit, by month
#   post vX.Y.Z     post (again) the Slack message for an existing Release and
#                   record it in the Release (the one edit a Release gets)
#   backfill-ext    tag a browser extension's history at its manifest bump commits
#   check-title T   exit 0 when T is a valid PR title (it becomes the squash title)
#
# Needs bash 3.2+, git, gh, jq and curl. Nothing about the calling repository is
# stored here: everything is read from it at run time. See README.md.
set -euo pipefail

KNOWN_TYPES=" feat fix chore docs refactor test ci perf infra build style revert "
MARK_HISTORY='<!-- release-tools history-through:'

log() { printf 'release: %s\n' "$*" >&2; }
warn() { printf 'release: warning: %s\n' "$*" >&2; }
die() {
	printf 'release: error: %s\n' "$*" >&2
	exit 1
}

usage() {
	sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
	cat <<'EOF'

Options (any subcommand):
  --kind deploy|store|apply   what "released" means: on prod / live on the Chrome
                              Web Store / applied (default: deploy)
  --sha SHA                   the shipped commit (default: HEAD; store: the bump
                              commit of --version)
  --version X.Y.Z             an explicit version (1.0.0 by hand; store: the
                              manifest's)
  --version-file PATH         bumped by the release commit: pyproject.toml,
                              package.json, package-lock.json, or a plain file
                              such as VERSION; repeatable; "none" for none
  --name NAME                 the name in the Slack post (default: the repo name)
  --repo OWNER/NAME           default: $GITHUB_REPOSITORY, else the remote URL
  --branch BRANCH             where the release commit goes (default: the
                              remote's default branch)
  --remote NAME               default: origin
  --changelog PATH            default: CHANGELOG.md
  --run-url URL               default: this Actions run
  --run-label TEXT            default: "CD run #N" (deploy) / "run #N"
  --dry-run                   render the entry and the Slack text; write nothing
  --no-gh                     do not read PR labels or bodies (offline render)
  --through REF               render-history: the last commit of the retro
                              section (default: the remote's default branch)
  --heading TEXT              render-history: default "Before v0.1.0"
  --write                     render-history: write it into the changelog file
  --bump-file PATH            backfill-ext / store: default manifest.config.ts
  --retro-note TEXT           backfill-ext: the line each retro Release carries
  --force                     post: post although the Release records a post

Environment: SLACK_RELEASES_BOT_TOKEN, SLACK_RELEASES_CHANNEL, SLACK_API_URL,
GH_TOKEN, RELEASE_NOW (an ISO time, for tests), RELEASE_GIT_NAME/EMAIL.
EOF
}

# ---------------------------------------------------------------- options --

KIND=deploy
SHA=""
VERSION=""
VERSION_FILES=""
NAME=""
REPO=""
BRANCH=""
REMOTE=origin
CHANGELOG=CHANGELOG.md
DRY_RUN=0
NO_GH=0
RUN_URL=""
RUN_LABEL=""
THROUGH=""
HEADING=""
WRITE=0
BUMP_FILE=manifest.config.ts
RETRO_NOTE=""
FORCE=0
POS1=""
POS2=""
NPOS=0

parse_opts() {
	while [ $# -gt 0 ]; do
		case $1 in
		--dry-run) DRY_RUN=1 ;;
		--no-gh) NO_GH=1 ;;
		--write) WRITE=1 ;;
		--force) FORCE=1 ;;
		-h | --help)
			usage
			exit 0
			;;
		--kind | --sha | --version | --version-file | --name | --repo | --branch | --remote | \
			--changelog | --run-url | --run-label | --through | --heading | --bump-file | --retro-note)
			[ $# -ge 2 ] || die "$1 needs a value"
			case $1 in
			--kind) KIND=$2 ;;
			--sha) SHA=$2 ;;
			--version) VERSION=${2#v} ;;
			--version-file) VERSION_FILES="$VERSION_FILES $2" ;;
			--name) NAME=$2 ;;
			--repo) REPO=$2 ;;
			--branch) BRANCH=$2 ;;
			--remote) REMOTE=$2 ;;
			--changelog) CHANGELOG=$2 ;;
			--run-url) RUN_URL=$2 ;;
			--run-label) RUN_LABEL=$2 ;;
			--through) THROUGH=$2 ;;
			--heading) HEADING=$2 ;;
			--bump-file) BUMP_FILE=$2 ;;
			--retro-note) RETRO_NOTE=$2 ;;
			esac
			shift
			;;
		--*) die "unknown option $1 (see --help)" ;;
		*)
			NPOS=$((NPOS + 1))
			case $NPOS in
			1) POS1=$1 ;;
			2) POS2=$1 ;;
			*) die "too many arguments: $1" ;;
			esac
			;;
		esac
		shift
	done
	case $KIND in deploy | store | apply) ;; *) die "--kind must be deploy, store or apply" ;; esac
	if [ -n "$VERSION" ] && ! is_semver "$VERSION"; then die "--version $VERSION is not X.Y.Z"; fi
	return 0
}

# ---------------------------------------------------------------- context --

WORK=""
WORKTREES=""

cleanup() {
	local wt
	for wt in $WORKTREES; do
		git worktree remove --force "$wt" >/dev/null 2>&1 || true
	done
	[ -z "$WORK" ] || rm -rf "$WORK"
}

init_context() {
	git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
	command -v jq >/dev/null || die "jq is required"
	if [ -z "$REPO" ]; then REPO=${GITHUB_REPOSITORY:-}; fi
	if [ -z "$REPO" ]; then
		local url
		url=$(git remote get-url "$REMOTE" 2>/dev/null || true)
		REPO=$(printf '%s\n' "$url" | sed -nE 's#^.*github\.com[:/]+([^/]+/[^/]+)$#\1#p' | sed 's/\.git$//')
	fi
	[ -n "$REPO" ] || die "cannot tell the GitHub repository: pass --repo OWNER/NAME"
	[ -n "$NAME" ] || NAME=${REPO##*/}
	SERVER=${GITHUB_SERVER_URL:-https://github.com}
	REPO_URL="$SERVER/$REPO"
	if [ -z "$RUN_URL" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
		RUN_URL="$SERVER/${GITHUB_REPOSITORY:-$REPO}/actions/runs/$GITHUB_RUN_ID"
	fi
	if [ -z "$RUN_LABEL" ]; then
		if [ "$KIND" = deploy ]; then RUN_LABEL="CD run"; else RUN_LABEL="run"; fi
		[ -z "${GITHUB_RUN_NUMBER:-}" ] || RUN_LABEL="$RUN_LABEL #$GITHUB_RUN_NUMBER"
	fi
	NOW_ISO=${RELEASE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
	TODAY=${NOW_ISO%%T*}
	ACTOR=${GITHUB_ACTOR:-$(git config user.name 2>/dev/null || echo someone)}
	GIT_NAME=${RELEASE_GIT_NAME:-github-actions[bot]}
	GIT_EMAIL=${RELEASE_GIT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}
	WORK=$(mktemp -d "${TMPDIR:-/tmp}/release-tools.XXXXXX")
	trap cleanup EXIT
	case $KIND in
	deploy) VERB="is on prod" FACT="Deployed" ;;
	store) VERB="is live on the Chrome Web Store" FACT="Published" ;;
	apply) VERB="is applied" FACT="Applied" ;;
	esac
}

resolve_branch() {
	[ -z "$BRANCH" ] || return 0
	local head
	head=$(git symbolic-ref -q --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null || true)
	if [ -n "$head" ]; then
		BRANCH=${head#"$REMOTE"/}
		return 0
	fi
	head=$(git ls-remote --symref "$REMOTE" HEAD 2>/dev/null | sed -n 's#^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$#\1#p')
	if [ -n "$head" ]; then BRANCH=$head; else BRANCH=master; fi
}

fetch_remote() {
	git fetch -q --tags --force "$REMOTE" "+refs/heads/$BRANCH:refs/remotes/$REMOTE/$BRANCH" ||
		die "git fetch $REMOTE $BRANCH failed"
}

write_output() {
	[ -z "${GITHUB_OUTPUT:-}" ] || printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
}

summary() {
	[ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY"
}

# ----------------------------------------------------------------- semver --

is_semver() { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }

# semver_gt A B: A > B
semver_gt() {
	local a1 a2 a3 b1 b2 b3
	IFS=. read -r a1 a2 a3 <<<"$1"
	IFS=. read -r b1 b2 b3 <<<"$2"
	[ "$a1" -gt "$b1" ] && return 0
	[ "$a1" -lt "$b1" ] && return 1
	[ "$a2" -gt "$b2" ] && return 0
	[ "$a2" -lt "$b2" ] && return 1
	[ "$a3" -gt "$b3" ]
}

bump_version() {
	local m n p
	IFS=. read -r m n p <<<"$1"
	case $2 in
	major) echo "$((m + 1)).0.0" ;;
	minor) echo "$m.$((n + 1)).0" ;;
	*) echo "$m.$n.$((p + 1))" ;;
	esac
}

# ------------------------------------------------------------------- tags --

release_tags() {
	git for-each-ref --sort=-v:refname --format='%(refname:strip=2)' 'refs/tags/v*' |
		grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true
}

tags_at() {
	git for-each-ref --sort=-v:refname --points-at="$1" --format='%(refname:strip=2)' 'refs/tags/v*' |
		grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true
}

tag_exists() { git rev-parse -q --verify "refs/tags/$1" >/dev/null; }
tag_commit() { git rev-parse "$1^{commit}"; }
tag_date() { TZ=UTC git for-each-ref --format='%(creatordate:format-local:%Y-%m-%d)' "refs/tags/$1"; }

# the release tag just below $1 by version, or nothing
prev_tag() {
	local t seen=0
	for t in $(release_tags); do
		if [ "$seen" = 1 ]; then
			echo "$t"
			return 0
		fi
		[ "$t" != "$1" ] || seen=1
	done
	return 0
}

history_marker() {
	local content
	content=$(git show "$1:$CHANGELOG" 2>/dev/null) || return 0
	printf '%s\n' "$content" | sed -n "s/^$MARK_HISTORY \\([0-9a-f]\\{7,\\}\\) -->\$/\\1/p" | sed -n 1p
}

# where the range of a release ending at $1 starts: the previous tag, else the
# retro section's last commit, else the root (empty). The retro marker is read
# at the branch head first: an extension's retro section lands long after its
# first bump commits, where no CHANGELOG exists yet. Then at $1 itself.
range_start() {
	local end=$1 prev=$2 marker ref
	if [ -n "$prev" ]; then
		echo "$prev"
		return 0
	fi
	for ref in ${BRANCH:+"refs/remotes/$REMOTE/$BRANCH"} "$end"; do
		marker=$(history_marker "$ref")
		if [ -n "$marker" ] && git merge-base --is-ancestor "$marker" "$end" 2>/dev/null; then
			echo "$marker"
			return 0
		fi
	done
	return 0
}

# first-parent "sha<TAB>subject" lines in start..end, newest first, without the
# release commits
range_lines() {
	local spec=$2
	[ -z "$1" ] || spec="$1..$2"
	git log --first-parent --format='%H%x09%s' "$spec" -- | awk -F '\t' '$2 !~ /^chore\(release\):/'
}

# ----------------------------------------------------------------- titles --

# sets P_VISUAL P_PR P_DISPLAY P_TYPE P_BANG (an unknown type reads as Other)
parse_title() {
	local t=$1
	local re_visual='^\[visual review missing\] (.*)$'
	local re_pr='^(.*) \(#([0-9]+)\)$'
	local re_conv='^([a-z]+)(\([^)]*\))?(!)?: .+$'
	P_VISUAL=0 P_PR="" P_TYPE="" P_BANG=0
	if [[ $t =~ $re_visual ]]; then
		P_VISUAL=1
		t=${BASH_REMATCH[1]}
	fi
	if [[ $t =~ $re_pr ]]; then
		t=${BASH_REMATCH[1]}
		P_PR=${BASH_REMATCH[2]}
	fi
	P_DISPLAY=$t
	if [[ $t =~ $re_conv ]]; then
		P_TYPE=${BASH_REMATCH[1]}
		if [ -n "${BASH_REMATCH[3]}" ]; then P_BANG=1; fi
	fi
	return 0
}

body_is_breaking() {
	local body
	body=$(git log -1 --format=%b "$1")
	grep -Eq '^BREAKING[ -]CHANGE:' <<<"$body"
}

# ------------------------------------------------------------- PR metadata --

GH_FAILS=0

# pr_fetch N: gh pr view into $WORK/pr-N.json, once. Call it in this shell, not
# in $(...): it counts failures.
pr_fetch() {
	local f="$WORK/pr-$1.json"
	if [ ! -f "$f" ]; then
		if [ "$NO_GH" = 1 ]; then
			echo '{}' >"$f"
		elif gh pr view "$1" --repo "$REPO" --json labels,body >"$f" 2>"$WORK/gh.err" </dev/null; then
			GH_FAILS=0
		else
			warn "gh pr view $1: $(sed -n 1p "$WORK/gh.err"); read as no labels and no release note"
			echo '{}' >"$f"
			GH_FAILS=$((GH_FAILS + 1))
			if [ "$GH_FAILS" -ge 3 ]; then
				warn "three gh failures in a row: not reading PR metadata for the rest of this run"
				NO_GH=1
			fi
		fi
	fi
	return 0
}

pr_has_label() {
	jq -e --arg l "$2" '(.labels // []) | map(.name) | index($l) != null' "$WORK/pr-$1.json" >/dev/null
}

# the "## Release note" section of a PR body, without HTML comments. The awk stops
# at the next heading, so it reads a file: on a pipe, whatever was still writing
# would take SIGPIPE, and pipefail would fail the release.
pr_release_note() {
	jq -r '.body // ""' "$WORK/pr-$1.json" | tr -d '\r' >"$WORK/pr-$1.body"
	awk '
		/^##[ \t]+[Rr]elease [Nn]otes?[ \t]*$/ { ins = 1; next }
		ins && /^#{1,2}[ \t]/ { exit }
		ins {
			line = $0; out = ""
			while (length(line) > 0) {
				if (inc) {
					p = index(line, "-->"); if (p == 0) { line = ""; break }
					line = substr(line, p + 3); inc = 0
				} else {
					p = index(line, "<!--")
					if (p == 0) { out = out line; line = "" }
					else { out = out substr(line, 1, p - 1); line = substr(line, p + 4); inc = 1 }
				}
			}
			n++; l[n] = out
		}
		END {
			first = 0; last = 0
			for (i = 1; i <= n; i++) if (l[i] ~ /[^ \t]/) { if (!first) first = i; last = i }
			if (first) for (i = first; i <= last; i++) print l[i]
		}' "$WORK/pr-$1.body"
}

# ---------------------------------------------------------------- collect --

# classify start..end into $WORK/c.{breaking,feat,fix,other} ("pr<TAB>visual<TAB>title", pr "-" when none)
# and $WORK/notes; sets N_TOTAL N_BREAKING N_FEAT N_FIX N_OTHER VISUAL_PRS
collect() {
	local start=$1 end=$2 sha title cat note
	: >"$WORK/c.breaking"
	: >"$WORK/c.feat"
	: >"$WORK/c.fix"
	: >"$WORK/c.other"
	: >"$WORK/notes"
	VISUAL_PRS=""
	N_TOTAL=0 N_BREAKING=0 N_FEAT=0 N_FIX=0 N_OTHER=0
	range_lines "$start" "$end" >"$WORK/range"
	while IFS="$(printf '\t')" read -r sha title <&3; do
		[ -n "$sha" ] || continue
		parse_title "$title"
		cat=other
		if [ "$P_BANG" = 1 ] || body_is_breaking "$sha"; then
			cat=breaking N_BREAKING=$((N_BREAKING + 1))
		elif [ "$P_TYPE" = feat ]; then
			cat=feat N_FEAT=$((N_FEAT + 1))
		elif [ "$P_TYPE" = fix ]; then
			cat=fix N_FIX=$((N_FIX + 1))
		else
			N_OTHER=$((N_OTHER + 1))
		fi
		N_TOTAL=$((N_TOTAL + 1))
		# "-" for no PR: a leading empty field would vanish into IFS whitespace
		printf '%s\t%s\t%s\n' "${P_PR:--}" "$P_VISUAL" "$P_DISPLAY" >>"$WORK/c.$cat"
		if [ -n "$P_PR" ]; then
			pr_fetch "$P_PR"
			if pr_has_label "$P_PR" release:visual; then VISUAL_PRS="$VISUAL_PRS #$P_PR"; fi
			note=$(pr_release_note "$P_PR")
			if [ -n "$note" ]; then
				printf '%s ([#%s](%s/pull/%s))\n\n' "$note" "$P_PR" "$REPO_URL" "$P_PR" >>"$WORK/notes"
			fi
		fi
	done 3<"$WORK/range"
	return 0
}

# ------------------------------------------------------------- rendering --

md_line() { # pr ("-" or empty: none) visual title
	local s="- $3"
	[ -z "$1" ] || [ "$1" = - ] || s="$s ([#$1]($REPO_URL/pull/$1))"
	[ "$2" != 1 ] || s="$s ⚠ visual review missing"
	printf '%s\n' "$s"
}

md_section() { # heading file
	[ -s "$2" ] || return 0
	printf '### %s\n' "$1"
	local pr vis title
	while IFS="$(printf '\t')" read -r pr vis title; do md_line "$pr" "$vis" "$title"; done <"$2"
	printf '\n'
}

render_sections() {
	md_section Breaking "$WORK/c.breaking"
	md_section Features "$WORK/c.feat"
	md_section Fixes "$WORK/c.fix"
	md_section Other "$WORK/c.other"
	if [ -s "$WORK/notes" ]; then
		printf '### Release notes\n'
		cat "$WORK/notes"
	fi
}

# facts_line verb sha run_url run_label slack_permalink [retro]
facts_line() {
	local s
	s="$1 \`$(git rev-parse --short=7 "$2")\`"
	[ -z "$3" ] || s="$s · [$4]($3)"
	[ -z "$5" ] || s="$s · [Slack thread]($5)"
	[ -z "${6:-}" ] || s="$s · retro"
	printf '%s\n' "$s"
}

# render_entry label date facts  (after collect)
render_entry() {
	printf '## [%s] — %s\n' "$1" "$2"
	[ -z "$3" ] || printf '%s\n' "$3"
	printf '\n'
	render_sections
}

# a marker value from a Release body file: marker_value file key
marker_value() {
	sed -n "s/^<!-- release-tools $2: \\(.*\\) -->\$/\\1/p" "$1" | sed -n 1p
}

# the Release body of a tag into $2; 1 when there is none
release_body() {
	[ "$NO_GH" = 0 ] || return 1
	gh release view "$1" --repo "$REPO" --json body >"$WORK/rel.json" 2>/dev/null </dev/null || return 1
	jq -r '.body // ""' "$WORK/rel.json" | tr -d '\r' >"$2"
}

# the CHANGELOG entry of an existing tag, facts from its Release when there is one
render_tag_entry() {
	local tag=$1 end start body="$WORK/body.$1" run_url="" run_label="" permalink="" retro=""
	end=$(tag_commit "$tag")
	start=$(range_start "$end" "$(prev_tag "$tag")")
	collect "$start" "$end"
	if release_body "$tag" "$body"; then
		run_url=$(marker_value "$body" run_url)
		run_label=$(marker_value "$body" run_label)
		permalink=$(marker_value "$body" slack_permalink)
		! grep -q '^<!-- release-tools retro -->' "$body" || retro=1
	fi
	render_entry "${tag#v}" "$(tag_date "$tag")" "$(facts_line "$FACT" "$end" "$run_url" "${run_label:-run}" "$permalink" "$retro")"
}

# ------------------------------------------------------------------ slack --

mrkdwn_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

slack_bullet() { # pr ("-": none) visual title
	local pr=${1#-} t=$3 s re_tail='^(.*) \(([^()]+)\)$'
	if [ -n "$pr" ] && [[ $t =~ $re_tail ]]; then
		s="$(mrkdwn_escape "${BASH_REMATCH[1]}") ($(mrkdwn_escape "${BASH_REMATCH[2]}"), #$pr)"
	elif [ -n "$pr" ]; then
		s="$(mrkdwn_escape "$t") (#$pr)"
	else
		s=$(mrkdwn_escape "$t")
	fi
	[ "$2" != 1 ] || s="$s ⚠ visual review missing"
	printf '• %s\n' "$s"
}

plural() { # n singular plural
	if [ "$1" = 1 ]; then printf '1 %s' "$2"; else printf '%s %s' "$1" "$3"; fi
}

counts_phrase() {
	local parts=""
	[ "$N_BREAKING" = 0 ] || parts="$parts, $(plural "$N_BREAKING" "breaking change" "breaking changes")"
	[ "$N_FEAT" = 0 ] || parts="$parts, $(plural "$N_FEAT" feature features)"
	[ "$N_FIX" = 0 ] || parts="$parts, $(plural "$N_FIX" fix fixes)"
	[ "$N_OTHER" = 0 ] || parts="$parts, $(plural "$N_OTHER" "other change" "other changes")"
	parts=${parts#, }
	printf '%s' "${parts:-no changes}"
}

# slack_release_text tag sha  (after collect)
slack_release_text() {
	local tag=$1 links shown=0 pr vis title cat
	links="<$REPO_URL/releases/tag/$tag|Release>"
	[ -z "$RUN_URL" ] || links="$links · <$RUN_URL|$RUN_LABEL>"
	links="$links · \`$(git rev-parse --short=7 "$2")\`"
	printf '🚀 *%s %s* %s — %s  (%s)\n' "$(mrkdwn_escape "$NAME")" "$tag" "$VERB" "$(counts_phrase)" "$links"
	for cat in breaking feat fix other; do
		while IFS="$(printf '\t')" read -r pr vis title; do
			shown=$((shown + 1))
			[ "$shown" -le 8 ] || continue
			slack_bullet "$pr" "$vis" "$title"
		done <"$WORK/c.$cat"
	done
	[ "$shown" -le 8 ] || printf '+ %s more in the Release\n' "$((shown - 8))"
	if [ -n "$VISUAL_PRS" ]; then
		printf '📸 screenshots follow in this thread (release:visual on %s)\n' "$(echo "$VISUAL_PRS" | sed 's/^ //; s/ /, /g')"
	fi
}

slack_redeploy_text() { # label sha detail
	local s
	s="♻️ *$(mrkdwn_escape "$NAME") $1* re-deployed to prod ($3) by $(mrkdwn_escape "$ACTOR")"
	[ -z "$RUN_URL" ] || s="$s  (<$RUN_URL|$RUN_LABEL>)"
	printf '%s\n' "$s"
}

# slack_post text: sets SLACK_TS SLACK_PERMALINK SLACK_ERROR. The token goes to
# curl on stdin, never on its command line and never to the log.
slack_post() {
	local api=${SLACK_API_URL:-https://slack.com/api} channel=${SLACK_RELEASES_CHANNEL:-} resp
	SLACK_TS="" SLACK_PERMALINK="" SLACK_ERROR=""
	if [ -z "${SLACK_RELEASES_BOT_TOKEN:-}" ]; then
		SLACK_ERROR="no token"
		return 1
	fi
	if [ -z "$channel" ]; then
		SLACK_ERROR="no channel"
		return 1
	fi
	jq -n --arg c "$channel" --arg t "$1" \
		'{channel: $c, text: $t, mrkdwn: true, unfurl_links: false, unfurl_media: false}' >"$WORK/slack.json"
	if ! resp=$(slack_curl --data-binary "@$WORK/slack.json" -H 'Content-Type: application/json; charset=utf-8' \
		"$api/chat.postMessage"); then
		SLACK_ERROR="request failed"
		return 1
	fi
	if [ "$(jq -r '.ok // false' <<<"$resp" 2>/dev/null)" != true ]; then
		SLACK_ERROR=$(jq -r '.error // "unreadable response"' <<<"$resp" 2>/dev/null || echo "unreadable response")
		return 1
	fi
	SLACK_TS=$(jq -r '.ts // ""' <<<"$resp")
	channel=$(jq -r --arg c "$channel" '.channel // $c' <<<"$resp")
	resp=$(slack_curl -G --data-urlencode "channel=$channel" --data-urlencode "message_ts=$SLACK_TS" \
		"$api/chat.getPermalink" || true)
	SLACK_PERMALINK=$(jq -r '.permalink // ""' <<<"$resp" 2>/dev/null || true)
	[ -n "$SLACK_PERMALINK" ] || SLACK_PERMALINK="https://slack.com/archives/$channel/p$(printf '%s' "$SLACK_TS" | tr -d .)"
	return 0
}

slack_curl() {
	printf 'header = "Authorization: Bearer %s"\n' "$SLACK_RELEASES_BOT_TOKEN" |
		curl -sS --max-time 20 --config - "$@"
}

# ---------------------------------------------------------------- release --

# release_body_new tag sha  (after collect): the notes a new Release starts with
release_body_new() {
	render_sections
	printf -- '---\n'
	local s
	s="$FACT \`$(git rev-parse "$2")\`"
	[ -z "$RUN_URL" ] || s="$s · [$RUN_LABEL]($RUN_URL)"
	printf '%s · %s\n' "$s" "$NOW_ISO"
	printf 'Slack: pending\n'
	if [ -n "$VISUAL_PRS" ]; then
		printf 'Screenshots: pending (release:visual on %s)\n' "$(echo "$VISUAL_PRS" | sed 's/^ //; s/ /, /g')"
	fi
	[ -z "$RUN_URL" ] || printf '<!-- release-tools run_url: %s -->\n' "$RUN_URL"
	printf '<!-- release-tools run_label: %s -->\n' "$RUN_LABEL"
}

push_tag() { # tag sha message [date]
	if [ -n "${4:-}" ]; then
		GIT_COMMITTER_DATE=$4 git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" tag -a "$1" -m "$3" "$2"
	else
		GIT_COMMITTER_DATE=$NOW_ISO git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" tag -a "$1" -m "$3" "$2"
	fi
	if ! git push -q "$REMOTE" "refs/tags/$1" 2>"$WORK/push.err"; then
		git fetch -q --force "$REMOTE" "+refs/tags/$1:refs/tags/$1" 2>/dev/null || true
		if [ "$(tag_commit "$1" 2>/dev/null)" = "$(git rev-parse "$2")" ]; then
			log "$1 was pushed meanwhile, on the same commit"
			return 0
		fi
		die "pushing $1: $(sed -n 1p "$WORK/push.err")"
	fi
	log "tagged $1 on $(git rev-parse --short=7 "$2")"
}

create_release() { # tag sha notes-file [extra gh flags]
	local tag=$1 sha=$2 notes=$3
	shift 3
	gh release create "$tag" --repo "$REPO" --verify-tag --target "$(git rev-parse "$sha")" \
		--title "$tag" --notes-file "$notes" "$@" >/dev/null </dev/null || die "gh release create $tag failed"
	log "GitHub Release $tag created"
}

# announce tag sha: post the release text, then record it in the Release
announce() {
	local tag=$1 sha=$2 line body="$WORK/announce.body"
	slack_release_text "$tag" "$sha" >"$WORK/slack.txt"
	if slack_post "$(cat "$WORK/slack.txt")"; then
		line="Slack: $SLACK_PERMALINK"
		log "posted to Slack (ts $SLACK_TS)"
		write_output slack_ts "$SLACK_TS"
	else
		line="Slack: not posted ($SLACK_ERROR)"
		warn "Slack not posted: $SLACK_ERROR. Re-post with: release.sh post $tag"
	fi
	release_body "$tag" "$body" || die "cannot read the Release $tag to record the Slack post"
	awk -v line="$line" '/^Slack: / && !d { print line; d = 1; next } { print } END { if (!d) print line }' \
		"$body" >"$body.new"
	if [ -n "$SLACK_TS" ]; then
		printf '<!-- slack_ts: %s -->\n<!-- release-tools slack_permalink: %s -->\n' "$SLACK_TS" "$SLACK_PERMALINK" >>"$body.new"
	fi
	gh release edit "$tag" --repo "$REPO" --notes-file "$body.new" >/dev/null </dev/null ||
		warn "could not record the Slack line in the Release $tag"
	summary "Slack: ${line#Slack: }"
}

redeploy_post() { # label sha detail
	local text
	text=$(slack_redeploy_text "$1" "$2" "$3")
	if [ "$DRY_RUN" = 1 ]; then
		printf '== Slack ==\n%s\n' "$text"
		return 0
	fi
	if slack_post "$text"; then log "posted the re-deploy line to Slack"; else warn "re-deploy line not posted: $SLACK_ERROR"; fi
	summary "Re-deploy: ${text}"
}

# ------------------------------------------------------- version files --

bump_file() { # path version (in cwd)
	local f=$1 v=$2
	case ${f##*/} in
	pyproject.toml)
		[ -f "$f" ] || {
			warn "$f not found; not bumped"
			return 0
		}
		awk -v v="$v" '
			/^\[/ { sect = $0 }
			sect == "[project]" && !done && /^version[ \t]*=/ { print "version = \"" v "\""; done = 1; next }
			{ print }
			END { if (!done) exit 3 }' "$f" >"$f.rt" || {
			rm -f "$f.rt"
			die "$f has no [project] version"
		}
		;;
	package.json)
		[ -f "$f" ] || {
			warn "$f not found; not bumped"
			return 0
		}
		awk -v v="$v" '
			!done && /^(  |\t)"version"[ \t]*:/ { sub(/"version"[ \t]*:[ \t]*"[^"]*"/, "\"version\": \"" v "\""); done = 1 }
			{ print }
			END { if (!done) exit 3 }' "$f" >"$f.rt" || {
			rm -f "$f.rt"
			die "$f has no top-level version"
		}
		;;
	package-lock.json)
		[ -f "$f" ] || {
			warn "$f not found; not bumped"
			return 0
		}
		jq --arg v "$v" '.version = $v | if (.packages // {}) | has("") then .packages[""].version = $v else . end' "$f" >"$f.rt"
		;;
	*) printf '%s\n' "$v" >"$f.rt" ;;
	esac
	mv "$f.rt" "$f"
}

# ------------------------------------------------------------- changelog --

default_header() {
	cat <<'EOF'
# Changelog

Every release, newest first. Generated by release-tools from the squash-merge titles: do not edit it by hand. A human-facing line goes in the PR body under `## Release note`.
EOF
}

trim_blank() { # print a file without leading/trailing blank lines
	awk '{ l[NR] = $0 } END { f = 0; e = 0; for (i = 1; i <= NR; i++) if (l[i] ~ /[^ \t]/) { if (!f) f = i; e = i }
		if (f) for (i = f; i <= e; i++) print l[i] }' "$1"
}

# write_changelog file: give every release tag an entry; keep the existing ones
# byte for byte. Prints the number of entries added.
write_changelog() {
	local f=$1 d tag v added=0
	d=$(mktemp -d "$WORK/cl.XXXXXX")
	mkdir -p "$d/blk"
	: >"$d/header"
	: >"$d/tail"
	if [ -f "$f" ]; then
		awk -v d="$d" '
			BEGIN { out = d "/header"; mode = "h" }
			/^## \[[0-9]+\.[0-9]+\.[0-9]+\]/ && mode != "t" { v = $2; gsub(/[][]/, "", v); close(out); out = d "/blk/" v; mode = "b" }
			/^## / && $0 !~ /^## \[[0-9]+\.[0-9]+\.[0-9]+\]/ && mode != "t" { close(out); out = d "/tail"; mode = "t" }
			{ print > out }' "$f"
	fi
	if ! grep -q '[^[:space:]]' "$d/header"; then default_header >"$d/header"; fi
	for tag in $(release_tags); do
		v=${tag#v}
		[ ! -f "$d/blk/$v" ] || continue
		render_tag_entry "$tag" >"$d/blk/$v"
		added=$((added + 1))
	done
	{
		trim_blank "$d/header"
		for v in $(find "$d/blk" -type f -exec basename {} \; | sort -t. -k1,1nr -k2,2nr -k3,3nr); do
			printf '\n'
			trim_blank "$d/blk/$v"
		done
		if grep -q '[^[:space:]]' "$d/tail"; then
			printf '\n'
			trim_blank "$d/tail"
		fi
	} >"$f.rt"
	mv "$f.rt" "$f"
	echo "$added"
}

# changelog_commit: on the remote branch's head, write every missing entry and
# the version file, commit, push; on a refused push start again from the new
# head, three times. Returns 1 when it gave up.
changelog_commit() {
	local attempt newest wt added f msg
	newest=$(release_tags | sed -n 1p)
	[ -n "$newest" ] || return 0
	msg="chore(release): $newest [skip ci]"
	for attempt in 1 2 3; do
		fetch_remote
		wt=$(mktemp -d "$WORK/wt.XXXXXX")
		git worktree add -q --detach "$wt" "refs/remotes/$REMOTE/$BRANCH" || die "git worktree add failed"
		WORKTREES="$WORKTREES $wt"
		added=$(write_changelog "$wt/$CHANGELOG")
		for f in $VERSION_FILES; do
			[ "$f" = none ] || (cd "$wt" && bump_file "$f" "${newest#v}")
		done
		if [ -z "$(git -C "$wt" status --porcelain)" ]; then
			log "CHANGELOG.md already has every release"
			return 0
		fi
		git -C "$wt" add -A
		git -C "$wt" -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" commit -q -m "$msg"
		if git -C "$wt" push -q "$REMOTE" "HEAD:refs/heads/$BRANCH" 2>"$WORK/push.err"; then
			log "committed $msg to $BRANCH ($added entr$([ "$added" = 1 ] && echo y || echo ies) added)"
			return 0
		fi
		warn "push to $BRANCH refused (attempt $attempt): $(sed -n 1p "$WORK/push.err")"
	done
	warn "gave up on the CHANGELOG commit; the next release writes every missing entry"
	return 1
}

# ---------------------------------------------------------- extension ---

file_version_at() { # sha
	local content
	content=$(git show "$1:$BUMP_FILE" 2>/dev/null) || return 0
	awk 'match($0, /(^|[^A-Za-z0-9_])version:[ \t]*["\047][0-9]+\.[0-9]+\.[0-9]+["\047]/) {
		s = substr($0, RSTART, RLENGTH); sub(/^[^v]*version:[ \t]*["\047]/, "", s); sub(/["\047]$/, "", s); print s; exit }' <<<"$content"
}

# "sha version" for each first-parent commit that changed the version in
# $BUMP_FILE, oldest first; a version that comes back later keeps its first commit
bump_commits() {
	local sha v prev="" seen=" "
	git log --first-parent --reverse --format=%H "$1" -- "$BUMP_FILE" >"$WORK/bumps"
	while read -r sha <&3; do
		v=$(file_version_at "$sha")
		[ -n "$v" ] || continue
		if [ "$v" != "$prev" ]; then
			case $seen in *" $v "*) ;; *)
				echo "$sha $v"
				seen="$seen$v "
				;;
			esac
		fi
		prev=$v
	done 3<"$WORK/bumps"
}

# reads to the end: an awk that left at the match would take bump_commits down
# with SIGPIPE on the next bump, and bump_commits lists a version only once
bump_commit_of() { # version head
	bump_commits "$2" | awk -v v="$1" '$2 == v { print $1 }'
}

# ----------------------------------------------------------- subcommands --

cmd_cut() {
	init_context
	resolve_branch
	fetch_remote
	local newest existing tag start version level ok=0
	if [ "$KIND" = store ]; then
		[ -n "$VERSION" ] || die "--kind store needs --version (the manifest's)"
		if [ -z "$SHA" ]; then
			SHA=$(bump_commit_of "$VERSION" "refs/remotes/$REMOTE/$BRANCH")
			[ -n "$SHA" ] || die "no commit sets version $VERSION in $BUMP_FILE"
		fi
	fi
	SHA=$(git rev-parse --verify -q "${SHA:-HEAD}^{commit}") || die "unknown commit ${SHA:-HEAD}"
	newest=$(release_tags | sed -n 1p)
	existing=$(tags_at "$SHA" | sed -n 1p)
	if [ "$KIND" = store ] && tag_exists "v$VERSION"; then
		[ "$(tag_commit "v$VERSION")" = "$SHA" ] || die "v$VERSION exists on another commit"
		existing="v$VERSION"
	fi
	write_output sha "$SHA"

	if [ -n "$existing" ]; then
		cut_existing "$existing" "$newest"
		return
	fi
	if [ -n "$newest" ]; then
		if git merge-base --is-ancestor "$SHA" "$newest"; then
			write_output action redeploy
			write_output released false
			local after
			after=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$SHA" 2>/dev/null || true)
			if [ "$KIND" = deploy ]; then
				redeploy_post "$(git rev-parse --short=7 "$SHA")" "$SHA" \
					"rollback from $newest${after:+, after $after}"
			else
				log "$(git rev-parse --short=7 "$SHA") is older than $newest: nothing to release"
			fi
			return 0
		fi
		git merge-base --is-ancestor "$newest" "$SHA" ||
			die "$(git rev-parse --short=7 "$SHA") does not descend from $newest; not releasing"
	fi
	start=$(range_start "$SHA" "$newest")
	collect "$start" "$SHA"
	if [ "$N_TOTAL" = 0 ] && [ -n "$newest" ]; then
		write_output action redeploy
		write_output released false
		if [ "$KIND" = deploy ]; then
			redeploy_post "$newest" "$SHA" "sha \`$(git rev-parse --short=7 "$SHA")\`, no changes since $newest"
		else
			log "nothing new since $newest"
		fi
		return 0
	fi

	if [ -n "$VERSION" ]; then
		version=$VERSION
		if [ -n "$newest" ] && ! semver_gt "$version" "${newest#v}"; then
			die "--version $version is not above $newest"
		fi
	elif [ -z "$newest" ]; then
		version=0.1.0
	else
		level='patch'
		[ "$N_FEAT" = 0 ] || level=minor
		if [ "$N_BREAKING" != 0 ]; then
			case ${newest#v} in 0.*) level=minor ;; *) level=major ;; esac
		fi
		version=$(bump_version "${newest#v}" "$level")
	fi
	tag="v$version"
	tag_exists "$tag" && die "$tag exists on another commit"
	write_output version "$version"
	write_output tag "$tag"
	write_output release_url "$REPO_URL/releases/tag/$tag"

	if [ "$DRY_RUN" = 1 ]; then
		printf '== plan ==\n'
		printf 'tag %s (annotated) on %s, pushed to %s\n' "$tag" "$(git rev-parse --short=7 "$SHA")" "$REMOTE"
		printf 'GitHub Release %s on %s\n' "$tag" "$REPO"
		printf 'Slack post to %s\n' "${SLACK_RELEASES_CHANNEL:-(SLACK_RELEASES_CHANNEL unset)}"
		printf '%s%s, committed "chore(release): %s [skip ci]" to %s\n' "$CHANGELOG" \
			"$(for f in $VERSION_FILES; do [ "$f" = none ] || printf ' + %s' "$f"; done)" "$tag" "$BRANCH"
		printf '\n== CHANGELOG entry ==\n'
		render_entry "$version" "$TODAY" "$(facts_line "$FACT" "$SHA" "$RUN_URL" "$RUN_LABEL" "")"
		printf '== Slack ==\n'
		slack_release_text "$tag" "$SHA"
		write_output action dry-run
		write_output released false
		return 0
	fi

	push_tag "$tag" "$SHA" "$tag"
	release_body_new "$tag" "$SHA" >"$WORK/notes.md"
	create_release "$tag" "$SHA" "$WORK/notes.md"
	summary "### $NAME $tag" "" "$(cat "$WORK/notes.md")"
	announce "$tag" "$SHA"
	write_output action release
	write_output released true
	changelog_commit || ok=1
	return "$ok"
}

# the sha already carries a release tag: finish what a crash left undone, else
# it is a re-deploy
cut_existing() {
	local tag=$1 newest=$2 body="$WORK/existing.body" posted=0 start
	write_output version "${tag#v}"
	write_output tag "$tag"
	write_output release_url "$REPO_URL/releases/tag/$tag"
	write_output released false
	if [ "$tag" = "$newest" ] && [ "$DRY_RUN" = 0 ]; then
		start=$(range_start "$(tag_commit "$tag")" "$(prev_tag "$tag")")
		if ! release_body "$tag" "$body"; then
			collect "$start" "$SHA"
			release_body_new "$tag" "$SHA" >"$WORK/notes.md"
			create_release "$tag" "$SHA" "$WORK/notes.md"
			announce "$tag" "$SHA"
			posted=1
		elif grep -q '^Slack: pending$' "$body"; then
			collect "$start" "$SHA"
			announce "$tag" "$SHA"
			posted=1
		fi
	fi
	if [ "$posted" = 1 ]; then
		write_output action recovered
	elif [ "$KIND" = deploy ]; then
		write_output action redeploy
		if [ "$tag" = "$newest" ]; then
			redeploy_post "$tag" "$SHA" "sha \`$(git rev-parse --short=7 "$SHA")\`"
		else
			redeploy_post "$tag" "$SHA" "rollback from $newest, sha \`$(git rev-parse --short=7 "$SHA")\`"
		fi
	else
		write_output action noop
		log "$tag is already released"
	fi
	[ "$DRY_RUN" = 1 ] || changelog_commit
}

cmd_render() {
	init_context
	resolve_branch
	[ "$NPOS" -ge 1 ] || die "usage: release.sh render <from|''> <to>"
	local from=$POS1 to=${POS2:-$POS1} end label date run_url="" run_label="" permalink="" body="$WORK/render.body"
	[ "$NPOS" -ge 2 ] || from=""
	end=$(git rev-parse --verify -q "$to^{commit}") || die "unknown revision $to"
	if [ -n "$from" ]; then git rev-parse --verify -q "$from^{commit}" >/dev/null || die "unknown revision $from"; fi
	[ -n "$from" ] || from=$(range_start "$end" "")
	collect "$from" "$end"
	if tag_exists "$to" && is_semver "${to#v}"; then
		label=${to#v}
		date=$(tag_date "$to")
		if release_body "$to" "$body"; then
			run_url=$(marker_value "$body" run_url)
			run_label=$(marker_value "$body" run_label)
			permalink=$(marker_value "$body" slack_permalink)
		fi
	else
		label=Unreleased
		date=$TODAY
	fi
	render_entry "$label" "$date" "$(facts_line "$FACT" "$end" "$run_url" "${run_label:-run}" "$permalink")"
}

render_history_section() { # through
	local through=$1 sha date title month="" cur
	printf '## %s\n%s %s -->\n' "${HEADING:-Before v0.1.0}" "$MARK_HISTORY" "$(git rev-parse "$through")"
	TZ=UTC git log --first-parent --date=format-local:%Y-%m-%d --format='%H%x09%cd%x09%s' "$through" -- |
		awk -F '\t' '$3 !~ /^chore\(release\):/' >"$WORK/history"
	while IFS="$(printf '\t')" read -r sha date title <&3; do
		cur=${date%-*}
		if [ "$cur" != "$month" ]; then
			printf '\n### %s\n' "$cur"
			month=$cur
		fi
		parse_title "$title"
		md_line "$P_PR" "$P_VISUAL" "$P_DISPLAY" | sed "s/^- /- $date /"
	done 3<"$WORK/history"
}

cmd_render_history() {
	init_context
	local through=$THROUGH
	if [ -z "$through" ]; then
		resolve_branch
		if git rev-parse -q --verify "refs/remotes/$REMOTE/$BRANCH" >/dev/null; then
			through="refs/remotes/$REMOTE/$BRANCH"
		else
			through=HEAD
		fi
	fi
	git rev-parse -q --verify "$through^{commit}" >/dev/null || die "unknown revision $through"
	if [ "$WRITE" = 0 ]; then
		render_history_section "$through"
		return 0
	fi
	# keep the header and the release entries; replace everything from the
	# first non-release "## " heading on
	local d
	d=$(mktemp -d "$WORK/rh.XXXXXX")
	if [ -f "$CHANGELOG" ]; then
		awk '/^## / && $0 !~ /^## \[[0-9]+\.[0-9]+\.[0-9]+\]/ { exit } { print }' "$CHANGELOG" >"$d/head"
	fi
	if [ ! -s "$d/head" ] || ! grep -q '[^[:space:]]' "$d/head"; then default_header >"$d/head"; fi
	{
		trim_blank "$d/head"
		printf '\n'
		render_history_section "$through"
	} >"$d/out"
	mv "$d/out" "$CHANGELOG"
	log "wrote the retro section ($(grep -c '^- ' "$WORK/history" 2>/dev/null || wc -l <"$WORK/history" | tr -d ' ') commits through $(git rev-parse --short=7 "$through")) into $CHANGELOG"
}

cmd_post() {
	init_context
	[ "$NPOS" = 1 ] || die "usage: release.sh post vX.Y.Z"
	local tag=v${POS1#v} body="$WORK/post.body" sha
	resolve_branch
	fetch_remote
	tag_exists "$tag" || die "no tag $tag"
	release_body "$tag" "$body" || die "no GitHub Release for $tag (or gh cannot read it)"
	if grep -q '^<!-- slack_ts: ' "$body" && [ "$FORCE" = 0 ]; then
		die "the Release $tag already records a post ($(sed -n 's/^<!-- slack_ts: \(.*\) -->$/\1/p' "$body")); --force posts again"
	fi
	[ -n "$RUN_URL" ] || RUN_URL=$(marker_value "$body" run_url)
	local label
	label=$(marker_value "$body" run_label)
	[ -z "$label" ] || RUN_LABEL=$label
	sha=$(tag_commit "$tag")
	collect "$(range_start "$sha" "$(prev_tag "$tag")")" "$sha"
	if [ "$DRY_RUN" = 1 ]; then
		printf '== Slack ==\n'
		slack_release_text "$tag" "$sha"
		return 0
	fi
	announce "$tag" "$sha"
	[ -n "$SLACK_TS" ] || return 1
}

cmd_backfill_ext() {
	init_context
	resolve_branch
	fetch_remote
	local head current sha v tag date note made=0
	head=$(git rev-parse --verify -q "${SHA:-refs/remotes/$REMOTE/$BRANCH}^{commit}") || die "unknown commit $SHA"
	current=$(file_version_at "$head")
	bump_commits "$head" >"$WORK/bump-list"
	while read -r sha v <&3; do
		tag="v$v"
		[ "$v" != "$current" ] || continue
		tag_exists "$tag" && continue
		if [ "$DRY_RUN" = 1 ]; then
			printf 'would tag %s on %s (retro, no Slack)\n' "$tag" "$(git rev-parse --short=7 "$sha")"
			continue
		fi
		date=$(git log -1 --format=%cI "$sha")
		push_tag "$tag" "$sha" "$tag (retro)" "$date"
		collect "$(range_start "$sha" "$(prev_tag "$tag")")" "$sha"
		note=${RETRO_NOTE:-"retro — cut on $TODAY from the bump commit; the build that shipped $v is this commit's."}
		{
			render_sections
			# shellcheck disable=SC2016 # the backquotes are Markdown
			printf -- '---\n%s `%s`\n\n%s\n' "$FACT" "$(git rev-parse "$sha")" "$note"
			printf 'Slack: none (retro)\n<!-- release-tools retro -->\n'
		} >"$WORK/notes.md"
		create_release "$tag" "$sha" "$WORK/notes.md" --latest=false
		made=$((made + 1))
	done 3<"$WORK/bump-list"
	log "backfill: $made retro tag(s); the manifest's current $current is left to cut"
	if [ "$DRY_RUN" = 0 ]; then changelog_commit; fi
}

cmd_check_title() {
	[ "$NPOS" = 1 ] || die "usage: release.sh check-title '<title>'"
	local t=$POS1 re='^(\[visual review missing\] )?([a-z]+)(\([^)]+\))?(!)?: [^[:space:]].*$' type
	if [[ $t =~ $re ]]; then
		type=${BASH_REMATCH[2]}
		case $KNOWN_TYPES in *" $type "*)
			echo "ok: $t"
			return 0
			;;
		esac
		echo "PR title type \"$type\" is not one of:$KNOWN_TYPES" >&2
	else
		echo "PR title does not read 'type(scope)!: subject' (scope and ! optional): $t" >&2
	fi
	echo "the PR title becomes the squash title, the version bump and the release note" >&2
	return 1
}

main() {
	[ $# -gt 0 ] || {
		usage >&2
		exit 2
	}
	local cmd=$1
	shift
	parse_opts "$@"
	case $cmd in
	cut) cmd_cut ;;
	render) cmd_render ;;
	render-history) cmd_render_history ;;
	post) cmd_post ;;
	backfill-ext) cmd_backfill_ext ;;
	check-title) cmd_check_title ;;
	-h | --help | help) usage ;;
	*) die "unknown subcommand $cmd (see --help)" ;;
	esac
}

main "$@"
