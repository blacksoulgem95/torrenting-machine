FROM docker.io/jellyfin/jellyfin:12.1

ARG RCLONE_VERSION=v1.75.1
ARG RCLONE_SHA256=982b5aa772841168f8e380f139e9e787b2a105403e32b94da8676a0e1c0a13ab

RUN apt-get update \
 && apt-get install -y --no-install-recommends fuse3 ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*

# rclone ufficiale (la versione di Debian è troppo vecchia)
RUN curl -fsSL -o /tmp/rclone.zip \
      "https://downloads.rclone.org/${RCLONE_VERSION}/rclone-${RCLONE_VERSION}-linux-amd64.zip" \
 && echo "${RCLONE_SHA256}  /tmp/rclone.zip" | sha256sum -c - \
 && unzip -j /tmp/rclone.zip '*/rclone' -d /usr/local/bin \
 && chmod 755 /usr/local/bin/rclone \
 && rm /tmp/rclone.zip

COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
