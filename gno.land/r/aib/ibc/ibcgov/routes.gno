package ibcgov

import (
	"strconv"
	"strings"

	"gno.land/p/aib/encoding/ethaddr/v0"
	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/p/aib/ibc/ics20/v0"
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
)

// The builders of the Ethereum route controls kept by the transfer app (ADR
// pr6375 §7.1, §7.8, §7.9, §7.12, §7.13). Each applies through
// transfer.GovApply, which re-checks the parameters against the live state
// and refuses (the decision is spent) rather than panics. Delays: enrolling a
// route, a new denom, raising a limit, a new fee collector, unrefusing
// recipients, credits, sweep payments, losses, recapitalizations, reductions,
// accepted deficits, reconciliation settlements and route replacements wait 7
// days; lowering a limit, refusing recipients, a void of packets a guardian
// named and a restore of withheld claims apply at once.

// view is the transfer app's controls, read only.
func view() controls.Reader {
	rd, ok := transfer.ExtView("controls").(controls.Reader)
	if !ok {
		panic("ibcgov: the transfer app keeps no route controls (install transfer impl/v1 first)")
	}
	return rd
}

// routeParams is a decision applied through transfer.GovApply.
type routeParams struct {
	op string
	p  controls.Params
	// enrolment and replacement also change this realm's records.
	enroll  bool
	replace string // the old client a replacement retires
}

func (p *routeParams) apply(cur realm, t int64) (string, string) {
	if p.replace != "" {
		// Re-check the new client before retiring the old one.
		if refusal := checkNewRouteClient(p.p.Client); refusal != "" {
			return "", refusal
		}
		if view().Client(p.p.Route) != p.replace {
			return "", "the route's client is no longer " + p.replace
		}
	}
	if refusal := transfer.GovApply(cross(cur), p.op, p.p.Encode()); refusal != "" {
		return "", refusal
	}
	note := p.op
	if p.enroll {
		routes.Set(p.p.Route, &routeRec{epochAt: t})
	}
	if p.replace != "" {
		if !core.IsClientRetired(p.replace) {
			core.RetireClient(cross(cur), p.replace)
		}
		// After a migration every meter starts empty (ADR pr6375 §7.1): a
		// new payouts epoch, reset lazily in constant work.
		bumpPayoutsEpoch(p.p.Route, t)
		note += ": client " + p.replace + " retired, meters emptied"
		if EpochClient() == p.replace {
			nextEpoch(p.p.Client)
			note += ", governance epoch " + strconv.FormatUint(uint64(epoch), 10) + " opened over " + p.p.Client
		}
	}
	return note, ""
}

func routeRequest(cur realm, op, kind, text string, p controls.Params, queued bool) Request {
	rp := &routeParams{op: op, p: p}
	return propose(cur, kind, text, func(cur realm, made, t int64) {
		decide(cur, kind, text, rp, made, t, queued)
	})
}

func mustRoute(route string) {
	if !routes.Has(route) {
		panic("ibcgov: no route " + route)
	}
}

func mustIncident(s string) {
	if !isIdent(s, 32) {
		panic("ibcgov: an incident is 1 to 32 characters of a-z, 0-9 and '-'")
	}
}

func mustKeys(list string) []string {
	keys := splitList(list)
	if len(keys) == 0 || len(keys) > controls.MaxKeys {
		panic("ibcgov: name 1 to " + strconv.Itoa(controls.MaxKeys) + " packet keys")
	}
	for _, k := range keys {
		if _, _, ok := controls.ParsePacketKey(k); !ok {
			panic("ibcgov: not a packet key: " + k)
		}
	}
	return keys
}

// checkNewRouteClient is why client cannot take a route now, or "".
func checkNewRouteClient(client string) string {
	switch {
	case core.ClientType(client) != ethereum.ClientType:
		return client + " is not an Ethereum client"
	case core.IsClientRetired(client):
		return client + " is retired"
	case core.ClientStatus(client) != "Active":
		return client + " is not Active"
	case core.CounterpartyClientID(client) == "":
		return client + " has no counterparty registered"
	}
	if rd, ok := transfer.ExtView("controls").(controls.Reader); ok {
		if (rd.RouteOf(client) != "" && !rd.Legacy(client)) || rd.RetiredRouteOf(client) != "" {
			return client + " is a route's client already"
		}
	}
	return ""
}

// NewEnrollRouteRequest makes the Ethereum client clientID a controlled route
// of the transfer app after 7 days (enrolling a route loosens): its key is
// clientID, its fee collector feeCollector. Until a denom is enabled on it
// (NewSetDenomRequest), the route refuses every send and receive.
func NewEnrollRouteRequest(cur realm, clientID, feeCollector string) Request {
	if refusal := checkNewRouteClient(clientID); refusal != "" {
		panic("ibcgov: " + refusal)
	}
	if routes.Has(clientID) {
		panic("ibcgov: " + clientID + " is a route already")
	}
	fc := mustAddr(feeCollector)
	text := "enroll route " + clientID + " with fee collector " + string(fc)
	rp := &routeParams{op: controls.OpEnroll, p: controls.Params{Route: clientID, To: fc}, enroll: true}
	return propose(cur, "enroll route", text, func(cur realm, made, t int64) {
		decide(cur, "enroll route", text, rp, made, t, true)
	})
}

// denomText spells out every field of a denom's configuration: the
// parameters are the record (ADR pr6375 §7.5), in the proposal's description
// and the decision's text alike.
func denomText(denom string, c controls.DenomConfig) string {
	remote := c.Remote
	if remote == "" {
		remote = "-"
	}
	return denom + " kind=" + c.Kind + " capFloor=" + itoa(c.CapFloor) + " supplyCap=" + itoa(c.SupplyCap) +
		" fee=" + itoa(c.Fee) + " feeFloor=" + itoa(c.FeeFloor) + " sendMax=" + itoa(c.SendMax) + " sendMin=" + itoa(c.SendMin) +
		" refundCap=" + itoa(c.RefundCap) + " remoteToken=" + remote
}

// denomConfig checks a denom's configuration as NewSetDenomRequest takes it
// and returns the accounting denom (a minted denom named by its token's
// Ethereum address becomes its voucher's IBC denom on route) and the
// configuration.
func denomConfig(route, denom, kind string, capFloor, supplyCap, fee, feeFloor, sendMax, sendMin, refundCap int64, remoteToken string) (string, controls.DenomConfig) {
	if !isDenom(denom) {
		panic("ibcgov: not a denom: " + denom)
	}
	if kind == controls.KindMint && strings.HasPrefix(denom, "0x") {
		a, err := ethaddr.Parse(denom)
		if err != nil {
			panic("ibcgov: " + err.Error())
		}
		denom = ics20.NewDenom(a.Lower(), ics20.NewHop("transfer", route)).IBCDenom()
	}
	if (kind == controls.KindMint) != strings.HasPrefix(denom, "ibc/") {
		panic("ibcgov: a minted denom is a voucher's ibc/ denom (or its token's address), an unescrowed one is not")
	}
	remote := ""
	if remoteToken != "" {
		a, err := ethaddr.Parse(remoteToken)
		if err != nil {
			panic("ibcgov: " + err.Error())
		}
		remote = a.Lower()
	}
	c := controls.DenomConfig{Kind: kind, CapFloor: capFloor, SupplyCap: supplyCap, Fee: fee, FeeFloor: feeFloor,
		SendMax: sendMax, SendMin: sendMin, RefundCap: refundCap, Remote: remote}
	if err := c.Validate(); err != nil {
		panic("ibcgov: " + err.Error())
	}
	return denom, c
}

// NewSetDenomRequest enables a denom on route or changes its limits (ADR
// pr6375 §7.1, §7.8, §9): kind "unescrow" (a gno-native token: denom is its
// escrow denom, "ugnot" or a GRC20 alias) or "mint" (an Ethereum token: denom
// is its voucher's IBC denom); capFloor the day cap floor (unescrow) or day
// cap (mint); supplyCap the voucher supply cap (mint, else 0); fee and its
// floor; sendMax and sendMin (unescrow, else 0); refundCap the refund meter's
// day cap; remoteToken (unescrow, else "") the token's GnoVoucher on Ethereum,
// which sends may never name as their receiver. For a minted denom, denom may be the token's Ethereum address
// (0x…): the voucher denom is then computed, ibc/<sha256("transfer/<route>/
// <lower-case address>")>, the denom this chain keys the token's vouchers by.
// A change that only tightens applies at once; a new denom or any loosening
// waits 7 days.
func NewSetDenomRequest(cur realm, route, denom, kind string, capFloor, supplyCap, fee, feeFloor, sendMax, sendMin, refundCap int64, remoteToken string) Request {
	mustRoute(route)
	denom, c := denomConfig(route, denom, kind, capFloor, supplyCap, fee, feeFloor, sendMax, sendMin, refundCap, remoteToken)
	if old, ok := view().DenomConfig(route, denom); ok && old.Kind != kind {
		panic("ibcgov: a denom never changes accounting")
	}
	// At once or queued is decided against the configuration when the
	// decision is recorded: another decision may have changed it since the
	// request was built.
	loosens := func() bool {
		old, ok := view().DenomConfig(route, denom)
		return !ok || controls.Loosens(old, c)
	}
	text := "denom on route " + route + ": " + denomText(denom, c)
	rp := &routeParams{op: controls.OpDenom, p: controls.Params{Route: route, Denom: denom, Config: c}}
	return propose(cur, "set denom", text, func(cur realm, made, t int64) {
		decide(cur, "set denom", text, rp, made, t, loosens())
	})
}

// NewSetFeeCollectorRequest replaces a route's fee collector after 7 days.
func NewSetFeeCollectorRequest(cur realm, route, feeCollector string) Request {
	mustRoute(route)
	fc := mustAddr(feeCollector)
	return routeRequest(cur, controls.OpCollector, "set fee collector", "fee collector of route "+route+": "+string(fc),
		controls.Params{Route: route, To: fc}, true)
}

func mustEthAddrs(list string) []string {
	items := splitList(list)
	if len(items) == 0 || len(items) > controls.MaxKeys {
		panic("ibcgov: name 1 to " + strconv.Itoa(controls.MaxKeys) + " addresses")
	}
	var out []string
	for _, it := range items {
		a, err := ethaddr.Parse(it)
		if err != nil {
			panic("ibcgov: " + err.Error())
		}
		out = append(out, a.Lower())
	}
	return out
}

// NewRefuseRecipientsRequest adds Ethereum addresses (the route's bridge
// contracts: router, ICS20, escrow, IBCAdmin, vouchers) to the route's refused
// send recipients, at once.
func NewRefuseRecipientsRequest(cur realm, route, addrs string) Request {
	mustRoute(route)
	list := mustEthAddrs(addrs)
	return routeRequest(cur, controls.OpRefuse, "refuse recipients", "refuse recipients on route "+route+": "+strings.Join(list, ","),
		controls.Params{Route: route, Keys: list}, false)
}

// NewUnrefuseRecipientsRequest removes refused send recipients after 7 days.
func NewUnrefuseRecipientsRequest(cur realm, route, addrs string) Request {
	mustRoute(route)
	list := mustEthAddrs(addrs)
	return routeRequest(cur, controls.OpUnrefuse, "unrefuse recipients", "stop refusing recipients on route "+route+": "+strings.Join(list, ","),
		controls.Params{Route: route, Keys: list}, true)
}

// NewVoidRequest voids claims or sweep entries of route by packet key (ADR
// pr6375 §7.9): forged drops the remainders and books what was paid as lost;
// withheld keeps the remainders booked and restorable. It applies at once when
// a guardian's standing payouts flag names every packet, after 7 days
// otherwise. A void never refunds the source.
func NewVoidRequest(cur realm, route, keys string, forged bool, incident string) Request {
	mustRoute(route)
	mustIncident(incident)
	list := mustKeys(keys)
	rd := view()
	for _, k := range list {
		if !rd.Voidable(route, k, forged) {
			panic("ibcgov: " + k + " cannot be voided that way as it stands")
		}
	}
	// Whether a guardian named every packet is read when the decision is
	// recorded.
	named := func() bool {
		for _, k := range list {
			if !NamedSuspect(route, k) {
				return false
			}
		}
		return true
	}
	how := "withheld"
	if forged {
		how = "forged"
	}
	text := "void as " + how + " on route " + route + " (incident " + incident + "): " + strings.Join(list, ",")
	rp := &routeParams{op: controls.OpVoid, p: controls.Params{Route: route, Keys: list, Forged: forged, Incident: incident}}
	return propose(cur, "void", text, func(cur realm, made, t int64) {
		decide(cur, "void", text, rp, made, t, !named())
	})
}

// NewRestoreRequest restores withheld claims, at once (ADR pr6375 §7.9: a
// withheld void can be restored). A forged void and a voided sweep entry are
// final; transfer re-checks every key when the decision applies.
func NewRestoreRequest(cur realm, route, keys string) Request {
	mustRoute(route)
	list := mustKeys(keys)
	rd := view()
	for _, k := range list {
		if c, ok := rd.Claim(route, k); !ok || c.State != controls.Withheld {
			panic("ibcgov: " + k + " is no withheld claim")
		}
	}
	text := "restore on route " + route + ": " + strings.Join(list, ",")
	return routeRequest(cur, controls.OpRestore, "restore", text, controls.Params{Route: route, Keys: list}, false)
}

// NewCreditRequest credits a packet by vote after 7 days (ADR pr6375 §7.9):
// only a packet received on the route with a success acknowledgement, for
// its whole payable amount (a haircut goes through NewReduceRequest), never
// above the free lock, deduplicated against every claim of the packet.
func NewCreditRequest(cur realm, route, key, denom, to string, amount int64) Request {
	mustRoute(route)
	if _, _, ok := controls.ParsePacketKey(key); !ok {
		panic("ibcgov: not a packet key: " + key)
	}
	if !isDenom(denom) || amount <= 0 {
		panic("ibcgov: a credit names a denom and a positive amount")
	}
	a := mustAddr(to)
	text := "credit " + itoa(amount) + " " + denom + " to " + string(a) + " for packet " + key + " on route " + route
	return routeRequest(cur, controls.OpCredit, "credit", text, controls.Params{Route: route, Key: key, Denom: denom, To: a, Amount: amount}, true)
}

// NewSweepRequest pays sweep entries of one denom to an address after 7
// days.
func NewSweepRequest(cur realm, route, keys, to string) Request {
	mustRoute(route)
	list := mustKeys(keys)
	a := mustAddr(to)
	return routeRequest(cur, controls.OpSweep, "sweep", "pay sweep entries on route "+route+" to "+string(a)+": "+strings.Join(list, ","),
		controls.Params{Route: route, Keys: list, To: a}, true)
}

// Reconciliation causes a recorded loss may name (ADR pr6375 §7.12).
var lossCauses = map[string]bool{
	"refund-for-delivered": true, // a refund paid for a packet the destination delivered
	"forged-delivery":      true, // a delivery the honest source never sent
	"collision":            true, // a forged receipt occupied an honest packet's sequence
}

// NewRecordLossRequest records a loss a reconciliation recognized, after 7
// days: chain "gno" or "ethereum", cause one of refund-for-delivered,
// forged-delivery, collision.
func NewRecordLossRequest(cur realm, route, key, denom string, amount int64, chain, incident, cause string) Request {
	mustRoute(route)
	mustIncident(incident)
	if !lossCauses[cause] {
		panic("ibcgov: a loss cause is refund-for-delivered, forged-delivery or collision")
	}
	if chain != controls.ChainGno && chain != controls.ChainEthereum {
		panic("ibcgov: a loss happens on gno or ethereum")
	}
	if _, _, ok := controls.ParsePacketKey(key); !ok || !isDenom(denom) || amount <= 0 {
		panic("ibcgov: a loss names a packet key, a denom and a positive amount")
	}
	text := "loss of " + itoa(amount) + " " + denom + " on " + chain + " for packet " + key + " on route " + route + " (" + cause + ", incident " + incident + ")"
	return routeRequest(cur, controls.OpLoss, "record loss", text,
		controls.Params{Route: route, Key: key, Denom: denom, Amount: amount, Chain: chain, Incident: incident, Cause: cause}, true)
}

// NewRecapitalizeRequest authorizes a recapitalization of route's escrow of
// denom by amount after 7 days; anyone then pays it with
// transfer.Recapitalize(route, id).
func NewRecapitalizeRequest(cur realm, route, denom string, amount int64, incident string) Request {
	mustRoute(route)
	mustIncident(incident)
	if !isDenom(denom) || amount <= 0 {
		panic("ibcgov: a recapitalization names a denom and a positive amount")
	}
	return routeRequest(cur, controls.OpRecapitalize, "recapitalize", "recapitalize "+itoa(amount)+" "+denom+" on route "+route+" (incident "+incident+")",
		controls.Params{Route: route, Denom: denom, Amount: amount, Incident: incident}, true)
}

// NewRevokeRecapRequest revokes the unpaid recapitalization authorization id
// of route, at once (a removal): its funding fell through, and its part of
// the incident's losses is free for another restoring decision. A reduction
// or an accepted deficit decided later revokes conflicting authorizations by
// itself.
func NewRevokeRecapRequest(cur realm, route string, id int64) Request {
	mustRoute(route)
	if r, ok := view().Recap(route, id); !ok || r.Paid || r.Revoked {
		panic("ibcgov: no unpaid recapitalization " + itoa(id) + " on route " + route)
	}
	return routeRequest(cur, controls.OpRevokeRecap, "revoke recap", "revoke recapitalization "+itoa(id)+" on route "+route,
		controls.Params{Route: route, Amount: id}, false)
}

// NewReduceRequest cuts an open or withheld claim, or an unpaid owed sweep
// entry, by amount against an incident after 7 days (a published liability
// reduction; refunds are never reduced).
func NewReduceRequest(cur realm, route, key string, amount int64, incident string) Request {
	mustRoute(route)
	mustIncident(incident)
	if _, _, ok := controls.ParsePacketKey(key); !ok || amount <= 0 {
		panic("ibcgov: a reduction names a packet key and a positive amount")
	}
	return routeRequest(cur, controls.OpReduce, "reduce", "reduce the liability of "+key+" on route "+route+" by "+itoa(amount)+" (incident "+incident+")",
		controls.Params{Route: route, Key: key, Amount: amount, Incident: incident}, true)
}

// NewAcceptDeficitRequest records an accepted deficit after 7 days: the route
// reopens with amount of its losses unrecovered, as the trust statement says.
func NewAcceptDeficitRequest(cur realm, route, denom string, amount int64, incident string) Request {
	mustRoute(route)
	mustIncident(incident)
	if !isDenom(denom) || amount <= 0 {
		panic("ibcgov: an accepted deficit names a denom and a positive amount")
	}
	return routeRequest(cur, controls.OpAccept, "accept deficit", "accept a deficit of "+itoa(amount)+" "+denom+" on route "+route+" (incident "+incident+")",
		controls.Params{Route: route, Denom: denom, Amount: amount, Incident: incident}, true)
}

// NewSettleRequest applies a reconciliation's outcomes to the sends of
// client, a client a replacement retired from route, after 7 days (ADR pr6375
// §7.12, the gno analogue of Ethereum's kind 12): items is a comma-separated
// list of "sequence:action:amount", action 1 a genuine refund: pay its whole
// remainder (amount equals what the send carried minus what was refunded: a
// refund is never cut short; 0 for one paid in full, which only settles the
// record), 2 reject a queued refund none of which was paid (amount 0), 3
// settled as delivered, no refund paid (amount 0), 4 a forged refund: the
// unpaid remainder rejected and what was paid (amount, equal to it) recorded
// as a loss; at most 64 items. Each send is settled exactly once; a queued refund leaves the queue
// under any action.
func NewSettleRequest(cur realm, route, client, items, incident string) Request {
	mustRoute(route)
	mustIncident(incident)
	if view().RetiredRouteOf(client) != route {
		panic("ibcgov: " + client + " is no client a replacement retired from route " + route)
	}
	list := splitList(items)
	if len(list) == 0 || len(list) > controls.MaxKeys {
		panic("ibcgov: name 1 to " + strconv.Itoa(controls.MaxKeys) + " settlement items")
	}
	var parsed []controls.SettleItem
	seen := map[uint64]bool{}
	for _, it := range list {
		parts := strings.Split(it, ":")
		if len(parts) != 3 {
			panic("ibcgov: a settlement item is sequence:action:amount, not " + it)
		}
		seq, err1 := strconv.ParseUint(parts[0], 10, 64)
		action, err2 := strconv.ParseUint(parts[1], 10, 8)
		amount, err3 := strconv.ParseInt(parts[2], 10, 64)
		if err1 != nil || err2 != nil || err3 != nil || seq == 0 || seen[seq] || action < 1 || action > 4 || amount < 0 {
			panic("ibcgov: not a settlement item, or a sequence named twice: " + it)
		}
		if (action == 4 && amount == 0) || ((action == 2 || action == 3) && amount != 0) {
			panic("ibcgov: a forged refund names a positive amount, a rejection or a delivery none: " + it)
		}
		seen[seq] = true
		parsed = append(parsed, controls.SettleItem{Seq: seq, Action: uint8(action), Amount: amount})
	}
	text := "settle sends of " + client + " on route " + route + " (incident " + incident + "): " + strings.Join(list, ",")
	return routeRequest(cur, controls.OpSettle, "settle", text,
		controls.Params{Route: route, Client: client, Items: parsed, Incident: incident}, true)
}

// NewReplaceRouteRequest replaces route's Ethereum client by newClientID after
// 7 days (ADR pr6375 §7.12, R18, the gno.land side): the transfer app re-points
// the route to the new client in constant work (escrow, vouchers and controls
// stay keyed by the route key; denoms on the wire carry the new client id),
// the core retires the old client, and if the governance channel ran over the
// old client its next epoch opens over the new one. newClientID is an Active
// Ethereum client with its counterparty (the new router client) registered.
// The route closes with the replacement: the reconciliation's settlements
// (NewSettleRequest) and restoring decisions follow, then
// NewReopenRouteRequest reopens it. suspectFrom is the gno.land height from
// which acknowledgements and timeouts processed through the old client are
// suspect (ADR pr6375 §7.12): every send of it processed at or after that
// height must be settled before the reopening. As on Ethereum, a route is
// replaced once at a time (never while closed from the previous
// replacement), and the interval never starts before the previous
// replacement.
func NewReplaceRouteRequest(cur realm, route, newClientID string, suspectFrom int64) Request {
	mustRoute(route)
	if suspectFrom < 0 || suspectFrom > chainHeight() {
		panic("ibcgov: the suspect interval starts at a past gno.land height (0 for every record)")
	}
	if view().Closed(route) {
		panic("ibcgov: route " + route + " is still closed from its previous replacement: one replacement at a time")
	}
	if refusal := checkNewRouteClient(newClientID); refusal != "" {
		panic("ibcgov: " + refusal)
	}
	old := view().Client(route)
	text := "replace the client of route " + route + ": " + old + " by " + newClientID + ", suspect from gno.land height " + itoa(suspectFrom)
	rp := &routeParams{op: controls.OpReplace, p: controls.Params{Route: route, Client: newClientID, Height: suspectFrom}, replace: old}
	return propose(cur, "replace route", text, func(cur realm, made, t int64) {
		decide(cur, "replace route", text, rp, made, t, true)
	})
}

// NewReopenRouteRequest reopens a route a replacement closed, after 7 days
// (ADR pr6375 §5.4, §7.12, the gno analogue of Ethereum's kind 13): transfer
// refuses it while any send record of a retired client of the route is
// still open (its commitment outstanding or its refund queued, not settled by
// NewSettleRequest), and records every loss not recapitalized or reduced as
// an accepted deficit.
func NewReopenRouteRequest(cur realm, route string) Request {
	mustRoute(route)
	if !view().Closed(route) {
		panic("ibcgov: route " + route + " is not closed")
	}
	return routeRequest(cur, controls.OpReopen, "reopen route", "reopen route "+route, controls.Params{Route: route}, true)
}

// bindParams opens governance epoch 1 over a client.
type bindParams struct{ client string }

func (p *bindParams) apply(cur realm, t int64) (string, string) {
	if epoch != 0 {
		return "", "the governance channel is bound already"
	}
	switch {
	case core.ClientType(p.client) != ethereum.ClientType || core.IsClientRetired(p.client):
		return "", p.client + " is no usable Ethereum client"
	case core.CounterpartyClientID(p.client) == "":
		return "", p.client + " has no counterparty registered"
	}
	bindChannel(p.client)
	return "governance epoch 1 over " + p.client, ""
}

// NewBindGovernanceRequest binds the governance channel to the Ethereum client
// clientID after 7 days (enrolling a route loosens): it opens epoch 1, whose
// decisions go to IBCAdmin over clientID. Once only: later epochs open with a
// route replacement.
func NewBindGovernanceRequest(cur realm, clientID string) Request {
	if epoch != 0 {
		panic("ibcgov: the governance channel is bound already")
	}
	if core.ClientType(clientID) != ethereum.ClientType || core.CounterpartyClientID(clientID) == "" {
		panic("ibcgov: " + clientID + " is no Ethereum client with a counterparty")
	}
	text := "bind the governance channel to " + clientID + " (epoch 1)"
	p := &bindParams{client: clientID}
	return propose(cur, "bind governance", text, func(cur realm, made, t int64) {
		decide(cur, "bind governance", text, p, made, t, true)
	})
}

// maxActivationDenoms bounds the denoms an activation enables.
const maxActivationDenoms = 16

// activateParams is the switch of the transfer app to an implementation with
// the route controls, staged with its first route and that route's denoms
// so they take effect in the same transaction (ADR pr6375 R17, §6.7, §7.3):
// no moment exists in which an Ethereum client is under the controls but its
// vouchers cannot go back.
type activateParams struct {
	path   string
	enroll controls.Params
	denoms []controls.Params
}

func (p *activateParams) apply(cur realm, t int64) (string, string) {
	// Every refusal the staged steps could meet is checked first, so the
	// switch never lands without its route (it would abort instead).
	if refusal := transfer.CheckUpdateImpl(p.path); refusal != "" {
		return "", refusal
	}
	if !transfer.KeepsControls(p.path) {
		return "", p.path + " keeps no route controls"
	}
	if rd, ok := transfer.ExtView("controls").(controls.Reader); ok {
		for _, d := range p.denoms {
			if old, ok := rd.DenomConfig(p.enroll.Route, d.Denom); ok && old.Kind != d.Config.Kind {
				return "", "denom " + d.Denom + " is accounted as " + old.Kind + " on " + p.enroll.Route + " already"
			}
		}
	}
	if routes.Has(p.enroll.Route) {
		return "", p.enroll.Route + " is a route already"
	}
	if refusal := checkNewRouteClient(p.enroll.Route); refusal != "" {
		return "", refusal
	}
	transfer.UpdateImpl(cross(cur), p.path)
	if refusal := transfer.GovApply(cross(cur), controls.OpEnroll, p.enroll.Encode()); refusal != "" {
		panic("ibcgov: the staged route could not be enrolled: " + refusal)
	}
	routes.Set(p.enroll.Route, &routeRec{epochAt: t})
	for _, d := range p.denoms {
		if refusal := transfer.GovApply(cross(cur), controls.OpDenom, d.Encode()); refusal != "" {
			panic("ibcgov: the staged denom " + d.Denom + " could not be enabled: " + refusal)
		}
	}
	return "transfer " + p.path + " active with route " + p.enroll.Route + " and " + strconv.Itoa(len(p.denoms)) + " denoms", ""
}

// NewTransferActivateControlsRequest switches the transfer app to the
// implementation at path (impl/v1: the route controls) after 7 days, staged
// with its first route: the Ethereum client clientID, enrolled with fee
// collector feeCollector, and the denoms it carries, enabled in the same
// transaction (ADR pr6375 R17). Vouchers impl/v0 minted go back at once after
// the switch, recorded and metered, with no later decision. denoms is a
// ";"-separated list of "denom kind capFloor supplyCap fee feeFloor sendMax
// sendMin refundCap remoteToken" (space-separated, as NewSetDenomRequest
// takes them; remoteToken "-" for none), at most 16.
func NewTransferActivateControlsRequest(cur realm, path, clientID, feeCollector, denoms string) Request {
	mustImplPath(TransferPath, path)
	if refusal := checkNewRouteClient(clientID); refusal != "" {
		panic("ibcgov: " + refusal)
	}
	if routes.Has(clientID) {
		panic("ibcgov: " + clientID + " is a route already")
	}
	fc := mustAddr(feeCollector)
	p := &activateParams{path: path, enroll: controls.Params{Route: clientID, To: fc}}
	var names []string
	seen := map[string]bool{}
	for _, spec := range strings.Split(denoms, ";") {
		f := strings.Fields(spec)
		if len(f) == 0 {
			continue
		}
		if len(f) != 10 {
			panic("ibcgov: a staged denom is \"denom kind capFloor supplyCap fee feeFloor sendMax sendMin refundCap remoteToken\", not " + spec)
		}
		var n [7]int64
		for i := range n {
			v, err := strconv.ParseInt(f[2+i], 10, 64)
			if err != nil {
				panic("ibcgov: not a number: " + f[2+i])
			}
			n[i] = v
		}
		remote := f[9]
		if remote == "-" {
			remote = ""
		}
		denom, c := denomConfig(clientID, f[0], f[1], n[0], n[1], n[2], n[3], n[4], n[5], n[6], remote)
		if seen[denom] {
			panic("ibcgov: denom " + denom + " named twice")
		}
		seen[denom] = true
		p.denoms = append(p.denoms, controls.Params{Route: clientID, Denom: denom, Config: c})
		names = append(names, denomText(denom, c))
	}
	if len(p.denoms) == 0 || len(p.denoms) > maxActivationDenoms {
		panic("ibcgov: stage 1 to " + strconv.Itoa(maxActivationDenoms) + " denoms")
	}
	text := "transfer: activate " + path + " with route " + clientID + " (fee collector " + string(fc) + ") and denoms " + strings.Join(names, "; ")
	return propose(cur, "transfer activate controls", text, func(cur realm, made, t int64) {
		decide(cur, "transfer activate controls", text, p, made, t, true)
	})
}
