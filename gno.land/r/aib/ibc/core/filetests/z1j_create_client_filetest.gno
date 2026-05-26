// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/r/aib/ibc/core"
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
// client type does not meet naming constraints: not a valid clientID: wrong---0
