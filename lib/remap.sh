# shellcheck shell=bash
#
# remap.sh — the remap file, shared by the tools that read it.
#
# Format: "<branch-name>  <commit message substring>", one entry per line. The
# first whitespace-delimited token is a PR branch; the rest of the line,
# trimmed, is a substring matched against commit subjects. Blank lines are
# ignored, and so is everything from a "#" on — which is how an entry that has
# landed is retired: `pr-stack advance` comments it out in place with a
# "# [merged] " prefix, and no reader here sees it again.
#
# Two tools read this: pr-stack moves, pushes and rebases the branches the
# file lists, and pr-stack-review-claude reviews them, each against the one
# below it. Both need the same two answers — which branches, and which commit
# each belongs on — so the parsing and the matching live here once.
#
# Needs die() from common.sh.

REMAP_BRANCHES=()
REMAP_PATTERNS=()

# parse_remap_file <remap-file>
#
# Reads the file into the global parallel arrays REMAP_BRANCHES and
# REMAP_PATTERNS. Skips blank/comment lines. Aborts on a line that has a
# branch but no pattern.
parse_remap_file() {
	local remap_file="$1"
	[[ -f "$remap_file" ]] || die "remap file not found: $remap_file"

	REMAP_BRANCHES=()
	REMAP_PATTERNS=()
	local line pr_branch pattern lineno=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		lineno=$((lineno + 1))

		# Strip comments and surrounding whitespace; skip blanks.
		line="${line%%#*}"
		line="${line#"${line%%[![:space:]]*}"}" # ltrim
		line="${line%"${line##*[![:space:]]}"}" # rtrim
		[[ -n "$line" ]] || continue

		# First whitespace-delimited token is the branch; remainder is pattern.
		pr_branch="${line%%[[:space:]]*}"
		pattern="${line#"$pr_branch"}"
		pattern="${pattern#"${pattern%%[![:space:]]*}"}" # ltrim
		[[ -n "$pattern" ]] || die "$remap_file:$lineno: no commit message pattern for branch $pr_branch"

		REMAP_BRANCHES+=("$pr_branch")
		REMAP_PATTERNS+=("$pattern")
	done <"$remap_file"

	[[ ${#REMAP_BRANCHES[@]} -gt 0 ]] || die "no usable entries in remap file: $remap_file"
}

# resolve_remap_commits <base> <branch>
#
# Matches every pattern against the commit subjects in <base>..<branch> and
# fills REMAP_HASHES / REMAP_SUBJECTS, parallel to REMAP_BRANCHES. Each pattern
# must match exactly one commit; anything else is reported and aborts, so
# callers can assume every entry resolved or none did. parse_remap_file must
# have run first.
REMAP_HASHES=()
REMAP_SUBJECTS=()
resolve_remap_commits() {
	local base="$1" branch="$2"

	# Snapshot candidate commits once: "<hash><TAB><subject>" per line.
	local range="$base..$branch"
	local commits
	commits="$(git log --reverse --format='%H%x09%s' "$range")"
	[[ -n "$commits" ]] || die "no commits in range $range"

	REMAP_HASHES=()
	REMAP_SUBJECTS=()
	local errors=0 i pattern matches count hash subject exact exact_count
	for i in "${!REMAP_BRANCHES[@]}"; do
		pattern="${REMAP_PATTERNS[$i]}"

		# Literal substring match against subjects, case sensitive.
		matches="$(printf '%s\n' "$commits" | awk -F'\t' -v p="$pattern" 'index($2, p) { print }')" || true
		count=0
		[[ -n "$matches" ]] && count="$(printf '%s\n' "$matches" | grep -c '')"

		# Several substring matches still resolve when exactly one of them is
		# the whole subject: a later `Revert "<subject>"` contains the original
		# subject without being it, and capture writes full subjects as
		# patterns.
		if [[ "$count" -gt 1 ]]; then
			exact="$(printf '%s\n' "$matches" | awk -F'\t' -v p="$pattern" '$2 == p { print }')" || true
			exact_count=0
			[[ -n "$exact" ]] && exact_count="$(printf '%s\n' "$exact" | grep -c '')"
			if [[ "$exact_count" -eq 1 ]]; then
				matches="$exact"
				count=1
			fi
		fi

		if [[ "$count" -eq 0 ]]; then
			printf 'error: no commit in %s matches "%s" (branch %s)\n' "$range" "$pattern" "${REMAP_BRANCHES[$i]}" >&2
			errors=1; REMAP_HASHES+=("") REMAP_SUBJECTS+=(""); continue
		fi
		if [[ "$count" -gt 1 ]]; then
			printf 'error: %d commits match "%s" (branch %s) — pattern is ambiguous:\n' "$count" "$pattern" "${REMAP_BRANCHES[$i]}" >&2
			printf '%s\n' "$matches" | sed 's/\t/  /;s/^/         /' >&2
			errors=1; REMAP_HASHES+=("") REMAP_SUBJECTS+=(""); continue
		fi

		hash="${matches%%$'\t'*}"
		subject="${matches#*$'\t'}"
		REMAP_HASHES+=("$hash")
		REMAP_SUBJECTS+=("$subject")
	done

	[[ "$errors" -eq 0 ]] || return 1
	return 0
}
