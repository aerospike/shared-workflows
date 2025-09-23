#!/usr/bin/env bash
set -euo pipefail

export PS4='+($LINENO): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
trap 'handle_error ${LINENO}' ERR

# shellcheck disable=SC2317
handle_error() {
    local exit_code=$?
    local line_number=$1
    echo "Error: Command failed with exit code $exit_code at line $line_number" >&2
    exit 1
}

error() {
    local reason="${1:-}"
    if [[ -n "$reason" ]]; then
        echo "Error: $reason" >&2
    else
        echo "Error" >&2
    fi
    exit 1
}

# Default values for optional arguments
DRY_RUN="false"
BUILD_INFO_REPO=""

show_help() {
  echo "Usage: $0 --project <project> --parent-build-name <name> --parent-build-id <id> --build-info-search-pattern <pattern> [OPTIONS]" >&2
  echo "" >&2
  echo "Aggregates multiple JFrog build-infos into a single parent build using jf rt build-append" >&2
  echo "" >&2
  echo "Required Arguments:" >&2
  echo "  --project <project>              JFrog Artifactory project name" >&2
  echo "  --parent-build-name <name>       Name for the parent aggregated build" >&2
  echo "  --parent-build-id <id>           Build ID for the parent aggregated build" >&2
  echo "  --build-info-search-pattern <pattern>   Pattern to match matrix build names (e.g., 'test-build-*')" >&2
  echo "" >&2
  echo "Options:" >&2
  echo "  --build-info-repo <repo>         Project-scoped build-info repo (default: <project>-build-info)" >&2
  echo "  --dry-run                        Show what would be done without actually doing it" >&2
  echo "  --help, -h                       Show this help message" >&2
  echo "" >&2
  echo "Examples:" >&2
  echo "  $0 --project test --parent-build-name myapp --parent-build-id 123 --build-info-search-pattern 'myapp-*'" >&2
  echo "  $0 --project test --parent-build-name myapp --parent-build-id 123 --build-info-search-pattern 'myapp-*' --dry-run" >&2
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --project)
      PROJECT="$2"
      shift 2
      ;;
    --parent-build-name)
      PARENT_BUILD_NAME="$2"
      shift 2
      ;;
    --parent-build-id)
      PARENT_BUILD_ID="$2"
      shift 2
      ;;
    --build-info-search-pattern)
      BUILD_INFO_SEARCH_PATTERN="$2"
      shift 2
      ;;
    --build-info-repo)
      BUILD_INFO_REPO="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --help|-h)
      show_help
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage information" >&2
      exit 1
      ;;
    *)
      echo "Unexpected argument: $1" >&2
      echo "Use --help for usage information" >&2
      exit 1
      ;;
  esac
done

# Validate required arguments
if [[ -z "${PROJECT:-}" ]]; then
  error "--project is required"
fi
if [[ -z "${PARENT_BUILD_NAME:-}" ]]; then
  error "--parent-build-name is required"
fi
if [[ -z "${PARENT_BUILD_ID:-}" ]]; then
  error "--parent-build-id is required"
fi
if [[ -z "${BUILD_INFO_SEARCH_PATTERN:-}" ]]; then
  error "--build-info-search-pattern is required"
fi

# Set defaults
if [[ -z "${BUILD_INFO_REPO:-}" ]]; then
  BUILD_INFO_REPO="${PROJECT}-build-info"
fi

# Run function for dry-run support
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Would run: $*" >&2
  else
    echo "Running: $*" >&2
    "$@"
  fi
}

echo "Build-info repo:     $BUILD_INFO_REPO"
echo "Parent build:        $PARENT_BUILD_NAME/$PARENT_BUILD_ID"
echo "Project:             $PROJECT"

# === Construct AQL ===
# Calculate the date 90 days ago for proper AQL syntax
LOOKBACK_DATE=$(date -d "90 days ago" -u +"%Y-%m-%dT%H:%M:%S.000Z")
read -r -d '' AQL <<AQL || true
items.find({
  "\$and":[
    {"repo":{"\$eq":"$BUILD_INFO_REPO"}},
    {"path":{"\$eq":"$PARENT_BUILD_NAME"}},
    {"name":{"\$match":"$BUILD_INFO_SEARCH_PATTERN.json"}},
    {"created":{"\$gte":"$LOOKBACK_DATE"}}
  ]
}).include("path","name")
AQL

# Query for build-info JSON files
RESP=$(jf rt curl -XPOST api/search/aql \
  -H 'Content-Type: text/plain' \
  -d "$AQL")

# Extract child build IDs from JSON file names
if echo "$RESP" | jq -e '.results' > /dev/null 2>&1; then
  # Extract matrix build IDs from JSON file names (filter out parent build ID)
  mapfile -t CHILD_BUILD_IDS < <(echo "$RESP" | jq -r '.results[] | .name' | sed 's/-[0-9]*\.json$//' | grep -v "^${PARENT_BUILD_ID}$" | sort -u)

  # All matrix builds use the same build name
  CHILD_NAMES=()
  for _ in "${CHILD_BUILD_IDS[@]}"; do
    CHILD_NAMES+=("$PARENT_BUILD_NAME")
  done

  echo "Found ${#CHILD_NAMES[@]} child builds to aggregate"
else
  echo "No build-info files found"
  CHILD_NAMES=()
fi

if (( ${#CHILD_NAMES[@]} == 0 )); then
  echo "No child builds found."
  exit 0
fi

# Append each child build to the parent
for i in "${!CHILD_NAMES[@]}"; do
  child_name="${CHILD_NAMES[$i]}"
  child_build_id="${CHILD_BUILD_IDS[$i]}"

  # Check if build exists and append to parent
  BUILD_CHECK=$(run jf rt curl "api/build/${child_name}/${child_build_id}?project=${PROJECT}" 2>/dev/null)

  if echo "$BUILD_CHECK" | jq -e '.errors' >/dev/null 2>&1; then
    echo "Skipping ${child_name}/${child_build_id} - not found in Artifactory"
  else
    echo "Appending ${child_name}/${child_build_id} to parent build"
    run jf rt build-append "$PARENT_BUILD_NAME" "$PARENT_BUILD_ID" \
                          "$child_name" "$child_build_id" \
                          --project="$PROJECT"
  fi
done

# Publish the aggregated parent build
echo "Publishing aggregated parent build ${PARENT_BUILD_NAME}/${PARENT_BUILD_ID}"
run jf rt build-publish "$PARENT_BUILD_NAME" "$PARENT_BUILD_ID" --project="$PROJECT"
