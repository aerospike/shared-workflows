# checkov:skip=CKV_DOCKER_2: Simple hello world app doesn't need healthcheck
FROM artifact.aerospike.io/test-docker-virtual/library/ubuntu:26.04@sha256:f3d28607ddd78734bb7f71f117f3c6706c666b8b76cbff7c9ff6e5718d46ff64 AS builder

# trunk-ignore(hadolint/DL3008)
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
    && useradd -r -m -s /usr/sbin/nologin builder \
    && mkdir -p /work \
    && chown -R builder:builder /work

WORKDIR /work
COPY --chown=builder:builder hi.c Makefile ./

USER builder
ENV DISTRO=jammy
ENV ARCH=x86_64
RUN --mount=type=secret,id=jfrog_token test -f /run/secrets/jfrog_token
RUN make build && chmod a+x build/jammy/x86_64/hi

FROM artifact.aerospike.io/test-docker-virtual/distroless/cc-debian12:debug-nonroot@sha256:4b2ac73905e8d2f11d105bba3328a5cf549d099f1dac1bdda0a753ac97858c14
COPY --from=builder /work/build/jammy/x86_64/hi /usr/local/bin/hi
ENTRYPOINT ["/usr/local/bin/hi"]
