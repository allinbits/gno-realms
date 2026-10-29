// PKGPATH: gno.land/r/aib/main
package main

import (
	"encoding/hex"
	"testing"

	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/lightclient/extproof/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

func h(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

func fork(v byte, epoch uint64) ethereum.Fork {
	return ethereum.Fork{Version: [4]byte{v, 0, 0, 0x38}, Epoch: epoch}
}

func newEthereumClient(cur realm) string {
	// The initial state of the solidity-ibc-eureka ERC20 transfer fixture.
	clientState := ethereum.ClientState{
		ChainID:                      3151908,
		GenesisValidatorsRoot:        h("d1ec305b97bf6336571c2348e4a8bf173684b0cdb7e55f7e6554d51f8478b5a3"),
		MinSyncCommitteeParticipants: 11,
		SyncCommitteeSize:            32,
		GenesisTime:                  1761902227,
		ForkParameters: ethereum.ForkParameters{
			GenesisForkVersion: [4]byte{0x10, 0, 0, 0x38},
			Altair:             fork(0x20, 0), Bellatrix: fork(0x30, 0), Capella: fork(0x40, 0),
			Deneb: fork(0x50, 0), Electra: fork(0x60, 0), Fulu: fork(0x70, 1),
			Gloas: ethereum.Fork{Epoch: ethereum.FarFutureEpoch},
		},
		SecondsPerSlot:               2,
		SlotsPerEpoch:                8,
		EpochsPerSyncCommitteePeriod: 8,
		LatestSlot:                   72,
		LatestExecutionBlockNumber:   72,
		IBCContractAddress:           h("1d95d544586eacb63b6154e9e45122b32ded11aa"),
		IBCCommitmentSlot:            h("1260944489272988d9df285149b5aa1b0f48f2136d6f416159f840a3e0747600"),
	}
	consensusState := ethereum.ConsensusState{
		Slot:      72,
		StateRoot: h("ab894d09789860d5ba3342f61eb77f681649d02252cc1c0260fc0ef379950481"),
		Timestamp: 1761902371,
		CurrentSyncCommittee: ethereum.SummarizedSyncCommittee{
			PubkeysHash:     h("22a9ff086ca3c4854ad0628c816a15fc8718d7efc9b293af2a5ac71d54b4b14f"),
			AggregatePubkey: h("b9287865303bf481aa80d7f250127bb0b22819ff681a02262680d31e7134fb5317f5531c5f84244641b692eef1bd151c"),
		},
	}
	return core.CreateClient(cross(cur), clientState, consensusState)
}

// ADR pr6375 R17: relaying for an Ethereum client is permissionless. With the
// whitelist naming another relayer, this signer's update, receive,
// acknowledgement and timeout on an Ethereum client all pass the relayer gate
// and fail only on their proofs; the whitelist still applies to creating a
// client.
func main(cur realm) {
	// Create the client while the whitelist is empty, then list another relayer.
	id := newEthereumClient(cur)
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, "client-0")
	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath))
	core.AddRelayer(cross(cur), "g1relayer000000000000000000000000000000")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))

	payload := types.Payload{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: "application/json", Value: []byte("{}")}
	println("update:", revive(func() {
		core.UpdateClient(cross(cur), id, &ethereum.Header{})
	}))
	println("recv:", revive(func() {
		core.RecvPacket(cross(cur), types.MsgRecvPacket{
			Packet:      types.Packet{Sequence: 1, SourceClient: "client-0", DestinationClient: id, TimeoutTimestamp: 1761903000, Payloads: []types.Payload{payload}},
			ProofHeight: types.NewHeight(0, 72),
			Ext:         extproof.Proof{Data: ethereum.MembershipProof{}},
		})
	}))
	println("ack:", revive(func() {
		core.Acknowledgement(cross(cur), types.MsgAcknowledgement{
			Packet:          types.Packet{Sequence: 1, SourceClient: id, DestinationClient: "client-0", TimeoutTimestamp: 1761903000, Payloads: []types.Payload{payload}},
			Acknowledgement: types.Acknowledgement{AppAcknowledgements: [][]byte{[]byte("ok")}},
			ProofHeight:     types.NewHeight(0, 72),
			Ext:             extproof.Proof{Data: ethereum.MembershipProof{}},
		})
	}))
	println("timeout:", revive(func() {
		core.Timeout(cross(cur), types.MsgTimeout{
			Packet:      types.Packet{Sequence: 1, SourceClient: id, DestinationClient: "client-0", TimeoutTimestamp: 1761903000, Payloads: []types.Payload{payload}},
			ProofHeight: types.NewHeight(0, 72),
			Ext:         extproof.Proof{Data: ethereum.MembershipProof{}},
		})
	}))
	// Creating a client still needs a listed relayer.
	println("create:", revive(func() { newEthereumClient(cur) }))
}

// Output:
// update: sync committee signature must be 96 bytes
// recv: failed packet commitment verification for client (ethereum-1): account proof: mpt: proof is missing a node
// ack: undefined
// timeout: proof timestamp: 1761902371, timeout timestamp: 1761903000
// create: unauthorized relayer g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm
