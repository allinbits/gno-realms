package main

import (
	"chain/banker"
	"encoding/hex"

	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

func hexDec(s string) []byte {
  b, err := hex.DecodeString(s)
  if err != nil { panic(err) }
  return b
}
func main() {
	var (
		packet = types.MsgSendPacket{
			SourceClient:     "07-tendermint-1",        // XXX update
			TimeoutTimestamp: uint64(1765192166), // XXX update
			Payloads: []types.Payload{
				{
					SourcePort:      "transfer",           // XXX update
					DestinationPort: "transfer",           // XXX update
					Encoding:        "application/x-protobuf",           // XXX update
					Value:           hexDec("0a0575676e6f74120231301a2867317a34333764707568357334703634767471303964756c67366a7a787072326864347138723578222c61746f6e65317a34333764707568357334703634767471303964756c67366a7a7870723268646775383872362a07474e4f20494243"),
					Version:         "ics20-1",           // XXX update
				},
			},
		}
		banker = banker.NewBanker(banker.BankerTypeOriginSend)
	)

	sequence := core.SendPacket(cross, banker, packet)

	println(sequence)
}
