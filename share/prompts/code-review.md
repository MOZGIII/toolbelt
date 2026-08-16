<!--
Prompt template for pr-stack-review-claude.sh.

Placeholder names (double-braced, spelled bare here so they survive this
comment): BRANCH, BASE, RANGE, PR, TITLE, REPO_ROOT, REVIEW_FILE,
VERDICT_FILE. Every occurrence in this file is substituted before the run,
including inside comments, so keep prose about them brace-free.

What must survive any rewrite is the contract the script enforces afterwards:
the review must be written to the REVIEW_FILE path, and the verdict to the
VERDICT_FILE path as exactly "true" or "false" and nothing else. Miss either
and the script fails the branch and stops the train. What Claude prints is
captured separately, so the transcript is never the deliverable.
-->

Review pull request #{{PR}} — {{TITLE}}.

`{{BRANCH}}` is checked out at `{{REPO_ROOT}}`. It sits on top of `{{BASE}}`
in a stacked-PR train, so its parent branch is already known and the scope of
this PR is exactly `git diff {{RANGE}}` — everything below `{{BASE}}` belongs
to the PRs underneath and has been reviewed already. Establish the scope from
that diff, then review it to determine whether it is merge ready.

Use your existing code review skill, and verify every suggestion and every
edge case you raise: check each one against the code before it goes in the
review, and drop the ones that do not survive.

Do that verification with subagents rather than inline — dispatch them in a
single batch so they run in parallel, one per finding, each told to argue
against the finding it was given and to report what it actually found in the
code. Run them synchronously (not in the background): this is a headless run,
so a subagent still in flight when the turn ends is a verification you never
received. Their conclusions decide what stays in the review.

Frame the output mostly as questions that should be asked in the review.
Comment on both architecture suggestions and specific issues with the current
approach.

When you are done, write two files:

1. `{{REVIEW_FILE}}` — the review, in Markdown. Lead with what the change
   does, then the questions and findings, most serious first, each anchored to
   the file and line it is about. Say so plainly if a section came back with
   nothing worth raising.

2. `{{VERDICT_FILE}}` — a single word, `true` if this PR is merge ready as it
   stands, `false` if anything in the review should hold it up. Nothing else
   in the file: it is read by a script, not a person.
