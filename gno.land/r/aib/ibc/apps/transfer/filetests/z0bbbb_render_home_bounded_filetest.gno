// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"
	"strings"
	"testing"
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

const (
	n              = 101
	counterpartyID = "07-tendermint-42"
)

// Render home with more clients, vouchers and escrowing clients than it
// lists. Clients are never removed and, while the relayer whitelist is empty,
// anyone may create one, then mint vouchers and escrow through it: the home
// page and total_escrow list the first 100 entries and keep the counts exact.
func main(cur realm) {
	receiver := testutils.TestAddress("receiver")
	// Each client tracks its own counterparty whose root commits one packet
	// minting a distinct voucher.
	for i := 1; i <= n; i++ {
		clientID := ufmt.Sprintf("07-tendermint-%d", i)
		packet := newPacket(clientID, ufmt.Sprintf("d%03d", i), receiver.String())
		proof, root := singleLeafProof(packet)
		clientState := tmtesting.NewClientState("chain-id-2", types.NewHeight(2, 2))
		consensusState := tmtesting.GenConsensusState(time.Now(), root, tmtesting.GenValset().Hash())
		if id := core.CreateClient(cross(cur), clientState, consensusState); id != clientID {
			panic("unexpected client id " + id)
		}
		core.RegisterCounterparty(cross(cur), clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, counterpartyID)
		res := core.RecvPacket(cross(cur), types.MsgRecvPacket{
			Packet:          packet,
			ProofCommitment: proof,
			ProofHeight:     types.NewHeight(2, 2),
		})
		if res != types.RESPONSE_SUCCESS {
			panic(ufmt.Sprintf("recv on %s: %v", clientID, res))
		}
	}
	// A user escrows 1ugnot through every client.
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("sender")))
	for i := 1; i <= n; i++ {
		testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1)))
		transfer.Transfer(cross(cur), ufmt.Sprintf("07-tendermint-%d", i), "atone1user", "ugnot", 1, uint64(time.Now().Add(time.Hour).Unix()), "")
	}
	testing.SetOriginSend(nil)

	var section string
	rows := map[string]int{}
	for _, line := range strings.Split(transfer.Render(""), "\n") {
		switch {
		case strings.HasPrefix(line, "## "):
			section = line
			println(line)
		case strings.HasPrefix(line, "First "):
			println(line)
		case strings.HasPrefix(line, "- [send via"), strings.HasPrefix(line, "| [`"):
			rows[section]++
		}
	}
	for _, s := range []string{"## Transfer", "## Vouchers (101)", "## Escrow (1)"} {
		println(s, "rows:", rows[s])
	}

	escrow := transfer.Render("total_escrow/ugnot")
	println("total_escrow/ugnot amount 101:", strings.HasPrefix(escrow, `{"denom":"ugnot","amount":101,`))
	println("total_escrow/ugnot clients listed:", strings.Count(escrow, `"client":`))
}

func newPacket(clientID, baseDenom, receiver string) types.Packet {
	data := ics20.NewFungibleTokenPacketData(baseDenom, "1", "atone1user", receiver, "")
	return types.Packet{
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
// ## Transfer
// First 100 of 101 clients; see [`clients`](/r/aib/ibc/core:clients) (`?page`, `?limit`) for all of them.
// ## Vouchers (101)
// First 100 of 101 vouchers; see [`vouchers`](/r/aib/ibc/apps/transfer:vouchers) (`?page`, `?limit`) for all of them.
// ## Escrow (1)
// ## JSON endpoints
// ## Transfer rows: 100
// ## Vouchers (101) rows: 100
// ## Escrow (1) rows: 1
// total_escrow/ugnot amount 101: true
// total_escrow/ugnot clients listed: 100
