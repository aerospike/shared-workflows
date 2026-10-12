#!/usr/bin/env bats
#
# Behavioural tests for scan.sh, fully offline: a fake `snyk` on PATH stands in for the real
# CLI, so no network, token, registry, or Docker is needed. The fake writes a canned JSON
# report (FAKE_REPORT) to --json-file-output and exits FAKE_EXIT, which is exactly the contract
# scan.sh reads. Covers the verdict/threshold, the exit-code branches (findings, operational
# error, timeout), fail-on-issues gating, and the monitor branch.
#
# summarize.py (the verdict math) has its own unit tests in test_summarize.py, and the CLI bake
# (verify_cli_age.py) in test_verify_cli_age.py; this file exercises the scan.sh wiring around them.

GIT_ROOT="$(git rev-parse --show-toplevel)"
SCAN="$GIT_ROOT/.github/actions/snyk-container-scan/scan.sh"

REPORT_FINDINGS='{"vulnerabilities":[{"id":"CVE-1","severity":"critical","packageName":"openssl","version":"1.1"},{"id":"CVE-2","severity":"high","packageName":"tar","version":"1.3"},{"id":"CVE-2","severity":"high","packageName":"tar","version":"1.3"},{"id":"CVE-3","severity":"low","packageName":"curl","version":"7.6"}]}'
REPORT_CLEAN='{"vulnerabilities":[]}'

setup() {
  FAKE_BIN="$(mktemp -d)"
  cat >"$FAKE_BIN/snyk" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "container test" ]]; then
  out=""
  for a in "$@"; do [[ "$a" == --json-file-output=* ]] && out="${a#--json-file-output=}"; done
  [[ -n "$out" ]] && printf '%s' "$FAKE_REPORT" >"$out"
  exit "${FAKE_EXIT:-0}"
elif [[ "$1 $2" == "container monitor" ]]; then
  echo "Monitoring https://app.snyk.io/org/demo/project/abc123"
  exit 0
fi
exit 0
EOF
  chmod +x "$FAKE_BIN/snyk"
  export PATH="$FAKE_BIN:$PATH"
  export SNYK_TOKEN=dummy
  export IMAGE=repo/app:1 # scan.sh reads the image from the environment, not $1
  export MONITOR=false
  unset JFROG_TOKEN GITHUB_OUTPUT || true
  # Defaults; individual tests override.
  export FAKE_REPORT="$REPORT_FINDINGS"
  export FAKE_EXIT=1
}

teardown() {
  rm -rf "$FAKE_BIN"
}

@test "findings at or above threshold -> FAIL with deduped counts, exits 1" {
  export SEVERITY_THRESHOLD=high
  run bash "$SCAN" repo/app:1
  [ "$status" -eq 1 ] # fail-on-issues defaults true + verdict FAIL
  [[ "$output" == *"verdict=FAIL"* ]]
  [[ "$output" == *"critical=1"* ]]
  [[ "$output" == *"high=1"* ]]   # CVE-2 on two paths counts once
  [[ "$output" == *"total=3"* ]]
}

@test "fail-on-issues=false reports FAIL but exits 0" {
  export SEVERITY_THRESHOLD=high FAIL_ON_ISSUES=false
  run bash "$SCAN" repo/app:1
  [ "$status" -eq 0 ]
  [[ "$output" == *"verdict=FAIL"* ]]
}

@test "clean report -> PASS, exits 0" {
  export SEVERITY_THRESHOLD=high FAKE_REPORT="$REPORT_CLEAN" FAKE_EXIT=0
  run bash "$SCAN" repo/app:1
  [ "$status" -eq 0 ]
  [[ "$output" == *"verdict=PASS"* ]]
  [[ "$output" == *"total=0"* ]]
}

@test "threshold=critical ignores high/low -> PASS" {
  export SEVERITY_THRESHOLD=critical FAKE_EXIT=0 \
    FAKE_REPORT='{"vulnerabilities":[{"id":"H","severity":"high"},{"id":"L","severity":"low"}]}'
  run bash "$SCAN" repo/app:1
  [ "$status" -eq 0 ]
  [[ "$output" == *"verdict=PASS"* ]]
}

@test "snyk operational error (exit >= 2) -> ERROR verdict, exits 1" {
  export FAKE_EXIT=2
  run bash "$SCAN" repo/app:1
  [ "$status" -eq 1 ]
  [[ "$output" == *"verdict=ERROR"* ]]
}

@test "snyk exit 124 -> TIMEOUT verdict, exits 1 under fail-on-issues" {
  export FAKE_EXIT=124
  run bash "$SCAN" repo/app:1
  [ "$status" -eq 1 ]
  [[ "$output" == *"verdict=TIMEOUT"* ]]
}

@test "snyk exit 124 with fail-on-issues=false -> TIMEOUT, exits 0" {
  export FAKE_EXIT=124 FAIL_ON_ISSUES=false
  run bash "$SCAN" repo/app:1
  [ "$status" -eq 0 ]
  [[ "$output" == *"verdict=TIMEOUT"* ]]
}

@test "monitor=true with SNYK_ORG emits a portal URL" {
  export SEVERITY_THRESHOLD=high FAIL_ON_ISSUES=false MONITOR=true SNYK_ORG=demo-org
  run bash "$SCAN" repo/app:1
  [ "$status" -eq 0 ]
  [[ "$output" == *"monitored=https://app.snyk.io/org/demo/project/abc123"* ]]
}

@test "monitor=true without SNYK_ORG warns and leaves monitored empty" {
  export SEVERITY_THRESHOLD=high FAIL_ON_ISSUES=false MONITOR=true
  unset SNYK_ORG || true
  run bash "$SCAN" repo/app:1
  [ "$status" -eq 0 ]
  [[ "$output" == *"SNYK_ORG is unset"* ]]
  [[ "$output" == *"monitored="* ]]
}

@test "missing SNYK_TOKEN aborts before scanning" {
  unset SNYK_TOKEN
  run bash "$SCAN" repo/app:1
  [ "$status" -ne 0 ]
  [[ "$output" == *"SNYK_TOKEN"* ]]
}
