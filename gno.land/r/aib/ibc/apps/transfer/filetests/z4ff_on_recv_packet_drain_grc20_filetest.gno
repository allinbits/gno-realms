// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"
	"strings"
	"testing"
	"time"

	"gno.land/p/aib/ibc/host"
	"gno.land/p/aib/ibc/lightclient/tendermint"
	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	"gno.land/p/nt/testutils/v0"
	"gno.land/r/aib/ibc/apps/testing/grc20test"
	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
)

// OnRecvPacket: per-client escrow isolation on the GRC20 release path.
//
// GRC20 sibling of z4f. OnRecvPacket branches on isGRC20Alias(coin.Denom) into
// two independently written release helpers -- unescrowNative and
// unescrowGRC20 -- each gated by its own checkEscrowForClient call. z4f covers
// only the native branch, so without this test a regression that dropped or
// swallowed the escrow check in unescrowGRC20 would reintroduce the
// shared-escrow drain for every non-IBC GRC20 token while the whole suite
// stayed green.
//
// Same attack as z4f: the attacker creates their own client (clientB) whose
// consensus root they control, forges a valid ICS-23 proof against that root,
// and submits a "returning token" packet on clientB trying to release GRC20
// tokens that an honest user escrowed under clientA.
func main(cur realm) {
	var (
		// clientA: the honest client the GRC20 escrow was locked under.
		clientAID = "07-tendermint-1"
		// clientB: the attacker-controlled client the malicious packet arrives on.
		clientBID = "07-tendermint-2"
		cpartyA   = "07-tendermint-42"
		cpartyB   = "07-tendermint-99"

		prefix      = [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}
		proofHeight = types.NewHeight(1, 100)

		// grc20reg key (slash form) and the on-the-wire denom (colon form) for
		// the test token. OnSendPacket escrows under the colon form, so the
		// returning packet must carry that same spelling to reach unescrowGRC20.
		denomKey = "gno.land/r/aib/ibc/apps/testing/grc20test." + grc20test.Slug
		alias    = strings.ReplaceAll(denomKey, "/", ":")
	)

	// --- Honest client A: escrow 100 GRC20 under clientA via a real Transfer. ---
	clientAState := tmtesting.NewClientState("honestchain-1", types.NewHeight(1, 50))
	consA := tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("honest-apphash"), tmtesting.GenValset().Hash())
	if core.CreateClient(cross(cur), clientAState, consA) != clientAID {
		panic("clientA id race")
	}
	core.RegisterCounterparty(cross(cur), clientAID, prefix, cpartyA)

	transferAppAddr := chain.PackageAddress("gno.land/r/aib/ibc/apps/transfer")
	sender := cur.Previous().Address()
	grc20test.Mint(cross(cur), sender, 1000)
	grc20test.Approve(cross(cur), sender, transferAppAddr, 100)
	testing.SetRealm(testing.NewUserRealm(sender))
	transfer.Transfer(cross(cur), clientAID, "atone1user", denomKey, 100,
		uint64(time.Now().Add(time.Hour).Unix()), "")

	// --- Attacker client B. ---
	attacker := testutils.TestAddress("attacker")
	// Sign the rest as the attacker, not the honest sender: creating clientB,
	// registering its counterparty and relaying the forged packet must all be
	// reachable by an unprivileged third party for this to be the real attack.
	testing.SetRealm(testing.NewUserRealm(attacker))
	// "returning token" packet: the trace starts with clientB's counterparty, so
	// OnRecvPacket strips it and takes the unescrow branch; the stripped base is
	// a GRC20 alias, so it routes to unescrowGRC20.
	denom := "transfer/" + cpartyB + "/" + alias
	payload := transfer.NewFungibleTokenPacketData(denom, "100", "atone1attacker", attacker.String(), "")
	packet := types.Packet{
		Sequence:          1,
		SourceClient:      cpartyB,
		DestinationClient: clientBID,
		TimeoutTimestamp:  uint64(time.Now().Add(time.Hour).Unix()),
		Payloads: []types.Payload{{
			SourcePort:      transfer.PortID,
			DestinationPort: transfer.PortID,
			Encoding:        transfer.EncodingProtobuf,
			Value:           payload.ProtoMarshal(),
			Version:         transfer.V1,
		}},
	}

	// Build the packet-commitment proof against a root the attacker chooses.
	mpath := types.BuildMerklePath(prefix, host.PacketCommitmentKey(cpartyB, 1))
	iavl, tmspec := ics23.IavlSpec(), ics23.TendermintSpec()
	e0 := &ics23.ExistenceProof{
		Key:   mpath.KeyPath[1],
		Value: types.CommitPacket(packet),
		Leaf: &ics23.LeafOp{
			Hash: iavl.LeafSpec.Hash, PrehashKey: iavl.LeafSpec.PrehashKey,
			PrehashValue: iavl.LeafSpec.PrehashValue, Length: iavl.LeafSpec.Length,
			Prefix: []byte("\x00\x02\x02"),
		},
	}
	sr0, err := e0.Calculate()
	if err != nil {
		panic(err)
	}
	e1 := &ics23.ExistenceProof{
		Key:   mpath.KeyPath[0],
		Value: sr0,
		Leaf: &ics23.LeafOp{
			Hash: tmspec.LeafSpec.Hash, PrehashKey: tmspec.LeafSpec.PrehashKey,
			PrehashValue: tmspec.LeafSpec.PrehashValue, Length: tmspec.LeafSpec.Length,
			Prefix: []byte("\x00"),
		},
	}
	root, err := e1.Calculate()
	if err != nil {
		panic(err)
	}
	proof := []ics23.CommitmentProof{
		ics23.CommitmentProof_Exist{Exist: e0},
		ics23.CommitmentProof_Exist{Exist: e1},
	}

	consB := tendermint.ConsensusState{
		Timestamp:          time.Now(),
		Root:               tendermint.NewMerkleRoot(root),
		NextValidatorsHash: tmtesting.GenValset().Hash(),
	}
	if core.CreateClient(cross(cur), tmtesting.NewClientState("attackerchain-1", proofHeight), consB) != clientBID {
		panic("clientB id race")
	}
	core.RegisterCounterparty(cross(cur), clientBID, prefix, cpartyB)

	println("----------- escrow + GRC20 balances before attack")
	println(transfer.Render("total_escrow/" + alias))
	println("realm:", grc20test.BalanceOf(transferAppAddr))
	println("attacker:", grc20test.BalanceOf(attacker))

	// --- The attack: recv the forged packet on clientB to drain clientA. ---
	// clientB never escrowed this GRC20, so checkEscrowForClient inside
	// unescrowGRC20 must reject before the teller moves anything. core.RecvPacket
	// still returns RESPONSE_SUCCESS (2): the failure lives in the written
	// acknowledgement, not the return value.
	res := core.RecvPacket(cross(cur), types.MsgRecvPacket{
		Packet:          packet,
		ProofCommitment: proof,
		ProofHeight:     proofHeight,
	})

	println("\nrecv result (2 == SUCCESS at core level; app ack is error):", int(res))
	// All three lines must be byte-identical to the pre-attack block: the escrow
	// accounting is untouched, the realm still holds the tokens, and the attacker
	// received nothing. The balances are what catch a regression that reports the
	// escrow correctly while still letting the teller pay out.
	println("----------- escrow + GRC20 balances after attack (all unchanged)")
	println(transfer.Render("total_escrow/" + alias))
	println("realm:", grc20test.BalanceOf(transferAppAddr))
	println("attacker:", grc20test.BalanceOf(attacker))
}

// Output:
// ----------- escrow + GRC20 balances before attack
// {"denom":"gno.land:r:aib:ibc:apps:testing:grc20test.TEST","amount":100,"clients":[{"client":"07-tendermint-1","amount":100}]}
// realm: 100
// attacker: 0
//
// recv result (2 == SUCCESS at core level; app ack is error): 2
// ----------- escrow + GRC20 balances after attack (all unchanged)
// {"denom":"gno.land:r:aib:ibc:apps:testing:grc20test.TEST","amount":100,"clients":[{"client":"07-tendermint-1","amount":100}]}
// realm: 100
// attacker: 0
