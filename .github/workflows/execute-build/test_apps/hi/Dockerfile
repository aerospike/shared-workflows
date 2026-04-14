# checkov:skip=CKV_DOCKER_2: Simple hello world app doesn't need healthcheck
FROM ubuntu:24.04@sha256:186072bba1b2f436cbb91ef2567abca677337cfc786c86e107d25b7072feef0c AS builder

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

FROM gcr.io/distroless/cc-debian12:debug-nonroot@sha256:78f0e748899b6f03259b13b362e82d7c4adc7211b1fb3f4e06deff716059e6cd
COPY --from=builder /work/build/jammy/x86_64/hi /usr/local/bin/hi
ENTRYPOINT ["/usr/local/bin/hi"]
