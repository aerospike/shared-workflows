#!/usr/bin/env bash
# Shared Rust crate test fixtures for bats tests.

# Populate <base>/build-artifacts with a valid .crate + .asc at the tree root.
# Args: <workspace_dir>  (creates build-artifacts/ underneath)
create_crate_fixture_tree() {
        local root="$1"
        local base="$root/build-artifacts"
        local temp="$root/temp-crate"
        local crate_src="$temp/aerospike-3.0.0-alpha.1/src"

        mkdir -p "$crate_src" "$base"
        cat >"$temp/aerospike-3.0.0-alpha.1/Cargo.toml" <<'CARGO'
[package]
name = "aerospike"
version = "3.0.0-alpha.1"
edition = "2021"
CARGO
        echo 'pub fn placeholder() {}' >"$crate_src/lib.rs"
        (cd "$temp" && tar -czf "$base/aerospike-3.0.0-alpha.1.crate" aerospike-3.0.0-alpha.1/)
        echo 'FAKE-GPG-SIGNATURE' >"$base/aerospike-3.0.0-alpha.1.crate.asc"
        echo 'not-a-valid-crate-archive' >"$base/invalid-fixture.crate"
        rm -rf "$temp"
}

# RBV2-like layout: database-generic-*/{build}/{version}/*.crate + .asc
# Args: <workspace_dir>  (creates build-artifacts/ underneath)
create_jfrog_crate_fixture_tree() {
        local root="$1"
        local base="$root/build-artifacts"
        local temp="$root/temp-crate"
        local crate_path="$base/database-generic-prod-public-local/ci-build/v1.0.0"
        local crate_src="$temp/aerospike-3.0.0-alpha.1/src"

        mkdir -p "$crate_src" "$crate_path"
        cat >"$temp/aerospike-3.0.0-alpha.1/Cargo.toml" <<'CARGO'
[package]
name = "aerospike"
version = "3.0.0-alpha.1"
edition = "2021"
CARGO
        echo 'pub fn placeholder() {}' >"$crate_src/lib.rs"
        (cd "$temp" && tar -czf "$crate_path/aerospike-3.0.0-alpha.1.crate" aerospike-3.0.0-alpha.1/)
        echo 'FAKE-GPG-SIGNATURE' >"$crate_path/aerospike-3.0.0-alpha.1.crate.asc"
        rm -rf "$temp"
}
