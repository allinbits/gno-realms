// PKGPATH: gno.land/r/aib/main
package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/onbloc/json/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// Render the JSON routes showing a client whose chain id carries a control
// character and whose counterparty merkle prefix carries invalid UTF-8, both
// chosen by its creator. The JSON encoder writes them as Go escapes (\x01,
// \xff), which JSON parsers reject; the routes must stay valid JSON.
func main(cur realm) {
	clientState := tmtesting.NewClientState("chain\x01id-2", types.NewHeight(2, 2))
	consensusState := tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("apphash"), tmtesting.GenValset().Hash())
	clientID := core.CreateClient(cross(cur), clientState, consensusState)
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{{'i', 0xff, 'c'}}, "07-tendermint-42")

	for _, path := range []string{"clients", "clients/" + clientID} {
		out := core.Render(path)
		_, err := json.Unmarshal([]byte(out))
		println(path, "-> valid JSON:", err == nil)
		println(out)
	}
}

// Output:
// clients -> valid JSON: true
// {"items":[{"id":"07-tendermint-1","type":"07-tendermint","creator":"g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm","status":"Active","counterparty_client_id":"07-tendermint-42","counterparty_merke_prefix":["i\ufffdc"],"client_state":{"chain_id":"chain\u0001id-2","latest_height":{"revision_number":2,"revision_height":2},"frozen_height":{"revision_number":0,"revision_height":0},"trust_level":{"numerator":1,"denominator":3},"trusting_period":3600,"unbonding_period":10800,"max_clock_drift":3600,"upgrade_path":[]},"last_consensus_state":{"height":{"revision_number":2,"revision_height":2},"timestamp":1234567890,"root":"EGkBgr/gwNYq9XkPLS+UWQksRtpw/yCAIRjy3KjUlI8=","next_validators_hash":"/9gNNzK6IBcVWTwBsskTrrKk/SQzd29h1wP8LYFJbKo="}}],"page":1,"total":1}
// clients/07-tendermint-1 -> valid JSON: true
// {"id":"07-tendermint-1","type":"07-tendermint","creator":"g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm","status":"Active","counterparty_client_id":"07-tendermint-42","counterparty_merke_prefix":["i\ufffdc"],"client_state":{"chain_id":"chain\u0001id-2","latest_height":{"revision_number":2,"revision_height":2},"frozen_height":{"revision_number":0,"revision_height":0},"trust_level":{"numerator":1,"denominator":3},"trusting_period":3600,"unbonding_period":10800,"max_clock_drift":3600,"upgrade_path":[]},"last_consensus_state":{"height":{"revision_number":2,"revision_height":2},"timestamp":1234567890,"root":"EGkBgr/gwNYq9XkPLS+UWQksRtpw/yCAIRjy3KjUlI8=","next_validators_hash":"/9gNNzK6IBcVWTwBsskTrrKk/SQzd29h1wP8LYFJbKo="}}
