// PKGPATH: gno.land/r/aib/main
package main

import (
	"strings"
	"time"

	"gno.land/p/aib/ibc/host/v0"
	"gno.land/p/aib/ibc/ics20/v0"
	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/aib/ics23/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

const counterpartyID = "07-tendermint-42"

// OnRecvPacket refuses a voucher base denomination that is not a plain
// denomination: it is stored and shown by the render routes, and becomes the
// voucher's GRC20 name. The render routes do not echo URL input either.
func main(cur realm) {
	receiver := testutils.TestAddress("receiver")
	for i, base := range []string{
		"[send](&#47;r&#47;evil$help&func=VoucherSend&to=a1)",
		strings.Repeat("a", 65),
		"uphoton",
	} {
		clientID := ufmt.Sprintf("07-tendermint-%d", i+1)
		recv(cur, clientID, base, receiver.String())
		voucher := ics20.NewDenom(base, ics20.NewHop(transfer.PortID, clientID)).IBCDenom()
		println(clientID, "voucher balance:", transfer.VoucherBalanceOf(voucher, receiver))
	}
	println("denoms:", transfer.Render("denoms"))

	voucher := ics20.NewDenom("uphoton", ics20.NewHop(transfer.PortID, "07-tendermint-3")).IBCDenom()
	for _, path := range []string{
		"denoms/ibc/[x](&#47;r&#47;evil)",
		"voucher/ibc/[x](&#47;r&#47;evil)",
		"voucher/ibc/[x](&#47;r&#47;evil)/balance/" + receiver.String(),
		strings.Replace(voucher, "ibc/", "voucher/ibc/", 1) + "/balance/[x](&#47;r&#47;evil)",
		"total_escrow/[x](&#47;r&#47;evil)",
	} {
		println(transfer.Render(path))
	}
	println(transfer.Render(strings.Replace(voucher, "ibc/", "voucher/ibc/", 1) + "/balance/" + strings.ToUpper(receiver.String())))
}

// recv relays a packet minting 100 base to receiver through a new client whose
// counterparty root commits only that packet. The acknowledgement (success or
// error) is in the events.
func recv(cur realm, clientID, base, receiver string) {
	data := ics20.NewFungibleTokenPacketData(base, "100", "atone1user", receiver, "")
	packet := types.Packet{
		Sequence:          1,
		SourceClient:      counterpartyID,
		DestinationClient: clientID,
		TimeoutTimestamp:  uint64(time.Now().Add(time.Hour).Unix()),
		Payloads: []types.Payload{{
			SourcePort:      transfer.PortID,
			DestinationPort: transfer.PortID,
			Encoding:        transfer.EncodingProtobuf,
			Value:           data.ProtoMarshal(),
			Version:         transfer.V1,
		}},
	}
	proof, root := singleLeafProof(packet)
	clientState := tmtesting.NewClientState("chain-id-2", types.NewHeight(2, 2))
	consensusState := tmtesting.GenConsensusState(time.Now(), root, tmtesting.GenValset().Hash())
	if id := core.CreateClient(cross(cur), clientState, consensusState); id != clientID {
		panic("unexpected client id " + id)
	}
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, counterpartyID)
	core.RecvPacket(cross(cur), types.MsgRecvPacket{
		Packet:          packet,
		ProofCommitment: proof,
		ProofHeight:     types.NewHeight(2, 2),
	})
}

// singleLeafProof returns the iavl + rootmulti proof of packet's commitment in
// a store holding only that commitment, and the resulting app hash.
func singleLeafProof(packet types.Packet) ([]ics23.CommitmentProof, []byte) {
	specs := ics23.IavlSpec()
	key := append([]byte("prefix2"), host.PacketCommitmentKey(packet.SourceClient, packet.Sequence)...)
	iavl := &ics23.ExistenceProof{
		Key:   key,
		Value: types.CommitPacket(packet),
		Leaf: &ics23.LeafOp{
			Hash:         specs.LeafSpec.Hash,
			PrehashKey:   specs.LeafSpec.PrehashKey,
			PrehashValue: specs.LeafSpec.PrehashValue,
			Length:       specs.LeafSpec.Length,
			Prefix:       []byte("\x00\x02\x02"),
		},
	}
	storeRoot, err := iavl.Calculate()
	if err != nil {
		panic(err)
	}
	multi := &ics23.ExistenceProof{
		Key:   []byte("iavlStoreKey"),
		Value: storeRoot,
		Leaf: &ics23.LeafOp{
			Hash:         specs.LeafSpec.Hash,
			PrehashKey:   specs.LeafSpec.PrehashKey,
			PrehashValue: specs.LeafSpec.PrehashValue,
			Length:       specs.LeafSpec.Length,
			Prefix:       []byte("\x00"),
		},
	}
	root, err := multi.Calculate()
	if err != nil {
		panic(err)
	}
	return []ics23.CommitmentProof{
		ics23.CommitmentProof_Exist{Exist: iavl},
		ics23.CommitmentProof_Exist{Exist: multi},
	}, root
}

// Output:
// 07-tendermint-1 voucher balance: 0
// 07-tendermint-2 voucher balance: 0
// 07-tendermint-3 voucher balance: 100
// denoms: {"items":[{"base":"uphoton","path":"transfer/07-tendermint-3/uphoton","denom":"ibc/0EBF460CFA40EAA8B8AC9B462B2F3685F5FC94871A4185AD827B58AAFB32BC5D"}],"page":1,"total":1}
// {"error":"denom not found"}
// {"error":"voucher token not found"}
// {"error":"voucher token not found"}
// {"error":"invalid address"}
// {"error":"invalid denom"}
// {"denom":"ibc/0EBF460CFA40EAA8B8AC9B462B2F3685F5FC94871A4185AD827B58AAFB32BC5D","address":"g1wfjkxetfwejhyh6lta047h6lta047h6llm82yl","balance":100}

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
//         "value": "0801121030372d74656e6465726d696e742d34321a0f30372d74656e6465726d696e742d3120e2a1d8cc042aa7010a087472616e7366657212087472616e736665721a0769637332302d3122166170706c69636174696f6e2f782d70726f746f6275662a700a335b73656e645d28262334373b72262334373b6576696c2468656c702666756e633d566f756368657253656e6426746f3d61312912033130301a0a61746f6e6531757365722228673177666a6b7865746677656a687968366c746130343768366c746130343768366c6c6d3832796c"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
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
//         "value": "g1wfjkxetfwejhyh6lta047h6lta047h6llm82yl"
//       },
//       {
//         "key": "denom",
//         "value": "transfer/07-tendermint-1/[send](\u0026#47;r\u0026#47;evil$help\u0026func=VoucherSend\u0026to=a1)"
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
//         "value": "false"
//       },
//       {
//         "key": "error",
//         "value": "base denomination must start with a letter and contain only letters, digits, ':', '.', '_' or '-'"
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
//         "value": "0801121030372d74656e6465726d696e742d34321a0f30372d74656e6465726d696e742d3120e2a1d8cc042aa7010a087472616e7366657212087472616e736665721a0769637332302d3122166170706c69636174696f6e2f782d70726f746f6275662a700a335b73656e645d28262334373b72262334373b6576696c2468656c702666756e633d566f756368657253656e6426746f3d61312912033130301a0a61746f6e6531757365722228673177666a6b7865746677656a687968366c746130343768366c746130343768366c6c6d3832796c"
//       },
//       {
//         "key": "encoded_acknowledgement_hex",
//         "value": "0a204774d4a575993f963b1c06573736617a457abef8589178db8d10c94b4ab511ab"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "create_client",
//     "attrs": [
//       {
//         "key": "client_id",
//         "value": "07-tendermint-2"
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
//         "value": "0801121030372d74656e6465726d696e742d34321a0f30372d74656e6465726d696e742d3220e2a1d8cc042ab5010a087472616e7366657212087472616e736665721a0769637332302d3122166170706c69636174696f6e2f782d70726f746f6275662a7e0a41616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616112033130301a0a61746f6e6531757365722228673177666a6b7865746677656a687968366c746130343768366c746130343768366c6c6d3832796c"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
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
//         "value": "g1wfjkxetfwejhyh6lta047h6lta047h6llm82yl"
//       },
//       {
//         "key": "denom",
//         "value": "transfer/07-tendermint-2/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
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
//         "value": "false"
//       },
//       {
//         "key": "error",
//         "value": "base denomination is longer than 64 bytes"
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
//         "value": "0801121030372d74656e6465726d696e742d34321a0f30372d74656e6465726d696e742d3220e2a1d8cc042ab5010a087472616e7366657212087472616e736665721a0769637332302d3122166170706c69636174696f6e2f782d70726f746f6275662a7e0a41616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616112033130301a0a61746f6e6531757365722228673177666a6b7865746677656a687968366c746130343768366c746130343768366c6c6d3832796c"
//       },
//       {
//         "key": "encoded_acknowledgement_hex",
//         "value": "0a204774d4a575993f963b1c06573736617a457abef8589178db8d10c94b4ab511ab"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "create_client",
//     "attrs": [
//       {
//         "key": "client_id",
//         "value": "07-tendermint-3"
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
//         "value": "07-tendermint-3"
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
//         "value": "0801121030372d74656e6465726d696e742d34321a0f30372d74656e6465726d696e742d3320e2a1d8cc042a7b0a087472616e7366657212087472616e736665721a0769637332302d3122166170706c69636174696f6e2f782d70726f746f6275662a440a077570686f746f6e12033130301a0a61746f6e6531757365722228673177666a6b7865746677656a687968366c746130343768366c746130343768366c6c6d3832796c"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "denomination",
//     "attrs": [
//       {
//         "key": "denom_hash",
//         "value": "0EBF460CFA40EAA8B8AC9B462B2F3685F5FC94871A4185AD827B58AAFB32BC5D"
//       },
//       {
//         "key": "denom",
//         "value": "{\"base\":\"uphoton\",\"path\":\"transfer/07-tendermint-3/uphoton\",\"denom\":\"ibc/0EBF460CFA40EAA8B8AC9B462B2F3685F5FC94871A4185AD827B58AAFB32BC5D\"}"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/apps/transfer"
//   },
//   {
//     "type": "NewToken",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/aib/ibc/apps/transfer.0EBF460CFA4.0000001"
//       },
//       {
//         "key": "name",
//         "value": "uphoton"
//       },
//       {
//         "key": "symbol",
//         "value": "0EBF460CFA4"
//       },
//       {
//         "key": "decimals",
//         "value": "0"
//       }
//     ],
//     "pkg_path": "gno.land/p/nt/grc20/v0"
//   },
//   {
//     "type": "register",
//     "attrs": [
//       {
//         "key": "token_path",
//         "value": "gno.land/r/aib/ibc/apps/transfer.0EBF460CFA4"
//       },
//       {
//         "key": "pkgpath",
//         "value": "gno.land/r/aib/ibc/apps/transfer"
//       },
//       {
//         "key": "slug",
//         "value": "0EBF460CFA40EAA8B8AC9B462B2F3685F5FC94871A4185AD827B58AAFB32BC5D"
//       },
//       {
//         "key": "symbol",
//         "value": "0EBF460CFA4"
//       }
//     ],
//     "pkg_path": "gno.land/r/nt/grc20reg/v0"
//   },
//   {
//     "type": "Transfer",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/aib/ibc/apps/transfer.0EBF460CFA4.0000001"
//       },
//       {
//         "key": "from",
//         "value": ""
//       },
//       {
//         "key": "to",
//         "value": "g1wfjkxetfwejhyh6lta047h6lta047h6llm82yl"
//       },
//       {
//         "key": "value",
//         "value": "100"
//       }
//     ],
//     "pkg_path": "gno.land/p/nt/grc20/v0"
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
//         "value": "g1wfjkxetfwejhyh6lta047h6lta047h6llm82yl"
//       },
//       {
//         "key": "denom",
//         "value": "transfer/07-tendermint-3/uphoton"
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
//         "value": "07-tendermint-3"
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
//         "value": "0801121030372d74656e6465726d696e742d34321a0f30372d74656e6465726d696e742d3320e2a1d8cc042a7b0a087472616e7366657212087472616e736665721a0769637332302d3122166170706c69636174696f6e2f782d70726f746f6275662a440a077570686f746f6e12033130301a0a61746f6e6531757365722228673177666a6b7865746677656a687968366c746130343768366c746130343768366c6c6d3832796c"
//       },
//       {
//         "key": "encoded_acknowledgement_hex",
//         "value": "0a117b22726573756c74223a2241513d3d227d"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   }
// ]
