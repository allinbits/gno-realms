package main

import (
	"chain"
	"chain/runtime"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"

	"gno.land/r/aib/ibc/apps/testing/grc20test"
	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
)

// Transfer: success for non-IBC GRC20 token
func main() {
	var (
		chainID        = "chain-id-2"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	clientID := core.CreateClient(cross, clientState, consensusState)
	core.RegisterCounterparty(cross, clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-2")

	caller := runtime.OriginCaller()

	// Mint test GRC20 tokens to the caller
	grc20test.Mint(cross, caller, 1000)

	// Approve the transfer app realm to spend 100 tokens
	transferAppAddr := chain.PackageAddress("gno.land/r/aib/ibc/apps/transfer")
	grc20test.Approve(cross, caller, transferAppAddr, 100)

	// grc20reg key for the test token (registered with empty slug)
	denom := "gno.land/r/aib/ibc/apps/testing/grc20test." + grc20test.Slug

	println("----------- balance before Transfer:", grc20test.BalanceOf(caller))

	transfer.Transfer(cross, clientID, "atone1user", denom, 100, uint64(time.Now().Add(time.Hour).Unix()), "")

	println("----------- balance after Transfer:", grc20test.BalanceOf(caller))
}

// Output:
// ----------- balance before Transfer: 1000
// ----------- balance after Transfer: 900

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
//     "type": "Transfer",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/aib/ibc/apps/testing/grc20test.TEST"
//       },
//       {
//         "key": "from",
//         "value": ""
//       },
//       {
//         "key": "to",
//         "value": "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm"
//       },
//       {
//         "key": "value",
//         "value": "1000"
//       }
//     ],
//     "pkg_path": "gno.land/p/demo/tokens/grc20"
//   },
//   {
//     "type": "Approval",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/aib/ibc/apps/testing/grc20test.TEST"
//       },
//       {
//         "key": "owner",
//         "value": "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm"
//       },
//       {
//         "key": "spender",
//         "value": "g1tp3gk4quumurav4858hjfdy6hxtyffwmnxyr00"
//       },
//       {
//         "key": "value",
//         "value": "100"
//       }
//     ],
//     "pkg_path": "gno.land/p/demo/tokens/grc20"
//   },
//   {
//     "type": "send_packet",
//     "attrs": [
//       {
//         "key": "packet_source_client",
//         "value": "07-tendermint-1"
//       },
//       {
//         "key": "packet_dest_client",
//         "value": "07-tendermint-2"
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
//         "value": "0801120f30372d74656e6465726d696e742d311a0f30372d74656e6465726d696e742d3220e2a1d8cc042ac0010a087472616e7366657212087472616e736665721a0769637332302d3122166170706c69636174696f6e2f782d70726f746f6275662a88010a4b676e6f2e6c616e64253246722532466169622532466962632532466170707325324674657374696e672532466772633230746573742e6d793a65786f746963253246736c7567253235324612033130301a28673177796d75343764726872306b7571323039386d3739326c797467746a326e797837377972736d220a61746f6e653175736572"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "Transfer",
//     "attrs": [
//       {
//         "key": "token",
//         "value": "gno.land/r/aib/ibc/apps/testing/grc20test.TEST"
//       },
//       {
//         "key": "from",
//         "value": "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm"
//       },
//       {
//         "key": "to",
//         "value": "g1tp3gk4quumurav4858hjfdy6hxtyffwmnxyr00"
//       },
//       {
//         "key": "value",
//         "value": "100"
//       }
//     ],
//     "pkg_path": "gno.land/p/demo/tokens/grc20"
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
//         "value": "atone1user"
//       },
//       {
//         "key": "denom",
//         "value": "gno.land%2Fr%2Faib%2Fibc%2Fapps%2Ftesting%2Fgrc20test.my:exotic%2Fslug%252F"
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
