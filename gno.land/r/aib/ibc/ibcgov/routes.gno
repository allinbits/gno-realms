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
// accepted deficits, reconciliation payments and route replacements wait 7
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
		note += ": client " + p.replace + " retired"
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
		if rd.RouteOf(client) != "" || rd.RetiredRouteOf(client) != "" {
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

// NewSetDenomRequest enables a denom on route or changes its limits (ADR
// pr6375 §7.1, §7.8, §9): kind "unescrow" (a gno-native token: denom is its
// escrow denom, "ugnot" or a GRC20 alias) or "mint" (an Ethereum token: denom
// is its voucher's IBC denom); capFloor the day cap floor (unescrow) or day
// cap (mint); supplyCap the voucher supply cap (mint, else 0); fee and its
// floor; sendMax and sendMin (unescrow, else 0); refundCap the refund meter's
// day cap. For a minted denom, denom may be the token's Ethereum address
// (0x…): the voucher denom is then computed, ibc/<sha256("transfer/<route>/
// <lower-case address>")>, the denom this chain keys the token's vouchers by.
// A change that only tightens applies at once; a new denom or any loosening
// waits 7 days.
func NewSetDenomRequest(cur realm, route, denom, kind string, capFloor, supplyCap, fee, feeFloor, sendMax, sendMin, refundCap int64) Request {
	mustRoute(route)
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
	c := controls.DenomConfig{Kind: kind, CapFloor: capFloor, SupplyCap: supplyCap, Fee: fee, FeeFloor: feeFloor,
		SendMax: sendMax, SendMin: sendMin, RefundCap: refundCap}
	if err := c.Validate(); err != nil {
		panic("ibcgov: " + err.Error())
	}
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
	text := "denom " + denom + " on route " + route + ": kind=" + kind + " capFloor=" + itoa(capFloor) + " supplyCap=" + itoa(supplyCap) +
		" fee=" + itoa(fee) + " feeFloor=" + itoa(feeFloor) + " sendMax=" + itoa(sendMax) + " sendMin=" + itoa(sendMin) +
		" refundCap=" + itoa(refundCap)
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
// only a packet received on the route with a success acknowledgement, never
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

// NewReduceRequest cuts an open or withheld claim by amount against an
// incident after 7 days (a published liability reduction; refunds are never
// reduced).
func NewReduceRequest(cur realm, route, key string, amount int64, incident string) Request {
	mustRoute(route)
	mustIncident(incident)
	if _, _, ok := controls.ParsePacketKey(key); !ok || amount <= 0 {
		panic("ibcgov: a reduction names a packet key and a positive amount")
	}
	return routeRequest(cur, controls.OpReduce, "reduce", "reduce claim "+key+" on route "+route+" by "+itoa(amount)+" (incident "+incident+")",
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

// NewRejectRefundRequest rejects a queued refund a reconciliation found was
// for a delivered packet, after 7 days.
func NewRejectRefundRequest(cur realm, route, sendKey, incident string) Request {
	mustRoute(route)
	mustIncident(incident)
	if _, _, ok := controls.ParsePacketKey(sendKey); !ok {
		panic("ibcgov: not a packet key: " + sendKey)
	}
	return routeRequest(cur, controls.OpRejectRefund, "reject refund", "reject the queued refund of "+sendKey+" on route "+route+" (incident "+incident+")",
		controls.Params{Route: route, Key: sendKey, Incident: incident}, true)
}

// NewPayEntitlementRequest pays a sender what a reconciliation found it is
// owed on a send (its amount minus what was refunded), after 7 days.
func NewPayEntitlementRequest(cur realm, route, sendKey string, amount int64, incident string) Request {
	mustRoute(route)
	mustIncident(incident)
	if _, _, ok := controls.ParsePacketKey(sendKey); !ok || amount <= 0 {
		panic("ibcgov: a payment names a packet key and a positive amount")
	}
	return routeRequest(cur, controls.OpPayEntitlement, "pay entitlement", "pay "+itoa(amount)+" for send "+sendKey+" on route "+route+" (incident "+incident+")",
		controls.Params{Route: route, Key: sendKey, Amount: amount, Incident: incident}, true)
}

// NewReplaceRouteRequest replaces route's Ethereum client by newClientID after
// 7 days (ADR pr6375 §7.12, R18, the gno.land side): the transfer app re-points
// the route to the new client in constant work (escrow, vouchers and controls
// stay keyed by the route key; denoms on the wire carry the new client id),
// the core retires the old client, and if the governance channel ran over the
// old client its next epoch opens over the new one. newClientID is an Active
// Ethereum client with its counterparty (the new router client) registered.
func NewReplaceRouteRequest(cur realm, route, newClientID string) Request {
	mustRoute(route)
	if refusal := checkNewRouteClient(newClientID); refusal != "" {
		panic("ibcgov: " + refusal)
	}
	old := view().Client(route)
	text := "replace the client of route " + route + ": " + old + " by " + newClientID
	rp := &routeParams{op: controls.OpReplace, p: controls.Params{Route: route, Client: newClientID}, replace: old}
	return propose(cur, "replace route", text, func(cur realm, made, t int64) {
		decide(cur, "replace route", text, rp, made, t, true)
	})
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
