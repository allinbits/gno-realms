// PKGPATH: gno.land/r/aib/main
package main

import (
	"strings"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

const (
	// The client creator chooses the chain id and the counterparty merkle
	// prefix; both are stored as is.
	chainID = "[send](&#47;r&#47;evil$help&func=Send)-1"
	prefix  = "[claim](https://evil.example/phish)"
)

// Render the JSON routes showing a client whose chain id and counterparty
// merkle prefix carry markdown, and the errors echoing markdown from the URL.
// The routes escape markdown in their string values (gnoweb renders them as
// markdown), and the values decode unchanged.
func main(cur realm) {
	clientState := tmtesting.NewClientState(chainID, types.NewHeight(1, 2))
	consensusState := tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("apphash"), tmtesting.GenValset().Hash())
	clientID := core.CreateClient(cross(cur), clientState, consensusState)
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{[]byte(prefix)}, "07-tendermint-42")

	for _, path := range []string{
		"clients/" + clientID,
		"clients/[x](&#47;r&#47;evil)",
		"clients/" + clientID + "/unreceived_packets?sequences=%5Bx%5D(https://evil.example/phish)",
	} {
		out := core.Render(path)
		raw := strings.Contains(out, "[send]") || strings.Contains(out, "[claim]") ||
			strings.Contains(out, "[x]") || strings.Contains(out, "&#47;")
		println(path, "-> raw markdown:", raw)
		println(out)
	}
}

// Output:
// clients/07-tendermint-1 -> raw markdown: false
// {"id":"07-tendermint-1","type":"07-tendermint","creator":"g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm","status":"Active","counterparty_client_id":"07-tendermint-42","counterparty_merke_prefix":["\u005bclaim\u005d\u0028https://evil.example/phish\u0029"],"client_state":{"chain_id":"\u005bsend\u005d\u0028\u0026\u002347;r\u0026\u002347;evil\u0024help\u0026func=Send\u0029-1","latest_height":{"revision_number":1,"revision_height":2},"frozen_height":{"revision_number":0,"revision_height":0},"trust_level":{"numerator":1,"denominator":3},"trusting_period":3600,"unbonding_period":10800,"max_clock_drift":3600,"upgrade_path":[]},"last_consensus_state":{"height":{"revision_number":1,"revision_height":2},"timestamp":1234567890,"root":"EGkBgr/gwNYq9XkPLS+UWQksRtpw/yCAIRjy3KjUlI8=","next_validators_hash":"/9gNNzK6IBcVWTwBsskTrrKk/SQzd29h1wP8LYFJbKo="}}
// clients/[x](&#47;r&#47;evil) -> raw markdown: false
// {"error":"client \u005bx\u005d\u0028\u0026\u002347;r\u0026\u002347;evil\u0029 not found"}
// clients/07-tendermint-1/unreceived_packets?sequences=%5Bx%5D(https://evil.example/phish) -> raw markdown: false
// {"error":"invalid sequence \"\u005bx\u005d\u0028https://evil.example/phish\u0029\": strconv.ParseUint: parsing \"\u005bx\u005d\u0028https://evil.example/phish\u0029\": invalid syntax"}
