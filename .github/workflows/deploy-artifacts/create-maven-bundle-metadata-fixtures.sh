#!/usr/bin/env bash
# Minimal signed-artifact tree for bundle-metadata upload tests.
# Produces only enough Maven content for .maven-bundle-metadata.json (maven_module_count > 0)
# without the full create-test-fixtures.sh artifact set.

set -euo pipefail

OUT="${1:-maven-bundle-fixtures}"
rm -rf "$OUT"
mkdir -p "$OUT"

make_minimal_jar() {
    local out="$1"
    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/META-INF/maven/com.example/hello-world"
    echo "Manifest-Version: 1.0" >"$tmp/META-INF/MANIFEST.MF"
    cat >"$tmp/META-INF/maven/com.example/hello-world/pom.properties" <<'EOF'
groupId=com.example
artifactId=hello-world
version=1.0.0
EOF
    (cd "$tmp" && zip -q -r "$out" .)
    rm -rf "$tmp"
}

cat >"$OUT/hello-world-1.0.0.pom" <<'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>hello-world</artifactId>
  <version>1.0.0</version>
  <packaging>jar</packaging>
</project>
POM

make_minimal_jar "$(cd "$OUT" && pwd)/hello-world-1.0.0.jar"
echo "FAKE-GPG-SIGNATURE" >"$OUT/hello-world-1.0.0.pom.asc"
echo "FAKE-GPG-SIGNATURE" >"$OUT/hello-world-1.0.0.jar.asc"

if ! zipinfo "$OUT/hello-world-1.0.0.jar" >/dev/null 2>&1; then
    echo "Error: hello-world-1.0.0.jar is not a valid zip/jar" >&2
    exit 1
fi

echo "Created minimal Maven fixtures in $OUT:"
find "$OUT" -type f | sort
