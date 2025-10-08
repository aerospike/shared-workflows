# checkov:skip=CKV_DOCKER_2: Simple hello world app doesn't need healthcheck
FROM ubuntu:22.04 AS builder

RUN apt-get update && apt-get install -y build-essential \
    && useradd -r -m -s /usr/sbin/nologin builder \
    && mkdir -p /work \
    && chown -R builder:builder /work

WORKDIR /work
COPY --chown=builder:builder hi.c Makefile ./

USER builder
ENV DISTRO=jammy
ENV ARCH=x86_64
RUN make build

FROM gcr.io/distroless/static-debian12:debug-nonroot
COPY --from=builder /work/build/jammy/x86_64/hi /usr/local/bin/hi
ENTRYPOINT ["/usr/local/bin/hi"]
