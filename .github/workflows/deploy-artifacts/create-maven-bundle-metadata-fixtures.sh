#!/usr/bin/env bash
# Minimal signed-artifact tree for bundle-metadata upload tests.
# Produces only enough Maven content for .maven-bundle-metadata.json (maven_module_count > 0)
# without the full create-test-fixtures.sh artifact set.

set -euo pipefail

OUT="${1:-maven-bundle-fixtures}"
rm -rf "$OUT"
mkdir -p "$OUT"

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

echo "placeholder-jar" >"$OUT/hello-world-1.0.0.jar"
echo "FAKE-GPG-SIGNATURE" >"$OUT/hello-world-1.0.0.pom.asc"
echo "FAKE-GPG-SIGNATURE" >"$OUT/hello-world-1.0.0.jar.asc"

echo "Created minimal Maven fixtures in $OUT:"
find "$OUT" -type f | sort
