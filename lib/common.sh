# shellcheck shell=bash
#
# common.sh — output, errors and git basics, for every entry point.
#
# Sourced, never executed, which is why it has no shebang and is not
# executable. It deliberately does not set shell options: `set -euo pipefail`
# is the entry point's decision, and a sourced file that changed it would be
# reaching into its caller.

# Nothing that sources this may take over the terminal, so colour goes away
# when stdout is not one, and NO_COLOR is exported so the tools we call follow
# suit and log files stay free of escape sequences.
if [[ -t 1 ]]; then
	BOLD=$'\033[1m'
	RESET=$'\033[0m'
else
	BOLD=""
	RESET=""
	export NO_COLOR=1
fi

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

step() {
	printf '\n%s== %s%s\n' "$BOLD" "$*" "$RESET"
}

# Timestamped progress line, for the waiting loops that unattended runs log.
tick() {
	printf '   [%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*"
}

note() {
	printf '   %s\n' "$*"
}

# Name of the currently checked-out branch; dies on detached HEAD.
current_branch() {
	local b
	b="$(git symbolic-ref --short -q HEAD)" ||
		die "detached HEAD — specify a branch explicitly"
	printf '%s' "$b"
}

# branch_sharing_commit <ref>
#
# The one local branch, other than <ref> itself, that points at <ref>'s
# commit. For a working branch kept on the same commit as a stack head (a
# "dev" branch that is never pushed as a PR), this is how the stack head is
# found. Remote-tracking branches are not candidates: the callers verify local
# branches. Dies unless exactly one branch qualifies; with several, the caller
# has to be told which one, so they are listed.
branch_sharing_commit() {
	local ref="$1" commit self candidates=() b
	commit="$(git rev-parse --verify --quiet "$ref^{commit}")" ||
		die "not a commit: $ref"
	self="$(git rev-parse --symbolic-full-name --verify --quiet "$ref" 2>/dev/null || true)"
	while IFS= read -r b; do
		[[ -n "$b" ]] || continue
		[[ "$b" == "$self" ]] && continue
		candidates+=("${b#refs/heads/}")
	done < <(git for-each-ref --points-at "$commit" --format='%(refname)' refs/heads)
	case ${#candidates[@]} in
	0) die "no other local branch points at the commit of $ref (${commit:0:12})" ;;
	1) printf '%s' "${candidates[0]}" ;;
	*)
		printf 'error: %d local branches point at the commit of %s:\n' "${#candidates[@]}" "$ref" >&2
		printf '         %s\n' "${candidates[@]}" >&2
		die "ambiguous — pass --stack <branch> to pick one"
		;;
	esac
}
