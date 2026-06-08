// PKGPATH: gno.land/r/aib/main
package main

// Regression test: a GRC20 send must be rejected when it does not originate
// from transfer.Transfer, even when the owner approved the transfer app.

import (
	"chain"
	"testing"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"

	"gno.land/r/aib/ibc/apps/testing/grc20test"
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

	owner := cur.Previous().Address()
	grc20test.Mint(cross(cur), owner, 1000)

	transferAppAddr := chain.PackageAddress("gno.land/r/aib/ibc/apps/transfer")
	grc20test.Approve(cross(cur), owner, transferAppAddr, 100)

	grc20regKey := "gno.land/r/aib/ibc/apps/testing/grc20test." + grc20test.Slug
	payload := transfer.NewFungibleTokenPacketData(transfer.GRC20Alias(grc20regKey), "100", owner.String(), "atone1user", "")
	packet := types.MsgSendPacket{
		SourceClient:     clientID,
		TimeoutTimestamp: uint64(time.Now().Add(time.Hour).Unix()),
		Payloads: []types.Payload{{
			SourcePort:      transfer.PortID,
			DestinationPort: transfer.PortID,
			Encoding:        transfer.EncodingProtobuf,
			Value:           payload.ProtoMarshal(),
			Version:         transfer.V1,
		}},
	}

	testing.SetOriginCaller(owner)
	core.SendPacket(cross(cur), packet)
}

// Error:
// send packet failed for payload #0 app "transfer": GRC20 packet must be initiated through transfer.Transfer
