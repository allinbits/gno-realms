// PKGPATH: gno.land/r/aib/main
package main

import (
	"encoding/hex"
	"testing"
	"time"

	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
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

// RetireClient (ADR pr6375 §7.12, R18): a governance decision retires a
// client for good; every later packet message, update and registration naming
// it is refused, whatever its verifier says.
func main(cur realm) {
	id := newEthereumClient(cur)
	core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, "client-0")

	println("not governance:", revive(func() {
		core.RetireClient(cross(cur), id)
	}))

	testing.SetRealm(testing.NewCodeRealm(core.IBCGovPath))
	core.RetireClient(cross(cur), id)
	println("retired:", core.IsClientRetired(id), "status:", core.ClientStatus(id))
	println("again:", revive(func() {
		core.RetireClient(cross(cur), id)
	}))
	println("unknown:", revive(func() {
		core.RetireClient(cross(cur), "ethereum-99")
	}))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))

	println("send:", revive(func() {
		core.SendPacket(cross(cur), types.MsgSendPacket{
			SourceClient:     id,
			TimeoutTimestamp: uint64(time.Now().Add(time.Hour).Unix()),
			Payloads:         []types.Payload{{SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1", Encoding: "application/json", Value: []byte("{}")}},
		})
	}))
	println("update:", revive(func() {
		core.UpdateClient(cross(cur), id, &ethereum.Header{})
	}))
	println("recv:", revive(func() {
		core.RecvPacket(cross(cur), types.MsgRecvPacket{Packet: types.Packet{DestinationClient: id}})
	}))
	println("ack:", revive(func() {
		core.Acknowledgement(cross(cur), types.MsgAcknowledgement{Packet: types.Packet{SourceClient: id}})
	}))
	println("timeout:", revive(func() {
		core.Timeout(cross(cur), types.MsgTimeout{Packet: types.Packet{SourceClient: id}})
	}))
	println("register:", revive(func() {
		core.RegisterCounterparty(cross(cur), id, [][]byte{{}}, "client-1")
	}))
}

// Output:
// not governance: retire_client: only gno.land/r/aib/ibc/ibcgov decides this, not gno.land/r/aib/main
// retired: true status: Active
// again: client ethereum-1 is retired already
// unknown: client ethereum-99 not found
// send: client ethereum-1 is retired
// update: client ethereum-1 is retired
// recv: client ethereum-1 is retired
// ack: client ethereum-1 is retired
// timeout: client ethereum-1 is retired
// register: client ethereum-1 is retired
