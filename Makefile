
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
	go tool gno test -v ./gno.land/...

update-fork:
	go mod edit -replace  github.com/gnolang/gno=github.com/allinbits/gno@ibc-fork
	go mod tidy
