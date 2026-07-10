# Build stage: compile atomoned from the v4.0.0 release tag.
# v4.0.0's go.mod requires go >= 1.26.4 (enforced by atomone's
# `make check_go_version`), so the base image must be at least 1.26.4.
FROM golang:1.26.4-alpine AS builder

RUN apk add --no-cache git make

# Clone the atomone repo at the pinned release tag. `--branch` accepts a tag,
# and the shallow clone keeps that tag ref so `git describe --tags` (used by
# atomone's `make install` for version stamping) resolves to v4.0.0.
RUN git clone --branch v4.0.0 --single-branch --depth 1 \
    https://github.com/atomone-hub/atomone.git /src/atomone

WORKDIR /src/atomone

RUN make install

# Runtime stage
FROM alpine:3.21

RUN apk add --no-cache curl bash jq

COPY --from=builder /go/bin/atomoned /usr/local/bin/atomoned

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 26657 1317 9090

ENTRYPOINT ["/entrypoint.sh"]
