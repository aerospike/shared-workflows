# Extract Version from Tag

Extracts a version string from an explicit input, a VERSION file, a Git tag, or a fallback.

## Priority Order

1. **`version` input** — explicit override, highest priority
2. **VERSION file** — reads from the file at `version-file` path
3. **Git tag** — extracts from `GITHUB_REF` when triggered by a tag push
4. **Fallback** — `git describe --tags`, or `0.0.0-dev+<sha>` if no tags exist

## Inputs

| Input          | Required | Default   | Description                                             |
| -------------- | -------- | --------- | ------------------------------------------------------- |
| `version`      | No       | `""`      | Explicit version override (bypasses all auto-detection) |
| `version-file` | No       | `VERSION` | Path to VERSION file                                    |
| `tag-prefix`   | No       | `v`       | Prefix to strip from version string                     |

## Outputs

| Output    | Description                                                        |
| --------- | ------------------------------------------------------------------ |
| `version` | Extracted version (prefix stripped)                                |
| `git_tag` | Full tag or raw version string before prefix stripping             |
| `source`  | Where the version came from: `input`, `file`, `tag`, or `fallback` |

## Example Usage

### Basic (VERSION file)

```yaml
steps:
  - uses: actions/checkout@v4
  - name: Extract Version
    id: version
    uses: aerospike/shared-workflows/.github/actions/extract-version-from-tag@v3
    with:
      version-file: VERSION
  - run: echo "Version is ${{ steps.version.outputs.version }}"
```

### Explicit version override (dev builds)

```yaml
on:
  workflow_dispatch:
    inputs:
      version:
        description: Version override (leave empty for auto-detection)
        required: false
        default: ""

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Extract Version
        id: version
        uses: aerospike/shared-workflows/.github/actions/extract-version-from-tag@v3
        with:
          version: ${{ inputs.version }}
          version-file: VERSION
```

### Custom tag prefix

```yaml
steps:
  - uses: actions/checkout@v4
  - name: Extract Version
    id: version
    uses: aerospike/shared-workflows/.github/actions/extract-version-from-tag@v3
    with:
      tag-prefix: release-
```

## SemVer Pre-release Support

Pre-release versions are fully supported. The action does not validate or reject any version format — it passes through whatever is resolved:

- `1.0.0-dev`
- `1.0.0-rc.1`
- `1.0.0-alpha.1`
- `1.0.0-SNAPSHOT`

## Running Tests

```bash
bats .github/actions/extract-version-from-tag/tests/
```
