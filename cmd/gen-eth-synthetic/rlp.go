package main

// RLP encoding (Ethereum yellow paper, appendix B) and the execution block
// header layout through Prague/Osaka (EIP-1559, -4895, -4844, -4788, -7685).

import "golang.org/x/crypto/sha3"

func keccak(b []byte) []byte {
	h := sha3.NewLegacyKeccak256()
	h.Write(b)
	return h.Sum(nil)
}

func rlpLen(prefix byte, n int) []byte {
	if n < 56 {
		return []byte{prefix + byte(n)}
	}
	var be []byte
	for x := n; x > 0; x >>= 8 {
		be = append([]byte{byte(x)}, be...)
	}
	return append([]byte{prefix + 55 + byte(len(be))}, be...)
}

func rlpBytes(b []byte) []byte {
	if len(b) == 1 && b[0] < 0x80 {
		return []byte{b[0]}
	}
	return append(rlpLen(0x80, len(b)), b...)
}

func rlpUint(v uint64) []byte {
	var be []byte
	for ; v > 0; v >>= 8 {
		be = append([]byte{byte(v)}, be...)
	}
	return rlpBytes(be)
}

func rlpList(items ...[]byte) []byte {
	var p []byte
	for _, it := range items {
		p = append(p, it...)
	}
	return append(rlpLen(0xc0, len(p)), p...)
}

// executionHeader is a post-Prague execution block header.
type executionHeader struct {
	ParentHash, OmmersHash, Coinbase, StateRoot, TxRoot, ReceiptsRoot []byte
	Bloom                                                             []byte
	Number, GasLimit, GasUsed, Time                                   uint64
	Extra, MixDigest                                                  []byte
	Nonce                                                             []byte // 8 bytes
	BaseFee                                                           uint64
	WithdrawalsRoot                                                   []byte
	BlobGasUsed, ExcessBlobGas                                        uint64
	ParentBeaconRoot, RequestsHash                                    []byte
}

func (h executionHeader) rlp() []byte {
	return rlpList(
		rlpBytes(h.ParentHash), rlpBytes(h.OmmersHash), rlpBytes(h.Coinbase), rlpBytes(h.StateRoot),
		rlpBytes(h.TxRoot), rlpBytes(h.ReceiptsRoot), rlpBytes(h.Bloom),
		rlpUint(0), // difficulty, zero since the merge
		rlpUint(h.Number), rlpUint(h.GasLimit), rlpUint(h.GasUsed), rlpUint(h.Time),
		rlpBytes(h.Extra), rlpBytes(h.MixDigest), rlpBytes(h.Nonce),
		rlpUint(h.BaseFee), rlpBytes(h.WithdrawalsRoot),
		rlpUint(h.BlobGasUsed), rlpUint(h.ExcessBlobGas),
		rlpBytes(h.ParentBeaconRoot), rlpBytes(h.RequestsHash),
	)
}
