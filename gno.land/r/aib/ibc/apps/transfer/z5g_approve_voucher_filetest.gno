package main

import (
	"chain/runtime"
	"encoding/hex"
	stdtesting "testing"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	"gno.land/p/nt/testutils/v0"
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
	"gno.land/r/demo/defi/grc20reg"
)

// ApproveVoucher: success for IBC voucher token via MsgCall helper.
func main() {
	var (
		chainID        = "chain-id-2"
		trustedHeight  = types.NewHeight(2, 2)
		clientState    = tmtesting.NewClientState(chainID, trustedHeight)
		apphash, _     = hex.DecodeString("0eadf50c7992d8e1366b8ea63ab7d1346de4762c3d449764ef7dc404ba48381f")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
		counterpartyID = "07-tendermint-42"
	)
	clientID := core.CreateClient(cross, clientState, consensusState)
	core.RegisterCounterparty(cross, clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, counterpartyID)

	owner := runtime.OriginCaller()
	spender := testutils.TestAddress("spender")
	recipient := testutils.TestAddress("recipient")

	mintVoucher(clientID, counterpartyID, trustedHeight, owner)

	voucherDenom := transfer.NewDenom("uphoton", transfer.NewHop(transfer.PortID, clientID)).IBCDenom()
	token := grc20reg.MustGet("gno.land/r/aib/ibc/apps/transfer." + voucherDenom[len("ibc/"):])

	println("allowance before ApproveVoucher:", token.Allowance(owner, spender))

	transfer.ApproveVoucher(cross, voucherDenom, spender, 40)

	println("allowance after ApproveVoucher:", token.Allowance(owner, spender))

	stdtesting.SetRealm(stdtesting.NewUserRealm(spender))
	appstesting.TransferApprovedGRC20(cross, "gno.land/r/aib/ibc/apps/transfer."+voucherDenom[len("ibc/"):], owner, recipient, 25)

	println("allowance after TransferFrom:", token.Allowance(owner, spender))
	println("owner voucher balance after TransferFrom:", transfer.VoucherBalanceOf(voucherDenom, owner))
	println("recipient voucher balance after TransferFrom:", transfer.VoucherBalanceOf(voucherDenom, recipient))
}

func mintVoucher(clientID, counterpartyID string, trustedHeight types.Height, receiver address) {
	payload := transfer.FungibleTokenPacketData{
		Denom:    "uphoton",
		Amount:   "100",
		Sender:   "atone1user",
		Receiver: receiver.String(),
	}
	payloadBz := payload.ProtoMarshal()

	specs := ics23.IavlSpec()
	proof := []ics23.CommitmentProof{
		ics23.CommitmentProof_Exist{
			Exist: &ics23.ExistenceProof{
				Key:   []byte("\x70\x72\x65\x66\x69\x78\x32\x30\x37\x2d\x74\x65\x6e\x64\x65\x72\x6d\x69\x6e\x74\x2d\x34\x32\x01\x00\x00\x00\x00\x00\x00\x00\x01"),
				Value: []byte("\x12\x6c\xcc\xff\x00\xd6\xb9\x73\x09\xb3\x8b\x1b\xec\x0f\xe2\xef\xc9\x54\xe5\xac\x1d\x90\x47\x36\xd0\x32\xbc\xc0\xb1\x66\xc4\x8f"),
				Leaf: &ics23.LeafOp{
					Hash:         specs.LeafSpec.Hash,
					PrehashKey:   specs.LeafSpec.PrehashKey,
					PrehashValue: specs.LeafSpec.PrehashValue,
					Length:       specs.LeafSpec.Length,
					Prefix:       []byte("\x00\x02\x02"),
				},
				Path: []*ics23.InnerOp{
					{
						Hash:   specs.InnerSpec.Hash,
						Prefix: []byte("\x02\x04\x02\x20\x35\xf8\xea\x80\x53\x90\xe0\x84\x85\x4f\x39\x9b\x42\xcc\xde\xae\xa3\x3a\x1d\xed\xc1\x15\x63\x8a\xc4\x8d\x06\x00\x63\x7d\xba\x1f\x20"),
						Suffix: []byte(""),
					},
					{
						Hash:   specs.InnerSpec.Hash,
						Prefix: []byte("\x04\x08\x02\x20"),
						Suffix: []byte("\x20\x79\x8e\x2c\xaa\x96\xfd\xfb\xa3\x76\xdd\xeb\x47\x99\x99\x54\xd2\xf4\x7e\x65\x16\x22\x64\xb0\x53\x6a\xb5\xdf\xf7\xfc\x0a\x2e\x07"),
					},
					{
						Hash:   specs.InnerSpec.Hash,
						Prefix: []byte("\x06\x0c\x02\x20\x9a\xf3\x7d\xd5\x95\xa0\x19\x08\x03\xb5\xe0\x5a\xae\xf4\x2a\xe3\xfa\xd4\x99\xe4\xfb\xe3\x7f\x7c\xd3\x1c\xad\xff\x22\xa9\xee\x74\x20"),
						Suffix: []byte(""),
					},
				},
			},
		},
		ics23.CommitmentProof_Exist{
			Exist: &ics23.ExistenceProof{
				Key:   []byte("\x69\x61\x76\x6c\x53\x74\x6f\x72\x65\x4b\x65\x79"),
				Value: []byte("\x4f\xa3\xdf\x13\x8a\x86\x32\xc8\x3f\xd8\x84\x92\x00\xe0\xf1\xd8\x8a\x05\x36\x85\x32\x15\x1b\x45\x67\xf6\x86\xec\xf1\xfb\x9f\x45"),
				Leaf: &ics23.LeafOp{
					Hash:         specs.LeafSpec.Hash,
					PrehashKey:   specs.LeafSpec.PrehashKey,
					PrehashValue: specs.LeafSpec.PrehashValue,
					Length:       specs.LeafSpec.Length,
					Prefix:       []byte("\x00"),
				},
				Path: []*ics23.InnerOp{},
			},
		},
	}

	recvPacket := types.MsgRecvPacket{
		Packet: types.Packet{
			Sequence:          1,
			SourceClient:      counterpartyID,
			DestinationClient: clientID,
			TimeoutTimestamp:  uint64(time.Now().Add(time.Hour).Unix()),
			Payloads: []types.Payload{{
				SourcePort:      transfer.PortID,
				DestinationPort: transfer.PortID,
				Encoding:        transfer.EncodingProtobuf,
				Value:           payloadBz,
				Version:         transfer.V1,
			}},
		},
		ProofCommitment: proof,
		ProofHeight:     trustedHeight,
	}

	core.RecvPacket(cross, recvPacket)
}

// Output:
// allowance before ApproveVoucher: 0
// allowance after ApproveVoucher: 40
// allowance after TransferFrom: 15
// owner voucher balance after TransferFrom: 75
// recipient voucher balance after TransferFrom: 25

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
//     "type": "recv_packet",
//     "attrs": [
//       {
//         "key": "packet_source_client",
//         "value": "07-tendermint-42"
//       },
//       {
//         "key": "packet_dest_client",
//         "value": "07-tendermint-1"
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
//         "value": "0801121030372d74656e6465726d696e742d34321a0f30372d74656e6465726d696e742d3120e2a1d8cc042a7b0a087472616e7366657212087472616e736665721a0769637332302d3122166170706c69636174696f6e2f782d70726f746f6275662a440a077570686f746f6e12033130301a0a61746f6e6531757365722228673177796d75343764726872306b7571323039386d3739326c797467746a326e797837377972736d"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "denomination",
//     "attrs": [
//       {
//         "key": "denom_hash",
//         "value": "CAEF9CA8CE6C302D73A831A49E34E59149D3A9AD96CCEBDFBF62F6D5710D92D8"
//       },
//       {
//         "key": "denom",
//         "value": "{\"base\":\"uphoton\",\"path\":\"transfer/07-tendermint-1/uphoton\",\"denom\":\"ibc/CAEF9CA8CE6C302D73A831A49E34E59149D3A9AD96CCEBDFBF62F6D5710D92D8\"}"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/apps/transfer"
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
//         "value": "CAEF9CA8CE6C302D73A831A49E34E59149D3A9AD96CCEBDFBF62F6D5710D92D8"
//       }
//     ],
//     "pkg_path": "gno.land/r/demo/defi/grc20reg"
//   },
//   {
//     "type": "Transfer",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/aib/ibc/apps/transfer.ibc/CAEF9CA8CE6C302D73A831A49E34E59149D3A9AD96CCEBDFBF62F6D5710D92D8"
//       },
//       {
//         "key": "from",
//         "value": ""
//       },
//       {
//         "key": "to",
//         "value": "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm"
//       },
//       {
//         "key": "value",
//         "value": "100"
//       }
//     ],
//     "pkg_path": "gno.land/p/demo/tokens/grc20"
//   },
//   {
//     "type": "fungible_token_packet",
//     "attrs": [
//       {
//         "key": "sender",
//         "value": "atone1user"
//       },
//       {
//         "key": "receiver",
//         "value": "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm"
//       },
//       {
//         "key": "denom",
//         "value": "transfer/07-tendermint-1/uphoton"
//       },
//       {
//         "key": "amount",
//         "value": "100"
//       },
//       {
//         "key": "memo",
//         "value": ""
//       },
//       {
//         "key": "success",
//         "value": "true"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/apps/transfer"
//   },
//   {
//     "type": "write_acknowledgement",
//     "attrs": [
//       {
//         "key": "packet_source_client",
//         "value": "07-tendermint-42"
//       },
//       {
//         "key": "packet_dest_client",
//         "value": "07-tendermint-1"
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
//         "value": "0801121030372d74656e6465726d696e742d34321a0f30372d74656e6465726d696e742d3120e2a1d8cc042a7b0a087472616e7366657212087472616e736665721a0769637332302d3122166170706c69636174696f6e2f782d70726f746f6275662a440a077570686f746f6e12033130301a0a61746f6e6531757365722228673177796d75343764726872306b7571323039386d3739326c797467746a326e797837377972736d"
//       },
//       {
//         "key": "encoded_acknowledgement_hex",
//         "value": "0a117b22726573756c74223a2241513d3d227d"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "Approval",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/aib/ibc/apps/transfer.ibc/CAEF9CA8CE6C302D73A831A49E34E59149D3A9AD96CCEBDFBF62F6D5710D92D8"
//       },
//       {
//         "key": "owner",
//         "value": "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm"
//       },
//       {
//         "key": "spender",
//         "value": "g1wdcx2mnyv4e97h6lta047h6lta047h6l735n06"
//       },
//       {
//         "key": "value",
//         "value": "40"
//       }
//     ],
//     "pkg_path": "gno.land/p/demo/tokens/grc20"
//   },
//   {
//     "type": "Transfer",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/aib/ibc/apps/transfer.ibc/CAEF9CA8CE6C302D73A831A49E34E59149D3A9AD96CCEBDFBF62F6D5710D92D8"
//       },
//       {
//         "key": "from",
//         "value": "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm"
//       },
//       {
//         "key": "to",
//         "value": "g1wfjkx6tsd9jkuazlta047h6lta047h6lu0zqma"
//       },
//       {
//         "key": "value",
//         "value": "25"
//       }
//     ],
//     "pkg_path": "gno.land/p/demo/tokens/grc20"
//   }
// ]
