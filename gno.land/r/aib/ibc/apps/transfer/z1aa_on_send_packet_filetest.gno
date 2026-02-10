// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain/banker"
	"chain/runtime"
	"testing"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"

	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
)

// OnSendPacket: success w/ IBC token
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

	signer := runtime.CurrentRealm().Address()

	// Pre-mint GRC20 voucher tokens for the signer
	voucherDenom := "ibc/F9A67CB19B2CAD2ADEC20AD475BE86DF851DEC2B6F6CABC9B7B781BD9131D18F"
	transfer.MintVoucherForTesting(cross, "transfer/"+clientID+"/uatone", signer, 100)

	payload := transfer.FungibleTokenPacketData{
		Denom:    "transfer/" + clientID + "/uatone", // expect transfer/07-tendermint-1/uatone
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
	println("signer GRC20 balance before SendPacket:", transfer.GRC20BalanceOf(voucherDenom, signer))

	core.SendPacket(cross, banker, packet)

	println("\nsigner GRC20 balance after SendPacket:", transfer.GRC20BalanceOf(voucherDenom, signer))
}

// Output:
// signer GRC20 balance before SendPacket: 100
//
// signer GRC20 balance after SendPacket: 0

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
//     "type": "register",
//     "attrs": [
//       {
//         "key": "pkgpath",
//         "value": "gno.land/r/aib/ibc/apps/transfer"
//       },
//       {
//         "key": "slug",
//         "value": "ibc/F9A67CB19B2CAD2ADEC20AD475BE86DF851DEC2B6F6CABC9B7B781BD9131D18F"
//       }
//     ],
//     "pkg_path": "gno.land/r/demo/defi/grc20reg"
//   },
//   {
//     "type": "Transfer",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/aib/ibc/apps/transfer.ibc/F9A67CB19B2CAD2ADEC20AD475BE86DF851DEC2B6F6CABC9B7B781BD9131D18F"
//       },
//       {
//         "key": "from",
//         "value": ""
//       },
//       {
//         "key": "to",
//         "value": "g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9"
//       },
//       {
//         "key": "value",
//         "value": "100"
//       }
//     ],
//     "pkg_path": "gno.land/p/demo/tokens/grc20"
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
//         "value": "0801120f30372d74656e6465726d696e742d311a0f30372d74656e6465726d696e742d3220e2a1d8cc042a93010a087472616e7366657212087472616e736665721a0769637332302d3122166170706c69636174696f6e2f782d70726f746f6275662a5c0a1f7472616e736665722f30372d74656e6465726d696e742d312f7561746f6e6512033130301a286731676a73386e6664726435357a33787539676a6361746e6a3239766b7775797834666671786439220a61746f6e653175736572"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "Transfer",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/aib/ibc/apps/transfer.ibc/F9A67CB19B2CAD2ADEC20AD475BE86DF851DEC2B6F6CABC9B7B781BD9131D18F"
//       },
//       {
//         "key": "from",
//         "value": "g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9"
//       },
//       {
//         "key": "to",
//         "value": ""
//       },
//       {
//         "key": "value",
//         "value": "100"
//       }
//     ],
//     "pkg_path": "gno.land/p/demo/tokens/grc20"
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
//         "value": "transfer/07-tendermint-1/uatone"
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
