package controls

import (
	"strconv"
	"strings"

	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/avl/v0"
)

// Reader is a read-only view of a Registry: it exposes no mutator and hands
// out values only, so the transfer proxy can give it to anyone (its renders,
// ibcgov's builders, monitors). Its registry pointer is unexported, so no
// other package can reach the Registry's mutators through it.
type Reader struct {
	r *Registry
}

// Valid reports whether the reader views a registry.
func (rd Reader) Valid() bool { return rd.r != nil }

func (rd Reader) route(key string) *Route {
	if rd.r == nil {
		return nil
	}
	return rd.r.Route(key)
}

// Routes lists the route keys.
func (rd Reader) Routes() []string {
	if rd.r == nil {
		return nil
	}
	return rd.r.Keys()
}

// RouteOf is the key of the route whose current client is clientID, or "".
func (rd Reader) RouteOf(clientID string) string {
	if rd.r == nil {
		return ""
	}
	if rt := rd.r.RouteOf(clientID); rt != nil {
		return rt.Key
	}
	return ""
}

// RetiredRouteOf is the key of the route a replacement retired clientID
// from, or "".
func (rd Reader) RetiredRouteOf(clientID string) string {
	if rd.r == nil {
		return ""
	}
	return rd.r.RetiredRouteOf(clientID)
}

// Client is the current client of a route, or "".
func (rd Reader) Client(route string) string {
	if rt := rd.route(route); rt != nil {
		return rt.Client
	}
	return ""
}

// LossClosed reports whether a route takes no new exposure because a loss
// has no restoring decision (see Route.ExposureClosed).
func (rd Reader) LossClosed(route string) bool {
	if rt := rd.route(route); rt != nil {
		return rt.LossClosed()
	}
	return false
}

// Closed reports whether a replacement closed a route (see Route.IsClosed).
func (rd Reader) Closed(route string) bool {
	if rt := rd.route(route); rt != nil {
		return rt.IsClosed()
	}
	return false
}

// FeeCollector is a route's fee collector, or "".
func (rd Reader) FeeCollector(route string) address {
	if rt := rd.route(route); rt != nil {
		return rt.FeeCollector
	}
	return ""
}

// Denoms lists a route's denoms.
func (rd Reader) Denoms(route string) []string {
	if rt := rd.route(route); rt != nil {
		return rt.Denoms()
	}
	return nil
}

// DenomConfig is a denom's configuration, and whether it is enabled.
func (rd Reader) DenomConfig(route, denom string) (DenomConfig, bool) {
	if rt := rd.route(route); rt != nil {
		if d := rt.Denom(denom); d != nil {
			return d.Config, true
		}
	}
	return DenomConfig{}, false
}

// Totals is a denom's accounting, and whether it is enabled.
func (rd Reader) Totals(route, denom string) (Totals, bool) {
	if rt := rd.route(route); rt != nil {
		if d := rt.Denom(denom); d != nil {
			return d.Totals, true
		}
	}
	return Totals{}, false
}

// Claim is a claim by packet key.
func (rd Reader) Claim(route, key string) (Claim, bool) {
	if rt := rd.route(route); rt != nil {
		return rt.Claim(key)
	}
	return Claim{}, false
}

// Sweep is a sweep entry by packet key.
func (rd Reader) Sweep(route, key string) (SweepEntry, bool) {
	if rt := rd.route(route); rt != nil {
		return rt.Sweep(key)
	}
	return SweepEntry{}, false
}

// Send is a send record by packet key.
func (rd Reader) Send(route, key string) (SendRecord, bool) {
	if rt := rd.route(route); rt != nil {
		return rt.Send(key)
	}
	return SendRecord{}, false
}

// Voidable reports whether a void can take key as it stands.
func (rd Reader) Voidable(route, key string, forged bool) bool {
	if rt := rd.route(route); rt != nil {
		return rt.Voidable(key, forged)
	}
	return false
}

// Unrecovered is a route's economic open loss total.
func (rd Reader) Unrecovered(route string) int64 {
	if rt := rd.route(route); rt != nil {
		return rt.Unrecovered()
	}
	return 0
}

// Unresolved is a route's loss total still waiting for a restoring decision.
func (rd Reader) Unresolved(route string) int64 {
	if rt := rd.route(route); rt != nil {
		return rt.Unresolved()
	}
	return 0
}

// Meters is what the bridge meter and a recipient's meter of a denom hold at
// now under the payouts epoch (epoch, as of epochAt) and lock, as PayClaims
// would find them, computed on copies: the state does not change. A
// recipient without a queue reads 0.
func (rd Reader) Meters(route, denom string, to address, now, epoch, epochAt, lock int64) (bridge, recipient int64) {
	rt := rd.route(route)
	if rt == nil {
		return 0, 0
	}
	d := rt.Denom(denom)
	if d == nil {
		return 0, 0
	}
	c := d.DayCap(lock)
	m := d.meter
	m.Refill(now, c, c, epoch, epochAt)
	if v := d.queues.Get(string(to)); v != nil {
		q := v.(*queue).meter
		q.Refill(now, c/4, c/4, epoch, epochAt)
		recipient = q.Level
	}
	return m.Level, recipient
}

// IsRefused reports whether addr is a refused send recipient of the route.
func (rd Reader) IsRefused(route, addr string) bool {
	if rt := rd.route(route); rt != nil {
		return rt.IsRefused(addr)
	}
	return false
}

// Recap is a recapitalization authorization of a route.
func (rd Reader) Recap(route string, id int64) (Recap, bool) {
	if rt := rd.route(route); rt != nil {
		return rt.Recap(id)
	}
	return Recap{}, false
}

// ------------------------------------------------------------------- JSON

func q(s string) string { return strconv.Quote(s) }

func strList(ss []string) string {
	parts := make([]string, len(ss))
	for i, s := range ss {
		parts[i] = q(s)
	}
	return "[" + strings.Join(parts, ",") + "]"
}

// RoutesJSON is every route's JSON, as an array.
func (rd Reader) RoutesJSON() string {
	var parts []string
	for _, k := range rd.Routes() {
		parts = append(parts, rd.RouteJSON(k))
	}
	return "[" + strings.Join(parts, ",") + "]"
}

// RouteJSON is a route's state for monitors (ADR pr6375 §7.11): its client,
// its retired clients, its fee collector, its refused recipients, and per
// denom the configuration, the meter levels as last refilled and the
// accounting terms. "null" for an unknown route.
func (rd Reader) RouteJSON(route string) string {
	rt := rd.route(route)
	if rt == nil {
		return "null"
	}
	var b strings.Builder
	b.WriteString("{\"route\":" + q(rt.Key) + ",\"client\":" + q(rt.Client) + ",\"replaced\":" + strList(rt.Replaced) +
		",\"enrolled\":" + itoa(rt.Enrolled) + ",\"activated\":" + itoa(rt.Activated) + ",\"closed\":" + strconv.FormatBool(rt.IsClosed()) + ",\"loss_closed\":" + strconv.FormatBool(rt.LossClosed()) + ",\"fee_collector\":" + q(string(rt.FeeCollector)) +
		",\"refused_recipients\":" + strList(rt.Refused()) + ",\"unrecovered\":" + itoa(rt.Unrecovered()) + ",\"unresolved\":" + itoa(rt.Unresolved()) + ",\"denoms\":[")
	for i, name := range rt.Denoms() {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(denomJSON(rt.Denom(name)))
	}
	b.WriteString("]}")
	return b.String()
}

func denomJSON(d *Denom) string {
	c, t := d.Config, d.Totals
	return "{\"denom\":" + q(d.Name) + ",\"kind\":" + q(c.Kind) +
		",\"cap_floor\":" + itoa(c.CapFloor) + ",\"launch_cap_floor\":" + itoa(d.LaunchCapFloor) +
		",\"supply_cap\":" + itoa(c.SupplyCap) + ",\"fee\":" + itoa(c.Fee) + ",\"fee_floor\":" + itoa(c.FeeFloor) +
		",\"send_max\":" + itoa(c.SendMax) + ",\"send_min\":" + itoa(c.SendMin) + ",\"refund_cap\":" + itoa(c.RefundCap) + ",\"remote\":" + q(c.Remote) +
		",\"meter\":{\"level\":" + itoa(d.meter.Level) + ",\"at\":" + itoa(d.meter.At) + ",\"epoch\":" + itoa(d.meter.Epoch) + "}" +
		",\"refund_meter\":{\"level\":" + itoa(d.refundMeter.Level) + ",\"at\":" + itoa(d.refundMeter.At) + "}" +
		",\"waiting\":" + itoa(int64(d.waiting.Size())) + ",\"queued_refunds\":" + itoa(int64(d.refundQueue.Size())) +
		",\"totals\":{\"credited\":" + itoa(t.Credited) + ",\"owed\":" + itoa(t.Owed) + ",\"withheld\":" + itoa(t.Withheld) +
		",\"swept\":" + itoa(t.Swept) + ",\"paid\":" + itoa(t.Paid) + ",\"fees\":" + itoa(t.Fees) +
		",\"sweep_paid\":" + itoa(t.SweepPaid) + ",\"outstanding\":" + itoa(t.Outstanding) + ",\"returning\":" + itoa(t.Returning) + ",\"sent\":" + itoa(t.Sent) +
		",\"send_fees\":" + itoa(t.SendFees) + ",\"refunded\":" + itoa(t.Refunded) + ",\"queued_refunds\":" + itoa(t.QueuedRefunds) +
		",\"lost\":" + itoa(t.Lost) + ",\"recapitalized\":" + itoa(t.Recapitalized) + ",\"reduced\":" + itoa(t.Reduced) +
		",\"accepted\":" + itoa(t.Accepted) + ",\"unrecovered\":" + itoa(t.Unrecovered()) + ",\"unresolved\":" + itoa(t.Unresolved()) + "}}"
}

// ClaimJSON is a claim's JSON.
func ClaimJSON(c Claim) string {
	return "{\"key\":" + q(c.Key) + ",\"denom\":" + q(c.Denom) + ",\"to\":" + q(string(c.To)) +
		",\"amount\":" + itoa(c.Amount) + ",\"paid\":" + itoa(c.Paid) + ",\"reduced\":" + itoa(c.Reduced) +
		",\"state\":" + q(c.State) + ",\"by\":" + q(c.By) + ",\"at\":" + itoa(c.At) + ",\"height\":" + itoa(c.Height) +
		",\"seq\":" + itoa(c.Seq) + "}"
}

// SweepJSON is a sweep entry's JSON.
func SweepJSON(e SweepEntry) string {
	return "{\"key\":" + q(e.Key) + ",\"denom\":" + q(e.Denom) + ",\"to\":" + q(e.To) + ",\"amount\":" + itoa(e.Amount) +
		",\"reason\":" + q(e.Reason) + ",\"height\":" + itoa(e.Height) + ",\"voided\":" + strconv.FormatBool(e.Voided) +
		",\"paid\":" + strconv.FormatBool(e.Paid) + ",\"paid_to\":" + q(e.PaidTo) + "}"
}

// SendJSON is a send record's JSON: the full packet (hex payload values), its
// commitment, the send's metadata and what the callbacks attached.
func SendJSON(r SendRecord) string {
	return "{\"key\":" + q(r.Key) + ",\"packet\":" + packetJSON(r.Packet) + ",\"commitment\":" + q(hexs(r.Commitment)) +
		",\"sender\":" + q(string(r.Sender)) + ",\"receiver\":" + q(r.Receiver) + ",\"denom\":" + q(r.Denom) +
		",\"kind\":" + q(r.Kind) + ",\"amount\":" + itoa(r.Amount) + ",\"fee\":" + itoa(r.Fee) +
		",\"sent_height\":" + itoa(r.SentHeight) + ",\"sent_at\":" + itoa(r.SentAt) + ",\"backfilled\":" + strconv.FormatBool(r.Backfilled) + ",\"outcome\":" + q(r.Outcome) +
		",\"processed_height\":" + itoa(r.ProcessedHeight) + ",\"processed_at\":" + itoa(r.ProcessedAt) +
		",\"payment\":" + q(r.Payment) + ",\"refunded\":" + itoa(r.Refunded) + ",\"settlement\":" + itoa(int64(r.Settlement)) + ",\"reservation\":" + itoa(r.Reservation) + ",\"incident\":" + q(r.Incident) + "}"
}

func packetJSON(p types.Packet) string {
	var pl []string
	for _, x := range p.Payloads {
		pl = append(pl, "{\"source_port\":"+q(x.SourcePort)+",\"destination_port\":"+q(x.DestinationPort)+
			",\"version\":"+q(x.Version)+",\"encoding\":"+q(x.Encoding)+",\"value\":"+q(hexs(x.Value))+"}")
	}
	return "{\"sequence\":" + strconv.FormatUint(p.Sequence, 10) + ",\"source_client\":" + q(p.SourceClient) +
		",\"destination_client\":" + q(p.DestinationClient) + ",\"timeout_timestamp\":" +
		strconv.FormatUint(p.TimeoutTimestamp, 10) + ",\"payloads\":[" + strings.Join(pl, ",") + "]}"
}

const hexDigits = "0123456789abcdef"

func hexs(b []byte) string {
	out := make([]byte, 2*len(b))
	for i, c := range b {
		out[2*i], out[2*i+1] = hexDigits[c>>4], hexDigits[c&0xf]
	}
	return string(out)
}

// LossJSON is a loss's JSON.
func LossJSON(l Loss) string {
	return "{\"key\":" + q(l.Key) + ",\"denom\":" + q(l.Denom) + ",\"amount\":" + itoa(l.Amount) + ",\"chain\":" + q(l.Chain) +
		",\"incident\":" + q(l.Incident) + ",\"cause\":" + q(l.Cause) + "}"
}

// page walks a tree from the first key at or after from, up to PageLines.
func page(t *avl.Tree, from string, fn func(v any) string) string {
	var parts []string
	t.Iterate(from, "", func(_ string, v any) bool {
		parts = append(parts, fn(v))
		return len(parts) >= PageLines
	})
	return "[" + strings.Join(parts, ",") + "]"
}

// ClaimsJSON is a page of a route's claims (every state), by packet key from
// from on.
func (rd Reader) ClaimsJSON(route, from string) string {
	rt := rd.route(route)
	if rt == nil {
		return "[]"
	}
	return page(&rt.claims, from, func(v any) string { return ClaimJSON(*v.(*Claim)) })
}

// SweepsJSON is a page of a route's sweep entries, by packet key.
func (rd Reader) SweepsJSON(route, from string) string {
	rt := rd.route(route)
	if rt == nil {
		return "[]"
	}
	return page(&rt.sweeps, from, func(v any) string { return SweepJSON(*v.(*SweepEntry)) })
}

// SendsJSON is a page of a route's send records, by packet key.
func (rd Reader) SendsJSON(route, from string) string {
	rt := rd.route(route)
	if rt == nil {
		return "[]"
	}
	return page(&rt.sends, from, func(v any) string { return SendJSON(*v.(*SendRecord)) })
}

// LossesJSON is a page of a route's loss ledger.
func (rd Reader) LossesJSON(route, from string) string {
	rt := rd.route(route)
	if rt == nil {
		return "[]"
	}
	return page(&rt.losses, from, func(v any) string { return LossJSON(*v.(*Loss)) })
}
