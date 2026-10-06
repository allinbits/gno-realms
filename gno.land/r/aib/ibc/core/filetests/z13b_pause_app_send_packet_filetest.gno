// PKGPATH: gno.land/r/aib/main
package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
)

// SendPacket is refused for a paused app; nothing is committed or sent.
func main(cur realm) {
	var (
		chainID        = "chain-id-2"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	clientID := core.CreateClient(cross(cur), clientState, consensusState)
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-2")

	println("next sequence:", core.Render("clients/"+clientID+"/next_sequence_send"))
	// Register 2 apps, only app1 is targeted by the packet payload.
	var (
		app1       = appstesting.NewApp(cross(cur))
		app1PortID = "app1"
	)
	core.RegisterApp(cross(cur), app1PortID, app1)
	var (
		app2       = appstesting.NewApp(cross(cur))
		app2PortID = "app2"
	)
	core.RegisterApp(cross(cur), app2PortID, app2)

	packet := types.MsgSendPacket{
		SourceClient:     clientID,
		TimeoutTimestamp: uint64(time.Now().Add(time.Hour).Unix()),
		Payloads: []types.Payload{
			{
				SourcePort:      app1PortID,
				DestinationPort: "destinationPort",
				Encoding:        "application/json",
				Value:           []byte("{}"),
				Version:         "v1",
			},
		},
	}

	core.AddAuthorityMember(cross(cur), cur.Address())
	core.PauseApp(cross(cur), app1PortID)
	core.SendPacket(cross(cur), packet)
}

// Error:
// app "app1" is paused
