package main

import (
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

func main() {
	var (
		packet = types.MsgSendPacket{
			SourceClient:     "",        // XXX update
			TimeoutTimestamp: uint64(0), // XXX update
			Payloads: []types.Payload{
				{
					SourcePort:      "",           // XXX update
					DestinationPort: "",           // XXX update
					Encoding:        "",           // XXX update
					Value:           []byte("{}"), // XXX update
					Version:         "",           // XXX update
				},
			},
		}
	)

	sequence := core.SendPacket(cross, packet)

	println(sequence)
}

// Error:
// validate client identifier: identifier cannot be blank
