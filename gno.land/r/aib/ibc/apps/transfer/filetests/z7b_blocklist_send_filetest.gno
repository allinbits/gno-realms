// PKGPATH: gno.land/r/aib/main
package main

import (
	"encoding/hex"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
)

// OnSendPacket rejects a blocked sender, whatever the asset, before any escrow
// or burn logic runs; the whole SendPacket fails.
func main(cur realm) {
	var (
		chainID        = "chain-id-2"
		trustedHeight  = types.NewHeight(2, 2)
		clientState    = tmtesting.NewClientState(chainID, trustedHeight)
		apphash, _     = hex.DecodeString("0eadf50c7992d8e1366b8ea63ab7d1346de4762c3d449764ef7dc404ba48381f")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	clientID := core.CreateClient(cross(cur), clientState, consensusState)
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-42")

	// The sender is the signing EOA (OriginCaller), also made admin here.
	sender := cur.Previous().Address()
	transfer.AddAuthorityMember(cross(cur), cur.Address())
	transfer.BlockAddress(cross(cur), sender)

	data := transfer.NewFungibleTokenPacketData("ugnot", "100", sender.String(), "atone1user", "")
	msg := types.MsgSendPacket{
		SourceClient: clientID,
		Payloads: []types.Payload{{
			SourcePort:      transfer.PortID,
			DestinationPort: transfer.PortID,
			Encoding:        transfer.EncodingProtobuf,
			Value:           data.ProtoMarshal(),
			Version:         transfer.V1,
		}},
		TimeoutTimestamp: uint64(time.Now().Add(time.Hour).Unix()),
	}
	core.SendPacket(cross(cur), msg)
}

// Error:
// send packet failed for payload #0 app "transfer": sender g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm is blocked
