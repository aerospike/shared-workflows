# Aggregate Build Info

Best practice is to have build info generated as close as possible to the actual build. This causes us to make the build in advance of the actual artifact making it up to artifactory. In the case of matrixed builds they also must be aggregated under one jfrog build.

This workflow aggregates multiple JFrog build-infos into a single parent build using `jf rt build-append`.
[https://docs.jfrog-applications.jfrog.io/jfrog-applications/jfrog-cli/binaries-management-with-jfrog-artifactory/build-integration#aggregating-published-builds](https://docs.jfrog-applications.jfrog.io/jfrog-applications/jfrog-cli/binaries-management-with-jfrog-artifactory/build-integration#aggregating-published-builds)

## Inputs

| Input                            | Description                                           | Required | Default                         |
| -------------------------------- | ----------------------------------------------------- | -------- | ------------------------------- |
| `project`                        | JFrog Artifactory project name                        | Yes      | -                               |
| `parent-build-name`              | Name for the parent aggregated build                  | Yes      | -                               |
| `parent-build-version`           | Version for the parent aggregated build               | Yes      | -                               |
| `build-name-pattern`             | Pattern to match child build names (e.g., "myapp-\*") | Yes      | -                               |
| `artifactory-url`                | JFrog Artifactory URL                                 | No       | `https://artifact.aerospike.io` |
| `artifactory-oidc-provider-name` | OIDC provider name                                    | No       | `gh-aerospike`                  |
| `artifactory-oidc-audience`      | OIDC audience                                         | No       | `aerospike`                     |

## Outputs

| Output                 | Description              |
| ---------------------- | ------------------------ |
| `parent-build-name`    | The parent build name    |
| `parent-build-version` | The parent build version |
