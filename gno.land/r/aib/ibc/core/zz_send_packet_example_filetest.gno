package main

import (
	"chain/banker"

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
		banker = banker.NewBanker(banker.BankerTypeOriginSend)
	)

	sequence := core.SendPacket(cross, banker, packet)

	println(sequence)
}

// Error:
// validate client identifier: identifier cannot be blank
