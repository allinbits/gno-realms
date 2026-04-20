package main

import (
	"testing"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// RecoverClient success: an Expired subject client is recovered using an
// Active substitute. Expiry is simulated by advancing block time past the
// subject's TrustingPeriod via testing.SetContext.
func main() {
	core.SetAdmin(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	core.AddRelayer(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")

	var (
		chainID        = "chain-id-2"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	subjectID := core.CreateClient(cross, clientState, consensusState)

	// Advance block time past the subject's TrustingPeriod so its status
	// becomes Expired.
	ctx := testing.GetContext()
	ctx.Time = time.Now().Add(clientState.TrustingPeriod)
	testing.SetContext(ctx)

	// Substitute is created AFTER the time jump, so its consensus state
	// timestamp (time.Now() = ctx.Time) is fresh relative to the new clock.
	substituteConsState := tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("apphash-sub"), trustedValset.Hash())
	substituteID := core.CreateClient(cross, clientState, substituteConsState)

	println("----------- before recover: subject status")
	println(core.Render("clients/" + subjectID + "/status"))
	println("----------- before recover: substitute status")
	println(core.Render("clients/" + substituteID + "/status"))

	core.RecoverClient(cross, subjectID, substituteID)

	println("----------- after recover: subject status")
	println(core.Render("clients/" + subjectID + "/status"))
}

// Output:
// ----------- before recover: subject status
// {"status":"Expired"}
// ----------- before recover: substitute status
// {"status":"Active"}
// ----------- after recover: subject status
// {"status":"Active"}

// Events:
// [
//   {
//     "type": "create_client",
//     "attrs": [
//       {
//         "key": "client_id",
//         "value": "07-tendermint-1"
//       },
//       {
//         "key": "client_type",
//         "value": "07-tendermint"
//       },
//       {
//         "key": "consensus_heights",
//         "value": "2/2"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "create_client",
//     "attrs": [
//       {
//         "key": "client_id",
//         "value": "07-tendermint-2"
//       },
//       {
//         "key": "client_type",
//         "value": "07-tendermint"
//       },
//       {
//         "key": "consensus_heights",
//         "value": "2/2"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "recover_client",
//     "attrs": [
//       {
//         "key": "subject_client_id",
//         "value": "07-tendermint-1"
//       },
//       {
//         "key": "client_type",
//         "value": "07-tendermint"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   }
// ]
