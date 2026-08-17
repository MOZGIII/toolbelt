# shellcheck shell=bash
#
# review.sh — the layout of the local review tree.
#
# Two tools share it: the reviewer writes the tree, the merge driver gates on
# it. That makes the layout a contract, and one whose divergence does not fail
# loudly — if the two disagree about where a verdict lives, the gate looks in a
# directory nothing ever writes and waits for a verdict that cannot arrive.
# Hence one definition, here, rather than two kept in step by hand.
#
#   <reviews-dir>/<pr-number>-<branch-slug>/
#       001/ …            one directory per run; nothing is ever overwritten
#       002/ …
#       latest -> 002     symlink onto the newest run
#
# The verdict of record is <latest>/verdict, holding "true" or "false".

# review_slug <pr-number> <branch>
#
# The directory a branch's reviews are filed under. The PR number leads so a
# listing sorts into merge order; the branch follows so the directory is
# readable. Without a number (a standalone review, which no PR covers) the
# slug is the branch alone.
review_slug() {
	local number="$1" branch="$2" slug
	slug="${branch//\//-}"
	slug="${slug//[^A-Za-z0-9._-]/-}"
	if [[ -n "$number" ]]; then
		printf '%s-%s' "$number" "$slug"
	else
		printf '%s' "$slug"
	fi
}

# review_root <reviews-dir> <pr-number> <branch>
review_root() {
	printf '%s/%s' "$1" "$(review_slug "$2" "$3")"
}

# review_latest_dir <reviews-dir> <pr-number> <branch>
review_latest_dir() {
	printf '%s/latest' "$(review_root "$@")"
}

# review_verdict_file <reviews-dir> <pr-number> <branch>
review_verdict_file() {
	printf '%s/verdict' "$(review_latest_dir "$@")"
}

# normalize_verdict <verdict-file>
#
# The file's contents with whitespace stripped and case folded away; empty when
# the file is missing or holds nothing. Callers that need to tell "no verdict"
# from "an empty one" test for the file themselves.
normalize_verdict() {
	local file="$1"
	[[ -f "$file" ]] || return 0
	tr -d '[:space:]' <"$file" | tr '[:upper:]' '[:lower:]'
}

# read_verdict <verdict-file>
#
# "true" or "false" when the run decided, "malformed" when it wrote something
# else, and nothing at all when there is no verdict yet.
read_verdict() {
	local file="$1" value
	[[ -f "$file" ]] || return 0
	value="$(normalize_verdict "$file")"
	case "$value" in
	true | false) printf '%s' "$value" ;;
	*) printf 'malformed' ;;
	esac
}
