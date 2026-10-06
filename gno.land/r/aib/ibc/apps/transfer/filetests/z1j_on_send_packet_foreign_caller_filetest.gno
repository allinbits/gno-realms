// PKGPATH: gno.land/r/aib/main
package main

// OnSendPacket: fails because the caller is not the IBC core realm.
//
// OnSendPacket was already protected by the pending-send slots that only
// transfer.Transfer fills, but it now rejects a foreign caller up front like
// the other callbacks, so the four entry points share one gate.

import (
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/apps/transfer"
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
	app.OnSendPacket(cross(cur), "07-tendermint-1", "07-tendermint-42", 1, payload)
}

// Error:
// transfer: callback must be invoked by gno.land/r/aib/ibc/core, got gno.land/r/aib/main
