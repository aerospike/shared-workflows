#!/usr/bin/env bats
# Tests for PR hygiene allowlist pattern matching

GIT_ROOT="$(git rev-parse --show-toplevel)"
HELPERS_DIR="$GIT_ROOT/.github/workflows/pr-hygiene/tests/helpers"
load "$HELPERS_DIR/setup.bash"

# --- Default pattern tests ---

@test "Dependabot title matches default pattern" {
    title_matches_patterns 'Build(deps): bump step-security/harden-runner from 2.14.0 to 2.14.2' "${DEFAULT_PATTERNS[@]}"
}

@test "Dependabot dev-deps title matches default pattern" {
    title_matches_patterns 'Build(deps-dev): bump eslint from 8.0.0 to 9.0.0' "${DEFAULT_PATTERNS[@]}"
}

@test "StepSecurity title matches default pattern" {
    title_matches_patterns '[StepSecurity] Apply security best practices' "${DEFAULT_PATTERNS[@]}"
}

@test "Revert with quotes matches default pattern" {
    title_matches_patterns 'Revert "feat(workflows): [INFRA-370] add integration tests"' "${DEFAULT_PATTERNS[@]}"
}

@test "lowercase revert matches default pattern" {
    title_matches_patterns 'revert: undo the thing' "${DEFAULT_PATTERNS[@]}"
}

# --- Non-matching tests ---

@test "conventional commit with JIRA does not match allowlist" {
    run title_matches_patterns 'feat(workflows): [INFRA-378] add pr hygiene checks' "${DEFAULT_PATTERNS[@]}"
    [ "$status" -ne 0 ]
}

@test "plain text title does not match allowlist" {
    run title_matches_patterns 'fix some bug' "${DEFAULT_PATTERNS[@]}"
    [ "$status" -ne 0 ]
}

@test "partial pattern match at wrong position does not match" {
    run title_matches_patterns 'feat: Build(deps) is not at start' "${DEFAULT_PATTERNS[@]}"
    [ "$status" -ne 0 ]
}

@test "empty title does not match allowlist" {
    run title_matches_patterns '' "${DEFAULT_PATTERNS[@]}"
    [ "$status" -ne 0 ]
}

# --- Custom pattern tests ---

@test "custom pattern matches when added" {
    local patterns=("${DEFAULT_PATTERNS[@]}" '^chore\(release\):')
    title_matches_patterns 'chore(release): 2.0.0' "${patterns[@]}"
}

@test "custom pattern does not affect default rejections" {
    local patterns=("${DEFAULT_PATTERNS[@]}" '^chore\(release\):')
    run title_matches_patterns 'feat: no jira ticket' "${patterns[@]}"
    [ "$status" -ne 0 ]
}

@test "custom-only patterns match when defaults are overridden" {
    local patterns=('^my-bot:')
    title_matches_patterns 'my-bot: automated update' "${patterns[@]}"
}

@test "default titles rejected when patterns are overridden" {
    local patterns=('^my-bot:')
    run title_matches_patterns 'Build(deps): bump something' "${patterns[@]}"
    [ "$status" -ne 0 ]
}

# --- JIRA ticket extraction tests ---

@test "valid title extracts JIRA ticket" {
    local ticket
    ticket=$(extract_jira_ticket "feat(workflows): [INFRA-378] add pr hygiene checks")
    [ "$ticket" = "INFRA-378" ]
}

@test "breaking change title without scope extracts JIRA ticket" {
    local ticket
    ticket=$(extract_jira_ticket "feat!: [INFRA-649] Major release on breaking API changes")
    [ "$ticket" = "INFRA-649" ]
}

@test "breaking change title with scope extracts JIRA ticket" {
    local ticket
    ticket=$(extract_jira_ticket "feat(workflows)!: [INFRA-649] Major release on breaking API changes")
    [ "$ticket" = "INFRA-649" ]
}

@test "missing JIRA ticket returns empty" {
    local ticket
    ticket=$(extract_jira_ticket "feat: missing jira ticket")
    [ -z "$ticket" ]
}

@test "JIRA without brackets returns empty" {
    local ticket
    ticket=$(extract_jira_ticket "feat(scope): INFRA-123 missing brackets")
    [ -z "$ticket" ]
}

# --- Edge cases ---

@test "Revert with single quotes does not match default pattern" {
    run title_matches_patterns "Revert 'some change'" "${DEFAULT_PATTERNS[@]}"
    [ "$status" -ne 0 ]
}

@test "Build without deps scope does not match Dependabot pattern" {
    run title_matches_patterns 'Build: something else' "${DEFAULT_PATTERNS[@]}"
    [ "$status" -ne 0 ]
}

@test "lowercase build(deps) matches default pattern" {
    title_matches_patterns 'build(deps): bump foo from 1.0.0 to 2.0.0' "${DEFAULT_PATTERNS[@]}"
}

@test "chore(deps) matches default pattern" {
    title_matches_patterns 'chore(deps): bump bar from 1.0 to 2.0' "${DEFAULT_PATTERNS[@]}"
}

@test "fix(deps-dev) matches default pattern" {
    title_matches_patterns 'fix(deps-dev): bump eslint from 8.0 to 9.0' "${DEFAULT_PATTERNS[@]}"
}

@test "empty patterns array matches nothing" {
    local patterns=()
    run title_matches_patterns 'Build(deps): bump something' "${patterns[@]}"
    [ "$status" -ne 0 ]
}

# --- Commit type extraction tests ---

@test "extract_commit_type returns feat from conventional commit" {
    local ctype
    ctype=$(extract_commit_type "feat(workflows): [INFRA-378] add pr hygiene checks")
    [ "$ctype" = "feat" ]
}

@test "extract_commit_type returns chore from scopeless commit" {
    local ctype
    ctype=$(extract_commit_type "chore: update readme")
    [ "$ctype" = "chore" ]
}

# --- JIRA required types tests ---

@test "feat type requires JIRA with default types" {
    type_requires_jira "feat" "$DEFAULT_JIRA_REQUIRED_TYPES"
}

@test "fix type requires JIRA with default types" {
    type_requires_jira "fix" "$DEFAULT_JIRA_REQUIRED_TYPES"
}

@test "refactor type requires JIRA with default types" {
    type_requires_jira "refactor" "$DEFAULT_JIRA_REQUIRED_TYPES"
}

@test "chore type does not require JIRA with default types" {
    run type_requires_jira "chore" "$DEFAULT_JIRA_REQUIRED_TYPES"
    [ "$status" -ne 0 ]
}

@test "build type does not require JIRA with default types" {
    run type_requires_jira "build" "$DEFAULT_JIRA_REQUIRED_TYPES"
    [ "$status" -ne 0 ]
}

@test "perf type does not require JIRA with default types" {
    run type_requires_jira "perf" "$DEFAULT_JIRA_REQUIRED_TYPES"
    [ "$status" -ne 0 ]
}

@test "test type does not require JIRA with default types" {
    run type_requires_jira "test" "$DEFAULT_JIRA_REQUIRED_TYPES"
    [ "$status" -ne 0 ]
}

@test "empty jira-required-types means JIRA never required" {
    run type_requires_jira "feat" ""
    [ "$status" -ne 0 ]
}

@test "custom jira-required-types list is respected" {
    type_requires_jira "chore" "chore, test"
}

@test "type not in custom list does not require JIRA" {
    run type_requires_jira "feat" "chore, test"
    [ "$status" -ne 0 ]
}
