// PKGPATH: gno.land/r/aib/main
// SEND: 100ugnot
package main

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"crypto/sha256"
	"testing"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"

	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
)

// OnSendPacket: success
func main() {
	var (
		chainID        = "chain-id-2"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = sha256.Sum256([]byte("apphash"))
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash[:], trustedValset.Hash())
	)
	clientID := core.CreateClient(cross, clientState, consensusState)
	core.RegisterCounterparty(cross, clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-2")

	signer := runtime.CurrentRealm().Address()
	payload := transfer.FungibleTokenPacketData{
		Denom:    "ugnot",
		Amount:   "100",
		Sender:   signer.String(),
		Receiver: "atone1user",
	}
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
	banker := banker.NewBanker(banker.BankerTypeOriginSend)
	testing.SetOriginCaller(signer)
	transferAppAddr := chain.PackageAddress("gno.land/r/aib/ibc/apps/transfer")
	println("signer balance before SendPacket:", banker.GetCoins(signer))
	println("transferAppAddr balance before SendPacket:", banker.GetCoins(transferAppAddr))

	core.SendPacket(cross, banker, packet)

	println("\nsigner balance after SendPacket:", banker.GetCoins(signer))
	println("transferAppAddr balance after SendPacket:", banker.GetCoins(transferAppAddr))
}

// Output:
// signer balance before SendPacket: 100ugnot
// transferAppAddr balance before SendPacket:
//
// signer balance after SendPacket:
// transferAppAddr balance after SendPacket: 100ugnot

// Events:
// [
//   {
//     "type": "create_client",
//     "attrs": [
//       {
//         "key": "client_id",
//         "value": "07-tendermint-1"
//       },
//       {
//         "key": "client_type",
//         "value": "07-tendermint"
//       },
//       {
//         "key": "consensus_heights",
//         "value": "2/2"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "send_packet",
//     "attrs": [
//       {
//         "key": "packet_source_client",
//         "value": "07-tendermint-1"
//       },
//       {
//         "key": "packet_dest_client",
//         "value": "07-tendermint-2"
//       },
//       {
//         "key": "packet_sequence",
//         "value": "1"
//       },
//       {
//         "key": "packet_timeout_timestamp",
//         "value": "1234571490"
//       },
//       {
//         "key": "encoded_packet_hex",
//         "value": "0801120f30372d74656e6465726d696e742d311a0f30372d74656e6465726d696e742d3220e2a1d8cc042a790a087472616e7366657212087472616e736665721a0769637332302d3122166170706c69636174696f6e2f782d70726f746f6275662a420a0575676e6f7412033130301a286731676a73386e6664726435357a33787539676a6361746e6a3239766b7775797834666671786439220a61746f6e653175736572"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "ibc_transfer",
//     "attrs": [
//       {
//         "key": "sender",
//         "value": "g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9"
//       },
//       {
//         "key": "receiver",
//         "value": "atone1user"
//       },
//       {
//         "key": "denom",
//         "value": "ugnot"
//       },
//       {
//         "key": "amount",
//         "value": "100"
//       },
//       {
//         "key": "memo",
//         "value": ""
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/apps/transfer"
//   }
// ]
