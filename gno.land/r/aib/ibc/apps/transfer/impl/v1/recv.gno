package impl

import (
	"strconv"

	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/p/aib/ibc/ics20/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	implv0 "gno.land/r/aib/ibc/apps/transfer/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

// isBridgeRealm reports whether a is a realm of the bridge
// (ibcgov.BridgeRealm): a credit to one is swept, never paid.
func isBridgeRealm(a address) bool { return ibcgov.BridgeRealm(a) != "" }

// receivedDenom is the denom a received token is booked under on rt, its
// accounting denom and accounting: a gno-native token returning is released
// from the route's escrow; an Ethereum token arriving is a voucher keyed by
// the route key.
func receivedDenom(rt *controls.Route, sourceClient string, payload types.Payload, token ics20.Token) (denom ics20.Denom, accDenom, kind string) {
	if token.Denom.HasPrefix(payload.SourcePort, sourceClient) {
		denom = ics20.Denom{Base: token.Denom.Base, Trace: token.Denom.Trace[1:]}
		return denom, denom.IBCDenom(), controls.KindUnescrow
	}
	trace := append([]ics20.Hop{ics20.NewHop(payload.DestinationPort, rt.Key)}, token.Denom.Trace...)
	denom = ics20.Denom{Base: token.Denom.Base, Trace: trace}
	return denom, denom.IBCDenom(), controls.KindMint
}

// OnRecvPacket is impl/v0's for clients the controls do not cover. On a route
// it books the transfer as a claim keyed by the packet (or a sweep entry) in
// the transaction of the receipt, and answers a success acknowledgement; the
// claim is paid later by Claim. Every refusal answers an error acknowledgement
// before any state change, so the sender is refunded on Ethereum: a credits
// flag, a closed route, an Ethereum client of no route, a blocked receiver, a
// denom not enabled on the route, a minted denom past its supply cap. An
// undecodable receiver is no refusal: it is swept, owed to a decision.
func (l *logic) OnRecvPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) types.RecvPacketResult {
	rt, covered := l.routeOf(0, rlm, destinationClient)
	if !covered {
		return l.Logic.OnRecvPacket(0, rlm, sourceClient, destinationClient, sequence, payload)
	}
	var (
		data   ics20.FungibleTokenPacketData
		token  ics20.Token
		ackErr error
		swept  bool
	)
	refuse := func(err error) types.RecvPacketResult {
		ackErr = err
		ack := types.NewErrorAppAcknowledgement(err)
		transfer.EmitPacket(0, rlm,
			transfer.AttributeKeySender, data.Sender,
			transfer.AttributeKeyReceiver, data.Receiver,
			transfer.AttributeKeyDenom, token.Denom.Path(),
			transfer.AttributeKeyAmount, token.Amount,
			transfer.AttributeKeyMemo, data.Memo,
			transfer.AttributeKeyAckSuccess, strconv.FormatBool(ack.Success()),
			transfer.AttributeKeyAckError, ackErr.Error(),
		)
		return types.RecvPacketResult{Status: types.PacketStatus_Failure}
	}
	if rt == nil {
		return refuse(ufmt.Errorf("client %s is an Ethereum client of no enrolled route", destinationClient))
	}
	if rt.ExposureClosed() {
		return refuse(ufmt.Errorf("route %s is closed (a replacement awaiting its reopening, or a loss without a restoring decision)", rt.Key))
	}
	if err := validatePayload(destinationClient, sourceClient, payload); err != nil {
		return refuse(err)
	}
	var err error
	data, token, err = unmarshalPayload(payload)
	if err != nil {
		return refuse(err)
	}
	if err := implv0.ValidateBaseDenomNoSlash(token); err != nil {
		return refuse(err)
	}
	if ibcgov.Flagged(rt.Key, ibcgov.FnCredits) {
		return refuse(ufmt.Errorf("credits are paused on route %s", rt.Key))
	}
	// An undecodable receiver is booked as an owed sweep entry keeping the
	// raw receiver, with a success acknowledgement: it is paid only by a
	// 7-day decision naming the payee (ADR pr6375 §6.8, §7.1).
	reason := ""
	receiver, ok := transfer.CanonicalAddress(data.Receiver)
	if !ok {
		receiver, reason = address(data.Receiver), "invalid receiver"
	} else if transfer.IsBlocked(receiver) {
		return refuse(ufmt.Errorf("receiver %s is blocked", data.Receiver))
	}
	amount, err := token.AmountInt64()
	if err != nil {
		return refuse(err)
	}

	denom, accDenom, kind := receivedDenom(rt, sourceClient, payload, token)
	if acc := rt.Denom(accDenom); acc != nil && acc.Config.Kind != kind {
		return refuse(ufmt.Errorf("denom %s is accounted as %s on route %s", accDenom, acc.Config.Kind, rt.Key))
	}
	if err := rt.CheckCredit(accDenom, amount); err != nil {
		return refuse(err)
	}

	// No refusal from here: book the credit.
	if kind == controls.KindMint {
		if !l.store.HasDenom(accDenom) {
			l.store.SetDenom(0, rlm, denom)
		}
		transfer.EmitDenom(0, rlm, denom.HashHex(), string(denom.MarshalJSON()))
		l.store.GetOrCreateVoucher(0, rlm, denom.Base, accDenom)
	}
	if reason == "" && isBridgeRealm(receiver) {
		reason = "bridge realm"
	}
	epoch, _ := ibcgov.PayoutsEpoch(rt.Key)
	lock := l.store.Escrowed(rt.Key, accDenom)
	key := controls.PacketKey(destinationClient, sequence)
	swept, err = rt.Credit(now(), chainHeight(), epoch, key, accDenom, receiver, amount, controls.ByPacket, reason, lock)
	if err != nil {
		// CheckCredit passed and the key is the receipt's: a failure here is
		// a broken invariant, which must abort the receive.
		panic(err)
	}
	ack := types.NewResultAppAcknowledgement([]byte{byte(1)})
	booked := "claim"
	if swept {
		booked = "sweep"
	}
	transfer.EmitPacket(0, rlm,
		transfer.AttributeKeySender, data.Sender,
		transfer.AttributeKeyReceiver, data.Receiver,
		transfer.AttributeKeyDenom, token.Denom.Path(),
		transfer.AttributeKeyAmount, token.Amount,
		transfer.AttributeKeyMemo, data.Memo,
		transfer.AttributeKeyAckSuccess, strconv.FormatBool(ack.Success()),
	)
	transfer.EmitRoute(0, rlm, "credit", "route", rt.Key, "packet", key, "denom", accDenom,
		"receiver", string(receiver), "amount", strconv.FormatInt(amount, 10), "booked", booked)
	return types.RecvPacketResult{Status: types.PacketStatus_Success, Acknowledgement: ack.MarshalJSON()}
}
