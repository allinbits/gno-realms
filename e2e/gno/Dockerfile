# Build stage: compile gnodev and gnokey from the gno fork
FROM golang:1.26.0-alpine AS builder

ARG FORK_REPO
ARG FORK_REF
# Optional Go build tags for gnodev. Set to "gastrace" to enable the
# store-gas tracing build (emits GAS_STORE/GAS_TX_* lines to stderr).
# Default empty: normal production build, zero tracing overhead.
ARG GO_BUILD_TAGS

RUN apk add --no-cache make

# Download the pinned ref as a source archive. The endpoint takes a branch, a
# tag, or a commit — and unlike `git fetch`, it resolves an abbreviated commit
# (it redirects to codeload with the full hash), so the Makefile can pass the
# 12-char commit that go.mod's pseudo-version already carries instead of
# resolving the full 40-char hash out of the module cache. The archive also
# skips fetching git history we never use.
RUN test -n "${FORK_REF}" || { echo "FORK_REF build arg is empty (expected a branch, tag or commit)" >&2; exit 1; } \
    && mkdir -p /src/gno \
    && wget -qO- "https://${FORK_REPO}/archive/${FORK_REF}.tar.gz" \
       | tar xz -C /src/gno --strip-components=1 \
    && echo "${FORK_REF}" > /src/gno/GNO_REF

WORKDIR /src/gno

# Build gnodev (optionally with -tags gastrace via GO_BUILD_TAGS)
RUN cd contribs/gnodev && go build -tags "${GO_BUILD_TAGS}" -o /usr/local/bin/gnodev .

# Build gnokey
RUN cd gno.land/cmd/gnokey && go build -o /usr/local/bin/gnokey .

# Build gno CLI
RUN cd gnovm/cmd/gno && go build -o /usr/local/bin/gno .

# Copy IBC realms/packages and download dependencies from local gnodev.
COPY gnowork.toml /aibgno/gnowork.toml
COPY gno.land /aibgno/gno.land
ENV GNOROOT=/src/gno
RUN cd /aibgno && \
    gnodev -empty-blocks \
        -paths "gno.land/p/nt/uassert/v0,gno.land/p/nt/urequire/v0,gno.land/p/nt/testutils/v0,gno.land/r/aib/ibc/core,gno.land/r/aib/ibc/apps/transfer,gno.land/r/aib/ibc/apps/testing/grc20test" > /tmp/gnodev.log 2>&1 & \
    gnodev_pid=$!; \
    while ! wget -q -O- 'http://127.0.0.1:26657/abci_query?path=%22.app/version%22' 2>/dev/null | grep -q '"response"'; do \
        kill -0 "$gnodev_pid" 2>/dev/null || { echo "gnodev exited before becoming ready:"; cat /tmp/gnodev.log; exit 1; }; \
        sleep 1; \
    done && \
    gno clean -modcache=true && \
    cd /aibgno/gno.land/r/aib/ibc/apps/transfer && \
    gno mod download -remote-overrides gno.land=http://127.0.0.1:26657

# Runtime stage
FROM alpine:3.21

RUN apk add --no-cache curl bash

COPY --from=builder /usr/local/bin/gnodev /usr/local/bin/gnodev
COPY --from=builder /usr/local/bin/gnokey /usr/local/bin/gnokey
COPY --from=builder /src/gno /gnoroot

# Copy IBC realms/packages (with downloaded dependencies) from builder.
# gnowork.toml lets the entrypoint's gnodev auto-detect /aibgno as the workspace.
COPY --from=builder /aibgno/gnowork.toml /aibgno/gnowork.toml
COPY --from=builder /aibgno/gno.land /aibgno/gno.land

ENV GNOROOT=/gnoroot

COPY e2e/gno/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 26657 8888 8546

ENTRYPOINT ["/entrypoint.sh"]
