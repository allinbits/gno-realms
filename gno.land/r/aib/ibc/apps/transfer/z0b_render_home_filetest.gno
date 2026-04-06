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
