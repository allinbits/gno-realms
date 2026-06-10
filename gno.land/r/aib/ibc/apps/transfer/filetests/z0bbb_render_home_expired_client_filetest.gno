// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"

	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
)

// renderHome with a non-active (Expired) client: confirms the Transfer section
// still lists the client with its status and trusted height, but omits the
// "send via" txlink since packets can't be sent through it. The client is
// created Active, then block time is advanced past the trusting period to
// expire it.
func main(cur realm) {
	var (
		chainID        = "chain-id-2"
		clientState    = tmtesting.NewClientState(chainID, types.NewHeight(2, 2))
		apphash        = tmtesting.Hash("apphash")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
	)
	clientID := core.CreateClient(cross(cur), clientState, consensusState)
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-2")

	// Advance block time past the trusting period to expire the client.
	ctx := testing.GetContext()
	ctx.Time = time.Now().Add(clientState.TrustingPeriod)
	testing.SetContext(ctx)

	println(transfer.Render(""))
}

// Output:
// # IBC transfer
//
// ICS-20 style transfer state and voucher token queries.
//
// ## Transfer
//
// Trigger an IBC transfer from your wallet. Pick the client of the destination chain:
//
// - `07-tendermint-1` — Expired, trusted height `2/2` ([client details](/r/aib/ibc/core:clients/07-tendermint-1))
//
// ## Vouchers (0)
//
// No vouchers yet.
//
// ## Escrow (0)
//
// No escrow yet.
//
// ## JSON endpoints
//
// - [`denoms`](/r/aib/ibc/apps/transfer:denoms): list known IBC denoms (`?page`, `?limit`)
// - `denoms/ibc/{hash}`: get metadata for an IBC denom
// - `total_escrow/{denom}`: get total escrow tracked for a base denom
// - [`vouchers`](/r/aib/ibc/apps/transfer:vouchers): list voucher tokens (`?page`, `?limit`)
// - `voucher/ibc/{hash}`: get voucher token metadata
// - `voucher/ibc/{hash}/balance/{addr}`: get a voucher balance for an address
