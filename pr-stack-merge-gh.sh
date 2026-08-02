#!/usr/bin/env bash
#
# pr-stack-merge-gh.sh — drive a stacked-PR train through GitHub, one PR at a
# time, on top of pr-stack.sh.
#
# The workflow assumes a chained stack: every PR's base is the previous PR's
# branch, and only the bottom PR targets the trunk. Two files drive it:
#
#   * a pr-stack.sh *map file* ("branch -> commit subject"), which may contain
#     duplicates and branches that are not on the merge chain at all;
#   * a *merge order plan* produced by this script's `plan` command, which is
#     exactly the chain of PRs to merge, bottom first.
#
# The plan is derived from the GitHub base chain rather than from the map,
# precisely because the map is allowed to be a superset of the train.
#
# Subcommands:
#
#   plan [--stack <branch>] [--base <branch>] [--output <file>]
#       Walk the GitHub PR base chain down from <stack>'s PR until it reaches
#       <base> (or a branch whose PR is already merged, which just means the
#       bottom PR has not been retargeted yet), then emit the reverse: the
#       merge order, bottom PR first. Verifies every chain branch exists
#       locally and is an ancestor of the stack head.
#
#   merge-all [--max <n>] [<merge-next options>] <plan-file> <map-file>
#       merge-next in a loop until the plan is drained. Every option is
#       forwarded, so an unattended drain of the whole stack is just:
#
#           pr-stack-merge-gh.sh merge-all \
#               --ignore-checks-file ci-ignore.txt plan.map stack.map
#
#       The loop stops the moment anything inside merge-next aborts, and
#       refuses to spin if a "successful" merge-next fails to consume a
#       plan entry.
#
#   merge-next [options] <plan-file> <map-file>
#       Merge the first not-yet-merged PR in the plan and restack everything
#       above it:
#
#         1. verify the local stack matches the map (pr-stack.sh remap --check)
#            and that the PR branch matches its remote tip;
#         2. retarget the PR onto <base> if it still points at a merged branch;
#         3. wait until it is approved and CI is green;
#         4. merge via GitHub, wait for the merge to land;
#         5. pr-stack.sh advance — pull <base>, comment the merged branch out
#            of the map;
#         6. rebase the stack onto <base>, pr-stack.sh remap --apply, push;
#         7. comment the merged PR out of the plan.
#
#       Every step is guarded by a state check, so re-running after a failure
#       resumes rather than redoing. Any problem aborts with a resume hint;
#       nothing is left half-applied on purpose.
#
#       The readiness step is a wait, not an abort: a missing approval, a
#       draft PR, red or missing checks — and a failed status query, which
#       says nothing about the PR — are all retried until the PR becomes
#       mergeable (or --ci-timeout elapses), so a run can be left unattended
#       while a reviewer approves and somebody fixes the build. An
#       unapproved PR outranks a red build as the reported blocker, since
#       it cannot merge either way. --no-wait-ci
#       restores fail-fast behaviour for interactive use. The stack is
#       verified again after any such wait, because CI usually turns green
#       by way of somebody pushing to the PR branch, which invalidates the
#       earlier local-vs-remote check. A PR merged or closed by someone
#       else while waiting is noticed and handled rather than fought.
#
# Plan file format: "<branch-name>  #<pr-number>  <pr-title>", one per line.
# Unlike map files, only whole-line "#" comments are recognised (a PR number
# is spelled "#490", so trailing comments would be ambiguous).
#
# Authentication: gh's own GH_TOKEN takes precedence over the stored login, so
# a different token can be used per invocation without touching `gh auth`:
#
#     GH_TOKEN=ghp_… pr-stack-merge-gh.sh merge-next plan.txt map.txt
#
# This matters for repositories owned by someone else: fine-grained PATs only
# ever reach repos owned by the token's own owner, so retargeting and merging
# fail with "Resource not accessible by personal access token" even when the
# account itself has write access. A classic PAT with the `repo` scope, or an
# OAuth token from `gh auth login --web`, does work. Pushes are unaffected
# when the remote is SSH — the token is only used for the GitHub API.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_STACK="${PR_STACK:-$SCRIPT_DIR/pr-stack.sh}"

# Nothing here may take over the terminal: no prompts, no pager, no update
# banners, and no live-redrawing UI (the CI step polls JSON rather than using
# `gh pr checks --watch`). When stdout is not a terminal, drop colour too so
# log files stay free of escape sequences.
export GH_PROMPT_DISABLED=1
export GH_NO_UPDATE_NOTIFIER=1
export GH_NO_EXTENSION_UPDATE_NOTIFIER=1
export GH_PAGER=cat
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

# Printed on every abort inside merge-next so the way back is never a guess.
RESUME_HINT=""
die_resumable() {
	printf 'error: %s\n' "$1" >&2
	[[ -n "${2:-}" ]] && printf '\n%s\n' "$2" >&2
	[[ -n "$RESUME_HINT" ]] && printf '\nresume with: %s\n' "$RESUME_HINT" >&2
	exit 1
}

current_branch() {
	local b
	b="$(git symbolic-ref --short -q HEAD)" ||
		die "detached HEAD — specify a branch explicitly"
	printf '%s' "$b"
}

# gh_json <gh-args...>
#
# A read-only gh call for which any nonzero exit means "the query failed", not
# "the answer is no". Retries a few times with a short backoff so a momentary
# API hiccup does not take down a long unattended run.
gh_json() {
	local attempt=1 out rc
	while :; do
		rc=0
		out="$(gh "$@" 2>/dev/null)" || rc=$?
		if [[ "$rc" -eq 0 ]]; then
			printf '%s' "$out"
			return 0
		fi
		[[ "$attempt" -ge "${GH_READ_RETRIES:-3}" ]] && return "$rc"
		sleep $((attempt * 2))
		attempt=$((attempt + 1))
	done
}

require_tools() {
	command -v gh >/dev/null || die "gh (GitHub CLI) is required but not on PATH"
	[[ -x "$PR_STACK" ]] || die "pr-stack.sh not found or not executable: $PR_STACK"
}

usage() {
	cat >&2 <<'EOF'
Usage: pr-stack-merge-gh.sh <command> [options] [args]

Commands:
  plan [--stack <branch>] [--base <branch>] [--output <file>]
        Build a merge order plan by walking the GitHub PR base chain down
        from <stack> (default: current branch) to <base> (default: main).
        Writes to <file> or stdout, bottom PR first.

  merge-all [--max <n>] [<merge-next options>] <plan-file> <map-file>
        Run merge-next in a loop until the plan is drained, printing a
        banner per PR. Any abort inside merge-next stops the whole train
        (nonzero exit) so nothing is left half-applied; re-run to resume.
        --max <n> stops after n merges. The plan and map must be the last
        two arguments, as for merge-next.

  merge-next [--base <branch>] [--stack <branch>] [--remote <name>]
             [--merge-method merge|squash|rebase] [--skip-ci | --no-wait-ci]
             [--skip-approval] [--ci-interval <seconds>]
             [--ci-retry-interval <seconds>] [--ci-timeout <seconds>]
             [--no-checks-timeout <seconds>] [--dry-run]
             <plan-file> <map-file>
        Merge the first unmerged PR in the plan, then advance the map,
        rebase the stack, remap the branches and push. Re-run to resume
        after a failure; re-run again for the next PR in the train.

        A PR is merged only once it is approved and its checks are green.
        Both are waited out by default, so a run can be left unattended
        while a reviewer approves and someone fixes the build; the stack is
        re-verified before merging, since a fix usually arrives as a push
        to the PR branch.

        --skip-approval
                       merge without an approving review.
        --no-wait-ci   abort on the first red or missing CI result, or the
                       first unapproved PR, instead of waiting (the old
                       behaviour, for interactive use).
        --required-only
                       only let branch-protection *required* checks gate
                       the merge; a red advisory check is ignored, matching
                       what GitHub itself would allow.
        --ignore-checks-file <path>
                       file of checks that must not gate the merge: they
                       may fail or hang without holding it up. One name per
                       line, whole-line # comments. This is the durable
                       place for the list.
        --ignore-check <name-or-glob>
                       same, for one check, ad hoc. Repeatable; combines
                       with the file.

                       Both are matched as bash globs against the check
                       name, so "flaky-e2e" is exact and "codecov*" is a
                       family. Neither is ever split, since check names
                       routinely contain spaces, commas and parentheses.
        --ci-interval  how often to poll while checks are still running
                       (30s).
        --ci-retry-interval
                       delay between retries after a red round (120s).
        --ci-timeout   give up after this long waiting for green; 0 (the
                       default) waits forever.
        --no-checks-timeout
                       how long to wait for checks to appear at all before
                       giving up (900s; 0 waits forever). Separate from
                       --ci-timeout because "no CI configured" never
                       resolves on its own.

  status <plan-file>
        Show the plan's progress: merged entries and what is up next.

  checks [--required-only] [--ignore-checks-file <path>]
         [--ignore-check <name-or-glob>] <pr-number>
        Print every check on a PR as this script classifies it, plus the
        verdict it would act on. Use it to build the ignore file.

Plan file: "<branch-name>  #<pr-number>  <pr-title>"; whole-line # comments.

Environment:
  GH_TOKEN   Overrides the stored `gh auth` login for this invocation. Needed
             for repos owned by others: fine-grained PATs cannot reach them,
             so use a classic PAT with `repo` scope or `gh auth login --web`.
EOF
	exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Plan file handling
# ---------------------------------------------------------------------------

# parse_plan_file <plan-file>
#
# Fills PLAN_BRANCHES / PLAN_NUMBERS / PLAN_TITLES with the *active* (not
# commented out) entries, in file order. Only whole-line "#" comments are
# stripped: "#490" is data, not a comment.
PLAN_BRANCHES=()
PLAN_NUMBERS=()
PLAN_TITLES=()
parse_plan_file() {
	local plan_file="$1"
	[[ -f "$plan_file" ]] || die "plan file not found: $plan_file"

	PLAN_BRANCHES=()
	PLAN_NUMBERS=()
	PLAN_TITLES=()
	local line branch number title rest lineno=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		lineno=$((lineno + 1))

		line="${line#"${line%%[![:space:]]*}"}" # ltrim
		line="${line%"${line##*[![:space:]]}"}" # rtrim
		[[ -n "$line" && "$line" != \#* ]] || continue

		branch="${line%%[[:space:]]*}"
		rest="${line#"$branch"}"
		rest="${rest#"${rest%%[![:space:]]*}"}"
		number="${rest%%[[:space:]]*}"
		title="${rest#"$number"}"
		title="${title#"${title%%[![:space:]]*}"}"

		[[ "$number" == \#* ]] ||
			die "$plan_file:$lineno: expected \"#<pr-number>\" after branch $branch, got \"$number\""
		number="${number#\#}"
		[[ "$number" =~ ^[0-9]+$ ]] ||
			die "$plan_file:$lineno: malformed PR number for branch $branch"

		PLAN_BRANCHES+=("$branch")
		PLAN_NUMBERS+=("$number")
		PLAN_TITLES+=("$title")
	done <"$plan_file"
}

# comment_out_plan_entry <plan-file> <branch> <pr-number>
#
# Rewrites the plan in place, prefixing the matching active entry with
# "# [merged] ". Fails loudly if the entry is not there any more.
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

# map_has_active_branch <map-file> <branch>
#
# True when the map still lists <branch> on a non-commented line. Map files do
# support trailing comments, so strip from the first "#".
map_has_active_branch() {
	local map_file="$1" branch="$2" line stripped
	while IFS= read -r line || [[ -n "$line" ]]; do
		stripped="${line%%#*}"
		stripped="${stripped#"${stripped%%[![:space:]]*}"}"
		[[ -n "$stripped" ]] || continue
		[[ "${stripped%%[[:space:]]*}" == "$branch" ]] && return 0
	done <"$map_file"
	return 1
}

# ---------------------------------------------------------------------------
# plan
# ---------------------------------------------------------------------------

cmd_plan() {
	local base="main" stack="" output="" limit=300
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--base) base="${2:-}"; [[ -n "$base" ]] || die "--base requires a value"; shift 2 ;;
		--stack) stack="${2:-}"; [[ -n "$stack" ]] || die "--stack requires a value"; shift 2 ;;
		-o | --output) output="${2:-}"; [[ -n "$output" ]] || die "--output requires a value"; shift 2 ;;
		--limit) limit="${2:-}"; [[ -n "$limit" ]] || die "--limit requires a value"; shift 2 ;;
		-h | --help) usage 0 ;;
		-*) die "unknown option: $1" ;;
		*) die "unexpected argument: $1" ;;
		esac
	done
	require_tools
	stack="${stack:-$(current_branch)}"

	git rev-parse --verify --quiet "$stack^{commit}" >/dev/null || die "stack branch not found: $stack"

	# One API call for the whole open-PR set; the walk is pure lookup after this.
	local prs
	prs="$(gh_json pr list --state open --limit "$limit" \
		--json number,headRefName,baseRefName,title \
		--jq '.[] | [.headRefName, .baseRefName, .number, .title] | @tsv')" ||
		die "failed to list pull requests (after retries)"

	declare -A pr_base pr_number pr_title
	local head_ref base_ref number title
	while IFS=$'\t' read -r head_ref base_ref number title; do
		[[ -n "$head_ref" ]] || continue
		pr_base["$head_ref"]="$base_ref"
		pr_number["$head_ref"]="$number"
		pr_title["$head_ref"]="$title"
	done <<<"$prs"

	[[ -n "${pr_number[$stack]:-}" ]] ||
		die "no open PR found for the stack head branch: $stack"

	# Walk down the base chain, head first; guard against cycles and runaway
	# chains that never reach the base.
	local chain_branches=() chain_numbers=() chain_titles=()
	declare -A seen
	local cur="$stack" retarget_note=""
	while :; do
		if [[ -n "${seen[$cur]:-}" ]]; then
			die "cycle detected in the PR base chain at $cur"
		fi
		seen["$cur"]=1

		if [[ -z "${pr_number[$cur]:-}" ]]; then
			# Chain bottomed out on something without an open PR. That is fine
			# only if it is the base itself, or a branch whose PR already merged
			# (GitHub leaves children pointing at it until it is deleted).
			[[ "$cur" == "$base" ]] && break
			local merged_num
			merged_num="$(gh pr list --state merged --head "$cur" --limit 1 --json number \
				--jq '.[0].number // empty')" || die "failed to query merged PRs for $cur"
			[[ -n "$merged_num" ]] ||
				die "base chain reached \"$cur\", which has neither an open nor a merged PR (expected to reach $base)"
			retarget_note="$cur (PR #$merged_num, already merged)"
			break
		fi

		chain_branches+=("$cur")
		chain_numbers+=("${pr_number[$cur]}")
		chain_titles+=("${pr_title[$cur]}")
		cur="${pr_base[$cur]}"
	done

	[[ ${#chain_branches[@]} -gt 0 ]] || die "empty chain — nothing to plan"

	# Every branch on the chain must exist locally and be part of the stack,
	# otherwise the local view and GitHub's view disagree.
	local problems=() b
	for b in "${chain_branches[@]}"; do
		if ! git show-ref --verify --quiet "refs/heads/$b"; then
			problems+=("$b: no local branch")
		elif ! git merge-base --is-ancestor "$b" "$stack"; then
			problems+=("$b: not an ancestor of $stack (local stack is out of sync)")
		fi
	done
	if [[ ${#problems[@]} -gt 0 ]]; then
		printf 'error: %d chain branch(es) do not match the local stack:\n' "${#problems[@]}" >&2
		printf '         %s\n' "${problems[@]}" >&2
		die "aborting: rebase/remap the stack first, or fix the PR bases on GitHub"
	fi

	# Merge order is the reverse of the walk: bottom PR first.
	local order_branches=() order_numbers=() order_titles=()
	local i width=0
	for ((i = ${#chain_branches[@]} - 1; i >= 0; i--)); do
		order_branches+=("${chain_branches[$i]}")
		order_numbers+=("${chain_numbers[$i]}")
		order_titles+=("${chain_titles[$i]}")
		[[ ${#chain_branches[$i]} -gt $width ]] && width=${#chain_branches[$i]}
	done

	local nl=$'\n'
	local buf="# Merge order plan for ${stack} (base ${base})${nl}"
	buf+="#${nl}"
	buf+="# Format: <branch-name>  #<pr-number>  <pr-title>${nl}"
	buf+="# Whole-line \"#\" comments only. Generated by pr-stack-merge-gh plan.${nl}"
	if [[ -n "$retarget_note" ]]; then
		buf+="#${nl}"
		buf+="# Bottom PR still targets ${retarget_note};${nl}"
		buf+="# merge-next retargets it onto ${base} before merging.${nl}"
	fi
	buf+="${nl}"
	for i in "${!order_branches[@]}"; do
		buf+="$(printf '%-*s  #%-5s %s' "$width" "${order_branches[$i]}" \
			"${order_numbers[$i]}" "${order_titles[$i]}")${nl}"
	done

	if [[ -n "$output" ]]; then
		printf '%s' "$buf" >"$output"
		printf 'Planned %d PR(s) for %s -> %s\n' "${#order_branches[@]}" "$stack" "$output" >&2
	else
		printf '%s' "$buf"
	fi
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

cmd_status() {
	[[ $# -eq 1 ]] || usage 1
	case "$1" in -h | --help) usage 0 ;; esac
	local plan_file="$1"
	[[ -f "$plan_file" ]] || die "plan file not found: $plan_file"

	local merged_count
	merged_count="$(grep -c '^# \[merged\] ' "$plan_file" || true)"
	parse_plan_file "$plan_file"

	printf 'Plan %s: %s merged, %d remaining.\n' "$plan_file" "$merged_count" "${#PLAN_BRANCHES[@]}"
	if [[ ${#PLAN_BRANCHES[@]} -eq 0 ]]; then
		printf '\nThe train is complete.\n'
		return 0
	fi
	printf '\nUp next:\n'
	local i marker
	for i in "${!PLAN_BRANCHES[@]}"; do
		if [[ $i -eq 0 ]]; then marker="->"; else marker="  "; fi
		printf '  %s #%-5s %-48s %s\n' \
			"$marker" "${PLAN_NUMBERS[$i]}" "${PLAN_BRANCHES[$i]}" "${PLAN_TITLES[$i]}"
	done
}

# ---------------------------------------------------------------------------
# checks
# ---------------------------------------------------------------------------

cmd_checks() {
	local number="" required_only=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--required-only) required_only="--required"; shift ;;
		--ignore-check) [[ -n "${2:-}" ]] || die "--ignore-check requires a value"; IGNORE_CHECKS+=("$2"); shift 2 ;;
		--ignore-checks-file) [[ -n "${2:-}" ]] || die "--ignore-checks-file requires a value"; load_ignore_checks_file "$2"; shift 2 ;;
		-h | --help) usage 0 ;;
		-*) die "unknown option: $1" ;;
		*) number="$1"; shift ;;
		esac
	done
	[[ -n "$number" ]] || usage 1
	require_tools

	local checks state summary
	checks="$(poll_checks "$number" "$required_only")" || die "could not read checks for PR #$number"
	state="${checks%%$'\t'*}"
	summary="${checks#*$'\t'}"
	[[ "$state" == "error" ]] && die "could not read checks for PR #$number: $summary"

	local rows
	rows="$(gh pr checks "$number" ${required_only:+--required} --json name,bucket \
		--jq '.[] | [.bucket, .name] | @tsv' 2>/dev/null)" || true

	if [[ -z "$rows" ]]; then
		printf 'No checks reported for PR #%s.\n' "$number"
		return 0
	fi

	printf 'Checks for PR #%s (as this script sees them):\n\n' "$number"
	local bucket name mark
	while IFS=$'\t' read -r bucket name; do
		[[ -n "$bucket" ]] || continue
		if check_is_ignored "$name"; then
			mark="ignored"
		else
			mark="$bucket"
		fi
		printf '  %-9s %s\n' "$mark" "$name"
	done <<<"$rows"

	printf '\nVerdict: %s (%s)\n' "$state" "$summary"

	local status pr_state pr_draft pr_decision blocker
	if status="$(poll_pr_status "$number")"; then
		IFS=$'\t' read -r pr_state pr_draft pr_decision <<<"$status"
		blocker="$(approval_blocker "$pr_draft" "$pr_decision")"
		if [[ -n "$blocker" ]]; then
			printf 'Review:  not ready — %s\n' "$blocker"
		else
			printf 'Review:  approved\n'
		fi
	fi
}

# ---------------------------------------------------------------------------
# merge-next
# ---------------------------------------------------------------------------

# Checks whose result must not gate a merge, as exact names or globs. Filled
# from --ignore-checks-file and/or repeated --ignore-check flags.
IGNORE_CHECKS=()

# check_is_ignored <check-name>
#
# Patterns are matched with bash globbing, so a plain name matches exactly and
# "codecov*" or "*(macos*)" match families. Names routinely contain spaces,
# parentheses and commas, so patterns are never split on anything.
check_is_ignored() {
	local name="$1" pattern
	for pattern in ${IGNORE_CHECKS[@]+"${IGNORE_CHECKS[@]}"}; do
		# shellcheck disable=SC2053  # unquoted RHS: glob matching is the point
		[[ "$name" == $pattern ]] && return 0
	done
	return 1
}

# poll_pr_status <pr-number>
#
# Prints "<state><TAB><isDraft><TAB><reviewDecision>" in one API call, so the
# wait loop learns in a single round whether the PR was merged or closed under
# it, whether it is still a draft, and whether it has been approved.
# reviewDecision is "" when nobody has reviewed and branch protection does not
# demand one — which is "not approved yet", not "approval not applicable".
poll_pr_status() {
	local number="$1" out
	out="$(gh_json pr view "$number" --json state,isDraft,reviewDecision \
		--jq '[.state, (.isDraft | tostring), (.reviewDecision // "")] | @tsv')" || return 1
	printf '%s' "$out"
}

# approval_blocker <is-draft> <review-decision>
#
# Prints why the PR may not be merged yet, or nothing when it is good to go.
approval_blocker() {
	local is_draft="$1" decision="$2"
	if [[ "$is_draft" == "true" ]]; then
		printf 'PR is still a draft'
		return 0
	fi
	case "$decision" in
	APPROVED) ;;
	CHANGES_REQUESTED) printf 'a reviewer requested changes' ;;
	REVIEW_REQUIRED) printf 'a required review is missing' ;;
	"") printf 'no approving review yet' ;;
	*) printf 'review decision is %s' "$decision" ;;
	esac
}

# poll_checks <pr-number> [--required]
#
# One non-interactive look at a PR's checks. Prints "<state><TAB><summary>",
# where state is green | red | pending | none | error. Ignored checks are
# dropped before the state is computed, so they can neither fail nor stall a
# merge. "error" carries gh's own message and is a transient condition for
# the caller to retry, not a verdict about the PR.
#
# Deliberately does not use `gh pr checks --watch`: that renders a live
# redrawing terminal UI, blocks for an unbounded time, and makes a mess of
# log files.
poll_checks() {
	local number="$1" required="${2:-}"
	local args=(pr checks "$number" --json name,bucket)
	[[ -n "$required" ]] && args+=(--required)

	local out rc=0 err_file
	err_file="$(mktemp)"
	out="$(gh "${args[@]}" --jq '.[] | [.bucket, .name] | @tsv' 2>"$err_file")" || rc=$?

	# gh exits 8 when a PR has no checks at all and nonzero when checks are
	# failing (with output). Empty output with any other status means the query
	# itself failed — a network blip, a rate limit, a 5xx.
	if [[ -z "$out" ]]; then
		if [[ "$rc" -eq 0 || "$rc" -eq 8 ]]; then
			rm -f "$err_file"
			printf 'none\tno checks reported'
			return 0
		fi
		local message
		message="$(tr '\n' ' ' <"$err_file" | tr -s ' ')"
		message="${message%"${message##*[![:space:]]}"}"
		rm -f "$err_file"
		printf 'error\t%s' "${message:-gh exited $rc}"
		return 0
	fi
	rm -f "$err_file"

	local bucket name
	local fail=0 pending=0 pass=0 other=0 ignored=0
	local failing=()
	while IFS=$'\t' read -r bucket name; do
		[[ -n "$bucket" ]] || continue
		if check_is_ignored "$name"; then
			ignored=$((ignored + 1))
			continue
		fi
		case "$bucket" in
		fail | cancel) fail=$((fail + 1)); failing+=("$name") ;;
		pending) pending=$((pending + 1)) ;;
		pass) pass=$((pass + 1)) ;;
		*) other=$((other + 1)) ;;
		esac
	done <<<"$out"

	local summary
	summary="$(printf '%d passed, %d failed, %d pending' "$pass" "$fail" "$pending")"
	[[ "$other" -gt 0 ]] && summary+=", $other skipped"
	[[ "$ignored" -gt 0 ]] && summary+=", $ignored ignored"

	if [[ "$fail" -gt 0 ]]; then
		local joined
		joined="$(printf '%s; ' "${failing[@]}")"
		printf 'red\t%s — failing: %s' "$summary" "${joined%'; '}"
	elif [[ "$pending" -gt 0 ]]; then
		printf 'pending\t%s' "$summary"
	else
		printf 'green\t%s' "$summary"
	fi
}

# load_ignore_checks_file <path>
#
# One pattern per line; blank lines and whole-line "#" comments skipped. Not
# split on commas or spaces — check names contain both.
load_ignore_checks_file() {
	local file="$1" line
	[[ -f "$file" ]] || die "ignore-checks file not found: $file"
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"
		[[ -n "$line" && "$line" != \#* ]] || continue
		IGNORE_CHECKS+=("$line")
	done <"$file"
}

# verify_stack_sync <map-file> <base> <stack> <branch> <remote>
#
# The two conditions that must hold before a merge is safe: every mapped branch
# sits on its mapped commit, and the PR branch matches its remote tip. Aborts
# with a resume hint if either fails. Re-checked after any CI wait, because the
# usual way CI goes green is somebody pushing to the PR branch.
verify_stack_sync() {
	local map_file="$1" base="$2" stack="$3" branch="$4" remote="$5"

	"$PR_STACK" remap --check --base "$base" "$map_file" "$stack" ||
		die_resumable "the local branches do not match $map_file" \
			"Fix with: $PR_STACK remap --apply --base $base $map_file $stack"

	git fetch --quiet "$remote" "$branch" ||
		die_resumable "could not fetch $remote/$branch"
	local local_tip remote_tip
	local_tip="$(git rev-parse "refs/heads/$branch")"
	remote_tip="$(git rev-parse FETCH_HEAD)"
	[[ "$local_tip" == "$remote_tip" ]] ||
		die_resumable "$branch differs from $remote/$branch (local ${local_tip:0:12}, remote ${remote_tip:0:12})" \
			"CI on a stale head means nothing. If the fix was pushed by someone else, pull it
into the stack and restack before merging:
  git fetch $remote && git branch -f $branch $remote/$branch
  git rebase --onto $branch <old-tip> $stack   # then remap --apply and push
Otherwise push what you have: $PR_STACK push --remote $remote $map_file"
	note "$branch matches $remote/$branch at ${local_tip:0:12}"
}

cmd_merge_next() {
	local base="main" stack="" remote="origin" merge_method="merge"
	local skip_ci=0 skip_approval=0 dry_run=0 ci_interval=30 merge_timeout=300
	local wait_ci=1 ci_retry_interval=120 ci_timeout=0 no_checks_timeout=900
	local required_only=""
	local positional=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--base) base="${2:-}"; [[ -n "$base" ]] || die "--base requires a value"; shift 2 ;;
		--stack) stack="${2:-}"; [[ -n "$stack" ]] || die "--stack requires a value"; shift 2 ;;
		--remote) remote="${2:-}"; [[ -n "$remote" ]] || die "--remote requires a value"; shift 2 ;;
		--merge-method) merge_method="${2:-}"; shift 2 ;;
		--ci-interval) ci_interval="${2:-}"; [[ -n "$ci_interval" ]] || die "--ci-interval requires a value"; shift 2 ;;
		--ci-retry-interval) ci_retry_interval="${2:-}"; [[ -n "$ci_retry_interval" ]] || die "--ci-retry-interval requires a value"; shift 2 ;;
		--ci-timeout) ci_timeout="${2:-}"; [[ -n "$ci_timeout" ]] || die "--ci-timeout requires a value"; shift 2 ;;
		--no-checks-timeout) no_checks_timeout="${2:-}"; [[ -n "$no_checks_timeout" ]] || die "--no-checks-timeout requires a value"; shift 2 ;;
		--merge-timeout) merge_timeout="${2:-}"; [[ -n "$merge_timeout" ]] || die "--merge-timeout requires a value"; shift 2 ;;
		--wait-ci) wait_ci=1; shift ;;
		--no-wait-ci) wait_ci=0; shift ;;
		--required-only) required_only="--required"; shift ;;
		--ignore-check) [[ -n "${2:-}" ]] || die "--ignore-check requires a value"; IGNORE_CHECKS+=("$2"); shift 2 ;;
		--ignore-checks-file) [[ -n "${2:-}" ]] || die "--ignore-checks-file requires a value"; load_ignore_checks_file "$2"; shift 2 ;;
		--skip-ci) skip_ci=1; shift ;;
		--skip-approval) skip_approval=1; shift ;;
		--dry-run) dry_run=1; shift ;;
		-h | --help) usage 0 ;;
		--) shift; while [[ $# -gt 0 ]]; do positional+=("$1"); shift; done ;;
		-*) die "unknown option: $1" ;;
		*) positional+=("$1"); shift ;;
		esac
	done
	[[ ${#positional[@]} -eq 2 ]] || usage 1
	local plan_file="${positional[0]}" map_file="${positional[1]}"
	[[ -f "$plan_file" ]] || die "plan file not found: $plan_file"
	[[ -f "$map_file" ]] || die "map file not found: $map_file"
	case "$merge_method" in
	merge | squash | rebase) ;;
	*) die "--merge-method must be one of: merge, squash, rebase" ;;
	esac

	require_tools
	stack="${stack:-$(current_branch)}"
	RESUME_HINT="$0 merge-next --base $base --stack $stack $plan_file $map_file"

	# --- preflight -------------------------------------------------------
	step "Preflight"

	local git_dir
	git_dir="$(git rev-parse --git-dir)"
	[[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]] &&
		die "a rebase is already in progress — finish or abort it first (git rebase --abort)"
	# Untracked files are fine (the plan and map often live in the tree); only
	# tracked modifications would block the rebase.
	[[ -z "$(git status --porcelain --untracked-files=no)" ]] ||
		die "working tree has uncommitted changes — commit or stash first"
	git show-ref --verify --quiet "refs/heads/$base" || die "base branch not found locally: $base"
	git rev-parse --verify --quiet "$stack^{commit}" >/dev/null || die "stack branch not found: $stack"

	parse_plan_file "$plan_file"
	if [[ ${#PLAN_BRANCHES[@]} -eq 0 ]]; then
		printf 'Nothing left in %s — the train is complete.\n' "$plan_file"
		return 0
	fi

	local branch="${PLAN_BRANCHES[0]}" number="${PLAN_NUMBERS[0]}" title="${PLAN_TITLES[0]}"
	note "target: #$number $branch"
	note "title:  $title"
	note "$((${#PLAN_BRANCHES[@]} - 1)) PR(s) queued behind it"

	git show-ref --verify --quiet "refs/heads/$branch" || die "PR branch not found locally: $branch"

	# --- PR state --------------------------------------------------------
	step "Checking PR #$number on GitHub"

	local pr_fields pr_state pr_base pr_head pr_merged
	pr_fields="$(gh_json pr view "$number" --json state,baseRefName,headRefName,mergedAt \
		--jq '[.state, .baseRefName, .headRefName, (.mergedAt // "")] | @tsv')" ||
		die "failed to read PR #$number (after retries)"
	IFS=$'\t' read -r pr_state pr_base pr_head pr_merged <<<"$pr_fields"

	[[ "$pr_head" == "$branch" ]] ||
		die "PR #$number head is $pr_head, but the plan says $branch — regenerate the plan"

	local already_merged=0
	case "$pr_state" in
	MERGED)
		already_merged=1
		note "already merged at $pr_merged — resuming the post-merge steps"
		;;
	OPEN)
		note "state: OPEN, base: $pr_base"
		;;
	*)
		die "PR #$number is $pr_state — expected OPEN (or MERGED, to resume)"
		;;
	esac

	if [[ "$already_merged" -eq 0 ]]; then
		# The map must still cover the branch, or advance/remap/push would not
		# act on it. Only meaningful pre-merge: once merged, advance is expected
		# to have commented it out already (that is the resume path).
		map_has_active_branch "$map_file" "$branch" ||
			die "$branch has no active entry in $map_file — advance/remap/push would not cover it"

		# --- local vs remote consistency ---------------------------------
		step "Verifying the local stack matches $map_file"
		verify_stack_sync "$map_file" "$base" "$stack" "$branch" "$remote"

		# --- retarget ----------------------------------------------------
		if [[ "$pr_base" != "$base" ]]; then
			step "Retargeting PR #$number: $pr_base -> $base"
			if [[ "$dry_run" -eq 1 ]]; then
				note "(dry run) gh pr edit $number --base $base"
			else
				gh pr edit "$number" --base "$base" </dev/null ||
					die_resumable "failed to retarget PR #$number onto $base" \
						"\"Resource not accessible by personal access token\" means the gh token
cannot write to this repo — fine-grained PATs never can, for repos owned by
someone else. Retry with a classic PAT (repo scope) or an OAuth login:
  GH_TOKEN=ghp_… $RESUME_HINT
  gh auth login --hostname github.com --web"
				note "retargeted"
			fi
		fi

		if [[ "$dry_run" -eq 1 ]]; then
			step "Dry run"
			note "would wait for approval and CI, merge #$number with --$merge_method, then:"
			note "  $PR_STACK advance --remote $remote --base $base $map_file"
			note "  git rebase $base $stack"
			note "  $PR_STACK remap --apply --base $base $map_file $stack"
			note "  $PR_STACK push --remote $remote $map_file"
			note "  comment #$number out of $plan_file"
			return 0
		fi

		# --- readiness: approval + CI ------------------------------------
		local ci_rounds=0
		if [[ "$skip_ci" -eq 1 && "$skip_approval" -eq 1 ]]; then
			step "Skipping the approval and CI waits (--skip-approval --skip-ci)"
		else
			step "Waiting for PR #$number to become mergeable"
			local checks ci_state summary waited_ci=0 no_checks_waited=0
			local delay reason head_oid last_head=""
			local status pr_now pr_draft pr_decision blocker
			while :; do
				# One call answers three questions: did the PR move under us, is
				# it still a draft, and has it been approved.
				if status="$(poll_pr_status "$number")"; then
					IFS=$'\t' read -r pr_now pr_draft pr_decision <<<"$status"
				else
					pr_now=""; pr_draft=""; pr_decision=""
				fi

				case "$pr_now" in
				MERGED)
					note "someone merged #$number while we were waiting — resuming post-merge steps"
					already_merged=1
					break
					;;
				CLOSED)
					die_resumable "PR #$number was closed while waiting"
					;;
				esac

				blocker=""
				if [[ "$skip_approval" -eq 0 ]]; then
					if [[ -z "$pr_now" ]]; then
						blocker="could not read the PR's review state"
					else
						blocker="$(approval_blocker "$pr_draft" "$pr_decision")"
					fi
				fi

				if [[ "$skip_ci" -eq 1 ]]; then
					ci_state="green"
					summary="checks skipped"
				else
					checks="$(poll_checks "$number" "$required_only")" ||
						checks="$(printf 'error\tpoll_checks failed unexpectedly')"
					ci_state="${checks%%$'\t'*}"
					summary="${checks#*$'\t'}"
				fi

				if [[ -z "$blocker" && "$ci_state" == "green" ]]; then
					if [[ "$skip_approval" -eq 1 ]]; then
						note "checks are green ($summary)"
					else
						note "approved and checks are green ($summary)"
					fi
					break
				fi

				# Approval outranks CI: no point reporting a red build as the
				# blocker when the PR could not be merged approved-or-not. This
				# also keeps --no-checks-timeout from firing while the real wait
				# is on a human.
				if [[ -n "$blocker" ]]; then
					[[ "$wait_ci" -eq 1 ]] ||
						die_resumable "PR #$number is not ready to merge: $blocker" \
							"Get it approved, then re-run — or drop --no-wait-ci to keep waiting.
Use --skip-approval to merge without one."
					if [[ "$ci_timeout" -gt 0 && "$waited_ci" -ge "$ci_timeout" ]]; then
						die_resumable "PR #$number still not approved after ${waited_ci}s ($blocker)" \
							"Get it approved, then re-run."
					fi
					tick "$blocker; checks: $summary — next check in ${ci_retry_interval}s"
					sleep "$ci_retry_interval"
					waited_ci=$((waited_ci + ci_retry_interval))
					ci_rounds=$((ci_rounds + 1))
					continue
				fi

				# A failed query says nothing about the PR: wait it out like any
				# other not-yet-green state rather than tearing down the run.
				if [[ "$ci_state" == "error" ]]; then
					[[ "$wait_ci" -eq 1 ]] ||
						die_resumable "could not read check status for PR #$number" "$summary"
					if [[ "$ci_timeout" -gt 0 && "$waited_ci" -ge "$ci_timeout" ]]; then
						die_resumable "could not read check status for PR #$number after ${waited_ci}s" "$summary"
					fi
					tick "could not read checks ($summary) — retrying in ${ci_retry_interval}s"
					sleep "$ci_retry_interval"
					waited_ci=$((waited_ci + ci_retry_interval))
					ci_rounds=$((ci_rounds + 1))
					continue
				fi

				case "$ci_state" in
				pending)
					# Normal progress, not a failure: poll at the tighter cadence.
					delay="$ci_interval"
					reason="checks running ($summary)"
					no_checks_waited=0
					;;
				red)
					[[ "$wait_ci" -eq 1 ]] ||
						die_resumable "CI is not green for PR #$number ($summary)" \
							"Fix the failures and push, then re-run — or drop --no-wait-ci to keep waiting for a fix."
					delay="$ci_retry_interval"
					reason="checks red ($summary)"
					no_checks_waited=0
					;;
				none)
					# "No checks at all" is usually a configuration fact rather
					# than a state that resolves itself, so it gets its own leash.
					[[ "$wait_ci" -eq 1 ]] ||
						die_resumable "no CI checks are reported for PR #$number" \
							"Re-run with --skip-ci if this PR genuinely has no checks, or drop --no-wait-ci to wait for them to appear."
					if [[ "$no_checks_timeout" -gt 0 && "$no_checks_waited" -ge "$no_checks_timeout" ]]; then
						die_resumable "no CI checks appeared for PR #$number after ${no_checks_waited}s" \
							"If this PR genuinely has no checks, re-run with --skip-ci.
If checks are just slow to register, raise --no-checks-timeout (0 waits forever)."
					fi
					delay="$ci_retry_interval"
					reason="no checks reported yet"
					no_checks_waited=$((no_checks_waited + delay))
					;;
				esac

				if [[ "$ci_timeout" -gt 0 && "$waited_ci" -ge "$ci_timeout" ]]; then
					die_resumable "CI for #$number is still not green after ${waited_ci}s (--ci-timeout)" \
						"Fix the failures and push, then re-run."
				fi

				# A moved head means someone pushed a fix; CI restarts on it.
				head_oid="$(gh_json pr view "$number" --json headRefOid --jq .headRefOid)" || head_oid=""
				if [[ -n "$head_oid" && -n "$last_head" && "$head_oid" != "$last_head" ]]; then
					tick "head moved to ${head_oid:0:12} — CI will re-run"
				fi
				last_head="$head_oid"

				tick "$reason — next check in ${delay}s"
				sleep "$delay"
				waited_ci=$((waited_ci + delay))
				ci_rounds=$((ci_rounds + 1))
			done
		fi

		# --- merge -------------------------------------------------------
		if [[ "$already_merged" -eq 0 ]]; then
			# If we waited, the branch may have moved under us (that is usually
			# how CI turns green) — re-check before merging something the local
			# stack no longer reflects.
			if [[ "$ci_rounds" -gt 0 ]]; then
				step "Re-verifying the stack after the CI wait"
				verify_stack_sync "$map_file" "$base" "$stack" "$branch" "$remote"
			fi

			step "Merging PR #$number via GitHub (--$merge_method)"
			gh pr merge "$number" "--$merge_method" </dev/null ||
				die_resumable "gh pr merge failed for #$number" \
					"If the PR needs approvals or is blocked, resolve it on GitHub, then re-run.
If it failed with \"Resource not accessible by personal access token\", the gh
token cannot write to this repo: use a classic PAT (repo scope) via GH_TOKEN,
or run \`gh auth login --hostname github.com --web\`."

			# GitHub merges asynchronously; do not touch the stack until it lands.
			local waited=0 merge_state=""
			while :; do
				merge_state="$(gh_json pr view "$number" --json state --jq .state)" || merge_state=""
				[[ "$merge_state" == "MERGED" ]] && break
				[[ "$waited" -ge "$merge_timeout" ]] &&
					die_resumable "PR #$number is still \"$merge_state\" after ${merge_timeout}s" \
						"Check the PR, then re-run — the post-merge steps will resume."
				sleep 5
				waited=$((waited + 5))
			done
			note "merged after ${waited}s"
		fi
	fi

	# --- advance ---------------------------------------------------------
	step "Advancing $base and updating $map_file"
	"$PR_STACK" advance --remote "$remote" --base "$base" "$map_file" ||
		die_resumable "pr-stack.sh advance failed"

	if map_has_active_branch "$map_file" "$branch"; then
		die_resumable "$branch is still active in $map_file after advance" \
			"The merge did not land in $base as expected; inspect the PR and the map before re-running."
	fi
	note "$branch is commented out in $map_file"

	# --- restack ---------------------------------------------------------
	local remaining
	remaining="$(git rev-list --count "$base..$stack")"
	if [[ "$remaining" -eq 0 ]]; then
		step "Stack is empty above $base — nothing left to restack"
	else
		step "Rebasing $stack onto $base ($remaining commit(s))"
		if ! git rebase "$base" "$stack"; then
			git rebase --abort || true
			die_resumable "rebase of $stack onto $base hit a conflict (aborted, tree is clean)" \
				"Resolve it by hand:
  git rebase $base $stack       # and fix the conflicts
  $PR_STACK remap --apply --base $base $map_file $stack
  $PR_STACK push --remote $remote $map_file
Then re-run this command: it will see #$number as merged and finish the bookkeeping."
		fi

		step "Remapping the PR branches"
		"$PR_STACK" remap --apply --base "$base" "$map_file" "$stack" ||
			die_resumable "pr-stack.sh remap --apply failed"

		step "Pushing the restacked branches"
		"$PR_STACK" push --remote "$remote" "$map_file" ||
			die_resumable "pr-stack.sh push failed" \
				"Re-run after fixing the push; the merge itself is already done."
	fi

	# --- plan bookkeeping ------------------------------------------------
	step "Marking #$number as merged in $plan_file"
	comment_out_plan_entry "$plan_file" "$branch" "$number"

	# The next PR still points at the branch we just merged; retarget it now so
	# it shows a clean diff in the meantime. Best effort: the next merge-next
	# run retargets it anyway, so a failure here is not worth aborting over.
	if [[ ${#PLAN_BRANCHES[@]} -gt 1 ]]; then
		local next_number="${PLAN_NUMBERS[1]}" next_branch="${PLAN_BRANCHES[1]}"
		step "Retargeting the next PR #$next_number ($next_branch) onto $base"
		if gh pr edit "$next_number" --base "$base" </dev/null; then
			note "retargeted"
		else
			printf 'warning: could not retarget #%s onto %s; the next merge-next run will retry\n' \
				"$next_number" "$base" >&2
		fi
	fi

	printf '\n%sDone.%s #%s (%s) is merged and the stack is restacked on %s.\n' \
		"$BOLD" "$RESET" "$number" "$branch" "$base"
	if [[ ${#PLAN_BRANCHES[@]} -gt 1 ]]; then
		printf 'Next up: #%s %s\n' "${PLAN_NUMBERS[1]}" "${PLAN_BRANCHES[1]}"
	else
		printf 'That was the last PR in the plan.\n'
	fi
}

# ---------------------------------------------------------------------------
# merge-all
# ---------------------------------------------------------------------------

cmd_merge_all() {
	# Everything except --max is forwarded to merge-next verbatim.
	local max=0 forward=() dry_run=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--max) max="${2:-}"; [[ -n "$max" ]] || die "--max requires a value"; shift 2 ;;
		--dry-run) dry_run=1; forward+=("$1"); shift ;;
		-h | --help) usage 0 ;;
		*) forward+=("$1"); shift ;;
		esac
	done

	# merge-next takes the plan and map as its final two positionals; the loop
	# needs the plan to know when the train is drained.
	local count=${#forward[@]}
	[[ "$count" -ge 2 ]] || usage 1
	local plan_file="${forward[$((count - 2))]}" map_file="${forward[$((count - 1))]}"
	[[ -f "$plan_file" ]] || die "plan file not found: $plan_file (it must be the second-to-last argument)"
	[[ -f "$map_file" ]] || die "map file not found: $map_file (it must be the last argument)"

	if [[ "$dry_run" -eq 1 ]]; then
		# A dry run merges nothing, so looping would never terminate.
		cmd_merge_next "${forward[@]}"
		return 0
	fi

	local merged=0 before after
	while :; do
		parse_plan_file "$plan_file"
		before=${#PLAN_BRANCHES[@]}

		if [[ "$before" -eq 0 ]]; then
			printf '\n%sTrain complete.%s %d PR(s) merged this run.\n' "$BOLD" "$RESET" "$merged"
			return 0
		fi
		if [[ "$max" -gt 0 && "$merged" -ge "$max" ]]; then
			printf '\n%sStopping after %d merge(s)%s (--max); %d PR(s) still queued.\n' \
				"$BOLD" "$merged" "$RESET" "$before"
			return 0
		fi

		step "Train: merging #${PLAN_NUMBERS[0]} ${PLAN_BRANCHES[0]} ($before left, $merged done)"
		cmd_merge_next "${forward[@]}"

		# Guard against a merge-next that returns success without consuming an
		# entry, which would spin forever.
		parse_plan_file "$plan_file"
		after=${#PLAN_BRANCHES[@]}
		[[ "$after" -lt "$before" ]] ||
			die "merge-next reported success but $plan_file still lists $after PR(s) — stopping instead of looping"
		merged=$((merged + 1))
	done
}

[[ $# -gt 0 ]] || usage 1
command="$1"
shift
case "$command" in
plan) cmd_plan "$@" ;;
merge-next) cmd_merge_next "$@" ;;
merge-all) cmd_merge_all "$@" ;;
status) cmd_status "$@" ;;
checks) cmd_checks "$@" ;;
-h | --help) usage 0 ;;
*) die "unknown command: $command (expected 'plan', 'merge-next', 'merge-all', 'status', or 'checks')" ;;
esac
