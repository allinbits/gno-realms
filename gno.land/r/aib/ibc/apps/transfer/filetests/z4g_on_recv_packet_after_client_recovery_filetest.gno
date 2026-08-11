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

// OnRecvPacket: escrow stays reachable after the escrowing client is repaired.
//
// Escrow is accounted per (client, denom), so escrow is only ever releasable
// through the client ID it was locked under. That makes the escrow reachable
// only for as long as that client ID survives, which this test pins down: a
// client that breaks must be repaired in place by core.RecoverClient, never
// replaced by a fresh client ID, or every balance escrowed under the old ID
// becomes unreleasable.
//
// Flow: lock 100ugnot under clientA -> break clientA -> recover it from a
// healthy substitute -> receive a returning-token packet on clientA and see
// the coins actually paid out.
//
// The three properties that must hold across recovery, none of which
// RecoverClient touches (it replaces only the light-client state):
//
//  1. The client ID is preserved, so escrow[clientA] is still the bucket the
//     returning packet debits.
//  2. The registered counterparty survives, so the packet's SourceClient still
//     matches and no re-registration is needed.
//  3. The client is Active again, so core.RecvPacket's status gate passes.
//
// clientA is broken by misbehaviour (Frozen) rather than by expiry, because a
// filetest clock cannot be advanced past the trusting period. Both statuses
// take the identical recovery path -- core.RecoverClient accepts Frozen or
// Expired and rejects everything else -- so the property under test is the same.
func main(cur realm) {
	const admin = "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm"
	core.SetAdmin(cross(cur), admin)

	var (
		// clientA locks the escrow, breaks, and is recovered in place.
		clientAID = "07-tendermint-1"
		// The healthy substitute recovery copies its state from.
		substituteID = "07-tendermint-2"
		// clientA's counterparty, registered once and expected to survive.
		cpartyA = "07-tendermint-42"

		prefix = [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}
		// The substitute's height; clientA adopts it during recovery, so it is
		// also the height the returning packet's proof is verified at.
		proofHeight = types.NewHeight(1, 100)

		// Preamble reused verbatim from core's z9aaa recovery filetest: the
		// misbehaviour signatures below are over these exact chainID, heights,
		// valset and timestamps, so none of it can be changed independently.
		chainID       = "atomone-1"
		val1          = tendermint.NewValidator("9DIBYr64rywKO3Kk6+743xDHcEU=", "VMpO0RzmZu4OMVvsniYdeO/2eP+h1xeoAcHBTZC7Gfw=", 1)
		val2          = tendermint.NewValidator("y+naL3ubs9q1bXrY9+uRxY9c+J8=", "NeGV1CqewGUTpH5SxVRfkgYOMCVX84MyCslqtw9Ouvo=", 1)
		trustedValset = tendermint.NewValset(val1, val2)
		clientAState  = tmtesting.NewClientState(chainID, types.NewHeight(1, 2))
		consA         = tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("apphash-2"), trustedValset.Hash())
	)

	if got := core.CreateClient(cross(cur), clientAState, consA); got != clientAID {
		panic("clientA id race: " + got)
	}
	core.RegisterCounterparty(cross(cur), clientAID, prefix, cpartyA)

	// --- Lock 100ugnot under clientA through a real Transfer. ---
	transferAppAddr := chain.PackageAddress("gno.land/r/aib/ibc/apps/transfer")
	testing.IssueCoins(transferAppAddr, chain.NewCoins(chain.NewCoin("ugnot", 100)))
	sender := testutils.TestAddress("sender")
	testing.SetRealm(testing.NewUserRealm(sender))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 100)))
	transfer.Transfer(cross(cur), clientAID, "atone1user", "ugnot", 100,
		uint64(time.Now().Add(time.Hour).Unix()), "")
	testing.SetOriginSend(nil)
	// Restore the admin EOA: RecoverClient is gated on unsafe.OriginCaller().
	testing.SetRealm(testing.NewUserRealm(address(admin)))

	println("----------- escrow locked under clientA, clientA Active")
	println(transfer.Render("total_escrow/ugnot"))
	println(core.Render("clients/" + clientAID + "/status"))

	// --- Break clientA: two conflicting headers at the same trusted height. ---
	var header1, header2 *tendermint.MsgHeader
	{
		var (
			apphash         = tmtesting.Hash("apphash-4")
			val1            = tendermint.NewValidator("9DIBYr64rywKO3Kk6+743xDHcEU=", "VMpO0RzmZu4OMVvsniYdeO/2eP+h1xeoAcHBTZC7Gfw=", 10)
			val2            = tendermint.NewValidator("y+naL3ubs9q1bXrY9+uRxY9c+J8=", "NeGV1CqewGUTpH5SxVRfkgYOMCVX84MyCslqtw9Ouvo=", 10)
			valset          = tendermint.NewValset(val1, val2)
			commitTimestamp = tmtesting.ToTime("2025-09-25T07:55:57.306746166Z")
			newHeight       = uint64(4)
			newTimestamp    = consA.Timestamp.Add(time.Minute * time.Duration(0))
			nextValset      = tendermint.NewValset(val1, val2)
			trustedHeight   = clientAState.LatestHeight

			signatures = []tendermint.CommitSig{
				{
					BlockIDFlag:      tendermint.BlockIDFlagCommit,
					ValidatorAddress: valset.Validators[0].Address,
					Timestamp:        commitTimestamp,
					Signature:        []byte("\x2e\xba\x21\xb0\x2f\xd2\x85\xb9\xef\x82\x68\xdc\xef\xd1\xd1\x12\x70\x88\x94\x10\x7e\x4d\x49\xac\x46\x3d\x86\xe2\xf2\xae\x38\xb4\xa5\xab\x0c\xc1\x8f\x8a\x59\xda\x36\x17\x01\xe4\x16\x49\xbf\x03\x86\xf0\x31\x3f\x30\x37\x9e\x47\x28\x72\x3b\x0c\x89\xb9\x94\x05"),
				},
				{
					BlockIDFlag:      tendermint.BlockIDFlagCommit,
					ValidatorAddress: valset.Validators[1].Address,
					Timestamp:        commitTimestamp,
					Signature:        []byte("\x67\xcc\xc6\xc4\x20\xa0\xcb\x36\xaf\x33\x5c\xf8\xe4\xad\x47\x49\x38\x9d\x9e\xa3\x7c\xe6\x88\x81\x62\x51\x7f\xcc\xa5\x92\x0d\x98\xe9\xbe\x71\x2d\x22\xcd\x41\x30\x28\x83\x03\xcb\xf5\xd7\x28\xde\x7b\x92\x85\x9e\xa6\xe5\xde\x50\x89\x2d\x2b\xc5\x9d\x9a\x33\x00"),
				},
			}
		)
		header1 = tmtesting.NewMsgHeader(chainID, newTimestamp, apphash, newHeight,
			trustedHeight, valset, nextValset, trustedValset, signatures)
	}
	{
		var (
			apphash         = tmtesting.Hash("apphash-3")
			val1            = tendermint.NewValidator("9DIBYr64rywKO3Kk6+743xDHcEU=", "VMpO0RzmZu4OMVvsniYdeO/2eP+h1xeoAcHBTZC7Gfw=", 10)
			val2            = tendermint.NewValidator("y+naL3ubs9q1bXrY9+uRxY9c+J8=", "NeGV1CqewGUTpH5SxVRfkgYOMCVX84MyCslqtw9Ouvo=", 10)
			valset          = tendermint.NewValset(val1, val2)
			commitTimestamp = tmtesting.ToTime("2025-09-25T07:55:57.306746166Z")
			newHeight       = uint64(3)
			newTimestamp    = consA.Timestamp.Add(time.Minute * time.Duration(0))
			nextValset      = tendermint.NewValset(val1, val2)
			trustedHeight   = clientAState.LatestHeight

			signatures = []tendermint.CommitSig{
				{
					BlockIDFlag:      tendermint.BlockIDFlagCommit,
					ValidatorAddress: valset.Validators[0].Address,
					Timestamp:        commitTimestamp,
					Signature:        []byte("\x51\xa4\x8f\x78\x42\x4e\x6e\x0d\xc3\x2b\xe6\xcb\x09\x5c\xe5\x7d\x35\x84\xcf\xb1\x0f\x53\x72\x0c\x41\xde\xd3\x6d\xbc\x81\x28\x64\x41\xf7\xe9\x1e\xa9\x93\xd0\xa4\x84\x16\xca\xa8\xa3\x8e\x56\x45\xec\xae\x1d\x24\xb4\xa8\xf4\x29\x85\x04\x06\xe4\x18\x6b\x7d\x08"),
				},
				{
					BlockIDFlag:      tendermint.BlockIDFlagCommit,
					ValidatorAddress: valset.Validators[1].Address,
					Timestamp:        commitTimestamp,
					Signature:        []byte("\xd9\xd6\x82\x83\x78\x75\xfa\x2e\xd7\x1b\xa5\x3d\xfe\xb3\x80\xb6\xc7\x59\x20\x45\x10\xdf\x0c\x19\xd1\xcc\xfc\x37\xd5\x59\x79\x95\x93\x60\x08\xfb\x5f\xa0\x87\x95\x51\x1e\x29\xed\x94\xd1\x31\x5e\xda\x90\x86\x11\xbe\xb2\x88\x68\xe1\xba\xa7\x31\xc7\xa2\xda\x07"),
				},
			}
		)
		header2 = tmtesting.NewMsgHeader(chainID, newTimestamp, apphash, newHeight,
			trustedHeight, valset, nextValset, trustedValset, signatures)
	}
	core.UpdateClient(cross(cur), clientAID, &tendermint.Misbehaviour{Header1: header1, Header2: header2})

	println("----------- clientA broken; escrow is now unreleasable")
	println(core.Render("clients/" + clientAID + "/status"))

	// --- The returning-token packet that should release the escrow. ---
	// Its denom traces through clientA's counterparty, so OnRecvPacket takes
	// the unescrow branch rather than minting a voucher.
	receiver := testutils.TestAddress("receiver")
	denom := "transfer/" + cpartyA + "/ugnot"
	payload := transfer.NewFungibleTokenPacketData(denom, "100", "atone1user", receiver.String(), "")
	packet := types.Packet{
		Sequence:          1,
		SourceClient:      cpartyA,
		DestinationClient: clientAID,
		TimeoutTimestamp:  uint64(time.Now().Add(time.Hour).Unix()),
		Payloads: []types.Payload{{
			SourcePort:      transfer.PortID,
			DestinationPort: transfer.PortID,
			Encoding:        transfer.EncodingProtobuf,
			Value:           payload.ProtoMarshal(),
			Version:         transfer.V1,
		}},
	}

	// Build the packet-commitment proof, then derive the root it commits to.
	// The substitute is created carrying that root, so after recovery clientA
	// verifies this proof against the state it inherited.
	mpath := types.BuildMerklePath(prefix, host.PacketCommitmentKey(cpartyA, 1))
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

	// --- The healthy substitute. Same params as clientA (recovery rejects a
	// substitute differing on TrustLevel/UnbondingPeriod/MaxClockDrift/
	// ProofSpecs/UpgradePath), at a higher height, carrying the root above. ---
	substituteConsState := tendermint.ConsensusState{
		Timestamp:          time.Now(),
		Root:               tendermint.NewMerkleRoot(root),
		NextValidatorsHash: trustedValset.Hash(),
	}
	if got := core.CreateClient(cross(cur), tmtesting.NewClientState(chainID, proofHeight), substituteConsState); got != substituteID {
		panic("substitute id race: " + got)
	}

	// --- Repair clientA in place. ---
	core.RecoverClient(cross(cur), clientAID, substituteID)

	println("----------- clientA recovered in place, same ID")
	println(core.Render("clients/" + clientAID + "/status"))

	// --- The returning packet now releases the escrow it was locked under. ---
	// Note this call proves all three properties at once: it is addressed to
	// clientAID (ID preserved), its SourceClient matches the counterparty
	// registered before the break (registration survived), and it clears
	// core.RecvPacket's Active gate (client revived).
	res := core.RecvPacket(cross(cur), types.MsgRecvPacket{
		Packet:          packet,
		ProofCommitment: proof,
		ProofHeight:     proofHeight,
	})

	println("\nrecv result (2 == SUCCESS):", int(res))
	println("----------- escrow drawn down to 0")
	println(transfer.Render("total_escrow/ugnot"))
	// The decisive assertion: the coins physically moved. A regression that
	// left the accounting right but paid nothing out would pass on the render
	// alone.
	println("----------- receiver balance (100ugnot released)")
	println(banker.NewReadonlyBanker().GetCoins(receiver).String())
	println("----------- transfer realm balance (escrow emptied)")
	println(banker.NewReadonlyBanker().GetCoins(transferAppAddr).String())
}

// Output:
// ----------- escrow locked under clientA, clientA Active
// {"denom":"ugnot","amount":100,"clients":[{"client":"07-tendermint-1","amount":100}]}
// {"status":"Active"}
// ----------- clientA broken; escrow is now unreleasable
// {"status":"Frozen"}
// ----------- clientA recovered in place, same ID
// {"status":"Active"}
//
// recv result (2 == SUCCESS): 2
// ----------- escrow drawn down to 0
// {"denom":"ugnot","amount":0,"clients":[{"client":"07-tendermint-1","amount":0}]}
// ----------- receiver balance (100ugnot released)
// 100ugnot
// ----------- transfer realm balance (escrow emptied)
