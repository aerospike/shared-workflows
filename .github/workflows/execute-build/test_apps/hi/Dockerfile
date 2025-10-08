# checkov:skip=CKV_DOCKER_2: Simple hello world app doesn't need healthcheck
FROM ubuntu:22.04 AS builder

RUN apt-get update && apt-get install -y build-essential \
    && useradd -r -m -s /usr/sbin/nologin builder \
    && mkdir -p /work \
    && chown -R builder:builder /work

WORKDIR /work
# (optional) ensure files are owned by builder at copy time
# COPY --chown=builder:builder hi.c Makefile ./
COPY hi.c Makefile ./

USER builder
RUN make build

FROM gcr.io/distroless/static-debian12:debug-nonroot
COPY --from=builder /work/hi /usr/local/bin/hi
ENTRYPOINT ["/usr/local/bin/hi"]
