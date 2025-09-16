#!/usr/bin/env bash
set -euo pipefail
PROJECT='test'


# === Configurable inputs ===
BUILD_INFO_REPO="${BUILD_INFO_REPO:-test-build-info}"   # project-scoped build-info repo
PARENT_BUILD_NAME="${PARENT_BUILD_NAME:-test-build}"               # base name, e.g. foo
PARENT_BUILD_ID="${PARENT_BUILD_ID:-129}"          # run number, e.g. 1234
PROJECT="${PROJECT:-test}"                              # project key
LOOKBACK="${LOOKBACK:-90d}"                                 # optional: only consider recent runs

# === Derived ===
SUFFIX_PREFIX="${PARENT_BUILD_NAME}-"

echo "Build-info repo:     $BUILD_INFO_REPO"
echo "Parent build:        $PARENT_BUILD_NAME/$PARENT_BUILD_ID"
echo "Suffix prefix:       $SUFFIX_PREFIX"
echo "Project:             $PROJECT"
echo "Lookback:            $LOOKBACK"

# === Construct AQL ===
# Calculate the date 90 days ago for proper AQL syntax
LOOKBACK_DATE=$(date -d "90 days ago" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || date -u -v-90d +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || echo "2024-01-01T00:00:00.000Z")

read -r -d '' AQL <<AQL || true
items.find({
  "\$and":[
    {"repo":{"\$eq":"$BUILD_INFO_REPO"}},
    {"path":{"\$match":"$SUFFIX_PREFIX*"}},
    {"name":{"\$match":"$PARENT_BUILD_ID-*.json"}},
    {"created":{"\$gte":"$LOOKBACK_DATE"}}
  ]
}).include("path","name")
AQL

# === Run query ===
RESP=$(jf rt curl -XPOST api/search/aql \
  -H 'Content-Type: text/plain' \
  -d "$AQL")

# === Extract child names and build numbers ===
if echo "$RESP" | jq -e '.results' > /dev/null 2>&1; then
  echo "Raw AQL results:"
  echo "$RESP" | jq '.results[] | {path: .path, name: .name}'
  echo "---"
  
  # Extract build numbers from the file names
  echo "Extracting build numbers from file names:"
  echo "$RESP" | jq -r '.results[] | .name' | while read -r filename; do
    # Extract build number from filename like "129-amzn2023-x86_64-1758049781295.json"
    build_num=$(echo "$filename" | cut -d'-' -f1)
    echo "  File: $filename -> Build number: $build_num"
  done
  echo "---"
  
  mapfile -t CHILD_NAMES < <(echo "$RESP" | jq -r '.results[].path' | sort -u)
  echo "Found ${#CHILD_NAMES[@]} child builds"
  echo "Child builds found:"
  for child in "${CHILD_NAMES[@]}"; do
    echo "  - $child"
  done
else
  echo "Invalid JSON response or no results field"
  CHILD_NAMES=()
fi

if (( ${#CHILD_NAMES[@]} == 0 )); then
  echo "No child builds found."
  exit 0
fi

# === Append each child build to the parent ===
for child in "${CHILD_NAMES[@]}"; do
  [[ "$child" == "$PARENT_BUILD_NAME" ]] && continue
  
  # Check if the child build exists in Artifactory
  echo "Checking if build ${child}/${PARENT_BUILD_ID} exists..."
  BUILD_CHECK=$(jf rt curl "api/build/${child}/${PARENT_BUILD_ID}?projectKey=${PROJECT}" 2>/dev/null)
  if echo "$BUILD_CHECK" | jq -e '.errors' >/dev/null 2>&1; then
    echo "Build ${child}/${PARENT_BUILD_ID} not found in Artifactory, skipping..."
  else
    echo "Appending ${child}/${PARENT_BUILD_ID} -> ${PARENT_BUILD_NAME}/${PARENT_BUILD_ID}"
    jf rt build-append "$PARENT_BUILD_NAME" "$PARENT_BUILD_ID" \
                       "$child" "$PARENT_BUILD_ID" \
                       --project="$PROJECT" || true
  fi
done
