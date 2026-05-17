package main

// PKGPATH: gno.land/r/aib/main

import (
	"encoding/hex"
	"testing"
	"time"

	"gno.land/p/aib/ibc/lightclient/tendermint"
	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
)

// forwardingApp wraps the base mock and writes the deferred parent ack from
// inside OnTimeoutPacket. Defined here (rather than in apps/testing) so that
// apps/testing does not need to import core, which would create an import
// cycle with this directory's filetests during gnodev deploy. Pending state
// is held in package-level vars because the receiver is read-only when
// invoked across realms via the IBCApp interface.
type forwardingApp struct {
	*appstesting.App
}

var (
	pendingClientID  string
	pendingSequence  uint64
	asyncDeferredAck = types.Acknowledgement{
		AppAcknowledgements: [][]byte{{0x02}},
	}
)

func (f *forwardingApp) OnRecvPacket(
	_ realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	payload types.Payload,
) types.RecvPacketResult {
	res := f.App.OnRecvPacket(cross, sourceClient, destinationClient, sequence, payload)
	if res.Status == types.PacketStatus_Async {
		pendingClientID = destinationClient
		pendingSequence = sequence
	}
	return res
}

func (f *forwardingApp) OnTimeoutPacket(
	_ realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	payload types.Payload,
) error {
	err := f.App.OnTimeoutPacket(cross, sourceClient, destinationClient, sequence, payload)
	if pendingClientID != "" {
		clientID, seq := pendingClientID, pendingSequence
		pendingClientID, pendingSequence = "", 0
		core.WriteAcknowledgement(cross, clientID, seq, asyncDeferredAck)
	}
	return err
}

// Async ack via OnTimeoutPacket. Mirrors the PFM/ZKGM forwarded-ack timeout
// path on the middle chain B of A -> B -> C:
//
//   - parent packet arrives from chain A, app returns Async (deferred)
//   - child packet is sent to chain C
//   - chain C never receives the child; timeout elapses
//   - chain B times out the child; that triggers the mock's
//     OnTimeoutPacket, which calls core.WriteAcknowledgement to finally
//     ack the parent (with the deferred async ack)
//
// On us (chain B) two clients are needed, one per remote chain:
//
//   - clientToA: local id 07-tendermint-1, chain A's id for us is 07-tendermint-42
//   - clientToC: local id 07-tendermint-2, chain C's id for us is 07-tendermint-99
//
// clientToC mirrors z6a_timeout_filetest's validator set / chain id so the
// gen-block-signatures output for atomone-1 height=12 can be reused to
// advance the client past the child's timeout.
func main() {
	var (
		trustedHeight       = types.NewHeight(2, 2)
		trustedValset       = tmtesting.GenValset()
		chainAClientIDForUs = "07-tendermint-42"
		chainCClientIDForUs = "07-tendermint-99"
	)

	// clientToA: tracks chain A. apphash commits to the parent packet
	// commitment at prefix2/07-tendermint-42/packet/seq=1 on chain A.
	apphashA, _ := hex.DecodeString("8da82bb625ee946f4b7aa03a82010cb115f9ce3879c7caad8d92e71eb821996e")
	clientToA := core.CreateClient(cross,
		tmtesting.NewClientState("chainA-2", trustedHeight),
		tmtesting.GenConsensusState(time.Now(), apphashA, trustedValset.Hash()),
	)
	core.RegisterCounterparty(cross, clientToA, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, chainAClientIDForUs)

	// clientToC: tracks chain C with a deterministic validator set so the
	// timeout flow can advance the client via a generated block signature.
	// priv=8a6cAbQSpDbebmcTEhCMPhhr/SkL/2pizo60yzHRkN9Uyk7RHOZm7g4xW+yeJh147/Z4/6HXF6gBwcFNkLsZ/A==
	val1 := tendermint.NewValidator("9DIBYr64rywKO3Kk6+743xDHcEU=",
		"VMpO0RzmZu4OMVvsniYdeO/2eP+h1xeoAcHBTZC7Gfw=", 1)
	// priv=nWg6ETc62tyxd94lh8fFaQnZKaAW6vlS0L/4lfseJuI14ZXUKp7AZROkflLFVF+SBg4wJVfzgzIKyWq3D066+g==
	val2 := tendermint.NewValidator("y+naL3ubs9q1bXrY9+uRxY9c+J8=",
		"NeGV1CqewGUTpH5SxVRfkgYOMCVX84MyCslqtw9Ouvo=", 1)
	chainCValset := tendermint.NewValset(val1, val2)
	chainCInitialHeight := types.NewHeight(1, 2)
	chainCInitialApphash := tmtesting.Hash("apphash-1")
	chainCInitialConsensus := tmtesting.GenConsensusState(time.Now(), chainCInitialApphash, chainCValset.Hash())
	clientToC := core.CreateClient(cross,
		tmtesting.NewClientState("atomone-1", chainCInitialHeight),
		chainCInitialConsensus,
	)
	core.RegisterCounterparty(cross, clientToC, [][]byte{[]byte("iavlStoreKey"), []byte("prefix3")}, chainCClientIDForUs)

	// Register the forwarding mock from this realm, so the pkgPath stored
	// in core is gno.land/r/aib/main — the same realm that later calls
	// core.WriteAcknowledgement from inside OnTimeoutPacket.
	var (
		base      = appstesting.NewApp(cross)
		app       = &forwardingApp{App: base}
		appPortID = "appID"
	)
	app.SetOnRecvPacketReturn(types.RecvPacketResult{Status: types.PacketStatus_Async})
	core.RegisterApp(cross, appPortID, app)

	// Send the child packet to chain C. Its eventual timeout will trigger
	// the mock's OnTimeoutPacket and the deferred parent ack write.
	sendPacket := types.MsgSendPacket{
		SourceClient:     clientToC,
		TimeoutTimestamp: uint64(time.Now().Add(10 * time.Minute).Unix()),
		Payloads: []types.Payload{{
			SourcePort:      appPortID,
			DestinationPort: appPortID,
			Encoding:        "application/json",
			Value:           []byte("{}"),
			Version:         "v1",
		}},
	}
	childSeq := core.SendPacket(cross, sendPacket)

	// Receive the parent packet from chain A. The mock returns Async, so
	// core stores a pending entry and does not yet write the ack.
	specs := ics23.IavlSpec()
	// NOTE proof generated by:
	// go run -C ./cmd/gen-proof . 'prefix2' '07-tendermint-42' 'packet' '{"sequence":1,"source_client":"07-tendermint-42","destination_client":"07-tendermint-1","timeout_timestamp":1234571490,"payloads":[{"source_port":"appID","destination_port":"appID","encoding":"application/json","value":"e30=","version":"v1"}]}'
	parentRecvProof := []ics23.CommitmentProof{
		// iavl proof
		ics23.CommitmentProof_Exist{
			Exist: &ics23.ExistenceProof{
				Key:   []byte("\x70\x72\x65\x66\x69\x78\x32\x30\x37\x2d\x74\x65\x6e\x64\x65\x72\x6d\x69\x6e\x74\x2d\x34\x32\x01\x00\x00\x00\x00\x00\x00\x00\x01"),
				Value: []byte("\x23\x99\xf6\x84\x16\xb7\xd0\x09\x3b\xe4\x9e\x5f\x8e\xe1\xbe\x1c\x8e\x07\xa0\x93\xc5\x67\x09\x03\x46\xce\x36\xc9\x7d\x11\x71\x71"),
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
		// rootmulti proof
		ics23.CommitmentProof_Exist{
			Exist: &ics23.ExistenceProof{
				Key:   []byte("\x69\x61\x76\x6c\x53\x74\x6f\x72\x65\x4b\x65\x79"),
				Value: []byte("\xeb\xfd\x02\x8a\x5d\xe1\xcf\x93\xde\x5d\x0b\xa8\xcf\x6e\x0d\x5e\x29\xf8\x80\x1a\x08\x0b\x07\x20\x3c\xf1\xca\xf2\xf4\xdd\xd3\x10"),
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
			SourceClient:      chainAClientIDForUs,
			DestinationClient: clientToA,
			TimeoutTimestamp:  uint64(time.Now().Add(time.Hour).Unix()),
			Payloads: []types.Payload{{
				SourcePort:      appPortID,
				DestinationPort: appPortID,
				Encoding:        "application/json",
				Value:           []byte("{}"),
				Version:         "v1",
			}},
		},
		ProofCommitment: parentRecvProof,
		ProofHeight:     trustedHeight,
	}
	recvRes := core.RecvPacket(cross, recvPacket)

	println("recv res:", recvRes)
	println("\n----------- parent ack BEFORE child times out (deferred, should not exist)")
	println(core.Render("clients/" + clientToA + "/packet_acknowledgements/1"))

	// Advance block time past the child's timeout, then update chain C's
	// client to a header that proves the receipt is absent. Reuses the
	// height/timestamps/signatures from z6a_timeout_filetest because the
	// inputs to gen-block-signatures (chainid, apphash, height, time-shift,
	// privkeys) match and ed25519 signing is deterministic.
	ctx := testing.GetContext()
	ctx.Time = time.Now().Add(12 * time.Minute)
	testing.SetContext(ctx)
	// NOTE code generated by:
	// go run -C ./cmd/gen-block-signatures . -apphash-hex=82ea91f259352674360c621c4b0a1975cc076e3792b6d22a8bfbe8e7f7d0d2d7 -chainid=atomone-1 -header-time-shift=12 -height=12 -privkeys=8a6cAbQSpDbebmcTEhCMPhhr/SkL/2pizo60yzHRkN9Uyk7RHOZm7g4xW+yeJh147/Z4/6HXF6gBwcFNkLsZ/A==,nWg6ETc62tyxd94lh8fFaQnZKaAW6vlS0L/4lfseJuI14ZXUKp7AZROkflLFVF+SBg4wJVfzgzIKyWq3D066+g==
	// NOTE this apphash was provided by the gen-proof command below.
	apphashCAfter, _ := hex.DecodeString("82ea91f259352674360c621c4b0a1975cc076e3792b6d22a8bfbe8e7f7d0d2d7")
	commitTimestamp := tmtesting.ToTime("2025-09-25T07:55:57.306746166Z")
	newTimestamp := chainCInitialConsensus.Timestamp.Add(12 * time.Minute)
	signatures := []tendermint.CommitSig{
		{
			BlockIDFlag:      tendermint.BlockIDFlagCommit,
			ValidatorAddress: chainCValset.Validators[0].Address,
			Timestamp:        commitTimestamp,
			Signature:        []byte("\x90\x76\xf4\x27\xaf\x23\xd0\xcb\x97\xb1\x6d\xfa\x86\xae\x6d\x46\xe9\xe4\x65\x76\xf2\x6a\x1d\x5f\x83\xa6\x9e\x4a\x28\x55\x6e\x74\x84\x02\xff\x15\xc0\x41\xed\x15\xb7\xef\x3a\x3f\xe1\xe6\xa0\x8f\x34\x83\x9c\x2e\x27\x26\x69\x00\x73\x45\x87\xd2\x3c\xe6\x12\x07"),
		},
		{
			BlockIDFlag:      tendermint.BlockIDFlagCommit,
			ValidatorAddress: chainCValset.Validators[1].Address,
			Timestamp:        commitTimestamp,
			Signature:        []byte("\x45\x61\x3b\x34\x58\xa1\xf5\x75\x16\x6f\xb3\xad\xda\x12\xa8\xef\xb6\x64\x3f\x6b\x80\x73\x74\xe3\x15\x6f\xe1\x3b\x3f\x50\xed\x0d\xbc\xa7\x54\x11\x72\xe3\x71\x22\x95\xec\x77\x93\x45\x03\x67\xa5\x00\x4c\x84\x3b\x1c\xa4\xf7\x0e\x95\xd1\xe2\x04\xb6\x91\x63\x09"),
		},
	}
	msgHeader := tmtesting.NewMsgHeader(
		"atomone-1", newTimestamp, apphashCAfter, uint64(12), chainCInitialHeight,
		chainCValset, chainCValset, chainCValset, signatures,
	)
	core.UpdateClient(cross, clientToC, msgHeader)

	// Time out the child packet. core invokes the mock's OnTimeoutPacket,
	// which itself calls core.WriteAcknowledgement for the pending parent.
	// NOTE proof generated by:
	// go run -C ./cmd/gen-proof . 'prefix3' '07-tendermint-99' 'receipt'
	childTimeoutProof := []ics23.CommitmentProof{
		// iavl proof
		ics23.CommitmentProof_Nonexist{
			Nonexist: &ics23.NonExistenceProof{
				Key: []byte("\x70\x72\x65\x66\x69\x78\x33\x30\x37\x2d\x74\x65\x6e\x64\x65\x72\x6d\x69\x6e\x74\x2d\x39\x39\x02\x00\x00\x00\x00\x00\x00\x00\x01"),
				Left: &ics23.ExistenceProof{
					Key:   []byte("\x50"),
					Value: []byte("\x50"),
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
							Prefix: []byte("\x04\x06\x02\x20"),
							Suffix: []byte("\x20\x79\x8e\x2c\xaa\x96\xfd\xfb\xa3\x76\xdd\xeb\x47\x99\x99\x54\xd2\xf4\x7e\x65\x16\x22\x64\xb0\x53\x6a\xb5\xdf\xf7\xfc\x0a\x2e\x07"),
						},
						{
							Hash:   specs.InnerSpec.Hash,
							Prefix: []byte("\x06\x0a\x02\x20\x9a\xf3\x7d\xd5\x95\xa0\x19\x08\x03\xb5\xe0\x5a\xae\xf4\x2a\xe3\xfa\xd4\x99\xe4\xfb\xe3\x7f\x7c\xd3\x1c\xad\xff\x22\xa9\xee\x74\x20"),
							Suffix: []byte(""),
						},
					},
				},
				Right: &ics23.ExistenceProof{
					Key:   []byte("\x72"),
					Value: []byte("\x72"),
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
							Prefix: []byte("\x02\x04\x02\x20"),
							Suffix: []byte("\x20\xa3\x03\x93\x0c\xa8\x83\x16\x18\xac\x7e\x4d\xdd\x10\x54\x6c\xfc\x36\x6f\xb7\x30\xd6\x63\x0c\x03\x0a\x97\x22\x6b\xbe\xfc\x69\x35"),
						},
						{
							Hash:   specs.InnerSpec.Hash,
							Prefix: []byte("\x04\x06\x02\x20\x35\xf8\xea\x80\x53\x90\xe0\x84\x85\x4f\x39\x9b\x42\xcc\xde\xae\xa3\x3a\x1d\xed\xc1\x15\x63\x8a\xc4\x8d\x06\x00\x63\x7d\xba\x1f\x20"),
							Suffix: []byte(""),
						},
						{
							Hash:   specs.InnerSpec.Hash,
							Prefix: []byte("\x06\x0a\x02\x20\x9a\xf3\x7d\xd5\x95\xa0\x19\x08\x03\xb5\xe0\x5a\xae\xf4\x2a\xe3\xfa\xd4\x99\xe4\xfb\xe3\x7f\x7c\xd3\x1c\xad\xff\x22\xa9\xee\x74\x20"),
							Suffix: []byte(""),
						},
					},
				},
			},
		},
		// rootmulti proof
		ics23.CommitmentProof_Exist{
			Exist: &ics23.ExistenceProof{
				Key:   []byte("\x69\x61\x76\x6c\x53\x74\x6f\x72\x65\x4b\x65\x79"),
				Value: []byte("\x38\x22\xf3\x2f\x21\x66\x53\x63\x29\x4f\x96\xed\xda\x15\xa7\x81\x1a\x67\x6c\x2b\xa9\xdd\xcc\xec\x46\x63\x64\xf1\x00\x69\x82\x7d"),
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
	timeoutPacket := types.MsgTimeout{
		Packet: types.Packet{
			Sequence:          childSeq,
			SourceClient:      clientToC,
			DestinationClient: chainCClientIDForUs,
			TimeoutTimestamp:  sendPacket.TimeoutTimestamp,
			Payloads:          sendPacket.Payloads,
		},
		ProofUnreceived: childTimeoutProof,
		ProofHeight:     msgHeader.GetHeight(),
	}
	timeoutRes := core.Timeout(cross, timeoutPacket)

	println("\ntimeout res:", timeoutRes)
	println("\n----------- parent ack AFTER child timeout (written by mock.OnTimeout)")
	println(core.Render("clients/" + clientToA + "/packet_acknowledgements/1"))
	println("\n----------- child commitment AFTER timeout (cleared)")
	println(core.Render("clients/" + clientToC + "/packet_commitments/1"))
	println("\n----------- app report")
	println(app.Report())
}

// Output:
// recv res: (2 gno.land/p/aib/ibc/types.ResponseResultType)
//
// ----------- parent ack BEFORE child times out (deferred, should not exist)
// {"error":"sequence 1 not found"}
//
// timeout res: (2 gno.land/p/aib/ibc/types.ResponseResultType)
//
// ----------- parent ack AFTER child timeout (written by mock.OnTimeout)
// {"sequence":"1","data":"5HN8pSo727oJNsvAPYWESzo9UNpM5u0nIHMoEOg7WuA="}
//
// ----------- child commitment AFTER timeout (cleared)
// {"error":"sequence 1 not found"}
//
// ----------- app report
// OnSendPacket (1)
// - sourceClient: 07-tendermint-2
// - destinationClient: 07-tendermint-99
// - sequence: 1
// - payload:
//   - sourcePort: appID
//   - destinationPort: appID
//   - version: v1
//   - encoding: application/json
//   - value: {}
//
// OnRecvPacket (1)
// - sourceClient: 07-tendermint-42
// - destinationClient: 07-tendermint-1
// - sequence: 1
// - payload:
//   - sourcePort: appID
//   - destinationPort: appID
//   - version: v1
//   - encoding: application/json
//   - value: {}
//
// OnTimeoutPacket (1)
// - sourceClient: 07-tendermint-2
// - destinationClient: 07-tendermint-99
// - sequence: 1
// - payload:
//   - sourcePort: appID
//   - destinationPort: appID
//   - version: v1
//   - encoding: application/json
//   - value: {}
//
// OnAcknowledgementPacket (0)
