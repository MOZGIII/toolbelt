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
