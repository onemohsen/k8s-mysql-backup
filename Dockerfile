FROM alpine:3.20

# kubectl version to install (override at build: --build-arg KUBECTL_VERSION=v1.31.0)
ARG KUBECTL_VERSION=v1.31.0
# target arch: amd64 (x86_64) or arm64 (aarch64)
ARG TARGETARCH=amd64

RUN apk add --no-cache \
        bash \
        curl \
        ca-certificates \
        gzip \
        rclone \
        tzdata \
    && curl -fsSL -o /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client

# config (kubeconfig + rclone.conf) is mounted here read-only at runtime
ENV KUBECONFIG=/config/kubeconfig
ENV RCLONE_CONFIG=/config/rclone.conf

# where dumps land locally before upload
VOLUME ["/backups"]

COPY backup.sh /usr/local/bin/backup.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
