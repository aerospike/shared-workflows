# Agent Instructions

These rules apply to every change in this repo, whichever tool writes it. Repo layout, input naming, the artifact pipeline, and test commands are in `CLAUDE.md`.

## Inputs and actions

- Add an input only when a current caller sets it. Pin tool, chart, and image versions inside the action instead of exposing them as inputs.
- Do not add an input that does the same job as an existing one.
- Do not declare the same input on two actions. When one action needs a value another action decided, read it from that action's outputs.
- Before writing install, retry, or validation logic, check for a maintained action or a flag of the underlying tool that already does it.
- Add a reusable workflow only when a composite action cannot do the job (job environment, signer identity, `job_workflow_sha`).

## Scripts

- Do not embed Python or any other language in a shell script, a bats test, or a workflow `run:` block (`python3 -c`, `python3 - <<EOF`). Use the CLI built for the format, such as `jq` for JSON and `yq` for YAML, or write a standalone script in one language.
- Use Python only when the logic exceeds what the CLI can do: stateful iteration, library calls, or a real parser. Reading or validating a field never qualifies. `jq empty` validates JSON.

## Tests

- Test behavior that can regress and paths that must fail closed. Skip tests for failures that are unlikely to happen and tests whose path another test already covers.
- Assert on the lines that matter. Do not commit golden copies of whole generated files, such as full configs or full `docker run` argument lists, since every flag change rewrites them.

## Code comments

- Keep a comment only when it names a mistake a reader would otherwise make, such as "`-H` puts the token in argv".
- Delete a comment that restates the code, explains why the code is shaped this way, narrates the approach or the development process, records a finding or a measurement, or argues a choice to a reviewer. Findings go in the PR body or the ticket.
- A comment describes code that is on the page. Do not explain a removed step, a permission that is not requested, or an argument that is no longer passed. That rationale goes in the commit message.
- No history ("used to", "previously", "no longer"), no development state ("for now", "temporary until"), and no phase or task references. A ticket link is acceptable only when it is the one pointer to context that cannot be written inline, such as a held-back version pin.
- Do not guard against a mistake nobody is making ("do not add X here").
- Match the comment density of the surrounding code. Never raise it.

Tests and linters do not check comment content, so a passing suite says nothing about it.

## Documentation

- When a PR touches a Markdown file, review the whole file, not only the changed lines. Fix filler, duplicates, inaccuracies, and text the change now contradicts.
- Write what the reader needs and stop: "Callers grant `contents: read` and `id-token: write`." Do not document things that no longer exist, and do not keep troubleshooting entries for errors that cannot occur at the current ref.
- Brevity is not ellipsis. Name the subject and object in full: "Runner label for the job", not "Runner".
- State facts. Do not defend the work against an objection nobody raised, describe how carefully it was checked, or add "what changed" or correction sections.
- Use a plain, technical register. No colloquial metaphors, intensifiers ("genuinely", "really", "actually"), or casual asides. Precise technical terms are fine.
- Use plain verbs: "X has Y", "Y is added to X", "the check is in the workflow". Do not give files or fields agency ("owns", "lands", "surfaces", "carries").
- Do not use the "This isn't X. It's Y." construction, em dashes, or the phrases "load-bearing", "that is the crux", "worth knowing", and "the trap here".
- Keep release notes and announcements calm: say what changed and what it means for callers. Use `[!NOTE]` unless something breaks.

## Before marking a PR ready

- Reread the diff for size. Fold helpers that have one caller, drop parameters nothing uses, and drop tests that repeat another test's assertions.
- When a helper only cleans up after an earlier choice in the same change, revisit that choice instead of keeping the helper.
- List every input the PR adds in the PR body, with the caller that sets it.
