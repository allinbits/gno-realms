# Build stage: compile gnodev and gnokey from the allinbits/gno fork
FROM golang:1.24-alpine AS builder

RUN apk add --no-cache git make

# Clone the gno fork with IBC support
RUN git clone --branch tbruyelle/origin-send-filter --single-branch --depth 1 \
    https://github.com/tbruyelle/gno.git /src/gno

WORKDIR /src/gno

# Build gnodev
RUN cd contribs/gnodev && go build -o /usr/local/bin/gnodev .

# Build gnokey
RUN cd gno.land/cmd/gnokey && go build -o /usr/local/bin/gnokey .

# Runtime stage
FROM alpine:3.21

RUN apk add --no-cache curl bash

COPY --from=builder /usr/local/bin/gnodev /usr/local/bin/gnodev
COPY --from=builder /usr/local/bin/gnokey /usr/local/bin/gnokey
COPY --from=builder /src/gno /gnoroot

# Copy IBC realms/packages from the aibgno project
COPY gno.land /aibgno/gno.land

ENV GNOROOT=/gnoroot

COPY e2e/gno/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 26657 8888 8546

ENTRYPOINT ["/entrypoint.sh"]
