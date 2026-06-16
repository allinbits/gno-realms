# Build stage: compile gnodev and gnokey from the gno fork
FROM golang:1.26.0-alpine AS builder

ARG FORK_REPO
ARG FORK_BRANCH
# Optional Go build tags for gnodev. Set to "gastrace" to enable the
# store-gas tracing build (emits GAS_STORE/GAS_TX_* lines to stderr).
# Default empty: normal production build, zero tracing overhead.
ARG GO_BUILD_TAGS

RUN apk add --no-cache git make

# Clone the gno fork with IBC support
RUN git clone --branch ${FORK_BRANCH} --single-branch --depth 1 \
    https://${FORK_REPO}.git /src/gno

WORKDIR /src/gno

# Build gnodev (optionally with -tags gastrace via GO_BUILD_TAGS)
RUN cd contribs/gnodev && go build -tags "${GO_BUILD_TAGS}" -o /usr/local/bin/gnodev .

# Build gnokey
RUN cd gno.land/cmd/gnokey && go build -o /usr/local/bin/gnokey .

# Build gno CLI
RUN cd gnovm/cmd/gno && go build -o /usr/local/bin/gno .

# Copy IBC realms/packages and download dependencies from local gnodev
COPY gnowork.toml /aibgno/gnowork.toml
COPY gno.land /aibgno/gno.land
ENV GNOROOT=/src/gno
RUN cd /aibgno && \
    gnodev -empty-blocks -resolver root=. \
        -resolver root=$GNOROOT/examples \
        -paths "gno.land/r/aib/ibc/core,gno.land/r/aib/ibc/apps/transfer,gno.land/r/aib/ibc/apps/testing/grc20test" > /dev/null 2>&1 & \
    while ! wget -q -O- 'http://127.0.0.1:26657/abci_query?path=%22.app/version%22' 2>/dev/null | grep -q '"response"'; do sleep 1; done && \
    gno clean -modcache=true && \
    cd /aibgno/gno.land/r/aib/ibc/apps/transfer && \
    gno mod download -remote-overrides gno.land=http://127.0.0.1:26657

# Runtime stage
FROM alpine:3.21

RUN apk add --no-cache curl bash

COPY --from=builder /usr/local/bin/gnodev /usr/local/bin/gnodev
COPY --from=builder /usr/local/bin/gnokey /usr/local/bin/gnokey
COPY --from=builder /src/gno /gnoroot

# Copy IBC realms/packages (with downloaded dependencies) from builder
COPY --from=builder /aibgno/gno.land /aibgno/gno.land

ENV GNOROOT=/gnoroot

COPY e2e/gno/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 26657 8888 8546

ENTRYPOINT ["/entrypoint.sh"]
