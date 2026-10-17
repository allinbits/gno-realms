// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

type X struct{}

func (X) ClientType() string {
	return "wrong--"
}

func (X) ValidateBasic() error {
	return nil
}

// CreateClient w/ invalid client type
func main(cur realm) {
	core.CreateClient(cross(cur), X{}, X{})
}

// Error:
// the client and consensus states must be a light client's own types
