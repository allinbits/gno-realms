// PKGPATH: gno.land/r/aib/main
package main

import (
	"gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/aib/ibc/types/v0"
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

// CreateClient w/ client type mismatch
func main(cur realm) {
	core.CreateClient(cross(cur), testing.NewClientState("chainid", types.Height{}), SoloMachine{})
}

// Error:
// client type for client state and consensus state do not match
