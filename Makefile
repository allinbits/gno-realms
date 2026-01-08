
ifdef GNOROOT
	# If GNOROOT is already user defined, we need to override it with the
	# GNOROOT of the fork.
	# This is not required otherwise because the GNOROOT that originated the
	# binary is stored in a build flag.
	# (see -X github.com/gnolang/gno/gnovm/pkg/gnoenv._GNOROOT)
	GNOROOT = $(shell go list -f '{{.Module.Dir}}' github.com/gnolang/gno)
endif

# Create a comma-separated list of each module path from gnomod.toml files
paths_list := $(shell find gno.land -name 'gnomod.toml' -exec grep -h '^module' {} + | cut -d'"' -f2 | paste -sd,)

gnodev:
	go tool gnodev -v -empty-blocks -paths=${paths_list} \
		-resolver root=$(shell go tool gno env GNOROOT)/examples \
		-resolver root=. \

test: 
	go tool gno test ./gno.land/...
	go test -C ./cmd/gen-block-signatures
	go test -C ./cmd/gen-proof

update-fork:
	go mod edit -replace  github.com/gnolang/gno=github.com/allinbits/gno@ibc-fork
	go mod tidy
	go mod edit -replace  github.com/gnolang/gno/contribs/gnodev=github.com/allinbits/gno/contribs/gnodev@ibc-fork
	go mod tidy
