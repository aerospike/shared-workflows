# checkov:skip=CKV_DOCKER_2: Simple hello world app doesn't need healthcheck
FROM ubuntu:22.04@sha256:3ba65aa20f86a0fad9df2b2c259c613df006b2e6d0bfcc8a146afb8c525a9751 AS builder

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
RUN make build && chmod a+x build/jammy/x86_64/hi

FROM gcr.io/distroless/cc-debian12:debug-nonroot@sha256:641f055b21555d5e4f77b7f1f3caca80840a76c4f7ae5df36a159a436941d2c2
COPY --from=builder /work/build/jammy/x86_64/hi /usr/local/bin/hi
ENTRYPOINT ["/usr/local/bin/hi"]
