// PKGPATH: gno.land/r/aib/main
package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// WriteAcknowledgement without a pending async acknowledgement is refused.
func main(cur realm) {
	clientID := core.CreateClient(cross(cur),
		tmtesting.NewClientState("chainA-2", types.NewHeight(2, 2)),
		tmtesting.GenConsensusState(time.Now(), []byte("apphash"), tmtesting.GenValset().Hash()),
	)
	core.WriteAcknowledgement(cross(cur), clientID, 1, types.Acknowledgement{
		AppAcknowledgements: [][]byte{{0x01}},
	})
}

// Error:
// no pending async ack for client=07-tendermint-1 sequence=1
