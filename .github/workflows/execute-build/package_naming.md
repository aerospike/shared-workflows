# Aerospike Package Naming Guidelines

## Overview

This document covers how we name our packages across different Linux distributions and architectures. We've established these conventions to keep things consistent and predictable.
The naming patterns here work with standard DEB and RPM package tools, so they'll parse correctly with `dpkg-deb`, `rpm`, and other package management utilities.

## Canonical Fields

- **`<name>`** — Product SKU identifier, e.g., `aerospike-server-enterprise`, `aerospike-server-community`, `aerospike-tools`, `aerospike-client`.
- **`<version>`** — Semantic version format: `X.Y.Z[.W]` (three or four components).
- **`[tag]`** — Optional pre-release marker: any valid identifier that parses with standard DEB/RPM standards (e.g., `dev1`, `rc2`, `start28`, `beta3`).
- **`<release>`** — Packaging release number (starts at `1` for GA releases; increments for packaging-only respins).
- **`<distro>`** — Target distribution identifier (see tables below).
- **`<arch>`** — Target architecture identifier (see table below).

## Package Naming Patterns

### DEB Package Format

```text
{name}_{version}-{release}{distro}_{arch}.deb
```

### RPM Package Format

```text
{name}-{version}[_{tag}]-{release}.{distro}.{arch}.rpm
```

**Note**: The `[tag]` portion is optional and can be any valid identifier that parses with standard DEB/RPM standards.

**Note**: Distribution is included in the filename for debian which extends beyond standard Debian/Ubuntu conventions, which usually handles distribution through repository structure.

## Distribution Identifiers

### Debian/Ubuntu (DEB)

| Distribution | Codename | Filename Token |
| ------------ | -------- | -------------- |
| Ubuntu 20.04 | focal    | `ubuntu20.04`  |
| Ubuntu 22.04 | jammy    | `ubuntu22.04`  |
| Ubuntu 24.04 | noble    | `ubuntu24.04`  |
| Debian 11    | bullseye | `debian11`     |
| Debian 12    | bookworm | `debian12`     |

### RHEL/EL & Amazon Linux (RPM)

| Distribution Family | Filename Token Examples |
| ------------------- | ----------------------- |
| RHEL/EL             | `el8`, `el9`            |
| Amazon Linux        | `amzn2023`              |

## Architecture Identifiers

| Architecture | DEB Token | RPM Token |
| ------------ | --------- | --------- |
| x86-64       | `amd64`   | `x86_64`  |
| ARM64        | `arm64`   | `aarch64` |

## Examples

```text
# Server packages
aerospike-server-enterprise-8.1.0.0-1.el9.aarch64.rpm
aerospike-server-enterprise_8.1.0.0-1debian12_amd64.deb

# Tools packages
aerospike-tools-6.4.0-1.el9.x86_64.rpm
aerospike-tools_6.4.0_ubuntu24.04_amd64.deb

# Other packages
blastoid-6.4.0-1.amzn2023.aarch64.rpm
blastoid_6.4.0_debian11_arm64.deb

# Custom tags
aerospike-server-community-8.1.0.0-start28-1.el8.x86_64.rpm
aerospike-server-community_8.1.0.0-start28_debian11_amd64.deb
```

## Summary Rules

1. **Product Name First**: Always start with the product SKU identifier
2. **Full Semantic Version**: Use complete version string (`X.Y.Z[.W]`)
3. **Field Order**: version → (optional tag) → distro → arch
4. **Format Consistency**:
   - DEB uses underscore separators (`_`)
   - RPM uses dash and dot separators (`-` and `.`)
5. **Architecture Consistency**:
   - DEB: `amd64`/`arm64`
   - RPM: `x86_64`/`aarch64`
6. **Release Numbering**: RPM packages use release number `1` for GA releases

## References

### DEB Package Naming

- **Debian Policy Manual**: [Package naming conventions](https://www.debian.org/doc/debian-policy/ch-controlfields.html#s-f-version)
- **Ubuntu Packaging Guide**: [Package versioning](https://packaging.ubuntu.com/html/packaging-new-software.html#versioning)
- **dpkg-deb man page**: Package format and naming standards

### RPM Package Naming

- **RPM Packaging Guide**: [Package naming and versioning](https://rpm-packaging-guide.github.io/#package-naming)
- **Fedora Packaging Guidelines**: [Package naming](https://docs.fedoraproject.org/en-US/packaging-guidelines/Naming/)
- **rpm man page**: Package format and naming standards

### Semantic Versioning

- **SemVer 2.0.0**: [Semantic Versioning Specification](https://semver.org/)
