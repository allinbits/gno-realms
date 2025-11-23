package main

import (
	"time"

	ibctesting "gno.land/p/aib/ibc/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	"gno.land/r/aib/ibc/core"
)

func main() {
	// Acknowledge the packet
	ackPacket := types.MsgAcknowledgement{
		Packet: types.Packet{
			Sequence:          42,                        // XXX update
			SourceClient:      "clientID",                // XXX update
			DestinationClient: "counterPartyID",          // XXX update
			TimeoutTimestamp:  uint64(time.Now().Unix()), // XXX update: must be the same as the timestamp of the send packet
			Payloads: []types.Payload{{
				SourcePort:      "appID",             // XXX update
				DestinationPort: "counterPartyAppID", //XXX update
				Encoding:        "application/json",
				Value:           []byte("{}"), // XXX update
				Version:         "v1",         // XXX update: version of app (transfer uses v1)
			}},
		},
		Acknowledgement: types.Acknowledgement{
			// XXX update: this is the response of the app sent in the RecvPacket
			// response of the counterparty client.
			AppAcknowledgements: [][]byte{[]byte(`{"response":{"result":"BQ=="}}`)},
		},
		// Write the proof of acknowledgement written during the RecvPacket of the
		// counterparty client.
		// XXX update (and good luck for templating this :))
		ProofAcked: []ics23.CommitmentProof{
			ics23.CommitmentProof_Exist{
				// iavl proof
				Exist: ibctesting.NewExistenceProof(ics23.IavlSpec(),
					[]byte("prefix207-tendermint-42\x03\x00\x00\x00\x00\x00\x00\x00\x01"),
					"21293f61ea4291dc3188aa8be6de66eb0ee05b100325b0313b2584f2c09611af",
					"000202",
					[][]string{
						{"0204022035f8ea805390e084854f399b42ccdeaea33a1dedc115638ac48d0600637dba1f20", ""},
						{"04080220", "20798e2caa96fdfba376ddeb47999954d2f47e65162264b0536ab5dff7fc0a2e07"},
						{"060c02209af37dd595a0190803b5e05aaef42ae3fad499e4fbe37f7cd31cadff22a9ee7420", ""},
					},
				),
			},
			ics23.CommitmentProof_Exist{
				// rootmulti proof
				Exist: ibctesting.NewExistenceProof(ics23.IavlSpec(),
					[]byte("iavlStoreKey"), "54676b16cfa5413e302b0dff767d1da811440b383608c7d8ab6a1b3647821f1d",
					"00", nil),
			},
		},
		ProofHeight: types.NewHeight(1, 2000), // XXX update
	}

	res := core.Acknowledgement(cross, ackPacket)

	println(res)
}

// Error:
// client clientID not found
