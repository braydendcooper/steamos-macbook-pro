FROM --platform=linux/arm64 debian:trixie AS desync-builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates golang-go git \
    && rm -rf /var/lib/apt/lists/*
# Build the pinned release from Go module source, including go.sum verification.
RUN CGO_ENABLED=0 GOBIN=/build go install github.com/folbricht/desync/cmd/desync@v1.1.4

FROM --platform=linux/arm64 debian:trixie
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash coreutils curl squashfs-tools ca-certificates mawk util-linux \
    && rm -rf /var/lib/apt/lists/*
COPY --from=desync-builder /build/desync /usr/local/bin/desync
COPY fetch-rootfs.sh /usr/local/bin/fetch-rootfs.sh
RUN chmod 0755 /usr/local/bin/fetch-rootfs.sh
WORKDIR /src
ENTRYPOINT ["/usr/local/bin/fetch-rootfs.sh"]
