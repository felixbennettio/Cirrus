# Build from source (multi-stage). On a weak server prefer the prebuilt
# bundle from build-bundle.sh, which uses deploy/Dockerfile.runtime instead.
FROM golang:1.24-alpine AS build
# In mainland China: --build-arg GOPROXY=https://goproxy.cn,direct
ARG GOPROXY=https://proxy.golang.org,direct
ENV CGO_ENABLED=0 GOPROXY=${GOPROXY} GOTOOLCHAIN=local
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
ARG VERSION=source
RUN go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/cirrus-license ./cmd/cirrus-license

FROM alpine:3.20
# Optional apk mirror host, e.g. mirrors.tencent.com or mirrors.aliyun.com.
ARG ALPINE_MIRROR=
RUN if [ -n "$ALPINE_MIRROR" ]; then sed -i "s#dl-cdn.alpinelinux.org#${ALPINE_MIRROR}#g" /etc/apk/repositories; fi \
 && apk add --no-cache ca-certificates tzdata \
 && addgroup -S -g 10001 cirrus \
 && adduser -S -D -H -u 10001 -G cirrus cirrus \
 && mkdir -p /data && chown cirrus:cirrus /data
ENV TZ=Asia/Shanghai DATA_DIR=/data LISTEN=:8080 GOMEMLIMIT=96MiB
COPY --from=build /out/cirrus-license /usr/local/bin/cirrus-license
USER cirrus
VOLUME /data
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["/usr/local/bin/cirrus-license"]
