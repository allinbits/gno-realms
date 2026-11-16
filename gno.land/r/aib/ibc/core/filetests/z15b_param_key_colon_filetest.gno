// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain/params"

	"gno.land/p/aib/ibc/host/v0"
)

// Packet keys end in the big-endian sequence, which contains ':' (0x3a) for
// sequence 58. The chain must accept such keys, or the 58th packet on a
// client can never be committed.
func main() {
	for _, seq := range []uint64{57, 58, 0x3a3a} {
		params.SetBytes(string(host.PacketCommitmentKey("07-tendermint-1", seq)), []byte{1})
		println(seq, "ok")
	}
}

// Output:
// 57 ok
// 58 ok
// 14906 ok
