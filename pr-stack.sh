#!/usr/bin/env bash
#
# pr-stack.sh — manage a stack of PR branches from a map file.
#
# In a stacked-PR workflow each PR branch points at a specific commit in a
# stack. A map file records "branch name -> commit message substring":
#
#     # comment lines and blank lines are ignored
#     my-feature-part-1    Add the widget model
#     my-feature-part-2    Wire widget into the API
#
# The first field is the PR branch name; the rest of the line (trimmed) is a
# substring to match against commit subjects.
#
# Subcommands:
#
#   remap [--apply | --check] [--base <ref>] <map-file> <branch>
#       Locate each commit in <base>..<branch> by its message and move (or,
#       without --apply, just print) each PR branch onto its matching commit.
#       With --check nothing is printed as a plan and nothing moves: the exit
#       status reports whether every branch already sits where the map says.
#       Use this after rebasing the stack to snap the PR branches back onto
#       their commits. Each substring must match exactly one commit or the
#       command aborts without touching any branch. A branch checked out in
#       any worktree cannot be moved: it is skipped when it already sits on
#       its matched commit, and aborts the whole remap otherwise.
#
#   push [--remote <name>] [--no-force] [--dry-run] <map-file>
#       Push every branch named in the map to the remote, as-is (no
#       remapping). Verifies all branches exist locally first and aborts if
#       any are missing. Uses --force-with-lease unless --no-force is given.
#
#   capture [--base <ref>] [--output <file>] [--include-head] <branch>
#       The inverse of remap: reconstruct a map file from an existing stack.
#       Walks <base>..<branch> and, for each commit, records any local branch
#       that points at it (using the commit subject as the pattern). Handy
#       for snapshotting a stack you built by hand before a rebase. The
#       stack head branch itself is excluded unless --include-head is given.
#
#   advance [--remote <name>] [--base <branch>] <map-file>
#       Fast-forward the local base branch from the remote, then comment out
#       every map entry whose branch has landed in the base: either its tip
#       is an ancestor of the base (merge commit / fast-forward), or its
#       pattern matches a commit subject in the newly pulled range (rebase
#       or squash merges, where hashes are rewritten but subjects survive).
#
set -euo pipefail

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# Name of the currently checked-out branch; dies on detached HEAD.
current_branch() {
	local b
	b="$(git symbolic-ref --short -q HEAD)" ||
		die "detached HEAD — specify a branch explicitly"
	printf '%s' "$b"
}

usage() {
	cat >&2 <<'EOF'
Usage: pr-stack.sh <command> [options] <map-file> [args]

Commands:
  remap [--apply | --check] [--base <ref>] <map-file> [<branch>]
        Move each PR branch onto the commit whose subject matches its map
        pattern in <base>..<branch> (default base: main, branch: current).
        Without --apply, only prints the plan (dry run). With --check, exits
        nonzero unless every branch is already on its matched commit.

  push [--remote <name>] [--no-force] [--dry-run] <map-file>
        Push every branch in the map to <remote> (default: origin) as-is.
        Verifies all branches exist locally first. Uses --force-with-lease
        unless --no-force is given.

  capture [--base <ref>] [--output <file>] [--include-head] [<branch>]
        Build a map from an existing stack: for each commit in
        <base>..<branch> (default branch: current), record any local branch
        whose tip is that commit, using the commit subject as its pattern.
        The head branch itself is excluded unless --include-head is given.
        Writes to <file> or stdout.

  advance [--remote <name>] [--base <branch>] <map-file>
        Fast-forward local <base> (default: main) from <remote> (default:
        origin), then comment out map entries whose branches are now part
        of <base> (by ancestry, or by subject match in the pulled range).

  rebase [--base <ref>] [--branch <b>] [--map <file>] [--exec <cmd>]
         [--no-edit] [--dry-run]
        Rebase the stack onto <base> with --update-refs, so every PR branch
        in the range is carried along instead of being left behind. The todo
        opens in your editor as any interactive rebase would — with the exec
        lines already injected, so what you review is what will run, and you
        can reorder, drop or edit any of it. Quitting the editor with an
        error calls the rebase off. --no-edit skips the review, for
        unattended runs (and is required when there is no terminal).

        With --exec (-x), the command additionally runs once per PR rather
        than once per commit, as "git rebase --exec" would: only at each PR
        tip. It goes through the same interactive rebase either way — this
        script only supplies the todo list, so git does the walking, the
        stopping and the resuming. The command is told nothing about which
        branch it is at, because a commit can carry several. Ask git for
        them if you need them, with "git for-each-ref --points-at HEAD
        refs/heads" — though that only answers while picks fast-forward;
        rewritten commits have no branch on them until the rebase ends.

        PR tips come from local branch tips in the range by default; pass
        --map to take them from a map file instead, which is what you want
        when branches have drifted off their commits. --dry-run prints the
        plan without rebasing.

        Commit hashes survive when the stack already sits on <base> (the
        picks fast-forward); they are rewritten only when the rebase has
        real work to do, as any rebase onto a moved base would.

Map file: one entry per line, "<branch-name>  <commit message substring>".
Blank lines and "#" comments are ignored.
EOF
	exit "${1:-0}"
}

# parse_map_file <map-file>
#
# Reads the map into the global parallel arrays MAP_BRANCHES and MAP_PATTERNS.
# Skips blank/comment lines. Aborts on a line that has a branch but no pattern.
MAP_BRANCHES=()
MAP_PATTERNS=()
parse_map_file() {
	local map_file="$1"
	[[ -f "$map_file" ]] || die "map file not found: $map_file"

	MAP_BRANCHES=()
	MAP_PATTERNS=()
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
		[[ -n "$pattern" ]] || die "$map_file:$lineno: no commit message pattern for branch $pr_branch"

		MAP_BRANCHES+=("$pr_branch")
		MAP_PATTERNS+=("$pattern")
	done <"$map_file"

	[[ ${#MAP_BRANCHES[@]} -gt 0 ]] || die "no usable entries in map file: $map_file"
}

# resolve_map_commits <base> <branch>
#
# Matches every map pattern against the commit subjects in <base>..<branch> and
# fills PLAN_HASHES / PLAN_SUBJECTS, parallel to MAP_BRANCHES. Each pattern must
# match exactly one commit; anything else is reported and aborts, so callers can
# assume a resolved plan or no plan at all. parse_map_file must have run first.
PLAN_HASHES=()
PLAN_SUBJECTS=()
resolve_map_commits() {
	local base="$1" branch="$2"

	# Snapshot candidate commits once: "<hash><TAB><subject>" per line.
	local range="$base..$branch"
	local commits
	commits="$(git log --reverse --format='%H%x09%s' "$range")"
	[[ -n "$commits" ]] || die "no commits in range $range"

	PLAN_HASHES=()
	PLAN_SUBJECTS=()
	local errors=0 i pattern matches count hash subject
	for i in "${!MAP_BRANCHES[@]}"; do
		pattern="${MAP_PATTERNS[$i]}"

		# Literal substring match against subjects, case sensitive.
		matches="$(printf '%s\n' "$commits" | awk -F'\t' -v p="$pattern" 'index($2, p) { print }')" || true
		count=0
		[[ -n "$matches" ]] && count="$(printf '%s\n' "$matches" | grep -c '')"

		if [[ "$count" -eq 0 ]]; then
			printf 'error: no commit in %s matches "%s" (branch %s)\n' "$range" "$pattern" "${MAP_BRANCHES[$i]}" >&2
			errors=1; PLAN_HASHES+=("") PLAN_SUBJECTS+=(""); continue
		fi
		if [[ "$count" -gt 1 ]]; then
			printf 'error: %d commits match "%s" (branch %s) — pattern is ambiguous:\n' "$count" "$pattern" "${MAP_BRANCHES[$i]}" >&2
			printf '%s\n' "$matches" | sed 's/\t/  /;s/^/         /' >&2
			errors=1; PLAN_HASHES+=("") PLAN_SUBJECTS+=(""); continue
		fi

		hash="${matches%%$'\t'*}"
		subject="${matches#*$'\t'}"
		PLAN_HASHES+=("$hash")
		PLAN_SUBJECTS+=("$subject")
	done

	[[ "$errors" -eq 0 ]] || return 1
	return 0
}

cmd_remap() {
	local base="main" apply=0 check=0
	local positional=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--apply) apply=1; shift ;;
		--check) check=1; shift ;;
		--base) base="${2:-}"; [[ -n "$base" ]] || die "--base requires a value"; shift 2 ;;
		-h | --help) usage 0 ;;
		--) shift; while [[ $# -gt 0 ]]; do positional+=("$1"); shift; done ;;
		-*) die "unknown option: $1" ;;
		*) positional+=("$1"); shift ;;
		esac
	done
	[[ "$apply" -eq 0 || "$check" -eq 0 ]] || die "--check and --apply are mutually exclusive"
	[[ ${#positional[@]} -ge 1 && ${#positional[@]} -le 2 ]] || usage 1
	local map_file="${positional[0]}"
	local branch="${positional[1]:-$(current_branch)}"

	git rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "base ref not found: $base"
	git rev-parse --verify --quiet "$branch^{commit}" >/dev/null || die "branch not found: $branch"

	parse_map_file "$map_file"

	local range="$base..$branch"
	resolve_map_commits "$base" "$branch" ||
		die "aborting: some patterns did not match exactly one commit (no branches were moved)"
	local plan_hashes=("${PLAN_HASHES[@]}") plan_subjects=("${PLAN_SUBJECTS[@]}")
	local errors=0 i

	# `git branch -f` refuses to move a branch checked out in any worktree.
	# Tolerate such branches only when they already sit on their planned commit.
	local checked_out
	checked_out="$(git worktree list --porcelain |
		awk '$1 == "branch" { sub("^refs/heads/", "", $2); print $2 }')"

	local plan_skips=()
	for i in "${!MAP_BRANCHES[@]}"; do
		if printf '%s\n' "$checked_out" | grep -qxF "${MAP_BRANCHES[$i]}" &&
			git show-ref --verify --quiet "refs/heads/${MAP_BRANCHES[$i]}"; then
			if [[ "$(git rev-parse "refs/heads/${MAP_BRANCHES[$i]}")" == "${plan_hashes[$i]}" ]]; then
				plan_skips+=(1)
			else
				printf 'error: branch %s is checked out and not on its matched commit %s\n' \
					"${MAP_BRANCHES[$i]}" "${plan_hashes[$i]:0:12}" >&2
				errors=1; plan_skips+=(0)
			fi
		else
			plan_skips+=(0)
		fi
	done
	[[ "$errors" -eq 0 ]] || die "aborting: checked-out branch(es) would need to move (no branches were moved)"

	# --check: report whether every branch already sits on its matched commit,
	# without moving anything. Exit status is the answer.
	if [[ "$check" -eq 1 ]]; then
		local stale=()
		for i in "${!MAP_BRANCHES[@]}"; do
			if ! git show-ref --verify --quiet "refs/heads/${MAP_BRANCHES[$i]}"; then
				stale+=("${MAP_BRANCHES[$i]}: missing locally, expected ${plan_hashes[$i]:0:12}")
			elif [[ "$(git rev-parse "refs/heads/${MAP_BRANCHES[$i]}")" != "${plan_hashes[$i]}" ]]; then
				stale+=("${MAP_BRANCHES[$i]}: at $(git rev-parse --short=12 "refs/heads/${MAP_BRANCHES[$i]}"), expected ${plan_hashes[$i]:0:12}  (${plan_subjects[$i]})")
			fi
		done
		if [[ ${#stale[@]} -gt 0 ]]; then
			printf 'error: %d branch(es) are not on their mapped commit in %s:\n' "${#stale[@]}" "$range" >&2
			printf '         %s\n' "${stale[@]}" >&2
			die "aborting: run 'remap --apply' to fix"
		fi
		printf 'All %d mapped branch(es) are on their matched commits in %s.\n' "${#MAP_BRANCHES[@]}" "$range"
		return 0
	fi

	printf 'Remap plan for stack %s (base %s):\n\n' "$branch" "$base"
	for i in "${!MAP_BRANCHES[@]}"; do
		printf '  %-48s -> %s  %s%s\n' "${MAP_BRANCHES[$i]}" "${plan_hashes[$i]:0:12}" "${plan_subjects[$i]}" \
			"$([[ "${plan_skips[$i]}" -eq 1 ]] && printf '  [checked out, already in place]')"
	done
	printf '\n'

	if [[ "$apply" -eq 0 ]]; then
		printf 'Dry run — re-run with --apply to move these branches.\n'
		return 0
	fi

	local moved=0
	for i in "${!MAP_BRANCHES[@]}"; do
		if [[ "${plan_skips[$i]}" -eq 1 ]]; then
			printf 'skipped %s (checked out, already at %s)\n' "${MAP_BRANCHES[$i]}" "${plan_hashes[$i]:0:12}"
			continue
		fi
		git branch -f "${MAP_BRANCHES[$i]}" "${plan_hashes[$i]}"
		printf 'moved %s -> %s\n' "${MAP_BRANCHES[$i]}" "${plan_hashes[$i]:0:12}"
		moved=$((moved + 1))
	done
	printf '\nDone. %d branch(es) remapped.\n' "$moved"
}

# ---------------------------------------------------------------------------
# exec
# ---------------------------------------------------------------------------

# Absolute path to this script, so the rebase can call back into it as its
# sequence editor.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# cmd_todo_edit <todo-file>
#
# The sequence editor half of `rebase`: git hands us the todo, we hand it back
# with an `exec` line after each PR tip, then hand it on to the editor the user
# would have got anyway. Not meant to be run by hand.
#
# Its inputs arrive through the environment rather than argv, because git
# appends the todo path to whatever GIT_SEQUENCE_EDITOR says and an editor
# command is itself a shell string — nesting one inside the other survives
# neither quoting nor an editor with spaces in its path:
#
#   PR_STACK_SPEC     file of boundary commit hashes, one per line; empty for
#                     a plain rebase with nothing to inject
#   PR_STACK_COMMAND  the command to run at each of them
#   PR_STACK_EDITOR   the real sequence editor; empty to skip editing
#
# Boundaries are commits, not branches, and the command is told nothing about
# which refs happen to sit on one. A commit can carry any number of branches —
# the stack head always shares its commit with the topmost PR branch — so there
# is no "the branch for this commit" to hand over. A command that wants the
# names asks git for them itself, where it sees all of them rather than one
# picked for it:
#
#     -x 'git for-each-ref --points-at HEAD --format="%(refname:short)" refs/heads'
#
# With the caveat that this answers only while the rebase is fast-forwarding
# picks it does not need to rewrite. Once commits are genuinely rewritten the
# branches still point at their pre-rebase commits — --update-refs applies the
# whole set at the end — so nothing points at HEAD yet and the query comes back
# empty. Checking an already-based stack sees its refs; rebasing onto a moved
# base does not.
#
# Todo lines name commits abbreviated, so each pick is resolved back to a full
# hash before it is looked up — abbreviations are not stable enough to compare
# as text.
#
# The exec goes immediately after its pick, ahead of any `update-ref` lines
# --update-refs put there. Those lines do not move a branch when they are
# reached: git only records the intended update and applies the whole set once
# the rebase completes, so during the exec the PR branch still points at its
# pre-rebase commit either way. With the ref values identical, the exec belongs
# next to the commit it is about.
cmd_todo_edit() {
	local todo_file="$1"
	local spec_file="${PR_STACK_SPEC:-}" editor="${PR_STACK_EDITOR:-}"
	local command="${PR_STACK_COMMAND:-}"

	if [[ -z "$spec_file" ]]; then
		# Plain rebase: nothing to inject, straight on to the editor.
		run_todo_editor "$editor" "$todo_file"
		return $?
	fi

	local -A is_boundary=()
	local hash line

	while read -r hash; do
		[[ -n "$hash" ]] || continue
		is_boundary["$hash"]=1
	done <"$spec_file"

	local out="" nl=$'\n' verb rest full
	while IFS= read -r line || [[ -n "$line" ]]; do
		out+="$line$nl"

		verb="${line%%[[:space:]]*}"
		[[ "$verb" == "pick" || "$verb" == "p" ]] || continue

		rest="${line#"$verb"}"
		rest="${rest#"${rest%%[![:space:]]*}"}"
		full="$(git rev-parse --verify --quiet "${rest%%[[:space:]]*}^{commit}" || true)"
		[[ -n "$full" && -n "${is_boundary[$full]:-}" ]] || continue

		out+="exec $command$nl"
	done <"$todo_file"

	printf '%s' "$out" >"$todo_file"

	# The user reviews the todo *after* the execs are in it, so what they
	# approve is what actually runs — and they can still reorder, drop or edit
	# any of it, exec lines included.
	run_todo_editor "$editor" "$todo_file"
}

# run_todo_editor <editor> <todo-file>
#
# Hands the todo to the real sequence editor, the way git would have. An empty
# editor means --no-edit: leave the file alone. A non-zero exit propagates, and
# git treats that as "abort the rebase" — which makes quitting the editor with
# an error the natural way to call the whole thing off.
run_todo_editor() {
	local editor="$1" todo_file="$2"
	[[ -n "$editor" ]] || return 0
	# "$editor" is a command line, not a program name, so it goes through a
	# shell — same as git does it.
	sh -c "$editor \"\$@\"" "$editor" "$todo_file"
}

# collect_boundaries <base> <branch> [<map-file>]
#
# Works out which commits in <base>..<branch> are PR tips, filling
# BOUNDARY_LABEL_AT (hash -> branch name(s)) alongside RANGE_HASHES /
# RANGE_SUBJECTS for the whole range in rebase order.
#
# With a map file the tips come from the map, which is the authority when
# branches have drifted off their commits. Without one they come from git
# itself: any local branch whose tip is a commit in the range is a PR tip. That
# covers the ordinary case — a stack whose branches are where the map would put
# them anyway — without asking for a file to say so. The stack head is included,
# so a command also runs at the top of the stack.
declare -A BOUNDARY_LABEL_AT=()
RANGE_HASHES=()
RANGE_SUBJECTS=()
collect_boundaries() {
	local base="$1" branch="$2" map_file="${3:-}"

	BOUNDARY_LABEL_AT=()
	RANGE_HASHES=()
	RANGE_SUBJECTS=()

	if [[ -n "$map_file" ]]; then
		parse_map_file "$map_file"
		resolve_map_commits "$base" "$branch" ||
			die "aborting: some patterns did not match exactly one commit (nothing was rebased)"
		local i
		for i in "${!MAP_BRANCHES[@]}"; do
			BOUNDARY_LABEL_AT["${PLAN_HASHES[$i]}"]="${MAP_BRANCHES[$i]}"
		done
	else
		local hash name
		while read -r hash name; do
			[[ -n "$hash" ]] || continue
			# Several branches can share a commit; keep them all, space
			# separated, rather than picking a winner arbitrarily.
			BOUNDARY_LABEL_AT["$hash"]="${BOUNDARY_LABEL_AT[$hash]:+${BOUNDARY_LABEL_AT[$hash]} }$name"
		done < <(git for-each-ref --format='%(objectname) %(refname:short)' refs/heads)
	fi

	local hash subject
	while IFS=$'\t' read -r hash subject; do
		RANGE_HASHES+=("$hash")
		RANGE_SUBJECTS+=("$subject")
	done < <(git log --reverse --format='%H%x09%s' "$base..$branch")

	[[ ${#RANGE_HASHES[@]} -gt 0 ]] || die "no commits in range $base..$branch"
}

cmd_rebase() {
	local base="main" branch="" map_file="" command="" dry_run=0 no_edit=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--base) base="${2:-}"; [[ -n "$base" ]] || die "--base requires a value"; shift 2 ;;
		--branch) branch="${2:-}"; [[ -n "$branch" ]] || die "--branch requires a value"; shift 2 ;;
		--map) map_file="${2:-}"; [[ -n "$map_file" ]] || die "--map requires a value"; shift 2 ;;
		--exec | -x) command="${2:-}"; [[ -n "$command" ]] || die "--exec requires a command"; shift 2 ;;
		--no-edit) no_edit=1; shift ;;
		--dry-run) dry_run=1; shift ;;
		-h | --help) usage 0 ;;
		-*) die "unknown option: $1" ;;
		*) die "unexpected argument: $1 (the command goes in --exec)" ;;
		esac
	done

	[[ "$command" != *$'\n'* ]] || die "--exec must be a single line (rebase todo entries are line-based)"

	[[ -n "$branch" ]] || branch="$(current_branch)"
	git rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "base ref not found: $base"
	git rev-parse --verify --quiet "$branch^{commit}" >/dev/null || die "branch not found: $branch"
	[[ -z "$(git status --porcelain --untracked-files=no)" ]] ||
		die "worktree has modified tracked files — rebase needs a clean tree"

	collect_boundaries "$base" "$branch" "$map_file"

	local spec=""
	if [[ -n "$command" ]]; then
		spec="$(mktemp)"
		# shellcheck disable=SC2064  # $spec is expanded now on purpose.
		trap "rm -f '$spec'" EXIT
	fi

	local source_desc="boundaries from branch tips in the range"
	[[ -n "$map_file" ]] && source_desc="boundaries from $map_file"
	printf 'Rebase plan for %s onto %s (%s):\n\n' "$branch" "$base" "$source_desc"

	local i hash n=0
	for i in "${!RANGE_HASHES[@]}"; do
		hash="${RANGE_HASHES[$i]}"
		printf '  %s  %s\n' "${hash:0:12}" "${RANGE_SUBJECTS[$i]}"
		[[ -n "${BOUNDARY_LABEL_AT[$hash]:-}" ]] || continue
		n=$((n + 1))
		# The labels are here to show which PR a boundary is; they are not
		# passed to the command, which is told about a commit, not a branch.
		printf '        ^ %s\n' "${BOUNDARY_LABEL_AT[$hash]}"
		if [[ -n "$command" ]]; then
			printf '%s\n' "$hash" >>"$spec"
			printf '        exec %s\n' "$command"
		fi
	done

	if [[ -n "$command" ]]; then
		printf '\n%d PR boundary(ies) will run the command.\n' "$n"
		[[ "$n" -gt 0 ]] || die "no PR tip found in $base..$branch — nothing would run"
	else
		printf '\n%d PR branch(es) in range; --update-refs will carry them along.\n' "$n"
	fi

	if [[ "$dry_run" -eq 1 ]]; then
		printf '\nDry run — re-run without --dry-run to rebase.\n'
		return 0
	fi

	# Resolve the editor git would have used *before* taking its place, so the
	# whole precedence chain (GIT_SEQUENCE_EDITOR, sequence.editor, core.editor,
	# GIT_EDITOR, EDITOR, …) is honoured rather than reimplemented. Asking for
	# it later, from inside our own sequence editor, would just find us.
	local real_editor=""
	if [[ "$no_edit" -eq 0 ]]; then
		real_editor="$(git var GIT_SEQUENCE_EDITOR)"
		[[ -t 0 ]] ||
			die "not a terminal: the todo cannot be reviewed here — re-run with --no-edit to rebase unattended"
	fi

	printf '\nRebasing %s onto %s with --update-refs.\n' "$branch" "$base"
	[[ -n "$command" ]] &&
		printf 'A failing command stops the rebase mid-flight; fix and "git rebase --continue", or "git rebase --abort".\n'
	[[ -n "$real_editor" ]] &&
		printf 'The todo opens for review with the exec lines already in it; quit the editor with an error to call it off.\n'
	printf '\n'

	# Always the interactive machinery, with or without --exec, so the two
	# modes cannot drift apart: same walk, same --update-refs, same resume
	# behaviour, same chance to inspect the todo.
	#
	# --update-refs is what keeps this usable on a stack: every PR branch is
	# carried onto its commit, so the map still describes reality afterwards.
	# When the stack already sits on <base> the picks fast-forward and the
	# hashes survive untouched; they are only rewritten if the rebase has real
	# work to do, exactly as any other rebase onto a moved base would.
	PR_STACK_SPEC="$spec" PR_STACK_COMMAND="$command" PR_STACK_EDITOR="$real_editor" \
		GIT_SEQUENCE_EDITOR="'$SELF' __todo-edit" \
		git rebase --interactive --update-refs --no-autosquash "$base" "$branch"
}

cmd_push() {
	local remote="origin" dry_run=0 force=1
	local positional=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--remote) remote="${2:-}"; [[ -n "$remote" ]] || die "--remote requires a value"; shift 2 ;;
		--no-force) force=0; shift ;;
		--dry-run) dry_run=1; shift ;;
		-h | --help) usage 0 ;;
		--) shift; while [[ $# -gt 0 ]]; do positional+=("$1"); shift; done ;;
		-*) die "unknown option: $1" ;;
		*) positional+=("$1"); shift ;;
		esac
	done
	[[ ${#positional[@]} -eq 1 ]] || usage 1
	local map_file="${positional[0]}"

	parse_map_file "$map_file"

	# Verify every branch exists locally before pushing anything.
	local missing=() i
	for i in "${!MAP_BRANCHES[@]}"; do
		git show-ref --verify --quiet "refs/heads/${MAP_BRANCHES[$i]}" ||
			missing+=("${MAP_BRANCHES[$i]}")
	done
	if [[ ${#missing[@]} -gt 0 ]]; then
		printf 'error: %d branch(es) from the map are missing locally:\n' "${#missing[@]}" >&2
		printf '         %s\n' "${missing[@]}" >&2
		die "aborting: nothing was pushed (run 'remap --apply' first?)"
	fi

	local push_opts=()
	[[ "$force" -eq 1 ]] && push_opts+=(--force-with-lease)

	printf 'Pushing %d branch(es) to %s%s:\n' "${#MAP_BRANCHES[@]}" "$remote" \
		"$([[ "$force" -eq 1 ]] && printf ' (--force-with-lease)')"
	for i in "${!MAP_BRANCHES[@]}"; do
		printf '  %s\n' "${MAP_BRANCHES[$i]}"
	done
	printf '\n'

	if [[ "$dry_run" -eq 1 ]]; then
		printf 'Dry run — re-run without --dry-run to push.\n'
		return 0
	fi

	git push "${push_opts[@]}" "$remote" "${MAP_BRANCHES[@]}"
	printf '\nDone. %d branch(es) pushed.\n' "${#MAP_BRANCHES[@]}"
}

cmd_capture() {
	local base="main" output="" include_head=0
	local positional=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--base) base="${2:-}"; [[ -n "$base" ]] || die "--base requires a value"; shift 2 ;;
		--include-head) include_head=1; shift ;;
		-o | --output) output="${2:-}"; [[ -n "$output" ]] || die "--output requires a value"; shift 2 ;;
		-h | --help) usage 0 ;;
		--) shift; while [[ $# -gt 0 ]]; do positional+=("$1"); shift; done ;;
		-*) die "unknown option: $1" ;;
		*) positional+=("$1"); shift ;;
		esac
	done
	[[ ${#positional[@]} -le 1 ]] || usage 1
	local branch="${positional[0]:-$(current_branch)}"

	git rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "base ref not found: $base"
	git rev-parse --verify --quiet "$branch^{commit}" >/dev/null || die "branch not found: $branch"

	# The base is always excluded from the captured keys; the stack branch
	# itself (resolved to its name even if passed as HEAD) is excluded unless
	# --include-head is given.
	local self_name
	self_name="$(git rev-parse --abbrev-ref "$branch")"

	local range="$base..$branch"
	local commits
	commits="$(git log --reverse --format='%H%x09%s' "$range")"
	[[ -n "$commits" ]] || die "no commits in range $range"

	# Walk each commit oldest-first; record every local branch pointing at it.
	local cap_branches=() cap_subjects=()
	local width=0 hash subject b
	while IFS=$'\t' read -r hash subject; do
		while IFS= read -r b; do
			[[ -n "$b" ]] || continue
			[[ "$b" == "$base" ]] && continue
			[[ "$include_head" -eq 0 && "$b" == "$self_name" ]] && continue
			cap_branches+=("$b")
			cap_subjects+=("$subject")
			[[ ${#b} -gt $width ]] && width=${#b}
		done < <(git branch --points-at "$hash" --format='%(refname:short)')
	done < <(printf '%s\n' "$commits")

	[[ ${#cap_branches[@]} -gt 0 ]] || die "no local branches point at commits in $range"

	# Render the map to a buffer, then emit to stdout or the output file.
	# Build with explicit newlines — $() would strip trailing ones.
	local nl=$'\n'
	local buf="# PR stack map for ${self_name} (base ${base})${nl}"
	buf+="#${nl}"
	buf+="# Format: <branch-name>  <commit-subject>${nl}"
	buf+="# Generated by pr-stack capture.${nl}${nl}"
	local i
	for i in "${!cap_branches[@]}"; do
		buf+="$(printf '%-*s  %s' "$width" "${cap_branches[$i]}" "${cap_subjects[$i]}")${nl}"
	done

	if [[ -n "$output" ]]; then
		printf '%s' "$buf" >"$output"
		printf 'Captured %d branch(es) from %s -> %s\n' "${#cap_branches[@]}" "$range" "$output" >&2
	else
		printf '%s' "$buf"
	fi
}

cmd_advance() {
	local base="main" remote="origin"
	local positional=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--remote) remote="${2:-}"; [[ -n "$remote" ]] || die "--remote requires a value"; shift 2 ;;
		--base) base="${2:-}"; [[ -n "$base" ]] || die "--base requires a value"; shift 2 ;;
		-h | --help) usage 0 ;;
		--) shift; while [[ $# -gt 0 ]]; do positional+=("$1"); shift; done ;;
		-*) die "unknown option: $1" ;;
		*) positional+=("$1"); shift ;;
		esac
	done
	[[ ${#positional[@]} -eq 1 ]] || usage 1
	local map_file="${positional[0]}"
	[[ -f "$map_file" ]] || die "map file not found: $map_file"

	git show-ref --verify --quiet "refs/heads/$base" || die "base branch not found locally: $base"

	local old_tip
	old_tip="$(git rev-parse "refs/heads/$base")"

	# Bring the base up to date. Both paths are fast-forward-only: pull when the
	# base is checked out, an in-place fetch otherwise (refuses non-ff updates).
	local head_branch
	head_branch="$(git symbolic-ref --short -q HEAD || true)"
	if [[ "$head_branch" == "$base" ]]; then
		git pull --ff-only "$remote" "$base" ||
			die "could not fast-forward $base from $remote (diverged or fetch failed)"
	else
		git fetch "$remote" "$base:$base" ||
			die "could not fast-forward $base from $remote (diverged or fetch failed)"
	fi

	local new_tip
	new_tip="$(git rev-parse "refs/heads/$base")"
	if [[ "$old_tip" == "$new_tip" ]]; then
		printf '%s is up to date at %s.\n' "$base" "${new_tip:0:12}"
	else
		printf 'Advanced %s: %s -> %s\n' "$base" "${old_tip:0:12}" "${new_tip:0:12}"
	fi

	# Subjects of the commits that just arrived, for matching rebase/squash
	# merges whose branch tips are not ancestors of the base.
	local new_subjects=""
	[[ "$old_tip" != "$new_tip" ]] && new_subjects="$(git log --format='%s' "$old_tip..$new_tip")"

	# Rewrite the map: comment out entries whose branch has landed in the base.
	local nl=$'\n' buf="" merged_branches=()
	local line stripped pr_branch pattern lineno=0 merged
	while IFS= read -r line || [[ -n "$line" ]]; do
		lineno=$((lineno + 1))

		stripped="${line%%#*}"
		stripped="${stripped#"${stripped%%[![:space:]]*}"}" # ltrim
		stripped="${stripped%"${stripped##*[![:space:]]}"}" # rtrim
		if [[ -z "$stripped" ]]; then
			buf+="${line}${nl}"
			continue
		fi

		pr_branch="${stripped%%[[:space:]]*}"
		pattern="${stripped#"$pr_branch"}"
		pattern="${pattern#"${pattern%%[![:space:]]*}"}" # ltrim
		[[ -n "$pattern" ]] || die "$map_file:$lineno: no commit message pattern for branch $pr_branch"

		merged=0
		if git show-ref --verify --quiet "refs/heads/$pr_branch" &&
			git merge-base --is-ancestor "$pr_branch" "refs/heads/$base"; then
			merged=1
		elif [[ -n "$new_subjects" ]] &&
			printf '%s\n' "$new_subjects" | awk -v p="$pattern" 'index($0, p) { found = 1 } END { exit !found }'; then
			merged=1
		fi

		if [[ "$merged" -eq 1 ]]; then
			buf+="# [merged] ${line}${nl}"
			merged_branches+=("$pr_branch")
		else
			buf+="${line}${nl}"
		fi
	done <"$map_file"

	if [[ ${#merged_branches[@]} -eq 0 ]]; then
		printf 'No map entries are merged into %s; %s left untouched.\n' "$base" "$map_file"
		return 0
	fi

	printf '%s' "$buf" >"$map_file"
	printf 'Commented out %d merged branch(es) in %s:\n' "${#merged_branches[@]}" "$map_file"
	printf '  %s\n' "${merged_branches[@]}"
}

[[ $# -gt 0 ]] || usage 1
command="$1"
shift
case "$command" in
remap) cmd_remap "$@" ;;
push) cmd_push "$@" ;;
capture) cmd_capture "$@" ;;
advance) cmd_advance "$@" ;;
rebase) cmd_rebase "$@" ;;
# Internal: git calls this back as the rebase sequence editor.
__todo-edit) cmd_todo_edit "$@" ;;
-h | --help) usage 0 ;;
*) die "unknown command: $command (expected 'remap', 'push', 'capture', 'advance', or 'rebase')" ;;
esac
