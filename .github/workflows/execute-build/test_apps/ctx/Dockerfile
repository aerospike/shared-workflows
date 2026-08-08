# checkov:skip=CKV_DOCKER_2: fixture image runs once and exits; nothing to health-check
FROM artifact.aerospike.io/test-docker-virtual/distroless/cc-debian12:debug-nonroot@sha256:4b2ac73905e8d2f11d105bba3328a5cf549d099f1dac1bdda0a753ac97858c14

# A literal path, never `COPY ${VAR} /dest`. An ARG that is declared but never
# given a value leaves ${VAR} unsubstituted, so the instruction becomes
# `COPY  /dest`, which copies the entire build context into a directory and
# exits 0. That failure mode is what this fixture exists to catch, so the
# fixture must not contain it.
#
# Neither directory exists in the repository. Both are created in the build
# context by the caller's gh-context-artifacts-json delivery, so a build that
# reaches here without delivery fails on a missing source path. Two of them, so
# one image proves each entry lands at its own destination rather than merging.
COPY artifacts/ /delivered/
COPY extra/ /extra/

USER nonroot

ENTRYPOINT ["/busybox/sh", "-c", "find /delivered /extra -type f | sort && echo --- && find /delivered /extra -type f -exec cat {} +"]
