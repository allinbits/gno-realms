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

// CreateClient w/ invalid client type: a client state of the caller's own
// type is refused before any of its methods runs (Codex round 19). Our own
// states name valid client types, so the naming check the base reached here
// is no longer reachable.
func main(cur realm) {
	core.CreateClient(cross(cur), X{}, X{})
}

// Error:
// the client state must be a light client's own type
