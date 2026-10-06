// PKGPATH: gno.land/r/aib/main
package main

// OnTimeoutPacket: fails because the caller is not the IBC core realm.
//
// The refund path would otherwise release escrowed native coins to the
// attacker-chosen Sender, bounded only by the per-client escrow accounting.

import (
	"gno.land/p/aib/ibc/ics20/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v0"
)

func main(cur realm) {
	data := ics20.NewFungibleTokenPacketData("ugnot", "1000", "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm", "atone1user", "")
	payload := types.Payload{
		SourcePort:      transfer.PortID,
		DestinationPort: transfer.PortID,
		Encoding:        transfer.EncodingProtobuf,
		Value:           data.ProtoMarshal(),
		Version:         transfer.V1,
	}
	var app transfer.App
	app.OnTimeoutPacket(cross(cur), "07-tendermint-1", "07-tendermint-42", 1, payload)
}

// Error:
// transfer: callback must be invoked by gno.land/r/aib/ibc/core, got gno.land/r/aib/main
