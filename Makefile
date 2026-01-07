
ifdef GNOROOT
	# If GNOROOT is already user defined, we need to override it with the
	# GNOROOT of the fork.
	# This is not required otherwise because the GNOROOT that originated the
	# binary is stored in a build flag.
	# (see -X github.com/gnolang/gno/gnovm/pkg/gnoenv._GNOROOT)
	GNOROOT = $(shell go list -f '{{.Module.Dir}}' github.com/gnolang/gno)
endif

gnodev:
	go tool gnodev -empty-blocks -resolver root=. \
		-resolver root=$(shell go tool gno env GNOROOT)/examples

test: 
	go tool gno test ./gno.land/...
	go test -C ./cmd/gen-block-signatures
	go test -C ./cmd/gen-proof

FORK_REPO   := github.com/tbruyelle/gno
FORK_BRANCH := tbruyelle/origin-send-filter

update-fork:
	$(eval HASH := $(shell git ls-remote https://$(FORK_REPO).git refs/heads/$(FORK_BRANCH) | awk '{print $$1}'))
	go mod edit -replace github.com/gnolang/gno=$(FORK_REPO)@$(HASH)
	go mod tidy
	go mod edit -replace github.com/gnolang/gno/contribs/gnodev=$(FORK_REPO)/contribs/gnodev@$(HASH)
	go mod tidy
