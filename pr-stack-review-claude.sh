#!/usr/bin/env bash
#
# pr-stack-review-claude.sh — run a Claude Code review over one PR branch, or
# over a whole merge-order plan, one branch at a time.
#
# The script owns the git worktree it runs in: it checks out each branch under
# review, so anything else you are doing must happen in another worktree. The
# original branch is restored when the run finishes (--no-restore to stay on
# the last reviewed branch).
#
# What a branch is reviewed *against* is its parent in the stack, not the
# trunk: in a chained stack every PR's base is the previous PR's branch, so
# reviewing against the trunk would re-review everything underneath it. In
# plan mode the parent is the preceding entry in the plan file (merged ones
# included, since they are still the chain), and the bottom entry falls back
# to the trunk. --base overrides it for a single branch.
#
# Each branch gets a directory under the output directory, named
# "<pr-number>-<branch-slug>" so a listing sorts into merge order. Inside it,
# every review is a numbered run of its own — nothing is ever overwritten, so a
# re-review can be read against the one it supersedes — with a "latest" symlink
# onto the newest:
#
#   .reviews/493-mzg-2026-07-23-transient-bringup-refactor/
#       001/ …          first review
#       002/ …          re-review, e.g. after a push or a prompt change
#       latest -> 002
#
# The symlink moves when a run starts rather than when it finishes, so
# latest/output.jsonl can be tailed live. Each run directory holds four
# fixed-name files:
#
#   output.jsonl the full conversation as stream-json: one event per thinking
#                block, tool call, tool result, and the closing usage tally —
#                the record of how the review reached its conclusion;
#   debug.log    Claude Code's own instrumentation — settings and plugin
#                loading, API requests and their timing, hook firing. Disjoint
#                from output.jsonl: it holds none of the conversation, and the
#                transcript holds none of the internals;
#   review.md    the review itself — Claude writes this file, the prompt tells
#                it where;
#   verdict      a machine-readable "true" or "false": is this PR ready to
#                merge. Also written by Claude, also per the prompt.
#
# The latest run's verdict file doubles as the completion marker: a branch
# whose newest run decided something is skipped unless --force is given, so a
# plan run that dies halfway through resumes where it stopped, and --force
# means "review it again into a new run", never "overwrite what is there".
#
# The prompt is a template file (default: prompts/code-review.md next to this
# script) with these placeholders substituted before the run:
#
#   {{BRANCH}}       branch under review
#   {{BASE}}         branch it is reviewed against (its parent in the stack)
#   {{RANGE}}        "<base>..<branch>", ready for git log / git diff
#   {{PR}}           PR number without the "#", empty when unknown
#   {{TITLE}}        PR title, empty when unknown
#   {{REPO_ROOT}}    absolute path of the worktree
#   {{REVIEW_FILE}}  absolute path the review must be written to
#   {{VERDICT_FILE}} absolute path the verdict must be written to
#
# Subcommands:
#
#   review [options] <branch>
#       Review one branch. --plan <file> looks the branch up in a plan file to
#       pick up its PR number, title and parent.
#
#   review-all [options] <plan-file>
#       Review every active entry in the plan, bottom first, skipping the ones
#       already reviewed. Stops at the first failure unless --keep-going.
#
#   status [options] <plan-file>
#       Show which plan entries have been reviewed and what they came back
#       with. Touches neither git nor Claude.
#
# Plan file format is pr-stack-merge-gh.sh's: "<branch>  #<pr-number>
# <pr-title>", one per line, whole-line "#" comments. Entries commented out as
# merged are still read, because they are still part of the base chain.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE_DEFAULT="$SCRIPT_DIR/prompts/code-review.md"

# Reviews run unattended, so nothing may take over the terminal or wait for
# input. Drop colour when stdout is redirected so logs stay clean.
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

note() {
	printf '   %s\n' "$*"
}

tick() {
	printf '   [%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*"
}

require_tools() {
	command -v claude >/dev/null || die "claude (Claude Code CLI) is required but not on PATH"
	command -v git >/dev/null || die "git is required but not on PATH"
	# jq only renders the live view; the transcript is captured either way.
	command -v jq >/dev/null ||
		printf 'note: jq is not on PATH — reviews still run, but there is no live progress to watch\n' >&2
}

usage() {
	cat >&2 <<'EOF'
Usage: pr-stack-review-claude.sh <command> [options] [args]

Commands:
  review [options] [--plan <file>] [--base <branch>] <branch>
        Review one branch against its parent. Without --plan the parent is
        --base (default: the trunk) and the output files are named after
        the branch alone; with --plan the PR number, title and parent
        branch come from the plan file.

  review-all [options] [--max <n>] [--keep-going] <plan-file>
        Review every not-yet-reviewed active entry in the plan, bottom
        first. Stops at the first failure so nothing is silently skipped;
        --keep-going records the failure and carries on. Re-run to resume.
        A branch whose verdict file is missing or unreadable counts as
        not reviewed, so a run that went wrong is retried rather than
        quietly accepted.

  status [--output-dir <dir>] <plan-file>
        Print each plan entry with its review state and verdict.

Options (review, review-all):
  --trunk <branch>     what the bottom plan entry is reviewed against
                       (default: main)
  --output-dir <dir>   where the per-branch review directories go
                       (default: <repo-root>/.reviews). Each holds one
                       numbered directory per run (001, 002, …) plus a
                       "latest" symlink; a run holds output.jsonl, debug.log,
                       review.md and verdict.
  --prompt-file <path> prompt template (default: prompts/code-review.md
                       next to this script)
  --model <name>       passed to claude --model (default: fable); pass an
                       empty string to leave the model unset and take
                       whatever claude defaults to
  --effort <level>     passed to claude --effort
  --permission-mode <mode>
                       passed to claude --permission-mode
                       (default: acceptEdits)
  --allow <tool-spec>  replace the default tool allowlist; repeatable, so
                       --allow Read --allow "Bash(git *)" gives exactly those
                       two. Default: Read Bash Write Edit Skill ReportFindings
                       TodoWrite ToolSearch Task Agent TaskOutput TaskStop —
                       enough to search the tree, run the code-review skill,
                       fan verification out to subagents (listed under both
                       of the names that tool answers to) and write the two
                       output files; no network tools. Narrow it only for a
                       prompt you know needs
                       less: an unattended run cannot answer a permission
                       prompt, so anything left out is silently denied and
                       the review comes back hollow but still confident.
  --no-tool-limits     do not pass --allowed-tools at all; whatever the
                       permission mode allows is allowed.
  --timeout <seconds>  abort a single review after this long (0: no limit)
  --force              re-review branches whose latest run already decided,
                       as a new numbered run beside the old one
  --no-restore         stay on the last reviewed branch instead of going
                       back to the branch that was checked out at the start
  --dry-run            print the plan and the rendered prompt; run nothing

The worktree must have no modified tracked files: the script checks branches
out. Untracked files are fine, which is why the default output directory can
live inside the repo.
EOF
	exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Plan file handling
# ---------------------------------------------------------------------------

# parse_plan_file <plan-file>
#
# Fills PLAN_BRANCHES / PLAN_NUMBERS / PLAN_TITLES / PLAN_ACTIVE with *every*
# entry in file order — commented-out ones too, with PLAN_ACTIVE set to 0.
# Merged entries still matter here: they are links in the base chain, so the
# entry above one is reviewed against it.
#
# A line is an entry when its second whitespace-delimited token is "#<digits>",
# which is what tells a merged entry apart from the file's prose comments.
PLAN_BRANCHES=()
PLAN_NUMBERS=()
PLAN_TITLES=()
PLAN_ACTIVE=()
parse_plan_file() {
	local plan_file="$1"
	[[ -f "$plan_file" ]] || die "plan file not found: $plan_file"

	PLAN_BRANCHES=()
	PLAN_NUMBERS=()
	PLAN_TITLES=()
	PLAN_ACTIVE=()
	local line body branch number title rest active
	while IFS= read -r line || [[ -n "$line" ]]; do
		body="${line#"${line%%[![:space:]]*}"}" # ltrim
		body="${body%"${body##*[![:space:]]}"}" # rtrim
		[[ -n "$body" ]] || continue

		active=1
		if [[ "$body" == \#* ]]; then
			active=0
			# Strip the comment marker and the "[merged]" tag the merge
			# driver prefixes, then see whether an entry is left.
			body="${body#\#}"
			body="${body#"${body%%[![:space:]]*}"}"
			body="${body#\[merged\]}"
			body="${body#"${body%%[![:space:]]*}"}"
		fi

		branch="${body%%[[:space:]]*}"
		rest="${body#"$branch"}"
		rest="${rest#"${rest%%[![:space:]]*}"}"
		number="${rest%%[[:space:]]*}"
		[[ "$number" =~ ^#[0-9]+$ ]] || continue
		title="${rest#"$number"}"
		title="${title#"${title%%[![:space:]]*}"}"

		PLAN_BRANCHES+=("$branch")
		PLAN_NUMBERS+=("${number#\#}")
		PLAN_TITLES+=("$title")
		PLAN_ACTIVE+=("$active")
	done <"$plan_file"

	[[ ${#PLAN_BRANCHES[@]} -gt 0 ]] || die "no plan entries found in $plan_file"
}

# plan_index_of <branch>
#
# Prints the index of <branch> in the parsed plan, or nothing when absent.
plan_index_of() {
	local branch="$1" i
	for i in "${!PLAN_BRANCHES[@]}"; do
		if [[ "${PLAN_BRANCHES[$i]}" == "$branch" ]]; then
			printf '%s' "$i"
			return 0
		fi
	done
	return 1
}

# plan_parent_of <index> <trunk>
#
# The branch the entry at <index> is reviewed against: the preceding plan
# entry, or <trunk> for the bottom one. A parent branch that no longer exists
# locally (merged and deleted, say) also falls back to the trunk, since the
# trunk contains it by then.
plan_parent_of() {
	local i="$1" trunk="$2" parent
	if [[ "$i" -eq 0 ]]; then
		printf '%s' "$trunk"
		return 0
	fi
	parent="${PLAN_BRANCHES[$((i - 1))]}"
	if git rev-parse --verify --quiet "refs/heads/$parent" >/dev/null; then
		printf '%s' "$parent"
	else
		printf '%s' "$trunk"
	fi
}

# ---------------------------------------------------------------------------
# Output files
# ---------------------------------------------------------------------------

# review_slug <pr-number> <branch>
#
# Stable, filesystem-safe name for a branch's review directory. The PR number
# goes first so a listing sorts into merge order.
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

# set_review_paths <output-dir> <pr-number> <branch>
#
# One directory per branch, fixed file names inside it: the branch is already
# identified by the directory, so nothing downstream has to take a name apart
# to find out what it is looking at.
REVIEW_ROOT=""
REVIEW_LATEST=""
REVIEW_DIR=""
REVIEW_OUTPUT=""
REVIEW_DEBUG=""
REVIEW_MD=""
REVIEW_VERDICT=""

# set_run_files <run-dir>
#
# Points the four file globals at one run directory.
set_run_files() {
	REVIEW_DIR="$1"
	REVIEW_OUTPUT="$REVIEW_DIR/output.jsonl"
	REVIEW_DEBUG="$REVIEW_DIR/debug.log"
	REVIEW_MD="$REVIEW_DIR/review.md"
	REVIEW_VERDICT="$REVIEW_DIR/verdict"
}

# set_review_paths <output-dir> <pr-number> <branch>
#
# Points everything at the branch's *most recent* run, which is what reading
# code (skip checks, status) wants. Writing code calls plan_run_dir afterwards
# to move onto a fresh one.
set_review_paths() {
	local dir="$1"
	REVIEW_ROOT="$dir/$(review_slug "$2" "$3")"
	REVIEW_LATEST="$REVIEW_ROOT/latest"
	set_run_files "$REVIEW_LATEST"
}

# plan_run_dir <create>
#
# Picks the next run directory — 001, 002, … under the branch's directory —
# and points the file globals at it. With <create> set it also makes the
# directory and moves the "latest" symlink onto it; with <create> zero it only
# works out the name, so a dry run can show where output would go without
# leaving an empty directory behind.
#
# The symlink is moved when the run *starts*, not when it finishes, so
# latest/output.jsonl can be tailed while the review is still thinking. A run
# that dies leaves latest pointing at its wreckage, which is the right place to
# look anyway; the verdict file, not the symlink, is what says a review
# succeeded.
plan_run_dir() {
	local create="$1" n=1 entry num dir
	for entry in "$REVIEW_ROOT"/[0-9][0-9][0-9]; do
		# Without nullglob an unmatched glob arrives literally; -d rejects it.
		[[ -d "$entry" ]] || continue
		num=$((10#${entry##*/}))
		[[ "$num" -ge "$n" ]] && n=$((num + 1))
	done
	dir="$(printf '%s/%03d' "$REVIEW_ROOT" "$n")"
	set_run_files "$dir"

	[[ "$create" -eq 1 ]] || return 0
	mkdir -p "$dir"
	# Relative target, so the whole tree can be moved or copied elsewhere.
	ln -sfn "$(basename "$dir")" "$REVIEW_LATEST"
}

# count_runs
#
# How many runs a branch has accumulated, for reporting.
count_runs() {
	local entry n=0
	for entry in "$REVIEW_ROOT"/[0-9][0-9][0-9]; do
		[[ -d "$entry" ]] || continue
		n=$((n + 1))
	done
	printf '%s' "$n"
}

# read_verdict <verdict-file>
#
# Prints "true", "false", or "malformed"; nothing at all when the file is
# missing. Whitespace around the value is tolerated, nothing else is: the
# whole point of this file is that it needs no interpretation.
read_verdict() {
	local file="$1" value
	[[ -f "$file" ]] || return 0
	value="$(tr -d '[:space:]' <"$file" | tr '[:upper:]' '[:lower:]')"
	case "$value" in
	true | false) printf '%s' "$value" ;;
	*) printf 'malformed' ;;
	esac
}

# review_is_done <verdict-file>
#
# True only for a verdict that actually decided something. A missing file is a
# branch never reviewed; a malformed one is a run that went wrong, and either
# way there is work left to do — so neither counts as done and neither is
# skipped.
review_is_done() {
	local verdict
	verdict="$(read_verdict "$1")"
	[[ "$verdict" == "true" || "$verdict" == "false" ]]
}

# ---------------------------------------------------------------------------
# Worktree ownership
# ---------------------------------------------------------------------------

ORIG_BRANCH=""
RESTORE_BRANCH=1
restore_branch() {
	[[ "$RESTORE_BRANCH" -eq 1 && -n "$ORIG_BRANCH" ]] || return 0
	local now
	now="$(git symbolic-ref --short -q HEAD || true)"
	[[ "$now" != "$ORIG_BRANCH" ]] || return 0
	printf '\n'
	if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
		# Somebody's uncommitted work is sitting here — a review that edited
		# tracked files, most likely. Carrying it onto another branch would
		# only spread the mess; say where things stand and leave it alone.
		printf 'not restoring %s: %s has modified tracked files\n' "$ORIG_BRANCH" "$now" >&2
		return 0
	fi
	note "restoring $ORIG_BRANCH"
	git checkout --quiet "$ORIG_BRANCH" ||
		printf 'warning: could not restore branch %s (you are on %s)\n' "$ORIG_BRANCH" "$now" >&2
}

# claim_worktree
#
# Refuses to run unless the worktree is ours to move around: tracked files must
# be clean. Untracked files are deliberately allowed — the default output
# directory sits inside the repo.
claim_worktree() {
	git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
	[[ -z "$(git status --porcelain --untracked-files=no)" ]] ||
		die "worktree has modified tracked files — this script checks branches out; commit, stash, or run it in another worktree"
	ORIG_BRANCH="$(git symbolic-ref --short -q HEAD)" ||
		die "detached HEAD — check out a branch first, so there is something to come back to"
	trap restore_branch EXIT
}

# assert_worktree_undisturbed <branch>
#
# A review is supposed to read the code and write its two files, both of which
# live outside version control. If it edited a tracked file instead, the next
# checkout in the train fails and every review after this one is against a
# worktree nobody intended — so stop here, while the damage is still one
# branch wide and obvious.
assert_worktree_undisturbed() {
	local branch="$1" dirty
	dirty="$(git status --porcelain --untracked-files=no)"
	[[ -n "$dirty" ]] || return 0
	printf 'error: the review of %s modified tracked files:\n%s\n' "$branch" "$dirty" >&2
	printf 'the worktree is left as-is for you to inspect; nothing further is reviewed\n' >&2
	return 1
}

# ---------------------------------------------------------------------------
# Prompt rendering and the review itself
# ---------------------------------------------------------------------------

# render_prompt <template> <branch> <base> <pr> <title> <repo-root> <review-file> <verdict-file>
render_prompt() {
	local template="$1" branch="$2" base="$3" pr="$4" title="$5" root="$6" review="$7" verdict="$8"
	[[ -f "$template" ]] || die "prompt template not found: $template"
	local text
	text="$(<"$template")"
	text="${text//\{\{BRANCH\}\}/$branch}"
	text="${text//\{\{BASE\}\}/$base}"
	text="${text//\{\{RANGE\}\}/$base..$branch}"
	text="${text//\{\{PR\}\}/$pr}"
	text="${text//\{\{TITLE\}\}/$title}"
	text="${text//\{\{REPO_ROOT\}\}/$root}"
	text="${text//\{\{REVIEW_FILE\}\}/$review}"
	text="${text//\{\{VERDICT_FILE\}\}/$verdict}"
	printf '%s' "$text"
}

# Defaults for the claude invocation, overridable per run.
#
# The allowlist has to cover everything a review prompt legitimately does: read
# and search the tree (Bash, unrestricted — a review greps, finds and runs git
# however it likes), invoke the code-review skill (Skill), fan verification out
# to subagents (Task, plus TaskOutput/TaskStop to collect and cancel them, and
# ReportFindings for skills that report through it), reach deferred tool
# schemas (ToolSearch), and write its own two output files (Write, Edit). What
# it deliberately leaves out is the network: no WebFetch, no WebSearch, so a
# review is answered from this repository.
#
# The subagent tool answers to two names and both are listed, because which one
# the permission matcher keys on is not observable from the outside: the
# system/init event advertises it as "Task", while the tool_use blocks for the
# very same calls come back named "Agent". Listing both costs nothing and a
# wrong guess costs every verification subagent in the run.
#
# Do not read "no subagents ran" as "subagents were blocked" — a run with the
# wrong name allowlisted recorded zero denials, because the prompt of the day
# never asked for one. Denials show up in the result event's permission_denials
# array; an empty array with no Task/Agent calls means nothing was attempted.
#
# Erring narrow would be the worse mistake. An unattended `-p` run cannot
# answer a permission prompt, so a tool that is not pre-allowed is silently
# *denied* — and a review that was quietly refused the tools to look at the
# code still writes a confident verdict. The guard against a review disturbing
# the stack is assert_worktree_undisturbed after the run, not a narrow
# allowlist before it.
#
# ALLOWED_TOOLS is an array because tool specs contain spaces ("Bash(git *)").
ALLOWED_TOOLS=(
	Read Bash Write Edit
	Skill ReportFindings TodoWrite ToolSearch
	Task Agent TaskOutput TaskStop
)
TOOL_LIMITS=1
PERMISSION_MODE="acceptEdits"
MODEL="fable"
EFFORT=""
TIMEOUT=0
DRY_RUN=0

# format_stream
#
# Renders the stream-json transcript arriving on stdin as something worth
# watching — one line per tool call, the assistant's own prose, and the closing
# tally — while the JSON itself goes to output.jsonl untouched. Without jq
# there is nothing sensible to render, so the run goes quiet rather than
# dumping raw JSONL over the terminal.
#
# jq runs per line, not over the stream, for two reasons: one stray non-JSON
# line (a warning printed to stdout, say) would otherwise kill jq outright, and
# a dead jq means SIGPIPE upstream — killing the review it was only supposed to
# be narrating. For the same reason this function always succeeds: its exit
# status would otherwise become the pipeline's under `set -o pipefail` and be
# read as a failed review.
format_stream() {
	if ! command -v jq >/dev/null 2>&1; then
		cat >/dev/null
		return 0
	fi
	local line
	while IFS= read -r line; do
		printf '%s' "$line" | jq -r '
			if .type == "assistant" then
				(.message.content // [])[]
				| if .type == "tool_use" then
					"   -> \(.name): \((.input.description // .input.command // .input.file_path // .input.prompt // "") | tostring | .[0:110])"
				  elif .type == "text" and ((.text // "") | length) > 0 then
					"   \((.text | .[0:500]))"
				  else empty end
			elif .type == "result" then
				"   [\(.subtype // "done")] \(.num_turns // 0) turns, \((.duration_ms // 0) / 1000 | floor)s"
			else empty end
		' 2>/dev/null || true
	done
	return 0
}

# run_review <branch> <base> <pr> <title> <repo-root> <prompt-file>
#
# Checks the branch out, runs Claude, and validates that the two files the
# prompt asked for actually appeared. Returns nonzero on any of those failing;
# the caller decides whether that stops a train.
run_review() {
	local branch="$1" base="$2" pr="$3" title="$4" root="$5" prompt_file="$6"

	git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null ||
		die "branch not found locally: $branch"
	git rev-parse --verify --quiet "$base^{commit}" >/dev/null ||
		die "base ref does not resolve: $base"

	# Every review is a fresh numbered run; earlier ones are never overwritten,
	# so a re-review can be compared against what it supersedes. The prompt has
	# to be rendered against this run's paths, hence the naming comes first.
	local previous
	previous="$(count_runs)"
	plan_run_dir 0

	local prompt
	prompt="$(render_prompt "$prompt_file" "$branch" "$base" "$pr" "$title" \
		"$root" "$REVIEW_MD" "$REVIEW_VERDICT")"

	local commits
	commits="$(git rev-list --count "$base..$branch")"
	note "range  $base..$branch ($commits commit(s))"
	local kept=""
	[[ "$previous" -gt 0 ]] && kept=" ($previous earlier run(s) kept)"
	note "output $REVIEW_DIR/$kept"

	if [[ "$DRY_RUN" -eq 1 ]]; then
		printf '\n--- prompt ---\n%s\n--- end prompt ---\n' "$prompt"
		return 0
	fi

	git checkout --quiet "$branch" || die "could not check out $branch"

	plan_run_dir 1

	# stream-json (which -p only allows with --verbose) is what makes
	# output.jsonl a real transcript rather than a closing summary: one event
	# per thinking block, tool call, tool result and final usage tally.
	local -a claude_cmd=(
		claude -p --output-format stream-json --verbose
		--permission-mode "$PERMISSION_MODE"
		--debug-file "$REVIEW_DEBUG"
	)
	[[ -n "$MODEL" ]] && claude_cmd+=(--model "$MODEL")
	[[ -n "$EFFORT" ]] && claude_cmd+=(--effort "$EFFORT")
	[[ "$TOOL_LIMITS" -eq 1 ]] && claude_cmd+=(--allowed-tools "${ALLOWED_TOOLS[@]}")
	if [[ "$TIMEOUT" -gt 0 ]]; then
		claude_cmd=(timeout --signal=INT "$TIMEOUT" "${claude_cmd[@]}")
	fi

	tick "running claude"
	local rc=0
	printf '%s' "$prompt" | "${claude_cmd[@]}" | tee "$REVIEW_OUTPUT" | format_stream || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		printf 'error: claude exited %s for %s (transcript in %s)\n' "$rc" "$branch" "$REVIEW_OUTPUT" >&2
		return 1
	fi

	assert_worktree_undisturbed "$branch" || return 1

	# The prompt owns these two files; if they are not here the review did not
	# happen, whatever the transcript says.
	[[ -s "$REVIEW_MD" ]] || {
		printf 'error: %s wrote no review to %s\n' "$branch" "$REVIEW_MD" >&2
		return 1
	}
	local verdict
	verdict="$(read_verdict "$REVIEW_VERDICT")"
	case "$verdict" in
	true | false) ;;
	"")
		printf 'error: %s wrote no verdict to %s\n' "$branch" "$REVIEW_VERDICT" >&2
		return 1
		;;
	*)
		printf 'error: %s wrote a malformed verdict to %s (expected "true" or "false")\n' \
			"$branch" "$REVIEW_VERDICT" >&2
		return 1
		;;
	esac

	tick "verdict: ready-to-merge = $verdict"
	return 0
}

# ---------------------------------------------------------------------------
# Shared option parsing
# ---------------------------------------------------------------------------

OUTPUT_DIR=""
PROMPT_FILE="$PROMPT_FILE_DEFAULT"
FORCE=0
ALLOW_OVERRIDDEN=0

# parse_common_opt <arg> [value...]
#
# Handles the options shared by review and review-all, setting OPT_CONSUMED to
# how many arguments it took (0 when it does not recognise the option). It
# reports through a global rather than stdout because it assigns to globals
# itself: called in a command substitution, every one of those assignments
# would be lost with the subshell.
OPT_CONSUMED=0
parse_common_opt() {
	OPT_CONSUMED=2
	case "$1" in
	--output-dir)
		OUTPUT_DIR="${2:-}"
		[[ -n "$OUTPUT_DIR" ]] || die "--output-dir requires a value"
		;;
	--prompt-file)
		PROMPT_FILE="${2:-}"
		[[ -n "$PROMPT_FILE" ]] || die "--prompt-file requires a value"
		;;
	--model)
		# Empty is meaningful here — it means "do not pass --model at all" —
		# so this checks that an argument is present, not that it is non-empty.
		[[ $# -ge 2 ]] || die "--model requires a value"
		MODEL="$2"
		;;
	--effort)
		EFFORT="${2:-}"
		[[ -n "$EFFORT" ]] || die "--effort requires a value"
		;;
	--permission-mode)
		PERMISSION_MODE="${2:-}"
		[[ -n "$PERMISSION_MODE" ]] || die "--permission-mode requires a value"
		;;
	--allow)
		[[ -n "${2:-}" ]] || die "--allow requires a value"
		# First --allow replaces the defaults; the rest add to it.
		if [[ "$ALLOW_OVERRIDDEN" -eq 0 ]]; then
			ALLOWED_TOOLS=()
			ALLOW_OVERRIDDEN=1
		fi
		ALLOWED_TOOLS+=("$2")
		;;
	--timeout)
		TIMEOUT="${2:-}"
		[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout requires a number of seconds"
		;;
	--no-tool-limits)
		TOOL_LIMITS=0
		OPT_CONSUMED=1
		;;
	--force)
		FORCE=1
		OPT_CONSUMED=1
		;;
	--no-restore)
		RESTORE_BRANCH=0
		OPT_CONSUMED=1
		;;
	--dry-run)
		DRY_RUN=1
		OPT_CONSUMED=1
		;;
	-h | --help) usage 0 ;;
	*) OPT_CONSUMED=0 ;;
	esac
}

# resolve_output_dir <repo-root>
resolve_output_dir() {
	local root="$1"
	[[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="$root/.reviews"
	mkdir -p "$OUTPUT_DIR"
	OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
}

# ---------------------------------------------------------------------------
# review
# ---------------------------------------------------------------------------

cmd_review() {
	local plan_file="" base="" trunk="main" branch=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--plan)
			plan_file="${2:-}"
			[[ -n "$plan_file" ]] || die "--plan requires a value"
			shift 2
			;;
		--base)
			base="${2:-}"
			[[ -n "$base" ]] || die "--base requires a value"
			shift 2
			;;
		--trunk)
			trunk="${2:-}"
			[[ -n "$trunk" ]] || die "--trunk requires a value"
			shift 2
			;;
		--*)
			parse_common_opt "$@"
			[[ "$OPT_CONSUMED" -gt 0 ]] || die "unknown option: $1"
			shift "$OPT_CONSUMED"
			;;
		*)
			[[ -z "$branch" ]] || die "unexpected argument: $1"
			branch="$1"
			shift
			;;
		esac
	done
	[[ -n "$branch" ]] || usage 1

	require_tools
	claim_worktree

	local root
	root="$(git rev-parse --show-toplevel)"
	resolve_output_dir "$root"

	local pr="" title=""
	if [[ -n "$plan_file" ]]; then
		parse_plan_file "$plan_file"
		local idx
		idx="$(plan_index_of "$branch")" ||
			die "branch not listed in $plan_file: $branch"
		pr="${PLAN_NUMBERS[$idx]}"
		title="${PLAN_TITLES[$idx]}"
		[[ -n "$base" ]] || base="$(plan_parent_of "$idx" "$trunk")"
	fi
	[[ -n "$base" ]] || base="$trunk"

	set_review_paths "$OUTPUT_DIR" "$pr" "$branch"

	if [[ "$FORCE" -eq 0 && "$DRY_RUN" -eq 0 ]] && review_is_done "$REVIEW_VERDICT"; then
		die "already reviewed: $REVIEW_VERDICT says $(read_verdict "$REVIEW_VERDICT") (--force to redo)"
	fi

	step "Reviewing ${pr:+#$pr }$branch"
	run_review "$branch" "$base" "$pr" "$title" "$root" "$PROMPT_FILE"
}

# ---------------------------------------------------------------------------
# review-all
# ---------------------------------------------------------------------------

cmd_review_all() {
	local plan_file="" trunk="main" max=0 keep_going=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--trunk)
			trunk="${2:-}"
			[[ -n "$trunk" ]] || die "--trunk requires a value"
			shift 2
			;;
		--max)
			max="${2:-}"
			[[ "$max" =~ ^[0-9]+$ ]] || die "--max requires a number"
			shift 2
			;;
		--keep-going)
			keep_going=1
			shift
			;;
		--*)
			parse_common_opt "$@"
			[[ "$OPT_CONSUMED" -gt 0 ]] || die "unknown option: $1"
			shift "$OPT_CONSUMED"
			;;
		*)
			[[ -z "$plan_file" ]] || die "unexpected argument: $1"
			plan_file="$1"
			shift
			;;
		esac
	done
	[[ -n "$plan_file" ]] || usage 1

	require_tools
	claim_worktree
	parse_plan_file "$plan_file"

	local root
	root="$(git rev-parse --show-toplevel)"
	resolve_output_dir "$root"

	local -a todo_idx=()
	local i
	for i in "${!PLAN_BRANCHES[@]}"; do
		[[ "${PLAN_ACTIVE[$i]}" -eq 1 ]] || continue
		set_review_paths "$OUTPUT_DIR" "${PLAN_NUMBERS[$i]}" "${PLAN_BRANCHES[$i]}"
		if [[ "$FORCE" -eq 0 ]] && review_is_done "$REVIEW_VERDICT"; then
			continue
		fi
		todo_idx+=("$i")
	done

	if [[ ${#todo_idx[@]} -eq 0 ]]; then
		printf '%sNothing to review.%s Every active entry in %s already has a verdict.\n' \
			"$BOLD" "$RESET" "$plan_file"
		return 0
	fi

	printf '%s%d branch(es) to review from %s.%s\n' "$BOLD" "${#todo_idx[@]}" "$plan_file" "$RESET"

	local done_count=0 failed_count=0 idx branch base pr title verdict
	local -a summary=()
	for idx in "${todo_idx[@]}"; do
		if [[ "$max" -gt 0 && "$done_count" -ge "$max" ]]; then
			printf '\n%sStopping after %d review(s)%s (--max); %d left in the plan, re-run to continue.\n' \
				"$BOLD" "$done_count" "$RESET" "$((${#todo_idx[@]} - done_count))"
			break
		fi

		branch="${PLAN_BRANCHES[$idx]}"
		pr="${PLAN_NUMBERS[$idx]}"
		title="${PLAN_TITLES[$idx]}"
		base="$(plan_parent_of "$idx" "$trunk")"
		set_review_paths "$OUTPUT_DIR" "$pr" "$branch"

		step "Reviewing #$pr $branch ($((done_count + 1))/${#todo_idx[@]})"
		[[ -n "$title" ]] && note "$title"

		if run_review "$branch" "$base" "$pr" "$title" "$root" "$PROMPT_FILE"; then
			verdict="$(read_verdict "$REVIEW_VERDICT")"
			summary+=("$(printf '%-6s #%-5s %s' "${verdict:-dry-run}" "$pr" "$branch")")
		else
			failed_count=$((failed_count + 1))
			summary+=("$(printf '%-6s #%-5s %s' "FAILED" "$pr" "$branch")")
			if [[ "$keep_going" -eq 0 ]]; then
				printf '\n%sStopped at #%s %s.%s Re-run to resume; --keep-going to push through failures.\n' \
					"$BOLD" "$pr" "$branch" "$RESET" >&2
				print_summary "${summary[@]}"
				return 1
			fi
		fi
		done_count=$((done_count + 1))
	done

	print_summary "${summary[@]}"
	[[ "$failed_count" -eq 0 ]] || return 1
	return 0
}

print_summary() {
	[[ $# -gt 0 ]] || return 0
	printf '\n%sSummary%s (ready-to-merge)\n' "$BOLD" "$RESET"
	local line
	for line in "$@"; do
		printf '   %s\n' "$line"
	done
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

cmd_status() {
	local plan_file=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output-dir)
			OUTPUT_DIR="${2:-}"
			[[ -n "$OUTPUT_DIR" ]] || die "--output-dir requires a value"
			shift 2
			;;
		-h | --help) usage 0 ;;
		--*) die "unknown option: $1" ;;
		*)
			[[ -z "$plan_file" ]] || die "unexpected argument: $1"
			plan_file="$1"
			shift
			;;
		esac
	done
	[[ -n "$plan_file" ]] || usage 1

	parse_plan_file "$plan_file"

	local root
	root="$(git rev-parse --show-toplevel)" || die "not inside a git repository"
	[[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="$root/.reviews"

	printf 'Plan %s (reviews in %s)\n\n' "$plan_file" "$OUTPUT_DIR"
	local i state verdict runs pending=0
	for i in "${!PLAN_BRANCHES[@]}"; do
		set_review_paths "$OUTPUT_DIR" "${PLAN_NUMBERS[$i]}" "${PLAN_BRANCHES[$i]}"
		verdict="$(read_verdict "$REVIEW_VERDICT")"
		runs="$(count_runs)"
		if [[ "${PLAN_ACTIVE[$i]}" -eq 0 ]]; then
			state="merged"
		elif review_is_done "$REVIEW_VERDICT"; then
			state="$verdict"
		else
			# Missing and malformed alike: review-all will pick it up again.
			state="${verdict:-pending}"
			pending=$((pending + 1))
		fi
		printf '  %-9s %-8s #%-5s %s\n' "$state" \
			"$([[ "$runs" -gt 0 ]] && printf '%s run(s)' "$runs" || printf '')" \
			"${PLAN_NUMBERS[$i]}" "${PLAN_BRANCHES[$i]}"
	done
	printf '\n%d active entry(ies) still pending review.\n' "$pending"
}

[[ $# -gt 0 ]] || usage 1
command="$1"
shift
case "$command" in
review) cmd_review "$@" ;;
review-all) cmd_review_all "$@" ;;
status) cmd_status "$@" ;;
-h | --help) usage 0 ;;
*) die "unknown command: $command (expected 'review', 'review-all', or 'status')" ;;
esac
