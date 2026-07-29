# Build stage: compile gnodev and gnokey from the gno fork
FROM golang:1.26.0-alpine AS builder

ARG FORK_REPO
ARG FORK_REF
# Optional Go build tags for gnodev. Set to "gastrace" to enable the
# store-gas tracing build (emits GAS_STORE/GAS_TX_* lines to stderr).
# Default empty: normal production build, zero tracing overhead.
ARG GO_BUILD_TAGS

RUN apk add --no-cache git make

# Shallow-fetch the pinned ref. `git fetch <ref>` accepts a branch, a tag, or a
# commit hash (GitHub allows fetching a reachable commit SHA directly), whereas
# `git clone --branch` rejects commit hashes.
RUN git init /src/gno \
    && cd /src/gno \
    && git remote add origin https://${FORK_REPO}.git \
    && git fetch --depth 1 origin ${FORK_REF} \
    && git checkout --detach FETCH_HEAD

WORKDIR /src/gno

# Build gnodev (optionally with -tags gastrace via GO_BUILD_TAGS)
RUN cd contribs/gnodev && go build -tags "${GO_BUILD_TAGS}" -o /usr/local/bin/gnodev .

# Build gnokey
RUN cd gno.land/cmd/gnokey && go build -o /usr/local/bin/gnokey .

# Copy IBC realms/packages from the gno-ibc contracts context (see the
# `contracts` additional build context in docker-compose.yml). That tree is
# fully vendored (gno-ibc `make vendor`), so gnodev resolves every dependency
# from the workspace at runtime — no `gno mod download` step is needed here.
COPY gnowork.toml /aibgno/gnowork.toml
COPY --from=contracts . /aibgno/gno.land

# Drop scenario/mock realms: they are test-only fixtures, not part of the e2e
# node, and one (r/onbloc/ibc/scenario/helper/cometbls) fails on-chain
# type-check, which gnodev would report at genesis.
RUN rm -rf /aibgno/gno.land/r/onbloc/ibc/scenario \
           /aibgno/gno.land/r/onbloc/ibc/testing \
           /aibgno/gno.land/r/aib/ibc/apps/transfer/scenario

# Runtime stage
FROM alpine:3.21

RUN apk add --no-cache curl bash

COPY --from=builder /usr/local/bin/gnodev /usr/local/bin/gnodev
COPY --from=builder /usr/local/bin/gnokey /usr/local/bin/gnokey
COPY --from=builder /src/gno /gnoroot

# Copy the IBC realms/packages workspace from builder.
# gnowork.toml lets the entrypoint's gnodev auto-detect /aibgno as the workspace.
COPY --from=builder /aibgno/gnowork.toml /aibgno/gnowork.toml
COPY --from=builder /aibgno/gno.land /aibgno/gno.land

ENV GNOROOT=/gnoroot

COPY e2e/gno/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 26657 8888 8546

ENTRYPOINT ["/entrypoint.sh"]
