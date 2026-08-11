// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"
	"chain/banker"
	"testing"
	"time"

	"gno.land/p/aib/ibc/host"
	"gno.land/p/aib/ibc/lightclient/tendermint"
	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	"gno.land/p/nt/testutils/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
)

// OnRecvPacket: per-client escrow isolation prevents a shared-escrow drain.
//
// Regression test for the shared-escrow drain vulnerability. An attacker
// creates their own client (clientB) whose consensus root they control, then
// forges a valid ICS-23 proof against that root and submits a "returning token"
// packet on clientB that tries to unescrow native ugnot that honest users
// locked under a different client (clientA).
//
// Before the fix, escrow was a single global per-denom pool, so the malicious
// recv succeeded and drained clientA's escrow. The fix accounts escrow per
// (client, denom): clientB never escrowed any ugnot, so OnRecvPacket returns a
// failure acknowledgement and clientA's escrow is untouched.
func main(cur realm) {
	var (
		// clientA: the honest client the escrow was locked under.
		clientAID = "07-tendermint-1"
		// clientB: the attacker-controlled client the malicious packet arrives on.
		clientBID = "07-tendermint-2"
		// Counterparty IDs registered for each client.
		cpartyA = "07-tendermint-42"
		cpartyB = "07-tendermint-99"

		prefix      = [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}
		proofHeight = types.NewHeight(1, 100)
	)

	// --- Honest client A: lock 100ugnot under clientA via a real Transfer. ---
	clientAState := tmtesting.NewClientState("honestchain-1", types.NewHeight(1, 50))
	consA := tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("honest-apphash"), tmtesting.GenValset().Hash())
	if core.CreateClient(cross(cur), clientAState, consA) != clientAID {
		panic("clientA id race")
	}
	core.RegisterCounterparty(cross(cur), clientAID, prefix, cpartyA)

	// Fund the transfer realm and run a real native Transfer over clientA so the
	// per-client escrow under clientA is established.
	transferAppAddr := chain.PackageAddress("gno.land/r/aib/ibc/apps/transfer")
	testing.IssueCoins(transferAppAddr, chain.NewCoins(chain.NewCoin("ugnot", 100)))
	sender := testutils.TestAddress("sender")
	testing.SetRealm(testing.NewUserRealm(sender))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 100)))
	transfer.Transfer(cross(cur), clientAID, "atone1user", "ugnot", 100, uint64(time.Now().Add(time.Hour).Unix()), "")
	testing.SetOriginSend(nil)

	// --- Attacker client B: attacker controls the consensus root, so they can
	// produce a valid proof against it themselves via ExistenceProof.Calculate. ---
	attacker := testutils.TestAddress("attacker")
	// Switch off the honest sender's realm: everything from here on -- creating
	// clientB, registering its counterparty, relaying the forged packet -- is
	// signed by the attacker EOA. Without this the whole attack would run as
	// the same EOA that established clientA's escrow, and the test would not
	// exercise the documented threat model (an unprivileged third party).
	testing.SetRealm(testing.NewUserRealm(attacker))
	// "returning token" packet: the denom trace starts with the counterparty of
	// clientB, so OnRecvPacket takes the unescrow branch.
	denom := "transfer/" + cpartyB + "/ugnot"
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
	value := types.CommitPacket(packet)

	// Build the packet-commitment proof against a root the attacker chooses.
	mpath := types.BuildMerklePath(prefix, host.PacketCommitmentKey(cpartyB, 1))
	iavl, tmspec := ics23.IavlSpec(), ics23.TendermintSpec()
	e0 := &ics23.ExistenceProof{
		Key:   mpath.KeyPath[1],
		Value: value,
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

	// Create clientB with the attacker-chosen root.
	consB := tendermint.ConsensusState{
		Timestamp:          time.Now(),
		Root:               tendermint.NewMerkleRoot(root),
		NextValidatorsHash: tmtesting.GenValset().Hash(),
	}
	if core.CreateClient(cross(cur), tmtesting.NewClientState("attackerchain-1", proofHeight), consB) != clientBID {
		panic("clientB id race")
	}
	core.RegisterCounterparty(cross(cur), clientBID, prefix, cpartyB)

	// Sanity: clientA still holds the 100ugnot escrow before the attack.
	println("----------- assert render total_escrow/ugnot before attack")
	println(transfer.Render("total_escrow/ugnot"))
	// The escrow counter alone only proves the *accounting* was untouched. The
	// decisive property of a drain test is that no coins moved, so record where
	// the 100ugnot physically sits before the attack too.
	println("----------- realm / attacker ugnot before attack")
	println(banker.NewReadonlyBanker().GetCoins(transferAppAddr).String())
	println(banker.NewReadonlyBanker().GetCoins(attacker).String())

	// --- The attack: recv the forged packet on clientB to drain clientA. ---
	// OnRecvPacket must reject it: clientB never escrowed any ugnot, so the
	// unescrow fails and an error acknowledgement is written. core.RecvPacket
	// itself still returns RESPONSE_SUCCESS (2) because the recv was processed;
	// the failure is reflected in the written acknowledgement, not the return.
	// The decisive assertion is that clientA's escrow is untouched.
	res := core.RecvPacket(cross(cur), types.MsgRecvPacket{
		Packet:          packet,
		ProofCommitment: proof,
		ProofHeight:     proofHeight,
	})

	println("\nrecv result (2 == SUCCESS at core level; app ack is error):", int(res))
	println("----------- assert render total_escrow/ugnot after attack (unchanged)")
	println(transfer.Render("total_escrow/ugnot"))
	// Both balances must be byte-identical to the pre-attack lines above: the
	// realm still holds all 100ugnot and the attacker received nothing. This is
	// what catches a regression that reports the escrow correctly while still
	// paying the coins out.
	println("----------- realm / attacker ugnot after attack (both unchanged)")
	println(banker.NewReadonlyBanker().GetCoins(transferAppAddr).String())
	println(banker.NewReadonlyBanker().GetCoins(attacker).String())
}

// Output:
// ----------- assert render total_escrow/ugnot before attack
// {"denom":"ugnot","amount":100,"clients":[{"client":"07-tendermint-1","amount":100}]}
// ----------- realm / attacker ugnot before attack
// 100ugnot
//
//
// recv result (2 == SUCCESS at core level; app ack is error): 2
// ----------- assert render total_escrow/ugnot after attack (unchanged)
// {"denom":"ugnot","amount":100,"clients":[{"client":"07-tendermint-1","amount":100}]}
// ----------- realm / attacker ugnot after attack (both unchanged)
// 100ugnot

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
//         "value": "1/50"
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
//         "value": "07-tendermint-42"
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
//         "value": "0801120f30372d74656e6465726d696e742d311a1030372d74656e6465726d696e742d343220e2a1d8cc042a790a087472616e7366657212087472616e736665721a0769637332302d3122166170706c69636174696f6e2f782d70726f746f6275662a420a0575676e6f7412033130301a28673177646a6b75657239776630343768366c746130343768366c746130343768366c647978356178220a61746f6e653175736572"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "ibc_transfer",
//     "attrs": [
//       {
//         "key": "sender",
//         "value": "g1wdjkuer9wf047h6lta047h6lta047h6ldyx5ax"
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
//         "value": "1/100"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "recv_packet",
//     "attrs": [
//       {
//         "key": "packet_source_client",
//         "value": "07-tendermint-99"
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
//         "value": "0801121030372d74656e6465726d696e742d39391a0f30372d74656e6465726d696e742d3220e2a1d8cc042a97010a087472616e7366657212087472616e736665721a0769637332302d3122166170706c69636174696f6e2f782d70726f746f6275662a600a1f7472616e736665722f30372d74656e6465726d696e742d39392f75676e6f7412033130301a0e61746f6e653161747461636b657222286731763936386763747264646a687968366c746130343768366c746130343768366c706c34736334"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "fungible_token_packet",
//     "attrs": [
//       {
//         "key": "sender",
//         "value": "atone1attacker"
//       },
//       {
//         "key": "receiver",
//         "value": "g1v968gctrddjhyh6lta047h6lta047h6lpl4sc4"
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
//       },
//       {
//         "key": "success",
//         "value": "false"
//       },
//       {
//         "key": "error",
//         "value": "insufficient escrow for client 07-tendermint-2 denom ugnot: have 0, want 100"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/apps/transfer"
//   },
//   {
//     "type": "write_acknowledgement",
//     "attrs": [
//       {
//         "key": "packet_source_client",
//         "value": "07-tendermint-99"
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
//         "value": "0801121030372d74656e6465726d696e742d39391a0f30372d74656e6465726d696e742d3220e2a1d8cc042a97010a087472616e7366657212087472616e736665721a0769637332302d3122166170706c69636174696f6e2f782d70726f746f6275662a600a1f7472616e736665722f30372d74656e6465726d696e742d39392f75676e6f7412033130301a0e61746f6e653161747461636b657222286731763936386763747264646a687968366c746130343768366c746130343768366c706c34736334"
//       },
//       {
//         "key": "encoded_acknowledgement_hex",
//         "value": "0a204774d4a575993f963b1c06573736617a457abef8589178db8d10c94b4ab511ab"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   }
// ]
