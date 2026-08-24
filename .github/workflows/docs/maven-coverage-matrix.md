# Maven artifact test coverage matrix

Maps the three Maven release shapes exercised in CI to bats tests and fixture locations.
Update this table when adding or changing Maven structuring behavior.

## Maven release shapes

| Shape               | Description                                                                 | Input fixture                                                                                                                   |
| ------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| **jar+pom**         | Standard library release: sibling `.jar` + `.pom` + `.module` + signatures  | Flat `test.{jar,pom,module,asc,md5,sha1}`; nested `maven-repo/com/example/app/my-app/1.0.0/my-app-1.0.0.*`                      |
| **parent+children** | Reactor: aggregator parent (`packaging=pom`, no jar) + modules with jar+pom | Nested `maven-repo/com/example/parent/{parent-proj,child-one,child-two}/1.0.0/`                                                 |
| **pom-only**        | BOM / java-platform release without a jar (POM + Gradle `.module`)          | Flat `standalone-bom.{pom,module}` (+ sidecars); nested `maven-repo/.../standalone-bom/2.1.0/standalone-bom-2.1.0.{pom,module}` |

Nested fixtures live under `build-artifacts/maven-repo/` (JFrog download layout). Flat fixtures remain at `build-artifacts/` root for backward compatibility.

## Coverage matrix

| Scenario                     | detect structuring | deploy structuring (GAV path) | manifest                      | upload   | JFrog layout | Parent GAV resolution       | Primary test file(s)                                                                |
| ---------------------------- | ------------------ | ----------------------------- | ----------------------------- | -------- | ------------ | --------------------------- | ----------------------------------------------------------------------------------- |
| **jar + pom + asc** (flat)   | via full pipeline  | yes                           | partial (jar primary)         | yes      | no           | n/a                         | `test_java_upload.bats`, `test_structuring.bats`                                    |
| **jar + pom + asc** (nested) | yes                | yes                           | yes (pom primary from detect) | indirect | yes          | n/a                         | `test_maven_structuring.bats`, `test_structuring.bats`, `test_java_upload.bats`     |
| **parent + 2 children**      | yes                | yes                           | yes                           | no       | yes          | yes (child POM → child GAV) | `test_maven_structuring.bats`, `test_maven_bundle_metadata.bats`                    |
| **pom-only + asc** (flat)    | yes                | yes                           | yes                           | yes      | no           | n/a                         | `test_maven_bundle_metadata.bats`, `test_java_upload.bats`, `test_structuring.bats` |
| **pom-only + asc** (nested)  | yes                | yes                           | yes                           | no       | yes          | n/a                         | `test_maven_structuring.bats`, `test_structuring.bats`                              |

Legend: **yes** = dedicated assertion; **partial** = covered indirectly (e.g. upload implies on-disk layout); **no** = not asserted in that column.

## Test file index

| File                              | Layer           | What it covers                                                                                                         |
| --------------------------------- | --------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `test_maven_structuring.bats`     | detect + deploy | All three shapes in JFrog layout; detect-only GAV/manifest/JAR-skip; deploy GAV for nested jar+pom and parent+children |
| `test_maven_bundle_metadata.bats` | detect          | `.maven-bundle-metadata.json`; jar-less standalone structuring; reactor metadata + parent/child structuring            |
| `test_structuring.bats`           | deploy          | Flat + nested GAV paths; standalone BOM co-location (pom+module); no jar/pom/module leak to generic                    |
| `test_java_upload.bats`           | deploy          | Flat jar+pom+module upload; nested my-app `.module` upload; flat standalone BOM+`.module` upload                       |
| `test_manifest.bats`              | deploy          | Standalone `.pom` as manifest primary; companions excluded                                                             |

## Stage ownership

| Stage                 | jar+pom                                                                                          | pom-only                                                                             | parent aggregator |
| --------------------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------ | ----------------- |
| **detect_types**      | Structures `.pom` + `.pom.asc` when sibling `.jar` exists; does **not** copy `.jar` or `.module` | Structures `.pom` + `.module` + signatures/checksums when present                    | Same as pom-only  |
| **deploy entrypoint** | `process_jar` copies jar + full companion set (pom, module, checksums, signatures)               | `_detect_structure_maven_poms` via `structure_standalone_poms` delegate (idempotent) | Same as pom-only  |

## Helpers and fixtures

| Path                                | Purpose                                                                                                                |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `tests/helpers/maven_fixtures.bash` | `create_jfrog_maven_fixture_tree`, `make_maven_jar_with_coords`, `write_gradle_module_metadata`, `run_detect_types_in` |
| `create-test-fixtures.sh`           | Shared CI fixtures including `maven-repo/` subtree                                                                     |
| `tests/helpers/setup.bash`          | `run_entrypoint_dry_run` (detect + deploy dry-run)                                                                     |

## Gaps / non-goals

- **Upload tests for nested parent+children** — structuring is covered; upload commands are not asserted separately (flat jar+pom upload tests provide the upload contract).
- **detect_types `.pom.md5`/`.sha1`/`.module` for jar-present POMs** — only `.pom.asc` during detect; full companion set (including `.module`) comes from `process_jar` at deploy (by design).

## CI prerequisites

Deploy-stage structuring tests (`test_structuring.bats` Maven section, `test_maven_structuring.bats` deploy cases) require the entrypoint to finish `structure_build_artifacts()` through the JAR extension pass. That needs **`rpm`** and **`dpkg-deb`** on the runner (see `tests/README.md`). If the entrypoint aborts earlier (e.g. RPM metadata on macOS), JAR files will not appear under `structured_build_artifacts/jar/` even when detection succeeded.

Detect-only tests (`test_maven_structuring.bats` detect\_\* cases, `test_maven_bundle_metadata.bats`) need **bash 4+** and **`xmllint`** / **`jq`** only.
