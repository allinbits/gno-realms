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
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

const (
	counterpartyID = "07-tendermint-42"
	// The base denomination is the counterparty's: it is received as is, and
	// becomes the voucher's GRC20 name.
	baseDenom = "[send](&#47;r&#47;evil$help&func=VoucherSend&to=a1)"
)

// Render the JSON routes showing a voucher whose base denomination carries
// markdown. The packet is received as for any denomination; the routes
// escape markdown in their string values (gnoweb renders them as markdown),
// and the values decode unchanged.
func main(cur realm) {
	receiver := testutils.TestAddress("receiver")
	clientID := recv(cur, baseDenom, receiver.String())
	voucher := ics20.NewDenom(baseDenom, ics20.NewHop(transfer.PortID, clientID)).IBCDenom()
	println("voucher balance:", transfer.VoucherBalanceOf(voucher, receiver))

	hash := strings.TrimPrefix(voucher, "ibc/")
	for _, path := range []string{
		"denoms",
		"denoms/ibc/" + hash,
		"vouchers",
		"voucher/ibc/" + hash,
		"denoms/ibc/[x](&#47;r&#47;evil)",
	} {
		out := transfer.Render(path)
		raw := strings.Contains(out, "[send]") || strings.Contains(out, "[x]") || strings.Contains(out, "&#47;")
		println(path, "-> raw markdown:", raw)
		println(out)
	}
}

// recv relays a packet minting 100 base to receiver through a new client
// whose counterparty root commits only that packet, and returns the client.
func recv(cur realm, base, receiver string) string {
	clientID := "07-tendermint-1"
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
	specs := ics23.IavlSpec()
	iavl := &ics23.ExistenceProof{
		Key:   append([]byte("prefix2"), host.PacketCommitmentKey(counterpartyID, 1)...),
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
	clientState := tmtesting.NewClientState("chain-id-2", types.NewHeight(2, 2))
	consensusState := tmtesting.GenConsensusState(time.Now(), root, tmtesting.GenValset().Hash())
	if id := core.CreateClient(cross(cur), clientState, consensusState); id != clientID {
		panic("unexpected client id " + id)
	}
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, counterpartyID)
	core.RecvPacket(cross(cur), types.MsgRecvPacket{
		Packet: packet,
		ProofCommitment: []ics23.CommitmentProof{
			ics23.CommitmentProof_Exist{Exist: iavl},
			ics23.CommitmentProof_Exist{Exist: multi},
		},
		ProofHeight: types.NewHeight(2, 2),
	})
	return clientID
}

// Output:
// voucher balance: 100
// denoms -> raw markdown: false
// {"items":[{"base":"\u005bsend\u005d\u0028\u0026#47;r\u0026#47;evil$help\u0026func=VoucherSend\u0026to=a1\u0029","path":"transfer/07-tendermint-1/\u005bsend\u005d\u0028\u0026#47;r\u0026#47;evil$help\u0026func=VoucherSend\u0026to=a1\u0029","denom":"ibc/5651E44595E4B57D8432BFDEF9C12582F7BFE84A8797DC348CC368C2796427B7"}],"page":1,"total":1}
// denoms/ibc/5651E44595E4B57D8432BFDEF9C12582F7BFE84A8797DC348CC368C2796427B7 -> raw markdown: false
// {"base":"\u005bsend\u005d\u0028\u0026#47;r\u0026#47;evil$help\u0026func=VoucherSend\u0026to=a1\u0029","path":"transfer/07-tendermint-1/\u005bsend\u005d\u0028\u0026#47;r\u0026#47;evil$help\u0026func=VoucherSend\u0026to=a1\u0029","denom":"ibc/5651E44595E4B57D8432BFDEF9C12582F7BFE84A8797DC348CC368C2796427B7"}
// vouchers -> raw markdown: false
// {"items":[{"denom":"ibc/5651E44595E4B57D8432BFDEF9C12582F7BFE84A8797DC348CC368C2796427B7","grc20reg_key":"gno.land/r/aib/ibc/apps/transfer.5651E44595E","name":"\u005bsend\u005d\u0028\u0026#47;r\u0026#47;evil$help\u0026func=VoucherSend\u0026to=a1\u0029","symbol":"5651E44595E","decimals":0,"total_supply":100}],"page":1,"total":1}
// voucher/ibc/5651E44595E4B57D8432BFDEF9C12582F7BFE84A8797DC348CC368C2796427B7 -> raw markdown: false
// {"denom":"ibc/5651E44595E4B57D8432BFDEF9C12582F7BFE84A8797DC348CC368C2796427B7","grc20reg_key":"gno.land/r/aib/ibc/apps/transfer.5651E44595E","name":"\u005bsend\u005d\u0028\u0026#47;r\u0026#47;evil$help\u0026func=VoucherSend\u0026to=a1\u0029","symbol":"5651E44595E","decimals":0,"total_supply":100}
// denoms/ibc/[x](&#47;r&#47;evil) -> raw markdown: false
// {"error":"denom ibc/\u005bx\u005d\u0028\u0026#47;r\u0026#47;evil\u0029 not found"}
