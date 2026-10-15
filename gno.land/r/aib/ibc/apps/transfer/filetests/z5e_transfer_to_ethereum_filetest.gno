// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"
	"encoding/hex"
	"testing"
	"time"

	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
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

// Transfer over an Ethereum client: the payload is ABI-encoded, the only
// encoding the Solidity ICS20 application reads.
func main(cur realm) {
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
		// Just before the filetest clock: SendPacket requires the timeout to
		// follow the counterparty's latest timestamp.
		Timestamp: 1234567800,
		CurrentSyncCommittee: ethereum.SummarizedSyncCommittee{
			PubkeysHash:     h("22a9ff086ca3c4854ad0628c816a15fc8718d7efc9b293af2a5ac71d54b4b14f"),
			AggregatePubkey: h("b9287865303bf481aa80d7f250127bb0b22819ff681a02262680d31e7134fb5317f5531c5f84244641b692eef1bd151c"),
		},
	}
	clientID := core.CreateClient(cross(cur), clientState, consensusState)
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{{}}, "client-0")

	testing.SetRealm(testing.NewUserRealm("g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm"))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 100)))

	transfer.Transfer(cross(cur), clientID, "0x5f67a5398d91087d1b37a8a43436196a7830867f", "ugnot", 100,
		uint64(time.Now().Add(time.Hour).Unix()), "")

	println(transfer.Render("total_escrow/ugnot"))
}

// Output:
// {"denom":"ugnot","amount":100,"clients":[{"client":"ethereum-1","amount":100}]}

// Events:
// [
//   {
//     "type": "create_client",
//     "attrs": [
//       {
//         "key": "client_id",
//         "value": "ethereum-1"
//       },
//       {
//         "key": "client_type",
//         "value": "ethereum"
//       },
//       {
//         "key": "consensus_heights",
//         "value": "0/72"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "send_packet",
//     "attrs": [
//       {
//         "key": "packet_source_client",
//         "value": "ethereum-1"
//       },
//       {
//         "key": "packet_dest_client",
//         "value": "client-0"
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
//         "value": "0801120a657468657265756d2d311a08636c69656e742d3020e2a1d8cc042a9c040a087472616e7366657212087472616e736665721a0769637332302d31221a6170706c69636174696f6e2f782d736f6c69646974792d6162692ae003000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000000000000000000000000000000000006400000000000000000000000000000000000000000000000000000000000001a0000000000000000000000000000000000000000000000000000000000000000575676e6f740000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000028673177796d75343764726872306b7571323039386d3739326c797467746a326e797837377972736d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002a307835663637613533393864393130383764316233376138613433343336313936613738333038363766000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "ibc_transfer",
//     "attrs": [
//       {
//         "key": "sender",
//         "value": "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm"
//       },
//       {
//         "key": "receiver",
//         "value": "0x5f67a5398d91087d1b37a8a43436196a7830867f"
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
//   }
// ]
