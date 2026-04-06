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
// ## Clients (1)
//
// | Client | St. | Creator | Cpty | Height | CS | Seq | Cmts | Rcpts | Acks |
// |--------|-----|---------|------|--------|----|-----|------|-------|------|
// | [`07-tendermint-1`](/r/aib/ibc/core:clients/07-tendermint-1) | [Active](/r/aib/ibc/core:clients/07-tendermint-1/status) | [g1wymu…yrsm](/u/g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm) |  | [2/2](/r/aib/ibc/core:clients/07-tendermint-1/consensus_states/2/2) | [1](/r/aib/ibc/core:clients/07-tendermint-1/consensus_states) | [1](/r/aib/ibc/core:clients/07-tendermint-1/next_sequence_send) | [0](/r/aib/ibc/core:clients/07-tendermint-1/packet_commitments) | [0](/r/aib/ibc/core:clients/07-tendermint-1/packet_receipts) | [0](/r/aib/ibc/core:clients/07-tendermint-1/packet_acknowledgements) |
//
// ## Apps (0)
//
// No apps registered yet.
//
// ## JSON endpoints
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
