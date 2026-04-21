
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
	go tool gnodev -empty-blocks -resolver root=. \
		-resolver root=$(shell go tool gno env GNOROOT)/examples

# --- Unit tests ---

test:
	go tool gno test ./gno.land/...
	go test -C ./cmd/gen-block-signatures
	go test -C ./cmd/gen-proof

# Download gno module dependencies by starting a local gnodev from the fork.
# This is needed because some dependencies (e.g. p/onbloc/*) are not available
# on the default gno remote, but exist in the fork's examples.
mod-download:
	go tool gnodev -empty-blocks -resolver root=. \
		-resolver root=$(shell go tool gno env GNOROOT)/examples \
		-paths "gno.land/r/aib/ibc/core,gno.land/r/aib/ibc/apps/transfer,gno.land/r/aib/ibc/apps/testing/grc20test" & \
	while ! curl -sf 'http://127.0.0.1:26657/abci_query?path=%22.app/version%22' 2>/dev/null | grep -q '"response"'; do sleep 1; done; \
	go tool gno clean -modcache=true; \
	go tool gno mod download -remote-overrides gno.land=http://127.0.0.1:26657

# --- E2E tests ---

export COMPOSE_PROJECT_NAME=e2e
DC=docker compose -f e2e/docker-compose.yml --progress plain

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

# --- Fork management ---

export FORK_REPO   := github.com/allinbits/gno
export FORK_BRANCH := ibc-fork

update-fork:
	$(eval HASH := $(shell git ls-remote https://$(FORK_REPO).git refs/heads/$(FORK_BRANCH) | awk '{print $$1}'))
	go mod edit -replace github.com/gnolang/gno=$(FORK_REPO)@$(HASH)
	go mod tidy
	go mod edit -replace github.com/gnolang/gno/contribs/gnodev=$(FORK_REPO)/contribs/gnodev@$(HASH)
	go mod tidy
