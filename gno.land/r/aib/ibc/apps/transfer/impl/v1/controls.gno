package impl

import (
	"bytes"
	"chain"
	"errors"
	"strconv"
	"strings"

	"gno.land/p/aib/ibc/ics20/controls/v0"
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
// payouts flag it pays nothing.
func (l *logic) Claim(_ int, rlm realm, clientID, denom string, n int) int {
	rt := l.routeFor(0, rlm, clientID)
	if ibcgov.Flagged(rt.Key, ibcgov.FnPayouts) {
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
// §7.13). Under a refunds hold it pays nothing.
func (l *logic) ClaimRefunds(_ int, rlm realm, clientID, denom string, n int) int {
	rt := l.routeFor(0, rlm, clientID)
	hold := ibcgov.Flagged(rt.Key, ibcgov.FnRefunds)
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
	if !ok || r.Paid {
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
		if _, err := reg.Enroll(p.Route, p.To, t); err != nil {
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
		case !clientOfRoute(rt, client):
			return "packet " + p.Key + " was not received on route " + rt.Key
		case len(core.PacketReceipt(client, seq)) == 0:
			return "packet " + p.Key + " was never received"
		case !bytes.Equal(core.PacketAcknowledgement(client, seq), successAckCommitment()):
			return "packet " + p.Key + " has no success acknowledgement: an error-acknowledged packet is refunded at its source"
		}
		err = rt.CreditByVote(t, chainHeight(), epoch, p.Key, p.Denom, p.To, p.Amount, l.lockOf(rt, p.Denom))
	case controls.OpSweep:
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
	case controls.OpReduce:
		err = rt.Reduce(p.Key, p.Amount, p.Incident)
	case controls.OpAccept:
		err = rt.Accept(p.Denom, p.Amount, p.Incident)
	case controls.OpRejectRefund:
		err = rt.RejectRefund(p.Key, p.Incident)
	case controls.OpPayEntitlement:
		var pay controls.RefundPayment
		if rec, ok := rt.Send(p.Key); ok {
			pay, err = rt.PayEntitlement(p.Key, p.Amount, p.Incident, l.lockOf(rt, rec.Denom))
		} else {
			err = errors.New("no send record for " + p.Key)
		}
		if err == nil {
			l.payOut(0, rlm, rt, pay.Denom, pay.To, pay.Amount)
		}
	case controls.OpReplace:
		if !isEthereum(p.Client) || core.IsClientRetired(p.Client) {
			return p.Client + " is no usable Ethereum client"
		}
		err = reg.Replace(rt.Key, p.Client)
	default:
		return "unknown operation " + op
	}
	if err != nil {
		return err.Error()
	}
	transfer.EmitRoute(0, rlm, "gov", "op", op, "route", rt.Key, "note", note)
	return ""
}
