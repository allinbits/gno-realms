# Build stage: compile atomoned from the main branch
FROM golang:1.26.1-alpine AS builder

RUN apk add --no-cache git make

RUN git clone --branch main --single-branch --depth 1 \
    https://github.com/atomone-hub/atomone.git /src/atomone

WORKDIR /src/atomone

# Tag HEAD so `git describe` works (shallow clone has no tags)
RUN git tag v0.0.0-e2e

RUN make install

# Runtime stage
FROM alpine:3.21

RUN apk add --no-cache curl bash

COPY --from=builder /go/bin/atomoned /usr/local/bin/atomoned

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 26657 1317 9090

ENTRYPOINT ["/entrypoint.sh"]
