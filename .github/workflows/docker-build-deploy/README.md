# Reusable Docker Build, Publish & Attest (minimal)

This workflow builds, optionally attests, and publishes an OCI image to JFrog Artifactory

## Usage

```yaml
jobs:
  build-docker-deploy:
    uses: aerospike/shared-workflows/.github/workflows/reusable_docker-build-deploy.yaml@<sha>
    with:
      jf_project: test
      image_name: test-image
      tag: artifact.aerospike.io/test-container-dev-local/test-image:${{ github.run_number }}
      context: ./.github/workflows/execute-build/test_apps/hi
      file: ./.github/workflows/execute-build/test_apps/hi/Dockerfile
      jf_build_name: test-build-container
```

## Inputs

### Required

- `image_name` (string, required): Image repository/name (no registry)
- `jf_project` (string, required): JFrog project key
- `tag` (string, required): Full image tag including registry and repo path

### Optional / defaults

- `attest` (boolean, default true): Generate SLSA attestation
- `build_args_json` (string, default `{}`): JSON map of extra build args
- `context` (string, default `.`): Build context
- `file` (string, default `Dockerfile`): Dockerfile path (relative to context)
- `jf_build_name` (string, optional): Build name for JFrog build-info (defaults to workflow name)
- `jf_registry` (string, optional): Full registry including repository path
- `jf_registry_base` (string, default `artifact.aerospike.io`): Registry hostname
- `jf_url` (string, default `https://artifact.aerospike.io`): Artifactory URL
- `labels_json` (string, default `{}`): JSON map of labels
- `oidc_audience` (string, default `aerospike/testing`): OIDC audience
- `oidc_provider_name` (string, default `gh-dev-test`): OIDC provider
- `platforms` (string, default `linux/amd64,linux/arm64`): Buildx platforms
- `provenance` (string, default `mode=max`): BuildKit provenance setting
- `push` (boolean, default true): Push image to registry
- `repo_scope` (string, default `-container-dev-local`): Repository suffix appended to project to form registry path
- `sbom` (boolean, default true): Enable SBOM generation

## Outputs

- `digest`: Image manifest digest
- `image_ref`: Primary tag with `@digest`
- `tag`: Primary tag used

## Notes

- Prefer setting `tag` explicitly to avoid implicit tagging logic.
- For Artifactory, ensure `tag` uses the full registry path including repository (e.g., `artifact.aerospike.io/test-container-dev-local/...`).
