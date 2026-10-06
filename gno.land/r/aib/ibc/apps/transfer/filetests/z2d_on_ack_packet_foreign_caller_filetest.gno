// PKGPATH: gno.land/r/aib/main
package main

// OnAcknowledgementPacket: fails because the caller is not the IBC core realm.
//
// With the sentinel error acknowledgement the refund path would otherwise
// release escrowed coins to the attacker-chosen Sender.

import (
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

func main(cur realm) {
	data := transfer.NewFungibleTokenPacketData("ugnot", "1000", "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm", "atone1user", "")
	payload := types.Payload{
		SourcePort:      transfer.PortID,
		DestinationPort: transfer.PortID,
		Encoding:        transfer.EncodingProtobuf,
		Value:           data.ProtoMarshal(),
		Version:         transfer.V1,
	}
	var app transfer.App
	app.OnAcknowledgementPacket(cross(cur), "07-tendermint-1", "07-tendermint-42", 1, types.UniversalErrorAcknowledgement(), payload)
}

// Error:
// transfer: callback must be invoked by gno.land/r/aib/ibc/core, got gno.land/r/aib/main
