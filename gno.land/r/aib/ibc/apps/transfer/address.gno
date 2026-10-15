package transfer

import "crypto/bech32"

// CanonicalAddress decodes s as a gno address and returns its canonical
// encoding, the lowercase one, re-encoded from the decoded bytes. It reports
// false if s is not a valid address on this chain.
//
// bech32 accepts an address spelled all lowercase or all uppercase, and the
// banker credits the same account for both, but a string compared or used as
// a key as is (the blocklist, the GRC20 ledger) tells them apart. Addresses
// that come from outside the chain, such as an ICS-20 packet receiver, must
// go through this function before use, as ibc-go decodes them with
// addressCodec.StringToBytes.
func CanonicalAddress(s string) (address, bool) {
	// The chain's own check: checksum, the chain's address prefix, 20 bytes.
	if !address(s).IsValid() {
		return "", false
	}
	hrp, bz, err := bech32.DecodeToBase256(s) // hrp comes back lowercase
	if err != nil {
		return "", false
	}
	enc, err := bech32.EncodeFromBase256(hrp, bz)
	if err != nil {
		return "", false
	}
	return address(enc), true
}
