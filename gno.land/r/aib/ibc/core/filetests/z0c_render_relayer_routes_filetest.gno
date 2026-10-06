// PKGPATH: gno.land/r/aib/main
package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// Compatibility contract. The ts-relayer reads these routes through
// vm/qrender and parses their JSON (clients/{id}, consensus states, packet
// commitments and receipts); tooling reads the others. Render is served by
// the implementation, so a change in this golden output means a change every
// consumer must follow, and a relayer release for the routes it reads.
func main(cur realm) {
	clientID := core.CreateClient(cross(cur),
		tmtesting.NewClientState("chainA-2", types.NewHeight(2, 2)),
		tmtesting.GenConsensusState(time.Now(), []byte("apphash"), tmtesting.GenValset().Hash()),
	)
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{[]byte("ibc")}, "07-tendermint-42")
	core.RegisterApp(cross(cur), "appID", appstesting.NewApp(cross(cur)))
	core.SendPacket(cross(cur), types.MsgSendPacket{
		SourceClient:     clientID,
		TimeoutTimestamp: uint64(time.Now().Add(time.Hour).Unix()),
		Payloads: []types.Payload{{
			SourcePort:      "appID",
			DestinationPort: "appID",
			Encoding:        "application/json",
			Value:           []byte("{}"),
			Version:         "v1",
		}},
	})

	for _, route := range []string{
		"clients",
		"clients/" + clientID,
		"clients/" + clientID + "/status",
		"clients/" + clientID + "/consensus_states",
		"clients/" + clientID + "/consensus_states/2/2",
		"clients/" + clientID + "/next_sequence_send",
		"clients/" + clientID + "/packet_commitments",
		"clients/" + clientID + "/packet_commitments/1",
		"clients/" + clientID + "/packet_receipts",
		"clients/" + clientID + "/packet_receipts/1",
		"clients/" + clientID + "/packet_acknowledgements",
		"clients/" + clientID + "/unreceived_packets?sequences=1,2",
		"apps",
		"apps/pending",
	} {
		println("--- " + route)
		println(core.Render(route))
	}
}

// Output:
// --- clients
// {"items":[{"id":"07-tendermint-1","type":"07-tendermint","creator":"g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm","status":"Active","counterparty_client_id":"07-tendermint-42","counterparty_merke_prefix":["ibc"],"client_state":{"chain_id":"chainA-2","latest_height":{"revision_number":2,"revision_height":2},"frozen_height":{"revision_number":0,"revision_height":0},"trust_level":{"numerator":1,"denominator":3},"trusting_period":3600,"unbonding_period":10800,"max_clock_drift":3600,"upgrade_path":[]},"last_consensus_state":{"height":{"revision_number":2,"revision_height":2},"timestamp":1234567890,"root":"YXBwaGFzaA==","next_validators_hash":"/9gNNzK6IBcVWTwBsskTrrKk/SQzd29h1wP8LYFJbKo="}}],"page":1,"total":1}
// --- clients/07-tendermint-1
// {"id":"07-tendermint-1","type":"07-tendermint","creator":"g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm","status":"Active","counterparty_client_id":"07-tendermint-42","counterparty_merke_prefix":["ibc"],"client_state":{"chain_id":"chainA-2","latest_height":{"revision_number":2,"revision_height":2},"frozen_height":{"revision_number":0,"revision_height":0},"trust_level":{"numerator":1,"denominator":3},"trusting_period":3600,"unbonding_period":10800,"max_clock_drift":3600,"upgrade_path":[]},"last_consensus_state":{"height":{"revision_number":2,"revision_height":2},"timestamp":1234567890,"root":"YXBwaGFzaA==","next_validators_hash":"/9gNNzK6IBcVWTwBsskTrrKk/SQzd29h1wP8LYFJbKo="}}
// --- clients/07-tendermint-1/status
// {"status":"Active"}
// --- clients/07-tendermint-1/consensus_states
// {"items":[{"height":{"revision_number":2,"revision_height":2},"timestamp":1234567890,"root":"YXBwaGFzaA==","next_validators_hash":"/9gNNzK6IBcVWTwBsskTrrKk/SQzd29h1wP8LYFJbKo="}],"page":1,"total":1}
// --- clients/07-tendermint-1/consensus_states/2/2
// {"height":{"revision_number":2,"revision_height":2},"timestamp":1234567890,"root":"YXBwaGFzaA==","next_validators_hash":"/9gNNzK6IBcVWTwBsskTrrKk/SQzd29h1wP8LYFJbKo="}
// --- clients/07-tendermint-1/next_sequence_send
// {"next_sequence_send": 2}"
// --- clients/07-tendermint-1/packet_commitments
// {"items":[{"sequence":"1","data":"AmCMHo+FFzRMDItBW4xA5xUsjGfABbv4PuObJ6W8G10="}],"page":1,"total":1}
// --- clients/07-tendermint-1/packet_commitments/1
// {"sequence":"1","data":"AmCMHo+FFzRMDItBW4xA5xUsjGfABbv4PuObJ6W8G10="}
// --- clients/07-tendermint-1/packet_receipts
// {"items":[],"page":1,"total":1}
// --- clients/07-tendermint-1/packet_receipts/1
// {"error":"sequence 1 not found"}
// --- clients/07-tendermint-1/packet_acknowledgements
// {"items":[],"page":1,"total":1}
// --- clients/07-tendermint-1/unreceived_packets?sequences=1,2
// {"height":{"revision_number":0,"revision_height":123},"unreceived_sequences":["1","2"]}
// --- apps
// [{"port_id":"appID","pkg_path":"gno.land/r/aib/main","address":"g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9","paused":false}]
// --- apps/pending
// {"total":0,"pending":[]}
