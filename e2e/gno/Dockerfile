# Build stage: compile gnodev and gnokey from the gno fork
FROM golang:1.24-alpine AS builder

ARG FORK_REPO
ARG FORK_BRANCH

RUN apk add --no-cache git make

# Clone the gno fork with IBC support
RUN git clone --branch ${FORK_BRANCH} --single-branch --depth 1 \
    https://${FORK_REPO}.git /src/gno

WORKDIR /src/gno

# Build gnodev
RUN cd contribs/gnodev && go build -o /usr/local/bin/gnodev .

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
        -resolver root=$GNOROOT/examples > /dev/null 2>&1 & \
    while ! wget -q -O /dev/null http://127.0.0.1:26657/status 2>/dev/null; do sleep 1; done && \
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
