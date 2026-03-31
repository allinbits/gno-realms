package main

import "gno.land/r/aib/ibc/apps/transfer"

func main() {
	println(transfer.Render(""))
}

// Output:
// # IBC transfer
//
// ICS-20 style transfer state and voucher token queries.
//
// ## Dashboard
//
// - Known IBC denoms: `0`
// - Escrow denoms: `0`
// - Voucher GRC20 tokens: `0`
//
// ## Endpoints
//
// - [`denoms`](/r/aib/ibc/apps/transfer:denoms): list known IBC denoms (`?page`, `?limit`)
// - `denoms/ibc/{hash}`: get metadata for an IBC denom
// - `total_escrow/{denom}`: get total escrow tracked for a base denom
// - `grc20/ibc/{hash}`: get GRC20 voucher token metadata
// - `grc20/ibc/{hash}/balance/{addr}`: get a GRC20 voucher balance for an address
//
// ## Known denoms
//
// No denom traces yet. Receive an IBC voucher, then refresh this page.
