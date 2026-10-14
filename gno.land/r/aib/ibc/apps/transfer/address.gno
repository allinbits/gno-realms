package transfer

import "crypto/bech32"

// addressPrefix is the bech32 human-readable part of gno addresses.
const addressPrefix = "g"

// CanonicalAddress decodes s as a bech32 gno address and returns its
// canonical encoding, the lowercase one, re-encoded from the decoded bytes.
// It reports false if s is not a valid 20-byte gno address.
//
// bech32 accepts an address spelled all lowercase or all uppercase, and the
// banker credits the same account for both, but a string compared or used as
// a key as is (the blocklist, the GRC20 ledger) tells them apart. Addresses
// that come from outside the chain, such as an ICS-20 packet receiver, must
// go through this function before use, as ibc-go decodes them with
// addressCodec.StringToBytes.
func CanonicalAddress(s string) (address, bool) {
	hrp, bz, err := bech32.DecodeToBase256(s)
	if err != nil || hrp != addressPrefix || len(bz) != 20 {
		return "", false
	}
	enc, err := bech32.EncodeFromBase256(addressPrefix, bz)
	if err != nil {
		return "", false
	}
	return address(enc), true
}
