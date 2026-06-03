# Reusable Docker Build, Publish & Attest (Distributed Multi-Arch)

This workflow builds, optionally attests, and publishes a multi-architecture OCI
image to JFrog Artifactory — **building each architecture natively on its own
runner** instead of emulating other architectures with QEMU on a single runner.

It is a drop-in alternative to
[`reusable_docker-build-deploy.yaml`](../docker-build-deploy/README.md): the
`workflow_call` inputs, secrets, and outputs are identical (plus two optional
runner-label inputs), so a caller can switch `uses:` from one to the other
without changing any other arguments.

## When to use this vs. the single-job workflow

| | `reusable_docker-build-deploy.yaml` | `reusable_docker-build-deploy-multiarch.yaml` (this) |
| --- | --- | --- |
| How arches build | One runner, other arches via **QEMU emulation** | **Each arch native** on its own runner |
| Speed | Slower for non-host arches (emulated) | Faster (no emulation) |
| Runners needed | One | One per arch + a merge runner |
| `push` | Supports `push: false` | Requires `push: true` (pushes by digest, then merges) |
| Best for | Simple setups, single/host arch, no native arm runners | Multi-arch where emulation is too slow and native arm64 runners exist |

## Usage

```yaml
jobs:
  build-docker-deploy:
    uses: aerospike/shared-workflows/.github/workflows/reusable_docker-build-deploy-multiarch.yaml@<sha>
    with:
      jf-project: database
      image-name: test-image
      app-version: ${{ needs.extract-version.outputs.version }}
      context: .
      file: Dockerfile
      jf-build-name: test-build-container
      platforms: linux/amd64,linux/arm64
      # Override these if you use self-hosted runners:
      # amd64-runner: my-amd64-runner
      # arm64-runner: my-arm64-runner
```

## How it works

The build is split into three jobs:

1. **`prepare`** — computes the registry, the tag set, and the **immutable tag**
   (with timestamp) **once**, plus a build matrix mapping each requested platform
   to a native runner. Computing tags here (and only here) guarantees the
   immutable tag is identical across every downstream job.
2. **`build`** (matrix, one job per platform) — builds a single platform
   natively (no QEMU) and pushes the image **by digest, untagged**
   (`push-by-digest=true`). Each job uploads its digest as an artifact. Labels,
   build-args, build secrets, provenance, and SBOM are applied here.
3. **`merge`** — downloads every per-arch digest and runs
   `docker buildx imagetools create` to assemble a single multi-arch manifest
   list. **All tags are applied at this step**, to the combined manifest. It then
   creates the JFrog build-info, publishes it, and attests the final
   manifest-list digest.

> **Tags are applied once, at merge — not on the per-arch builds.** The per-arch
> images are pushed untagged (identified only by digest); the human-readable tags
> (`:7.0.0`, `:latest`, the immutable tag, etc.) are stamped onto the merged
> manifest list. This produces the **same immutable tag and same tag set** as the
> single-job workflow for the same inputs.

## Inputs

Identical to
[`reusable_docker-build-deploy.yaml`](../docker-build-deploy/README.md#inputs),
with two additions:

- `amd64-runner` (string, default `ubuntu-22.04`): Runner label used to natively
  build the `linux/amd64` platform.
- `arm64-runner` (string, default `ubuntu-22.04-arm`): Runner label used to
  natively build the `linux/arm64` platform.

Notable behavioral note for shared inputs:

- `push` (boolean, default `true`): This distributed flow requires `push: true`.
  It pushes each arch by digest and then merges them; with `push: false` there is
  nothing to merge.
- `platforms` (string, default `linux/amd64,linux/arm64`): Each comma-separated
  platform becomes its own native build job. `linux/amd64` and `linux/arm64` map
  to the runner inputs above; any other platform falls back to `amd64-runner`
  (override the inputs if you build other arches).

See the single-job README for the full list of shared inputs (`app-version`,
`image-name`, `jf-project`, `build-args-json`, `labels-json`, `jf-go-repo`,
`versions-override`, etc.) and the `build-secrets-json` secret.

## Outputs

Identical to the single-job workflow:

- `digest`: Image manifest digest (the **multi-arch manifest-list** digest)
- `image-ref`: Primary tag with `@digest`
- `tags`: Comma separated list of tags used
- `immutable-tag`: Immutable tag (`registry/image:version_timestamp`)

## Tag generation, build secrets, GOPROXY, notes

These behave exactly as in the single-job workflow — see
[its README](../docker-build-deploy/README.md#tag-generation) for tag generation
rules, JFrog token / `goproxy` / custom build secrets, and the `v`-prefix / `+`
handling notes. The only difference is *when* tags are applied (at merge, as
described above), not *what* tags are produced.
