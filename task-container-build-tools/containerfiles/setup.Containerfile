ARG TARGETARCH
FROM alpine/k8s:1.33.1 AS k8s

FROM docker.io/library/alpine AS entrypoint
RUN apk add clang curl-dev build-base util-linux-dev
WORKDIR /workdir
COPY scripts/entrypoint /workdir
RUN clang++ -static-libgcc -static-libstdc++ -std=c++17 entrypoint.cpp -lcurl -o entrypoint


FROM alpine/git:v2.47.2
USER root
RUN apk add gettext jq bash
COPY --from=k8s /usr/bin/kubectl /usr/local/bin/kubectl
ENV USER_UID=2000 \
    USER_NAME=i3-runner \
    HOME=/home/i3-runner
COPY scripts/usersetup /usersetup
RUN  /usersetup
COPY --from=entrypoint /workdir/entrypoint /usr/local/bin/entrypoint
USER 2000
ENTRYPOINT ["/usr/local/bin/entrypoint"]
LABEL org.opencontainers.image.source=https://github.com/galleybytes/infrakube
