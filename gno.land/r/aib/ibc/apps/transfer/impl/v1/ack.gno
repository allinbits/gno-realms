package impl

import (
	"bytes"
	"chain"
	"errors"
	"strconv"

	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/ibcgov"
)

// The acknowledgement and timeout callbacks of a route never fail on the
// controls: they attach the outcome to the send record and pay the refund, or
// queue it under the refund meter or a refunds hold. Pauses and limits never
// block them (ADR pr6375 §7.3).

// sendRecord is the record of a send on an Ethereum client the callbacks
// settle. A send without one (made before the controls, over a client not
// enrolled yet or not backfilled yet) is refused: the core keeps its
// commitment, so Backfill records it and the relayer retries (ADR pr6375
// §7.13: no refund on an Ethereum client bypasses the refund meter or the
// refunds hold).
func (l *logic) sendRecord(_ int, rlm realm, rt *controls.Route, sourceClient string, sequence uint64) (controls.SendRecord, error) {
	key := controls.PacketKey(sourceClient, sequence)
	if rt == nil {
		return controls.SendRecord{}, ufmt.Errorf("client %s is an Ethereum client of no enrolled route: enroll it and backfill send %s first", sourceClient, key)
	}
	rec, ok := rt.Send(key)
	if !ok {
		return controls.SendRecord{}, ufmt.Errorf("send %s has no record: backfill it first (transfer.Backfill)", key)
	}
	return rec, nil
}

// OnAcknowledgementPacket is impl/v0's for clients the controls do not cover.
// On an Ethereum client it settles the send's record: a success completes
// it, an error refunds the sender under the refund meter and the refunds
// hold. A send without a record is refused until it is backfilled.
func (l *logic) OnAcknowledgementPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, acknowledgement []byte, payload types.Payload) error {
	rt, covered := l.routeOf(0, rlm, sourceClient)
	if !covered {
		return l.Logic.OnAcknowledgementPacket(0, rlm, sourceClient, destinationClient, sequence, acknowledgement, payload)
	}
	rec, err := l.sendRecord(0, rlm, rt, sourceClient, sequence)
	if err != nil {
		return err
	}
	var ack types.AppAcknowledgement
	if bytes.Equal(acknowledgement, types.UniversalErrorAcknowledgement()) {
		ack = types.NewErrorAppAcknowledgement(errors.New("receive packet failed"))
	} else {
		if err := ack.UnmarshalJSON(acknowledgement); err != nil {
			return ufmt.Errorf("cannot unmarshal ICS-20 transfer packet acknowledgement: %v", err)
		}
		if !ack.Success() {
			return ufmt.Errorf("cannot pass in a custom error acknowledgement with IBC v2")
		}
	}
	outcome := controls.OutcomeSuccess
	if !ack.Success() {
		outcome = controls.OutcomeError
	}
	l.settle(0, rlm, rt, rec, outcome)
	attrs := []string{
		transfer.AttributeKeySender, string(rec.Sender),
		transfer.AttributeKeyReceiver, rec.Receiver,
		transfer.AttributeKeyDenom, rec.Denom,
		transfer.AttributeKeyAmount, strconv.FormatInt(rec.Amount, 10),
		transfer.AttributeKeyAck, string(acknowledgement),
	}
	transfer.EmitPacket(0, rlm, attrs...)
	if ack.Success() {
		transfer.EmitPacket(0, rlm, transfer.AttributeKeyAckSuccess, string(ack.Response.Result))
	} else {
		transfer.EmitPacket(0, rlm, transfer.AttributeKeyAckError, ack.Response.Error)
	}
	return nil
}

// OnTimeoutPacket is impl/v0's for clients the controls do not cover; on an
// Ethereum client it refunds the sender under the refund meter and the
// refunds hold. A send without a record is refused until it is backfilled.
func (l *logic) OnTimeoutPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) error {
	rt, covered := l.routeOf(0, rlm, sourceClient)
	if !covered {
		return l.Logic.OnTimeoutPacket(0, rlm, sourceClient, destinationClient, sequence, payload)
	}
	rec, err := l.sendRecord(0, rlm, rt, sourceClient, sequence)
	if err != nil {
		return err
	}
	l.settle(0, rlm, rt, rec, controls.OutcomeTimeout)
	transfer.EmitTimeout(0, rlm, string(rec.Sender), rec.Denom, strconv.FormatInt(rec.Amount, 10), "")
	return nil
}

// settle attaches the outcome to the record and pays what the refund meter
// allows now; the rest is queued (and everything under a refunds hold).
func (l *logic) settle(_ int, rlm realm, rt *controls.Route, rec controls.SendRecord, outcome string) {
	hold := ibcgov.Flagged(rt.Key, ibcgov.FnRefunds)
	pay, err := rt.Settle(now(), chainHeight(), rec.Key, outcome, hold, l.lockOf(rt, rec.Denom))
	if err != nil {
		panic(err)
	}
	if pay > 0 {
		l.payOut(0, rlm, rt, rec.Denom, rec.Sender, pay)
	}
	after, _ := rt.Send(rec.Key)
	transfer.EmitRoute(0, rlm, "settle", "route", rt.Key, "packet", rec.Key, "outcome", outcome,
		"payment", after.Payment, "refunded", strconv.FormatInt(pay, 10))
}

// payOut moves amount of denom to `to`: out of the route's escrow for a
// gno-native token, as newly minted vouchers for an Ethereum token.
func (l *logic) payOut(_ int, rlm realm, rt *controls.Route, denom string, to address, amount int64) {
	if amount <= 0 {
		return
	}
	acc := rt.Denom(denom)
	if acc != nil && acc.Config.Kind == controls.KindMint {
		if err := l.store.MintVoucher(0, rlm, denom, to, amount); err != nil {
			panic(err)
		}
		return
	}
	c := chain.NewCoin(denom, amount)
	var err error
	if transfer.IsGRC20Alias(denom) {
		err = l.store.UnescrowGRC20(0, rlm, rt.Key, string(to), c)
	} else {
		err = l.store.UnescrowNative(0, rlm, rt.Key, string(to), c)
	}
	if err != nil {
		panic(err)
	}
}
