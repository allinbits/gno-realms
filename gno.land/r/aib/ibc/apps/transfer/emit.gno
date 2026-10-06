package transfer

import "chain"

// The Emit* functions below keep the transfer events attributed to this
// realm: chain.Emit stamps the event with the package whose code contains the
// call, so the implementation emits through them. They are exported because
// the implementation lives in another package, hence the assertProxyRealm
// guard.

// EmitTransfer emits ibc_transfer, the record of a send accepted by
// OnSendPacket.
func EmitTransfer(_ int, rlm realm, sender, receiver, denom, amount, memo string) {
	assertProxyRealm(0, rlm)
	chain.Emit(EventTypeTransfer,
		AttributeKeySender, sender,
		AttributeKeyReceiver, receiver,
		AttributeKeyDenom, denom,
		AttributeKeyAmount, amount,
		AttributeKeyMemo, memo,
	)
}

// EmitPacket emits fungible_token_packet with the given key/value pairs: the
// outcome of a receive or of an acknowledgement.
func EmitPacket(_ int, rlm realm, attrs ...string) {
	assertProxyRealm(0, rlm)
	chain.Emit(EventTypePacket, attrs...)
}

// EmitTimeout emits timeout, the refund of a timed-out send.
func EmitTimeout(_ int, rlm realm, receiver, denom, amount, memo string) {
	assertProxyRealm(0, rlm)
	chain.Emit(EventTypeTimeout,
		AttributeKeyReceiver, receiver,
		AttributeKeyDenom, denom,
		AttributeKeyAmount, amount,
		AttributeKeyMemo, memo,
	)
}

// EmitDenom emits denomination, the first sighting of a voucher denom.
func EmitDenom(_ int, rlm realm, denomHash, denomJSON string) {
	assertProxyRealm(0, rlm)
	chain.Emit(EventTypeDenom,
		AttributeKeyDenomHash, denomHash,
		AttributeKeyDenom, denomJSON,
	)
}
