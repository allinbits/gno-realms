package main

import (
	"errors"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
)

// SendPacket fails app returns an error
func main() {
	var (
		chainID        = "chain-id-2"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	clientID := core.CreateClient(cross, clientState, consensusState)
	core.RegisterCounterparty(cross, clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-2")

	println("next sequence:", core.Render("clients/"+clientID+"/next_sequence_send"))
	// Register app
	var (
		app       = appstesting.NewApp(cross)
		appPortID = "app1"
	)
	app.SetOnSendPacketReturn(errors.New("app error"))
	core.RegisterApp(cross, appPortID, app)

	packet := types.MsgSendPacket{
		SourceClient:     clientID,
		TimeoutTimestamp: uint64(time.Now().Add(time.Hour).Unix()),
		Payloads: []types.Payload{{
			SourcePort:      appPortID,
			DestinationPort: "destinationPort",
			Encoding:        "application/json",
			Value:           []byte("{}"),
			Version:         "v1",
		}},
	}

	core.SendPacket(cross, packet)
}

// Error:
// send packet failed for payload #0 app "app1": app error
