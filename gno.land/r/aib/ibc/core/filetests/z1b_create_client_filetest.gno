// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

type SoloMachine struct{}

func (SoloMachine) ClientType() string {
	return lightclient.Solomachine
}

func (SoloMachine) ValidateBasic() error {
	return nil
}

// CreateClient w/ unhandled light client type: a client state of the
// caller's own type is refused before any of its methods runs (Codex round
// 19). Every state that passes is a Tendermint or Ethereum one, so the
// "unhandled light client type" branch the base reached here is no longer
// reachable.
func main(cur realm) {
	core.CreateClient(cross(cur), SoloMachine{}, SoloMachine{})
}

// Error:
// the client state must be a light client's own type
