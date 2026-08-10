# ctx test app

Fixture for `gh-context-artifacts-json` on `reusable_docker-build-deploy.yaml`.

The Dockerfile copies `artifacts/`, which does not exist in the repository. It is
created in the build context by the artifact delivery under test, so a build that
runs without delivery fails on a missing source path.

The entrypoint prints the delivered file paths, then `---`, then their contents,
so a verifying job can assert on both.

It is separate from `test_apps/hi` because that context is shared with build jobs
that receive no artifacts; adding a `COPY artifacts/` there would break them.
