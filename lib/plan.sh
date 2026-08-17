# shellcheck shell=bash
#
# plan.sh — the merge-order plan file, shared by the tools that read and write
# it.
#
# Format: "<branch-name>  #<pr-number>  <pr-title>", one entry per line. Only
# whole-line "#" comments are recognised, because a PR number is spelled "#490"
# and a trailing comment would be ambiguous. An entry that has been merged is
# commented out in place with a "# [merged] " prefix rather than deleted, so
# the file keeps the whole chain.
#
# Two tools read this and read it differently, which is exactly why the format
# lives in one file: the merge driver wants the entries still to be merged, and
# treats a line it cannot parse as a fault in the file that drives merges,
# while the reviewer wants every entry including the merged ones — they are
# still the base chain it reviews against — and skips whatever does not parse.
# Both readings belong to the format; the difference between them is two flags,
# not two parsers.

PLAN_BRANCHES=()
PLAN_NUMBERS=()
PLAN_TITLES=()
PLAN_ACTIVE=()

# parse_plan_file [--all] [--strict] <plan-file>
#
# Fills PLAN_BRANCHES / PLAN_NUMBERS / PLAN_TITLES / PLAN_ACTIVE, in file order
# and parallel to each other.
#
#   --all     also record the entries commented out as merged, with a 0 in
#             PLAN_ACTIVE. Without it only active entries are recorded.
#   --strict  an *active* line that does not parse is an error naming the file
#             and line, instead of being skipped. Commented-out lines are
#             skipped either way: a plan file's own header comments are not
#             malformed entries.
parse_plan_file() {
	local include_all=0 strict=0 plan_file=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--all) include_all=1; shift ;;
		--strict) strict=1; shift ;;
		*) plan_file="$1"; shift ;;
		esac
	done
	[[ -f "$plan_file" ]] || die "plan file not found: $plan_file"

	PLAN_BRANCHES=()
	PLAN_NUMBERS=()
	PLAN_TITLES=()
	PLAN_ACTIVE=()
	local line body branch number title rest active lineno=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		lineno=$((lineno + 1))

		body="${line#"${line%%[![:space:]]*}"}" # ltrim
		body="${body%"${body##*[![:space:]]}"}" # rtrim
		[[ -n "$body" ]] || continue

		active=1
		if [[ "$body" == \#* ]]; then
			active=0
			[[ "$include_all" -eq 1 ]] || continue
			# Strip the comment marker and the "[merged]" tag, then see whether
			# an entry is left underneath.
			body="${body#\#}"
			body="${body#"${body%%[![:space:]]*}"}"
			body="${body#\[merged\]}"
			body="${body#"${body%%[![:space:]]*}"}"
		fi

		branch="${body%%[[:space:]]*}"
		rest="${body#"$branch"}"
		rest="${rest#"${rest%%[![:space:]]*}"}"
		number="${rest%%[[:space:]]*}"
		title="${rest#"$number"}"
		title="${title#"${title%%[![:space:]]*}"}"

		if [[ ! "$number" =~ ^#[0-9]+$ ]]; then
			# Only an active line can be malformed. A comment that does not
			# parse as an entry is just a comment.
			if [[ "$strict" -eq 1 && "$active" -eq 1 ]]; then
				[[ "$number" == \#* ]] ||
					die "$plan_file:$lineno: expected \"#<pr-number>\" after branch $branch, got \"$number\""
				die "$plan_file:$lineno: malformed PR number for branch $branch"
			fi
			continue
		fi

		PLAN_BRANCHES+=("$branch")
		PLAN_NUMBERS+=("${number#\#}")
		PLAN_TITLES+=("$title")
		PLAN_ACTIVE+=("$active")
	done <"$plan_file"
}

# comment_out_plan_entry <plan-file> <branch> <pr-number>
#
# Rewrites the plan in place, prefixing the matching active entry with
# "# [merged] " — the marker parse_plan_file strips back off under --all.
# Fails loudly if the entry is not there any more.
comment_out_plan_entry() {
	local plan_file="$1" branch="$2" number="$3"
	local nl=$'\n' buf="" line stripped found=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		stripped="${line#"${line%%[![:space:]]*}"}"
		if [[ "$found" -eq 0 && -n "$stripped" && "$stripped" != \#* &&
			"${stripped%%[[:space:]]*}" == "$branch" && "$stripped" == *"#$number"* ]]; then
			buf+="# [merged] ${line}${nl}"
			found=1
		else
			buf+="${line}${nl}"
		fi
	done <"$plan_file"

	[[ "$found" -eq 1 ]] || die "could not find active plan entry for $branch (#$number) in $plan_file"
	printf '%s' "$buf" >"$plan_file"
}
