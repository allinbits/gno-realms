// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"

	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
)

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

	signer := cur.Previous().Address()
	payload := transfer.NewFungibleTokenPacketData("factory/alice/token", "100", signer.String(), "atone1user", "")
	packet := types.MsgSendPacket{
		SourceClient:     clientID,
		TimeoutTimestamp: uint64(time.Now().Add(time.Hour).Unix()),
		Payloads: []types.Payload{
			{
				SourcePort:      transfer.PortID,
				DestinationPort: transfer.PortID,
				Encoding:        transfer.EncodingProtobuf,
				Value:           payload.ProtoMarshal(),
				Version:         transfer.V1,
			},
		},
	}
	testing.SetOriginCaller(signer)

	core.SendPacket(cross(cur), packet)
}

// Error:
// send packet failed for payload #0 app "transfer": base denomination factory/alice/token cannot contain slashes for IBC v2 packet
