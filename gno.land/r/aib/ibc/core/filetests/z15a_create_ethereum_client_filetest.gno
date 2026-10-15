// PKGPATH: gno.land/r/aib/main
package main

import (
	"encoding/hex"

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

func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	core.AddRelayer(cross(cur), "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")

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
	id := core.CreateClient(cross(cur), clientState, consensusState)
	println(id)

	// Packets on this client carry their proof in Ext; an ICS23 proof is
	// refused before any verification.
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, "client-0")
	core.RecvPacket(cross(cur), types.MsgRecvPacket{
		Packet: types.Packet{
			Sequence: 1, SourceClient: "client-0", DestinationClient: id, TimeoutTimestamp: 1761903000,
			Payloads: []types.Payload{{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: "application/json", Value: []byte("{}")}},
		},
		ProofHeight: types.NewHeight(0, 72),
		Ext:         extproof.Proof{Data: ethereum.MembershipProof{}},
	})
}

// Output:
// ethereum-1

// Error:
// failed packet commitment verification for client (ethereum-1): account proof: mpt: proof is missing a node
