// Package testing provides Arc light client test data recorded from the Arc
// testnet (testnet.gno, written by gno-eth-ibc relayer/cmd/arc-fixtures):
// wire-encoded messages for ethrelay.CreateArcClient and
// ethrelay.UpdateArcClient, and the time at which they verify.
package testing

import "encoding/hex"

func hx(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}
