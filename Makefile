
ifdef GNOROOT
	# If GNOROOT is already user defined, we need to override it with the
	# GNOROOT of the fork.
	# This is not required otherwise because the GNOROOT that originated the
	# binary is stored in a build flag.
	# (see -X github.com/gnolang/gno/gnovm/pkg/gnoenv._GNOROOT)
	GNOROOT = $(shell go list -f '{{.Module.Dir}}' github.com/gnolang/gno)
endif

# --- Development ---

gnodev:
	go tool gnodev -empty-blocks

# --- Unit tests ---

test:
	go tool gno test ./gno.land/...
	go test -C ./cmd/gen-block-signatures
	go test -C ./cmd/gen-proof

# Download gno module dependencies by starting a local gnodev from the fork.
# This is needed because some dependencies (e.g. p/onbloc/*) are not available
# on the default gno remote, but exist in the fork's examples. The test-assertion
# helpers (uassert/urequire/testutils) are imported only from *_test.gno files, so
# preload them explicitly so `gno mod download` fetches them too.
mod-download:
	go tool gnodev -interactive=false -empty-blocks \
		-paths "gno.land/p/nt/uassert/v0,gno.land/p/nt/urequire/v0,gno.land/p/nt/testutils/v0,gno.land/r/aib/ibc/core,gno.land/r/aib/ibc/apps/transfer,gno.land/r/aib/ibc/apps/testing/grc20test" </dev/null & \
	gnodev_pid=$$!; \
	trap "kill $$gnodev_pid 2>/dev/null" EXIT; \
	while ! curl -sf 'http://127.0.0.1:26657/abci_query?path=%22.app/version%22' 2>/dev/null | grep -q '"response"'; do \
		if ! kill -0 $$gnodev_pid 2>/dev/null; then echo "gnodev exited before becoming ready" >&2; exit 1; fi; \
		sleep 1; \
	done; \
	go tool gno clean -modcache=true; \
	go tool gno mod download -remote-overrides gno.land=http://127.0.0.1:26657

# --- E2E tests ---

export COMPOSE_PROJECT_NAME=e2e
# The e2e gno image is always built from the commit go.mod pins, so the e2e
# chain and `make test` can never run different gno versions. Never a branch
# name: a moving ref keeps the docker build-arg string identical across pin
# bumps, so the `git fetch` layer stays cached and the image silently drifts —
# it once ran a gno a month older than the pin, and `--build --force-recreate`
# does not help, only `--no-cache` would. A resolved commit changes the layer
# key whenever the pin changes.
#
# To run e2e against another gno ref, pin it first: `make update-fork
# FORK_REF=<ref>` (then `make mod-download`), which moves both sides together.
DC=FORK_REF=$(GNO_PINNED_REF) docker compose -f e2e/docker-compose.yml --progress plain

e2e-up:
	$(DC) up -d --build --force-recreate

e2e-down:
	$(DC) down -v

e2e-test:
	$(DC) up -d --build --force-recreate
	cd e2e && go test -v -timeout 10m -count=1 ./...; ret=$$?; cd .. && if [ $$ret -ne 0 ]; then echo "=== relayer logs ===" && $(DC) logs relayer && echo "=== gno logs ===" && $(DC) logs gno; fi; $(DC) down -v; exit $$ret

e2e-test-only:
	cd e2e && go test -v -timeout 10m -count=1 ./...

e2e-clean:
	$(DC) down -v --rmi local

e2e-logs:
	$(DC) logs -f

e2e-build:
	$(DC) build

e2e-build-no-cache:
	$(DC) build --no-cache

# --- Fork management ---

export FORK_REPO := github.com/gnolang/gno

# The gno ref go.mod currently pins, read straight out of the replace
# directive: the 12-char commit of a pseudo-version, or a tag as-is. This is
# what the e2e gno image is built from (see DC above). Reading go.mod keeps it
# offline and instant — no module cache, no `go mod download` on every make
# invocation — and the abbreviated commit is enough because the image fetches
# a source archive, which GitHub resolves from a prefix (`git fetch` would
# have needed the full 40-char hash, which Go exposes nowhere but the module
# cache's .info file).
GNO_PINNED_REF := $(shell sed -n 's|^\tgithub.com/gnolang/gno => github.com/gnolang/gno \(v[^ ]*\)$$|\1|p' go.mod | sed -E 's/^v0\.0\.0-[0-9]{14}-//')

# FORK_REF is what `make update-fork` re-pins to: a branch name, a tag, or a
# commit hash, handed to `go mod edit -replace` for `go mod tidy` to resolve
# into a pseudo-version. It tracks a branch by default, so a plain
# `make update-fork` moves the pin to the tip of upstream master.
FORK_REF ?= master


# Optional Go build tags forwarded to the gnodev build in the e2e image.
# Set GO_BUILD_TAGS=gastrace to build the store-gas tracing variant used by
# e2e/gas-trace-report.md. Default empty: normal e2e build, no tracing.
export GO_BUILD_TAGS ?=

update-fork:
	@echo "pinning $(FORK_REPO) to '$(FORK_REF)'"
	go mod edit -replace github.com/gnolang/gno=$(FORK_REPO)@$(FORK_REF)
	go mod tidy
	go mod edit -replace github.com/gnolang/gno/contribs/gnodev=$(FORK_REPO)/contribs/gnodev@$(FORK_REF)
	go mod tidy
