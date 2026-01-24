#!/usr/bin/env bash
set -euo pipefail

echo "Building Java sample app..."
mvn -B -DskipTests package

artifact_id="$(mvn -q -DforceStdout help:evaluate -Dexpression=project.artifactId)"
version="$(mvn -q -DforceStdout help:evaluate -Dexpression=project.version)"

jar_path="target/${artifact_id}-${version}.jar"
if [[ ! -f $jar_path ]]; then
    echo "Error: JAR not found at ${jar_path}" >&2
    exit 1
fi

build_dir="build"
mkdir -p "$build_dir"
cp "$jar_path" "$build_dir/"
cp pom.xml "$build_dir/${artifact_id}-${version}.pom"

echo "Build artifacts:"
ls -la "$build_dir"
