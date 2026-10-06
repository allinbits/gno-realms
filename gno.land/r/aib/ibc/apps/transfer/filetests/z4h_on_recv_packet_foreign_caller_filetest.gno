// PKGPATH: gno.land/r/aib/main
package main

// OnRecvPacket: fails because the caller is not the IBC core realm.
//
// The App callbacks are exported methods and a zero-value transfer.App needs no
// composite literal, so any realm can reach them. Without the core-caller gate
// this call minted 1000 vouchers to an arbitrary address with no proof and no
// core involvement.

import (
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/apps/transfer"
)

func main(cur realm) {
	data := transfer.NewFungibleTokenPacketData("uatom", "1000", "atone1user", "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm", "")
	payload := types.Payload{
		SourcePort:      transfer.PortID,
		DestinationPort: transfer.PortID,
		Encoding:        transfer.EncodingProtobuf,
		Value:           data.ProtoMarshal(),
		Version:         transfer.V1,
	}
	var app transfer.App
	app.OnRecvPacket(cross(cur), "07-tendermint-42", "07-tendermint-1", 1, payload)
}

// Error:
// transfer: callback must be invoked by gno.land/r/aib/ibc/core, got gno.land/r/aib/main
