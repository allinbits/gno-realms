// PKGPATH: gno.land/r/aib/main
package main

import (
	"strconv"
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

const counterpartyID = "07-tendermint-42"

// Render vouchers whose trace is long: a counterparty can send a denom
// through dozens of hops, so 100 Home rows or 100 denoms items with full
// paths could exceed the query gas limit. Home cuts the base and path cells,
// and the denoms route returns at most 20 denoms per page.
func main(cur realm) {
	receiver := testutils.TestAddress("receiver").String()
	// 65 hops, a 1630-byte path once the receiving hop is added.
	long := strings.Repeat("transfer/07-tendermint-9/", 64) + "uatom"
	recv(cur, "07-tendermint-1", long, receiver)
	for i := 2; i <= 21; i++ {
		recv(cur, "07-tendermint-"+strconv.Itoa(i), "u"+strconv.Itoa(i), receiver)
	}

	voucher := ics20.ExtractDenomFromPath("transfer/07-tendermint-1/" + long).IBCDenom()
	for _, line := range strings.Split(transfer.Render(""), "\n") {
		if strings.Contains(line, "denoms/"+voucher+")") {
			cells := strings.Split(line, " | ")
			println("home base cell:", cells[1])
			println("home path cell:", len(cells[2]), "bytes, ends with", cells[2][len(cells[2])-8:])
		}
	}
	for _, page := range []string{"1", "2"} {
		out := transfer.Render("denoms?limit=100&page=" + page)
		println("denoms page", page, "items:", strings.Count(out, `"base":`), out[strings.LastIndex(out, `"page"`):])
	}
}

// recv relays a packet minting 100 base to receiver through a new client,
// expected to get clientID, whose counterparty root commits only that
// packet, and returns the client.
func recv(cur realm, clientID, base, receiver string) string {
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
// home base cell: uatom
// home path cell: 106 bytes, ends with ermin…
// denoms page 1 items: 20 "page":1,"total":2}
// denoms page 2 items: 1 "page":2,"total":2}
