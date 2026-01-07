FROM alpine:edge AS build

COPY . /

RUN set -xe \
    && echo "@testing https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories \
    && apk update \
    && apk add --no-cache \
        bash \
        finger@testing \
        jq \
        shadow \
        binutils \
    && chmod +x /entrypoint.sh

RUN set -xe \
    && rm -rf /etc/* /media /mnt /opt /root /srv /tmp/* /var /.ash_history || true \
    && echo 'root:*:0:0:::/bin/sh' > /etc/passwd \
    && echo 'root:x:0:root' > /etc/group

FROM scratch
COPY --from=build / /
EXPOSE 79/tcp
ENTRYPOINT ["./entrypoint.sh"]
