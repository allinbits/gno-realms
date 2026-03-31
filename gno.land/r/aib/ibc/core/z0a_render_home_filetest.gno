package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

func main() {
	var (
		chainID        = "chain-id-2"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	core.CreateClient(cross, clientState, consensusState)

	println(core.Render(""))
}

// Output:
// # IBC core
//
// IBC v2 core state and query endpoints.
//
// ## Dashboard
//
// - Registered apps: `0`
// - Clients: `1`
//
// ## Endpoints
//
// - [`apps`](/r/aib/ibc/core:apps): list registered IBC applications
// - [`clients`](/r/aib/ibc/core:clients): list clients (`?page`, `?limit`)
// - `clients/{id}`: get client details
// - `clients/{id}/status`: get client status
// - `clients/{id}/consensus_states`: list client consensus states (`?page`, `?limit`)
// - `clients/{id}/consensus_states/{revision_number}/{revision_height}`: get a consensus state by height
// - `clients/{id}/next_sequence_send`: get the next packet sequence to send
// - `clients/{id}/packet_commitments`: list packet commitments (`?page`, `?limit`)
// - `clients/{id}/packet_commitments/{sequence}`: get a packet commitment by sequence
// - `clients/{id}/packet_receipts`: list packet receipts (`?page`, `?limit`)
// - `clients/{id}/packet_receipts/{sequence}`: get a packet receipt by sequence
// - `clients/{id}/packet_acknowledgements`: list packet acknowledgements (`?page`, `?limit`)
// - `clients/{id}/packet_acknowledgements/{sequence}`: get a packet acknowledgement by sequence
// - `clients/{id}/unreceived_packets?sequences=1,2,3`: return sequences without a local packet receipt
//
// ## Known clients
//
// - `07-tendermint-1`: [details](/r/aib/ibc/core:clients/07-tendermint-1) | [status](/r/aib/ibc/core:clients/07-tendermint-1/status) | [consensus states](/r/aib/ibc/core:clients/07-tendermint-1/consensus_states) | [next sequence](/r/aib/ibc/core:clients/07-tendermint-1/next_sequence_send) | [commitments](/r/aib/ibc/core:clients/07-tendermint-1/packet_commitments) | [receipts](/r/aib/ibc/core:clients/07-tendermint-1/packet_receipts) | [acks](/r/aib/ibc/core:clients/07-tendermint-1/packet_acknowledgements)
