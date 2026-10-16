package impl

import (
	"bytes"
	"chain"
	"strconv"
	"strings"

	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/p/aib/ibc/ics20/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
	"gno.land/r/aib/ibc/ibcgov"
)

// routeFor is the route a Claim names: by its current client id, or by its
// route key.
func (l *logic) routeFor(_ int, rlm realm, clientOrRoute string) *controls.Route {
	reg := l.registry(0, rlm)
	if rt := reg.RouteOf(clientOrRoute); rt != nil {
		return rt
	}
	if rt := reg.Route(clientOrRoute); rt != nil {
		return rt
	}
	panic("no route " + clientOrRoute)
}

// lockOf is the escrow a gno-native denom of the route holds (its lock), 0
// for a minted denom.
func (l *logic) lockOf(rt *controls.Route, denom string) int64 {
	if acc := rt.Denom(denom); acc == nil || acc.Config.Kind == controls.KindMint {
		return 0
	}
	return l.store.Escrowed(rt.Key, denom)
}

// Claim pays up to n claims of denom on the route (ADR pr6375 §7.1). Under a
// payouts flag, on a closed route, or while a loss has no restoring decision,
// it pays nothing.
func (l *logic) Claim(_ int, rlm realm, clientID, denom string, n int) int {
	rt := l.routeFor(0, rlm, clientID)
	if ibcgov.Flagged(rt.Key, ibcgov.FnPayouts) || rt.ExposureClosed() {
		return 0
	}
	epoch, epochAt := ibcgov.PayoutsEpoch(rt.Key)
	ps, err := rt.PayClaims(now(), epoch, epochAt, denom, n, l.lockOf(rt, denom))
	if err != nil {
		panic(err)
	}
	for _, p := range ps {
		l.payOut(0, rlm, rt, denom, p.To, p.Amount)
		l.payOut(0, rlm, rt, denom, rt.FeeCollector, p.Fee)
		transfer.EmitRoute(0, rlm, "claim", "route", rt.Key, "packet", p.Key, "denom", denom, "to", string(p.To),
			"amount", strconv.FormatInt(p.Amount, 10), "fee", strconv.FormatInt(p.Fee, 10))
	}
	return len(ps)
}

// ClaimRefunds pays up to n queued refunds of denom on the route (ADR pr6375
// §7.13). Under a refunds hold, or on a route a replacement closed, it pays
// nothing; a loss does not hold refunds.
func (l *logic) ClaimRefunds(_ int, rlm realm, clientID, denom string, n int) int {
	rt := l.routeFor(0, rlm, clientID)
	hold := ibcgov.Flagged(rt.Key, ibcgov.FnRefunds) || rt.IsClosed()
	ps, err := rt.PayRefunds(now(), denom, n, hold, l.lockOf(rt, denom))
	if err != nil {
		panic(err)
	}
	for _, p := range ps {
		l.payOut(0, rlm, rt, denom, p.To, p.Amount)
		transfer.EmitRoute(0, rlm, "refund", "route", rt.Key, "packet", p.Key, "denom", denom, "to", string(p.To),
			"amount", strconv.FormatInt(p.Amount, 10))
	}
	return len(ps)
}

// Backfill records a send made over an Ethereum route before its controls
// (ADR pr6375 §7.13), authenticated against the commitment the core still
// holds for it: the route's current or retired client sent it, and its
// acknowledgement or timeout was not processed yet.
func (l *logic) Backfill(_ int, rlm realm, packet types.Packet) {
	reg := l.registry(0, rlm)
	rt := reg.RouteOf(packet.SourceClient)
	if rt == nil {
		if k := reg.RetiredRouteOf(packet.SourceClient); k != "" {
			rt = reg.Route(k)
		}
	}
	if rt == nil {
		panic("client " + packet.SourceClient + " is the client of no route")
	}
	c := core.PacketCommitment(packet.SourceClient, packet.Sequence)
	if len(c) == 0 {
		panic(ufmt.Sprintf("the core holds no commitment for %s/%d: never sent, or its acknowledgement or timeout was processed", packet.SourceClient, packet.Sequence))
	}
	if !bytes.Equal(c, types.CommitPacket(packet)) {
		panic("the packet differs from the one the core committed")
	}
	if len(packet.Payloads) != 1 || packet.Payloads[0].SourcePort != transfer.PortID {
		panic("not a transfer packet")
	}
	data, token, err := unmarshalPayload(packet.Payloads[0])
	if err != nil {
		panic(err)
	}
	amount, err := token.AmountInt64()
	if err != nil {
		panic(err)
	}
	sender := address(data.Sender)
	if !sender.IsValid() {
		panic("invalid sender " + data.Sender)
	}
	accDenom, kind := token.Denom.IBCDenom(), controls.KindUnescrow
	if token.Denom.HasPrefix(transfer.PortID, packet.SourceClient) {
		// A voucher returning: keyed by the route key on this chain.
		trace := append([]ics20.Hop{ics20.NewHop(transfer.PortID, rt.Key)}, token.Denom.Trace[1:]...)
		accDenom, kind = ics20.Denom{Base: token.Denom.Base, Trace: trace}.IBCDenom(), controls.KindMint
	}
	key := controls.PacketKey(packet.SourceClient, packet.Sequence)
	err = rt.Backfill(controls.SendRecord{
		Key: key, Packet: packet, Commitment: c, Sender: sender, Receiver: data.Receiver,
		Denom: accDenom, Kind: kind, Amount: amount, SentAt: now(),
	})
	if err != nil {
		panic(err)
	}
	transfer.EmitRoute(0, rlm, "backfill", "route", rt.Key, "packet", key, "denom", accDenom,
		"amount", strconv.FormatInt(amount, 10))
}

// ContinueReopen runs the next bounded batch of a route's reopening (ADR
// pr6375 §5.4 kind 13); anyone may.
func (l *logic) ContinueReopen(_ int, rlm realm, route string) bool {
	rt := l.registry(0, rlm).Route(route)
	if rt == nil {
		panic("no route " + route)
	}
	accepted, done, err := rt.ContinueReopen()
	if err != nil {
		panic(err)
	}
	transfer.EmitRoute(0, rlm, "reopen", "route", rt.Key, "accepted", strconv.FormatInt(accepted, 10), "open", strconv.FormatBool(done))
	return done
}

// Recapitalize pays an authorized recapitalization into the route's escrow
// (ADR pr6375 §7.9): exactly its amount, credited to the accounted backing
// and debited from the unrecovered losses. A plain transfer to the escrow
// address stays surplus and repairs nothing.
func (l *logic) Recapitalize(_ int, rlm realm, sent []chain.Coin, route string, id int64) {
	rt := l.registry(0, rlm).Route(route)
	if rt == nil {
		panic("no route " + route)
	}
	r, ok := rt.Recap(id)
	if !ok || r.Paid || r.Revoked {
		panic(ufmt.Sprintf("no unpaid recapitalization %d on route %s", id, route))
	}
	payer := rlm.Previous().Address()
	c := chain.NewCoin(r.Denom, r.Amount)
	if transfer.IsGRC20Alias(r.Denom) {
		if len(sent) > 0 {
			panic("a GRC20 recapitalization takes no coins")
		}
		if err := l.store.EscrowGRC20(0, rlm, rt.Key, transfer.ResolveGRC20Alias(r.Denom), payer, c); err != nil {
			panic(err)
		}
	} else {
		if len(sent) != 1 || sent[0].Denom != r.Denom || sent[0].Amount != r.Amount {
			panic(ufmt.Sprintf("send exactly %d%s in a direct call", r.Amount, r.Denom))
		}
		l.store.AddEscrow(0, rlm, rt.Key, c)
	}
	if err := rt.Recapitalize(id, r.Denom, r.Amount, payer); err != nil {
		panic(err)
	}
	transfer.EmitRoute(0, rlm, "recapitalize", "route", rt.Key, "id", strconv.FormatInt(id, 10), "denom", r.Denom,
		"amount", strconv.FormatInt(r.Amount, 10), "payer", string(payer))
}

// successAckCommitment is the acknowledgement commitment of this app's
// success acknowledgement, what a credited packet's acknowledgement must be.
func successAckCommitment() []byte {
	ack := types.NewResultAppAcknowledgement([]byte{byte(1)})
	return types.CommitAcknowledgement(types.Acknowledgement{AppAcknowledgements: [][]byte{ack.MarshalJSON()}})
}

// creditPending credits a packet whose asynchronous acknowledgement is still
// unwritten and writes its success acknowledgement in the same transaction
// (ADR pr6375 §7.9), so it can never be refunded at its source; on a retired
// client too, which the core allows for a receipt it holds. It returns why it
// refuses, before any change.
func (l *logic) creditPending(_ int, rlm realm, rt *controls.Route, p controls.Params, pkt types.Packet, height, epoch int64) string {
	if height < rt.Activated {
		return "packet " + p.Key + " was received before the route's activation"
	}
	if core.Paused() {
		return "the core is paused: the packet's acknowledgement cannot be written"
	}
	if len(pkt.Payloads) != 1 {
		return "packet " + p.Key + " carries no single transfer payload"
	}
	_, token, err := unmarshalPayload(pkt.Payloads[0])
	if err != nil {
		return err.Error()
	}
	_, accDenom, _ := receivedDenom(rt, pkt.SourceClient, pkt.Payloads[0], token)
	carried, err := token.AmountInt64()
	if err != nil {
		return err.Error()
	}
	if accDenom != p.Denom {
		return "packet " + p.Key + " carried " + accDenom + ", not " + p.Denom
	}
	if err := rt.CreditPending(now(), chainHeight(), epoch, p.Key, p.Denom, p.To, p.Amount, carried, l.lockOf(rt, p.Denom)); err != nil {
		return err.Error()
	}
	ack := types.NewResultAppAcknowledgement([]byte{byte(1)})
	client, seq, _ := controls.ParsePacketKey(p.Key)
	core.WriteAcknowledgement(cross(rlm), client, seq, types.Acknowledgement{AppAcknowledgements: [][]byte{ack.MarshalJSON()}})
	return ""
}

// isLegacyReceipt reports whether a receipt is the constant 0x02 that cores
// before this one stored for every packet (it identifies no packet): such a
// receive predates the controls.
func isLegacyReceipt(r []byte) bool { return len(r) == 1 && r[0] == 0x02 }

// clientOfRoute reports whether clientID is or was a client of rt.
func clientOfRoute(rt *controls.Route, clientID string) bool {
	if clientID == rt.Client {
		return true
	}
	for _, c := range rt.Replaced {
		if c == clientID {
			return true
		}
	}
	return false
}

// GovApply applies a governance operation decided by ibcgov (the proxy
// checked the caller). It re-checks the parameters against the live state and
// returns why it refuses, which spends the decision; nothing changes then.
func (l *logic) GovApply(_ int, rlm realm, op string, params []byte) string {
	p, err := controls.DecodeParams(params)
	if err != nil {
		return err.Error()
	}
	reg := l.registry(0, rlm)
	t := now()
	if op == controls.OpEnroll {
		if !isEthereum(p.Route) || core.IsClientRetired(p.Route) {
			return p.Route + " is no usable Ethereum client"
		}
		if _, err := reg.Enroll(p.Route, p.To, t, chainHeight()); err != nil {
			return err.Error()
		}
		transfer.EmitRoute(0, rlm, "gov", "op", op, "route", p.Route)
		return ""
	}
	rt := reg.Route(p.Route)
	if rt == nil {
		return "no route " + p.Route
	}
	epoch, _ := ibcgov.PayoutsEpoch(rt.Key)
	note := ""
	switch op {
	case controls.OpDenom:
		minted := strings.HasPrefix(p.Denom, "ibc/")
		if minted != (p.Config.Kind == controls.KindMint) {
			return "a minted denom is a voucher's ibc/ denom, an unescrowed one is not"
		}
		// A minted denom's vouchers already in circulation (minted by
		// impl/v0) count against its supply cap from the start.
		var outstanding int64
		if tok := l.store.VoucherToken(p.Denom); minted && tok != nil {
			outstanding = tok.TotalSupply()
		}
		err = rt.SetDenom(p.Denom, p.Config, t, epoch, outstanding)
	case controls.OpCollector:
		err = rt.SetFeeCollector(p.To)
	case controls.OpRefuse:
		rt.Refuse(p.Keys)
	case controls.OpUnrefuse:
		rt.Unrefuse(p.Keys)
	case controls.OpVoid:
		err = rt.Void(p.Keys, p.Forged, p.Incident)
	case controls.OpRestore:
		err = rt.Restore(p.Keys, t, epoch)
	case controls.OpCredit:
		client, seq, _ := controls.ParsePacketKey(p.Key)
		switch {
		case rt.ExposureClosed():
			return "route " + rt.Key + " is closed (a replacement awaiting its reopening, or a loss without a restoring decision): it credits nothing"
		case !clientOfRoute(rt, client):
			return "packet " + p.Key + " was not received on route " + rt.Key
		case len(core.PacketReceipt(client, seq)) == 0:
			return "packet " + p.Key + " was never received"
		case isLegacyReceipt(core.PacketReceipt(client, seq)):
			return "packet " + p.Key + "'s receipt is the legacy constant: it was received before the route's controls"
		}
		if pkt, height, pending := core.PendingAsyncAck(client, seq); pending {
			if refusal := l.creditPending(0, rlm, rt, p, pkt, height, epoch); refusal != "" {
				return refusal
			}
			break
		}
		if !bytes.Equal(core.PacketAcknowledgement(client, seq), successAckCommitment()) {
			return "packet " + p.Key + " has no success acknowledgement: an error-acknowledged packet is refunded at its source"
		}
		err = rt.CreditByVote(t, chainHeight(), epoch, p.Key, p.Denom, p.To, p.Amount, l.lockOf(rt, p.Denom))
	case controls.OpSweep:
		if rt.ExposureClosed() {
			return "route " + rt.Key + " is closed (a replacement awaiting its reopening, or a loss without a restoring decision): it pays nothing out"
		}
		if len(p.Keys) == 0 {
			return "no sweep entry named"
		}
		e, ok := rt.Sweep(p.Keys[0])
		if !ok {
			return "no sweep entry " + p.Keys[0]
		}
		var ps []controls.Payment
		ps, err = rt.PaySweeps(p.Keys, p.To, l.lockOf(rt, e.Denom))
		for _, x := range ps {
			l.payOut(0, rlm, rt, x.Denom, x.To, x.Amount)
		}
	case controls.OpLoss:
		err = rt.RecordLoss(p.Key, p.Denom, p.Amount, p.Chain, p.Incident, p.Cause)
	case controls.OpRecapitalize:
		var id int64
		id, err = rt.AuthorizeRecap(p.Denom, p.Amount, p.Incident)
		note = strconv.FormatInt(id, 10)
	case controls.OpRevokeRecap:
		err = rt.RevokeRecap(p.Amount)
	case controls.OpReduce:
		err = rt.Reduce(p.Key, p.Amount, p.Incident)
	case controls.OpAccept:
		err = rt.Accept(p.Denom, p.Amount, p.Incident)
	case controls.OpSettle:
		var ps []controls.RefundPayment
		ps, err = rt.SettleRecords(p.Client, p.Items, p.Incident, func(denom string) int64 { return l.lockOf(rt, denom) })
		for _, x := range ps {
			l.payOut(0, rlm, rt, x.Denom, x.To, x.Amount)
		}
	case controls.OpReopen:
		var accepted int64
		var done bool
		accepted, done, err = rt.Reopen()
		note = "accepted deficit " + strconv.FormatInt(accepted, 10)
		if !done {
			note += "; continue with transfer.ContinueReopen"
		}
	case controls.OpReplace:
		if !isEthereum(p.Client) || core.IsClientRetired(p.Client) {
			return p.Client + " is no usable Ethereum client"
		}
		err = reg.Replace(rt.Key, p.Client, p.Height)
	default:
		return "unknown operation " + op
	}
	if err != nil {
		return err.Error()
	}
	transfer.EmitRoute(0, rlm, "gov", "op", op, "route", rt.Key, "note", note)
	return ""
}
