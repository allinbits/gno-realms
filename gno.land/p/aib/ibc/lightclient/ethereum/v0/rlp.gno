package ethereum

import "errors"

// Minimal RLP decoding, enough to walk Merkle-Patricia trie nodes and read
// an account. See https://ethereum.org/developers/docs/data-structures-and-encoding/rlp

var errRLP = errors.New("invalid rlp")

// rlpItem is one decoded RLP item. For a string, payload is its bytes; for a
// list, payload is the concatenated encoding of its elements. raw is the
// item's full encoding.
type rlpItem struct {
	isList  bool
	payload []byte
	raw     []byte
}

// rlpSplit decodes the first item of b and returns it with the bytes that
// follow it.
func rlpSplit(b []byte) (rlpItem, []byte, error) {
	if len(b) == 0 {
		return rlpItem{}, nil, errRLP
	}
	prefix := b[0]
	var (
		isList         bool
		offset, length int
	)
	switch {
	case prefix < 0x80:
		return rlpItem{payload: b[:1], raw: b[:1]}, b[1:], nil
	case prefix <= 0xb7:
		offset, length = 1, int(prefix-0x80)
		if length == 1 && len(b) > 1 && b[1] < 0x80 {
			return rlpItem{}, nil, errRLP // single byte must be encoded as itself
		}
	case prefix <= 0xbf:
		n := int(prefix - 0xb7)
		l, err := rlpLength(b, n)
		if err != nil {
			return rlpItem{}, nil, err
		}
		offset, length = 1+n, l
	case prefix <= 0xf7:
		isList = true
		offset, length = 1, int(prefix-0xc0)
	default:
		isList = true
		n := int(prefix - 0xf7)
		l, err := rlpLength(b, n)
		if err != nil {
			return rlpItem{}, nil, err
		}
		offset, length = 1+n, l
	}
	end := offset + length
	if end < offset || end > len(b) {
		return rlpItem{}, nil, errRLP
	}
	return rlpItem{isList: isList, payload: b[offset:end], raw: b[:end]}, b[end:], nil
}

// rlpLength reads the n-byte big-endian length following the prefix byte of
// a long string or list, rejecting non-canonical encodings.
func rlpLength(b []byte, n int) (int, error) {
	if n > 4 || len(b) < 1+n || b[1] == 0 {
		return 0, errRLP
	}
	l := 0
	for i := 1; i <= n; i++ {
		l = l<<8 | int(b[i])
	}
	if l < 56 {
		return 0, errRLP
	}
	return l, nil
}

// rlpDecode decodes b, which must hold exactly one item.
func rlpDecode(b []byte) (rlpItem, error) {
	item, rest, err := rlpSplit(b)
	if err != nil {
		return rlpItem{}, err
	}
	if len(rest) != 0 {
		return rlpItem{}, errRLP
	}
	return item, nil
}

// rlpList returns the elements of a list item.
func rlpList(item rlpItem) ([]rlpItem, error) {
	if !item.isList {
		return nil, errRLP
	}
	var items []rlpItem
	rest := item.payload
	for len(rest) > 0 {
		var (
			it  rlpItem
			err error
		)
		it, rest, err = rlpSplit(rest)
		if err != nil {
			return nil, err
		}
		items = append(items, it)
	}
	return items, nil
}
