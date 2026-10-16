package impl

import (
	"chain"
	"strconv"

	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/p/aib/ibc/ics20/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/ibcgov"
)

// bridgeRealms are the realms of the bridge: a credit to one of them is swept
// (ADR pr6375 §7.1), never paid to an address whose code could not move it.
var bridgeRealms = []string{
	"gno.land/r/aib/ibc/core",
	"gno.land/r/aib/ibc/core/impl/v0",
	"gno.land/r/aib/ibc/core/impl/v1",
	"gno.land/r/aib/ibc/apps/transfer",
	"gno.land/r/aib/ibc/apps/transfer/impl/v0",
	"gno.land/r/aib/ibc/apps/transfer/impl/v1",
	"gno.land/r/aib/ibc/ibcgov",
	"gno.land/r/aib/ibc/ethrelay",
}

func isBridgeRealm(a address) bool {
	for _, p := range bridgeRealms {
		if chain.PackageAddress(p) == a {
			return true
		}
	}
	return false
}

// OnRecvPacket is impl/v0's for clients the controls do not cover. On a route
// it books the transfer as a claim keyed by the packet (or a sweep entry) in
// the transaction of the receipt, and answers a success acknowledgement; the
// claim is paid later by Claim. Every refusal answers an error acknowledgement
// before any state change, so the sender is refunded on Ethereum: a credits
// flag, an Ethereum client of no route, an invalid or blocked receiver, a
// denom not enabled on the route, a minted denom past its supply cap.
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
	if err := validatePayload(sourceClient, destinationClient, payload); err != nil {
		return refuse(err)
	}
	var err error
	data, token, err = unmarshalPayload(payload)
	if err != nil {
		return refuse(err)
	}
	if err := validateBaseDenomNoSlash(token); err != nil {
		return refuse(err)
	}
	if ibcgov.Flagged(rt.Key, ibcgov.FnCredits) {
		return refuse(ufmt.Errorf("credits are paused on route %s", rt.Key))
	}
	// An undecodable receiver is refused with an error acknowledgement (the
	// sender is refunded at the source) rather than swept: IBC has the exit.
	receiver, ok := transfer.CanonicalAddress(data.Receiver)
	if !ok {
		return refuse(ufmt.Errorf("invalid receiver address %s", data.Receiver))
	}
	if transfer.IsBlocked(receiver) {
		return refuse(ufmt.Errorf("receiver %s is blocked", data.Receiver))
	}
	amount, err := token.AmountInt64()
	if err != nil {
		return refuse(err)
	}

	var (
		accDenom string
		kind     string
		denom    ics20.Denom
	)
	if token.Denom.HasPrefix(payload.SourcePort, sourceClient) {
		// A gno-native token returning: released from the route's escrow.
		denom = ics20.Denom{Base: token.Denom.Base, Trace: token.Denom.Trace[1:]}
		accDenom, kind = denom.IBCDenom(), controls.KindUnescrow
	} else {
		// An Ethereum token arriving: a voucher, keyed by the route key.
		trace := append([]ics20.Hop{ics20.NewHop(payload.DestinationPort, rt.Key)}, token.Denom.Trace...)
		denom = ics20.Denom{Base: token.Denom.Base, Trace: trace}
		accDenom, kind = denom.IBCDenom(), controls.KindMint
	}
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
	reason := ""
	if isBridgeRealm(receiver) {
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
