package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
)

// Timeout commitment mismatch
func main() {
	var (
		chainID        = "chain-id-2"
		trustedHeight  = types.NewHeight(2, 2)
		clientState    = tmtesting.NewClientState(chainID, trustedHeight)
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
		counterpartyID = "07-tendermint-42"
	)
	clientID := core.CreateClient(cross, clientState, consensusState)
	core.RegisterCounterparty(cross, clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, counterpartyID)
	// Register app
	var (
		app       = appstesting.NewApp(cross)
		appPortID = "app"
	)
	core.RegisterApp(cross, appPortID, app)
	// Send a packet
	sendPacket := types.MsgSendPacket{
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
	sequence := core.SendPacket(cross, sendPacket)

	// Timeout the packet
	timeoutPacket := types.MsgTimeout{
		Packet: types.Packet{
			Sequence:          sequence,
			SourceClient:      clientID,
			DestinationClient: counterpartyID,
			// Timeout is different than in SendPacket, so the commitments bytes will
			// differ as well.
			TimeoutTimestamp: 1,
			Payloads:         sendPacket.Payloads,
		},
		ProofUnreceived: []ics23.CommitmentProof{
			ics23.CommitmentProof_Nonexist{
				Nonexist: &ics23.NonExistenceProof{},
			},
		},
		ProofHeight: trustedHeight,
	}

	core.Timeout(cross, timeoutPacket)
}

// Error:
// commitment bytes are not equal: got (95f930b7d780346ee34bc62df41384e82d5e665e583fb353dfaa322df8e75299), expected (af551c2bb8928f6b2f452fc421783d5ecd5a71b317b50224f25a9749ed89e479)
