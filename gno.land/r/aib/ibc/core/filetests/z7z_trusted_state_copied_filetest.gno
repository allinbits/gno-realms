// PKGPATH: gno.land/r/aib/main
package main

import (
	"encoding/binary"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/lightclient/tendermint/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/aib/ics23/v0"
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

const (
	chainID      = "atomone-1"
	counterparty = "07-tendermint-42"
)

var (
	// priv=8a6cAbQSpDbebmcTEhCMPhhr/SkL/2pizo60yzHRkN9Uyk7RHOZm7g4xW+yeJh147/Z4/6HXF6gBwcFNkLsZ/A==
	val1 = tendermint.NewValidator("9DIBYr64rywKO3Kk6+743xDHcEU=",
		"VMpO0RzmZu4OMVvsniYdeO/2eP+h1xeoAcHBTZC7Gfw=", 1)
	// priv=nWg6ETc62tyxd94lh8fFaQnZKaAW6vlS0L/4lfseJuI14ZXUKp7AZROkflLFVF+SBg4wJVfzgzIKyWq3D066+g==
	val2 = tendermint.NewValidator("y+naL3ubs9q1bXrY9+uRxY9c+J8=",
		"NeGV1CqewGUTpH5SxVRfkgYOMCVX84MyCslqtw9Ouvo=", 1)
	timeout = uint64(time.Now().Add(time.Hour).Unix())
)

// forged is a packet the counterparty never sent to dest and a proof of it,
// both layers built by hand, with the root that proof verifies against.
func forged(dest string) (types.Packet, []ics23.CommitmentProof, []byte) {
	p := types.Packet{Sequence: 7, SourceClient: counterparty, DestinationClient: dest, TimeoutTimestamp: timeout,
		Payloads: []types.Payload{{SourcePort: "appID", DestinationPort: "appID", Encoding: "application/json", Value: []byte(`{"forged":true}`), Version: "v1"}}}
	key := append([]byte("prefix2"+counterparty), 1)
	key = binary.BigEndian.AppendUint64(key, p.Sequence)
	iavl, tm := ics23.IavlSpec(), ics23.TendermintSpec()
	inner := &ics23.ExistenceProof{Key: key, Value: types.CommitPacket(p), Path: []*ics23.InnerOp{},
		Leaf: &ics23.LeafOp{Hash: iavl.LeafSpec.Hash, PrehashKey: iavl.LeafSpec.PrehashKey, PrehashValue: iavl.LeafSpec.PrehashValue, Length: iavl.LeafSpec.Length, Prefix: []byte("\x00\x02\x02")}}
	storeRoot, err := inner.Calculate()
	if err != nil {
		panic(err)
	}
	outer := &ics23.ExistenceProof{Key: []byte("iavlStoreKey"), Value: storeRoot, Path: []*ics23.InnerOp{},
		Leaf: &ics23.LeafOp{Hash: tm.LeafSpec.Hash, PrehashKey: tm.LeafSpec.PrehashKey, PrehashValue: tm.LeafSpec.PrehashValue, Length: tm.LeafSpec.Length, Prefix: []byte("\x00")}}
	root, err := outer.Calculate()
	if err != nil {
		panic(err)
	}
	return p, []ics23.CommitmentProof{ics23.CommitmentProof_Exist{Exist: inner}, ics23.CommitmentProof_Exist{Exist: outer}}, root
}

func newClient(cur realm, apphash []byte) (string, tendermint.ClientState, tendermint.ConsensusState) {
	cs := tmtesting.NewClientState(chainID, types.NewHeight(1, 2))
	cs.UpgradePath = []string{"upgrade", "upgradedIBCState"}
	cons := tmtesting.GenConsensusState(time.Now(), apphash, tendermint.NewValset(val1, val2).Hash())
	id := core.CreateClient(cross(cur), cs, cons)
	core.RegisterCounterparty(cross(cur), id, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, counterparty)
	return id, cs, cons
}

// recv is "received" or why the core refused the packet.
func recv(cur realm, p types.Packet, proof []ics23.CommitmentProof, h types.Height) string {
	if r := revive(func() {
		core.RecvPacket(cross(cur), types.MsgRecvPacket{Packet: p, ProofCommitment: proof, ProofHeight: h})
	}); r != nil {
		if e, ok := r.(error); ok {
			return "refused: " + e.Error()
		}
		return "refused: " + r.(string)
	}
	return "received"
}

func lastState(id string) string { return core.Render("clients/" + id + "/consensus_states") }

// A light client keeps copies of what it trusts (Codex round 18 #1): the
// caller's slices, written after CreateClient or after a verified
// UpdateClient, never move its client state or consensus states, so a proof
// against a root the caller substituted is refused.
func main(cur realm) {
	app := appstesting.NewApp(cross(cur))
	app.SetOnRecvPacketReturn(types.RecvPacketResult{Status: types.PacketStatus_Success, Acknowledgement: []byte{0x01}})
	core.RegisterApp(cross(cur), "appID", app)

	// The control: a client that genuinely trusts the forged root accepts
	// the forged proof, so the proof itself is sound.
	p1, proof1, root1 := forged("07-tendermint-1")
	control, _, _ := newClient(cur, root1)
	println("control accepts the forged proof:", recv(cur, p1, proof1, types.NewHeight(1, 2)) == "received", control)

	// Initialization: the root the caller passed is rewritten afterwards
	// to the forged one.
	p2, proof2, root2 := forged("07-tendermint-2")
	victim, cs, cons := newClient(cur, tmtesting.Hash("apphash-2"))
	before := core.Render("clients/" + victim)
	copy(cons.Root.Hash, root2)
	println("after initialization, state unchanged:", core.Render("clients/"+victim) == before)
	println("forged proof at the initial height:", recv(cur, p2, proof2, types.NewHeight(1, 2)))

	// Every other slice of a client's initialization, rewritten afterwards:
	// the validators hash, the nested proof specifications, the upgrade
	// path. The client still verifies its genuine proofs with the specs it
	// was given.
	p3, proof3, root3 := forged("07-tendermint-3")
	other, cs3, cons3 := newClient(cur, root3)
	before3 := core.Render("clients/" + other)
	cons3.NextValidatorsHash[0] ^= 0xff
	cs3.ProofSpecs[0].LeafSpec.Prefix[0] = 0x07
	cs3.ProofSpecs[0].InnerSpec.ChildOrder[0] = 9
	cs3.UpgradePath[0] = "evil"
	println("another client, state unchanged:", core.Render("clients/"+other) == before3, "| its proof:", recv(cur, p3, proof3, types.NewHeight(1, 2)))

	// A verified update: the header's app hash and next validators hash are
	// rewritten after UpdateClient returns.
	{
		var (
			apphash         = tmtesting.Hash("apphash-3")
			commitTimestamp = tmtesting.ToTime("2025-09-25T07:55:57.306746166Z")
			newTimestamp    = cons.Timestamp.Add(time.Minute)
			valset          = tendermint.NewValset(val1, val2)
			nextValset      = tendermint.NewValset(val1, val2)
			trustedValset   = tendermint.NewValset(val1, val2)
			signatures      = []tendermint.CommitSig{
				{
					BlockIDFlag:      tendermint.BlockIDFlagCommit,
					ValidatorAddress: valset.Validators[0].Address,
					Timestamp:        commitTimestamp,
					Signature:        []byte("\x5c\xd2\x8b\xe3\x4b\x60\x3e\xaa\x75\x3c\xce\x24\xfe\x15\x75\x55\x84\xd4\xa3\xce\xbe\x0f\x94\xe9\xf7\x27\xb3\x7a\xdd\x02\x2d\xa0\x0b\xa7\x83\x7f\x50\xc3\xde\x3d\x95\x59\xb3\xad\xed\xd0\xdd\x23\x1d\x39\x9a\x8e\x1f\xc3\xcf\xdb\x1d\xa9\x93\xf5\x9a\xc0\x2b\x05"),
				},
				{
					BlockIDFlag:      tendermint.BlockIDFlagCommit,
					ValidatorAddress: valset.Validators[1].Address,
					Timestamp:        commitTimestamp,
					Signature:        []byte("\x34\x41\x2e\x78\x7f\xbf\x70\xef\x14\x48\xe3\x14\xd5\x83\xdc\x42\xff\x40\xf6\x5b\x71\x62\x09\xf9\x6f\x54\x63\x3e\xdb\xc5\x98\xc0\x9e\xa7\xde\x33\xac\xa7\x5f\xbb\xd6\x63\x49\xe1\xe9\x98\x86\x03\x46\x6a\x7e\xb6\x5d\xe5\x71\xe5\x1e\x5d\x4d\xd8\x8d\xbe\x2f\x01"),
				},
			}

			msgHeader = tmtesting.NewMsgHeader(chainID, newTimestamp, apphash, 3, cs.LatestHeight, valset, nextValset, trustedValset, signatures)
		)
		core.UpdateClient(cross(cur), victim, msgHeader)
		before = lastState(victim)
		copy(msgHeader.Header.AppHash, root2)
		msgHeader.Header.NextValidatorsHash[0] ^= 0xff
		println("after the update, consensus states unchanged:", lastState(victim) == before)
	}
	println("forged proof at the updated height:", recv(cur, p2, proof2, types.NewHeight(1, 3)))
}

// Output:
// control accepts the forged proof: true 07-tendermint-1
// after initialization, state unchanged: true
// forged proof at the initial height: refused: failed packet commitment verification for client (07-tendermint-2): proof did not commit to expected root: 6007712b228383eb5441ce43962d9f6242768a6ce7a9b27e5037d0ef2d103653, got: d969f51bbcd3f798f1a57f45987ee21c62d26fbf99e3ee91d4601dda107fb387. Please ensure proof was submitted with correct proofHeight and to the correct chain.
// another client, state unchanged: true | its proof: received
// after the update, consensus states unchanged: true
// forged proof at the updated height: refused: failed packet commitment verification for client (07-tendermint-2): proof did not commit to expected root: 9bd69fa5cf8f5da6111dd182ec592bceecd1367f0e342d71442cd86003d1094f, got: d969f51bbcd3f798f1a57f45987ee21c62d26fbf99e3ee91d4601dda107fb387. Please ensure proof was submitted with correct proofHeight and to the correct chain.
