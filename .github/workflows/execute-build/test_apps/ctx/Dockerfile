# checkov:skip=CKV_DOCKER_2: fixture image runs once and exits; nothing to health-check
FROM artifact.aerospike.io/test-docker-virtual/distroless/cc-debian12:debug-nonroot@sha256:4b2ac73905e8d2f11d105bba3328a5cf549d099f1dac1bdda0a753ac97858c14

# Keep both paths literal. `COPY ${VAR} /dest` with an unset ARG becomes
# `COPY  /dest`, which copies the whole context into a directory and exits 0.
#
# Neither directory is in the repository; delivery creates them in the context.
COPY artifacts/ /delivered/
COPY extra/ /extra/

USER nonroot

ENTRYPOINT ["/busybox/sh", "-c", "find /delivered /extra -type f | sort && echo --- && find /delivered /extra -type f -exec cat {} +"]
