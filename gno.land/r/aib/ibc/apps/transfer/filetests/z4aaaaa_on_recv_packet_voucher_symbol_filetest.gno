// PKGPATH: gno.land/r/aib/main
package main

import (
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
	"gno.land/r/nt/grc20reg/v0"
)

const counterpartyID = "07-tendermint-42"

// Receive two vouchers whose IBC hashes share their first 11 hex characters:
// sha256("transfer/07-tendermint-1/usecret5") and
// sha256("transfer/07-tendermint-2/brubrky0") both start with 0893B0E31F1.
// Voucher symbols used to be that prefix, so the voucher minted first took the
// other's grc20reg key and every packet minting the other panicked. Symbols
// are now unique: both vouchers are minted, each under its own key.
func main(cur realm) {
	receiver := testutils.TestAddress("receiver")
	honest := newClient(cur, "07-tendermint-1", "usecret5", receiver.String())
	colliding := newClient(cur, "07-tendermint-2", "brubrky0", receiver.String())

	// The colliding voucher is minted first.
	println("colliding recv:", core.RecvPacket(cross(cur), colliding))
	println("honest recv:", core.RecvPacket(cross(cur), honest))

	for _, d := range []ics20.Denom{
		ics20.NewDenom("brubrky0", ics20.NewHop(transfer.PortID, "07-tendermint-2")),
		ics20.NewDenom("usecret5", ics20.NewHop(transfer.PortID, "07-tendermint-1")),
	} {
		voucher := d.IBCDenom()
		symbol := transfer.VoucherSymbol(voucher)
		token := grc20reg.MustGet(transfer.PkgPath + "." + symbol)
		println(voucher[:15], symbol, token.GetName(), transfer.VoucherBalanceOf(voucher, receiver))
		println("  VoucherDenom round-trips:", transfer.VoucherDenom(symbol) == voucher)
	}
	println("unknown symbol:", transfer.VoucherDenom("IBC3") == "")
}

// newClient creates a client whose counterparty root commits only a packet
// minting 100 base to receiver, and returns the message relaying it.
func newClient(cur realm, clientID, base, receiver string) types.MsgRecvPacket {
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
	return types.MsgRecvPacket{
		Packet: packet,
		ProofCommitment: []ics23.CommitmentProof{
			ics23.CommitmentProof_Exist{Exist: iavl},
			ics23.CommitmentProof_Exist{Exist: multi},
		},
		ProofHeight: types.NewHeight(2, 2),
	}
}

// Output:
// colliding recv: (2 gno.land/p/aib/ibc/types/v0.ResponseResultType)
// honest recv: (2 gno.land/p/aib/ibc/types/v0.ResponseResultType)
// ibc/0893B0E31F1 IBC1 brubrky0 100
//   VoucherDenom round-trips: true
// ibc/0893B0E31F1 IBC2 usecret5 100
//   VoucherDenom round-trips: true
// unknown symbol: true
