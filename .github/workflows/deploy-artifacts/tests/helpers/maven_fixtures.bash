#!/usr/bin/env bash
# Shared Maven test fixtures (JFrog repo layout) for bats tests.

# detect_types.sh needs bash 4+ (type_registry.sh associative arrays).
require_bash4_for_detect_types() {
        ((BASH_VERSINFO[0] >= 4)) || skip "requires bash 4+ for detect_types (type_registry associative arrays)"
}

# Create a minimal JAR with Maven pom.properties for get_jar_metadata().
# Args: <output.jar> <groupId> <artifactId> <version>
make_maven_jar_with_coords() {
        local out="$1" group_id="$2" artifact_id="$3" version="$4"
        local tmp props_dir out_dir
        mkdir -p "$(dirname "$out")"
        out_dir=$(cd "$(dirname "$out")" && pwd)
        out="$out_dir/$(basename "$out")"
        tmp=$(mktemp -d)
        mkdir -p "$tmp/META-INF"
        echo "Manifest-Version: 1.0" >"$tmp/META-INF/MANIFEST.MF"
        props_dir="$tmp/META-INF/maven/${group_id}/${artifact_id}"
        mkdir -p "$props_dir"
        cat >"$props_dir/pom.properties" <<EOF
groupId=${group_id}
artifactId=${artifact_id}
version=${version}
EOF
        (cd "$tmp" && zip -q -r "$out" .)
        rm -rf "$tmp"
}

# Populate <base>/build-artifacts with three Maven shapes in JFrog download layout:
#   1. jar+pom+asc (my-app)
#   2. parent aggregator + two children (jar+pom+asc each)
#   3. standalone BOM (pom+asc only)
# Args: <workspace_dir>  (creates build-artifacts/ underneath)
create_jfrog_maven_fixture_tree() {
        local root="$1"
        local base="$root/build-artifacts"
        local dir child

        mkdir -p "$base"

        # --- 1. Normal jar + pom + asc ---
        dir="$base/maven-repo/com/example/app/my-app/1.0.0"
        mkdir -p "$dir"
        make_maven_jar_with_coords "$dir/my-app-1.0.0.jar" "com.example.app" "my-app" "1.0.0"
        cat >"$dir/my-app-1.0.0.pom" <<'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example.app</groupId>
  <artifactId>my-app</artifactId>
  <version>1.0.0</version>
  <packaging>jar</packaging>
</project>
POM
        echo "FAKE-GPG-SIGNATURE my-app-jar" >"$dir/my-app-1.0.0.jar.asc"
        echo "FAKE-GPG-SIGNATURE my-app-pom" >"$dir/my-app-1.0.0.pom.asc"

        # --- 2. Parent + two children ---
        dir="$base/maven-repo/com/example/parent/parent-proj/1.0.0"
        mkdir -p "$dir"
        cat >"$dir/parent-proj-1.0.0.pom" <<'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example.parent</groupId>
  <artifactId>parent-proj</artifactId>
  <version>1.0.0</version>
  <packaging>pom</packaging>
  <modules>
    <module>child-one</module>
    <module>child-two</module>
  </modules>
</project>
POM
        echo "FAKE-GPG-SIGNATURE parent" >"$dir/parent-proj-1.0.0.pom.asc"

        for child in child-one child-two; do
                dir="$base/maven-repo/com/example/parent/${child}/1.0.0"
                mkdir -p "$dir"
                make_maven_jar_with_coords "$dir/${child}-1.0.0.jar" "com.example.parent" "$child" "1.0.0"
                cat >"$dir/${child}-1.0.0.pom" <<POM
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>com.example.parent</groupId>
    <artifactId>parent-proj</artifactId>
    <version>1.0.0</version>
  </parent>
  <artifactId>${child}</artifactId>
  <packaging>jar</packaging>
</project>
POM
                echo "FAKE-GPG-SIGNATURE ${child}-jar" >"$dir/${child}-1.0.0.jar.asc"
                echo "FAKE-GPG-SIGNATURE ${child}-pom" >"$dir/${child}-1.0.0.pom.asc"
        done

        # --- 3. Standalone BOM (pom + asc only) ---
        dir="$base/maven-repo/com/example/bom/standalone-bom/2.1.0"
        mkdir -p "$dir"
        cat >"$dir/standalone-bom-2.1.0.pom" <<'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example.bom</groupId>
  <artifactId>standalone-bom</artifactId>
  <version>2.1.0</version>
  <packaging>pom</packaging>
</project>
POM
        echo "FAKE-GPG-SIGNATURE standalone-bom" >"$dir/standalone-bom-2.1.0.pom.asc"
}

# Run detect_types.sh only. Args: <workspace_dir>
run_detect_types_in() {
        local wd="$1"
        (cd "$wd" && "$DEPLOY_ARTIFACTS_DIR/detect_types.sh" --artifacts-dir build-artifacts >/dev/null)
}
