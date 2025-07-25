# 🔐 Sign Artifacts Workflow

This is a reusable GitHub Actions workflow that signs binary artifacts using GPG. It supports `.deb`, `.rpm`, and any other file type passed via a glob pattern. It produces:

- GPG detached signature (`.asc`) for any file
- SHA256 checksums for both the file and signature (`.sha256`, `.asc.sha256`)
- Native signing for `.deb` and `.rpm` using `dpkg-sig` and `rpm --addsign`

---

## 📥 Inputs

| Name            | Type     | Required | Description                                                                 |
| --------------- | -------- | -------- | --------------------------------------------------------------------------- |
| `artifact_glob` | `string` | ✅       | Glob pattern to match artifacts for signing. Example: `dist/**/*.{deb,rpm}` |

Signed artifacts are left in-place, `shas` and `asc` files are adjacent to the originals.

---

## 🚀 Example Usage

From another workflow:

```yaml
jobs:
  sign:
    uses: aerospike/shared-workflows/.github/workflows/reusable_sign-artifacts.yaml@main
    with:
      artifact_glob: dist/**/*.{deb,rpm}
    secrets:
      gpg-private-key: ${{ secrets.GPG_SECRET_KEY }}
      gpg-public-key: ${{ secrets.GPG_PUBLIC_KEY }}
      gpg-key-pass: ${{ secrets.GPG_PASS }}
```
