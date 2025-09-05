# Sign Java Artifacts Workflow

This is a reusable GitHub Actions workflow that signs Java artifacts using GPG. It's specifically designed for Java projects and supports Maven Central deployment requirements. It supports `.jar`, `.war`, `.ear`, `.pom`, `.aar`, and any other file type passed via a glob pattern.

The workflow produces:

- GPG detached signature (`.asc`) for any file
- Maven Central compatible checksums (`.sha1`, `.md5`) when `maven-compatible` is enabled
- Standard SHA256 checksums when `maven-compatible` is disabled
- Proper signing for POM files required for Maven Central deployment

---

## Inputs

| Name                             | Type      | Required | Description                                                                             |
| -------------------------------- | --------- | -------- | --------------------------------------------------------------------------------------- |
| `unsigned-artifacts`             | `string`  | No       | Previously uploaded artifacts to sign. Default: `build-artifacts`                       |
| `artifact-name`                  | `string`  | No       | Name for the uploaded artifacts. Default: `signed-java-artifacts`                       |
| `retention-days`                 | `number`  | No       | Number of days to retain the signed artifacts. Default: `1`                             |
| `artifactory-url`                | `string`  | No       | JFrog Artifactory URL. Default: `https://aerospike.jfrog.io`                            |
| `artifactory-oidc-provider-name` | `string`  | No       | OIDC provider name. Default: `gh-aerospike`                                             |
| `artifactory-oidc-audience`      | `string`  | No       | OIDC audience. Default: `aerospike`                                                     |
| `checkout-path`                  | `string`  | No       | Directory to checkout the shared-workflows repository into. Default: `shared-workflows` |
| `runs-on`                        | `string`  | No       | The runner to use for the build. Default: `ubuntu-22.04`                                |
| `maven-compatible`               | `boolean` | No       | Create Maven Central compatible signatures and checksums. Default: `true`               |

## Secrets

| Name              | Required | Description                     |
| ----------------- | -------- | ------------------------------- |
| `gpg-private-key` | ✅       | GPG private key for signing     |
| `gpg-public-key`  | ✅       | GPG public key for verification |
| `gpg-key-pass`    | ✅       | Passphrase for the GPG key      |

---

## Java-Specific Features

### Maven Central Compatibility

When `maven-compatible` is set to `true` (default), the workflow creates:

- `.sha1` files with SHA1 checksums (required by Maven Central)
- `.md5` files with MD5 checksums (required by Maven Central)
- Proper signing of POM files for repository deployment

### Supported Java Artifacts

- `.jar` - Java Archive files
- `.war` - Web Application Archive files  
- `.ear` - Enterprise Application Archive files
- `.pom` - Maven Project Object Model files
- `.aar` - Android Archive files
- Any other file types (with generic signing)

### Maven Central Deployment

The signed artifacts produced by this workflow are compatible with Maven Central deployment requirements:

1. All artifacts are GPG signed with detached signatures
2. SHA1 and MD5 checksums are provided for both artifacts and signatures
3. POM files are properly signed
4. Directory structure is preserved for Maven repository layout

---

## Example Usage

### Basic Java Project

```yaml
jobs:
  sign:
    uses: aerospike/shared-workflows/.github/workflows/reusable_sign-java-artifacts.yaml@CURRENTGITSHA # vn.n.n
    with:
      unsigned-artifacts: java-build-artifacts
      artifact-name: signed-java-artifacts
      retention-days: 7
    secrets:
      gpg-private-key: ${{ secrets.GPG_SECRET_KEY }}
      gpg-public-key: ${{ secrets.GPG_PUBLIC_KEY }}
      gpg-key-pass: ${{ secrets.GPG_PASS }}
```

### Maven Central Deployment Preparation

```yaml
jobs:
  sign:
    uses: aerospike/shared-workflows/.github/workflows/reusable_sign-java-artifacts.yaml@CURRENTGITSHA # vn.n.n
    with:
      unsigned-artifacts: maven-artifacts
      artifact-name: maven-central-ready
      maven-compatible: true  # Enable Maven Central checksums
      retention-days: 30
    secrets:
      gpg-private-key: ${{ secrets.MAVEN_GPG_PRIVATE_KEY }}
      gpg-public-key: ${{ secrets.MAVEN_GPG_PUBLIC_KEY }}
      gpg-key-pass: ${{ secrets.MAVEN_GPG_PASSPHRASE }}
```

### Non-Maven Project (SHA256 checksums)

```yaml
jobs:
  sign:
    uses: aerospike/shared-workflows/.github/workflows/reusable_sign-java-artifacts.yaml@CURRENTGITSHA # vn.n.n
    with:
      unsigned-artifacts: gradle-artifacts
      artifact-name: signed-gradle-artifacts
      maven-compatible: false  # Use SHA256 instead of SHA1/MD5
    secrets:
      gpg-private-key: ${{ secrets.GPG_SECRET_KEY }}
      gpg-public-key: ${{ secrets.GPG_PUBLIC_KEY }}
      gpg-key-pass: ${{ secrets.GPG_PASS }}
```

## Output

The workflow uploads the signed artifacts as a GitHub Actions artifact with the specified retention period. Each artifact will have:

- Original file
- `.asc` signature file
- Checksum files (`.sha1` and `.md5` for Maven compatibility, or `.sha256` for standard mode)
- Signature checksum files

## Differences from Generic Sign-Artifacts Workflow

1. **Java-aware**: Recognizes and handles Java-specific file types
2. **Maven Central ready**: Creates SHA1/MD5 checksums required by Maven Central
3. **POM handling**: Special treatment for Maven POM files
4. **Flexible checksums**: Choose between Maven-compatible (SHA1/MD5) or standard (SHA256) checksums
5. **Default naming**: Uses `signed-java-artifacts` as default output name