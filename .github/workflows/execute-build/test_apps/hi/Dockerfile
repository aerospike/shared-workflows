# checkov:skip=CKV_DOCKER_2: Simple hello world app doesn't need healthcheck
FROM ubuntu:22.04 AS builder
RUN apt-get update && apt-get install -y build-essential && \
useradd -r -s /bin/false builder
USER builder
COPY hi.c Makefile ./
RUN make build
FROM gcr.io/distroless/static-debian12:debug-nonroot
COPY --from=builder hi /usr/local/bin/hi
CMD ["hi"]
