package ibcgov

import (
	"chain"
	"strconv"
	"strings"

	"gno.land/p/aib/decisions/v0"
	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/r/aib/ibc/core"
)

// The guardians on gno.land (ADR pr6375 §7.4, R10), per route (ADR 0007
// §5): each route has six seats, 0–3 the guardians (2 and 3 the outsiders')
// and 4–5 the operator's watch keys, each holding one gno address; one key
// may hold seats on several routes, each seat independent. A seat flags a
// function of its route, keyed by the route key: sends (gno-native sends),
// credits (receives from the counterparty), payouts (claim payouts) or
// refunds (the refunds hold of §7.13, which delays error-ack and timeout
// refunds and the payout of queued refunds). One flag pauses the function
// at once. Flags never stop voucher returns (burns), acknowledgements or
// timeouts; only the refunds flag delays refunds, never cancels them. A seat
// clears its own flag; an unpause decision clears every seat's flags of a
// function. Clearing a payouts flag starts the route's meters empty (a new
// payouts epoch). A seat may also flag a candidate client of its route
// before it joins (an enrolment's or a replacement's), which its flags
// follow when it joins that route.
//
// Two guardian seats of a route flagging (anything) make the route's hold:
// its queued decisions are deferred and its unpause decisions spent; every
// global decision is deferred too, to day 21 of the global hold that first
// deferred it (ADR 0007 §6). A hold ends 24 hours after fewer than two of
// the route's guardian seats flag. A seat change, a vacancy included, waits
// 7 days and lands through its route's hold no sooner than day 21 of it. A
// guardian's payouts flag may name the packets it suspects, which makes
// their void immediate. Guardians delay; they never veto.

const (
	SeatCount     = 6
	GuardianSeats = 4 // seats 0–3

	FnSends   = "sends"
	FnCredits = "credits"
	FnPayouts = "payouts"
	FnRefunds = "refunds"

	// holdLinger is how long a hold outlives the second flag's clearing.
	holdLinger = decisions.Day / decisions.Factor
	// holdReplacementWait is how long into a hold a seat change, or a global
	// decision, waits before it can land (day 21).
	holdReplacementWait = 21 * decisions.Day / decisions.Factor
)

// A seat's generation grows when its key leaves (removal or replacement): a
// flag counts only while its generation is the seat's, so a departing key's
// flags stop counting in constant work, however many there are. seatFlags
// counts each seat's live flags, kept as flags are set and cleared, which
// the hold reads in constant work. The stale entries are removed lazily: by
// a later flag at the same key, an unpause, a fold, or PruneFlags, which
// anyone may call. genEnds records when each ended seat generation ended,
// kept while entries of its flags remain: a flag reads its own generation's
// end, so a later generation of the seat ending does not move an earlier
// one's. A record goes with the last entry of its generation, so there is at
// most one per stale entry. All of it is the route's own.

// genEnd is when a seat generation ended and how many of its flags'
// entries remain.
type genEnd struct {
	at   int64
	left int64
}

func genKey(seat int, gen uint64) string {
	return strconv.Itoa(seat) + "|" + strconv.FormatUint(gen, 10)
}

type flag struct {
	seat int
	gen  uint64 // the seat's generation when it was set
	at   int64
	keys []string // a guardian's payouts flag: the packets it suspects
}

// live reports whether f still counts: its seat's key has not left since.
func (g *routeGov) live(f *flag) bool { return f.gen == g.seatGen[f.seat] }

// endedAt is when the generation of a flag that no longer counts ended.
func (g *routeGov) endedAt(f *flag) int64 {
	return g.genEnds.Get(genKey(f.seat, f.gen)).(*genEnd).at
}

// dropStale removes the entry at k of a flag that no longer counts, and its
// generation's record with the last of its entries.
func (g *routeGov) dropStale(k string, f *flag) {
	g.flags.Remove(k)
	gk := genKey(f.seat, f.gen)
	e := g.genEnds.Get(gk).(*genEnd)
	if e.left--; e.left == 0 {
		g.genEnds.Remove(gk)
	}
}

// flagKey is a flag's key in its route's record: the target it stands on
// (the route key, or a candidate client), the function and the seat.
func flagKey(target, fn string, seat int) string {
	return target + "|" + fn + "|" + strconv.Itoa(seat)
}
func flagPrefix(target, fn string) string { return target + "|" + fn + "|" }

func isFn(fn string) bool {
	return fn == FnSends || fn == FnCredits || fn == FnPayouts || fn == FnRefunds
}

// Seat is the address in seat n of route, "" if empty, out of range or no
// such route.
func Seat(route string, n int) address {
	g := govOf(routeKeyOf(route))
	if g == nil || n < 0 || n >= SeatCount {
		return ""
	}
	return g.seats[n]
}

// SeatOf is the seat an address holds on route, -1 if none.
func SeatOf(route string, a address) int {
	g := govOf(routeKeyOf(route))
	if g == nil {
		return -1
	}
	return g.seatOf(a)
}

func (g *routeGov) seatOf(a address) int {
	if a == "" {
		return -1
	}
	for i := 0; i < SeatCount; i++ {
		if g.seats[i] == a {
			return i
		}
	}
	return -1
}

// IsGuardianSeat reports whether seat n is a guardian's (0–3).
func IsGuardianSeat(n int) bool { return n >= 0 && n < GuardianSeats }

// foldFlags moves g's flags standing under the candidate from to the route
// key, when from becomes one of the route's clients (a replacement), and
// returns how many it moved. A seat's flag of a function standing under
// both is kept once, with the earlier time and the packets both name. Only
// the route's own seats' flags move: another route's flags on the same
// client stay with that route.
func foldFlags(g *routeGov, from string, t int64) int {
	to := g.key
	if from == to {
		return 0
	}
	var keys []string
	g.flags.Iterate(from+"|", from+"|~", func(k string, _ any) bool {
		keys = append(keys, k)
		return false
	})
	for _, k := range keys {
		f := g.flags.Get(k).(*flag)
		if !g.live(f) {
			pruneFlag(g, k, f) // its seat's key left: it stopped counting then
			continue
		}
		g.flags.Remove(k)
		fn := strings.Split(k, "|")[1]
		if w := g.flags.Get(flagKey(to, fn, f.seat)); w != nil && !g.live(w.(*flag)) {
			pruneFlag(g, flagKey(to, fn, f.seat), w.(*flag))
		} else if w != nil {
			g.seatFlags[f.seat]-- // merged into the route's own flag
			x := w.(*flag)
			if f.at < x.at {
				x.at = f.at
			}
			for _, key := range f.keys {
				if !contains(x.keys, key) && len(x.keys) < controls.MaxKeys {
					x.keys = append(x.keys, key)
				}
			}
			continue
		}
		g.flags.Set(flagKey(to, fn, f.seat), f)
	}
	if len(keys) > 0 {
		chain.Emit("FlagsMoved", "route", g.key, "from", from, "to", to, "flags", strconv.Itoa(len(keys)))
		updateHold(g, t)
	}
	return len(keys)
}

// hasFlagsOn reports whether g holds flag entries on target.
func (g *routeGov) hasFlagsOn(target string) bool {
	found := false
	g.flags.Iterate(target+"|", target+"|~", func(string, any) bool {
		found = true
		return true
	})
	return found
}

// flagTarget is the key g's flags on target stand under: target itself when
// g holds entries there (a candidate that joined another route since keeps
// g's flags under its own id: g's seats still clear them, and an unpause of
// g still does, ADR 0007 §5), and its route key otherwise.
func flagTarget(g *routeGov, target string) string {
	if target != "" && g.hasFlagsOn(target) {
		return target
	}
	return routeKeyOf(target)
}

// checkTarget is why a seat of route g cannot flag target, or "": target is
// the route itself (its key, or a client of its transfer route), or a
// candidate router client that belongs to no other route (ADR 0007 §5).
func checkTarget(g *routeGov, target string) string {
	if target == g.key {
		return ""
	}
	if routes.Has(target) {
		return "a seat of route " + g.key + " flags its own route or a candidate client, not route " + target
	}
	if !core.IsRouterClient(target) {
		return "no route or router client " + target
	}
	return checkClaim(target, g.key)
}

// Flagged reports whether any seat's flag for fn stands on route: what the
// transfer implementation asks before sending, crediting, paying out or
// refunding.
func Flagged(route, fn string) bool {
	key := routeKeyOf(route)
	g := govOf(key)
	if g == nil {
		return false
	}
	found := false
	g.flags.Iterate(flagPrefix(key, fn), flagPrefix(key, fn)+"~", func(_ string, v any) bool {
		found = g.live(v.(*flag))
		return found
	})
	return found
}

// PayoutsEpoch is how many times a standing payouts flag on route was
// cleared, and when the last was: the route's meters empty when it changes.
func PayoutsEpoch(route string) (epoch, at int64) {
	key := routeKeyOf(route)
	g := govOf(key)
	if g == nil {
		return 0, 0
	}
	epoch, at = g.payEpoch, g.payEpochAt
	// A payouts flag whose seat's key left was cleared then, though its
	// entry is not removed yet: it counts as that clearing (pruneFlag books
	// it the same way when it removes the entry).
	g.flags.Iterate(flagPrefix(key, FnPayouts), flagPrefix(key, FnPayouts)+"~", func(_ string, v any) bool {
		if f := v.(*flag); !g.live(f) {
			epoch++
			if e := g.endedAt(f); e > at {
				at = e
			}
		}
		return false
	})
	return epoch, at
}

// NamedSuspect reports whether a guardian's standing payouts flag on route
// names the packet key: what makes its void immediate.
func NamedSuspect(route, key string) bool {
	rk := routeKeyOf(route)
	g := govOf(rk)
	if g == nil {
		return false
	}
	found := false
	g.flags.Iterate(flagPrefix(rk, FnPayouts), flagPrefix(rk, FnPayouts)+"~", func(_ string, v any) bool {
		f := v.(*flag)
		if !IsGuardianSeat(f.seat) || !g.live(f) {
			return false
		}
		for _, k := range f.keys {
			if k == key {
				found = true
				return true
			}
		}
		return false
	})
	return found
}

// Held reports whether route's guardian hold stands now.
func Held(route string) bool {
	g := govOf(routeKeyOf(route))
	return g != nil && g.heldAt(now())
}

// HoldSince is when route's current hold began, 0 if none stands.
func HoldSince(route string) int64 {
	g := govOf(routeKeyOf(route))
	if g == nil || !g.heldAt(now()) {
		return 0
	}
	return g.holdSince
}

func (g *routeGov) heldAt(t int64) bool {
	if g.holdSince == 0 {
		return false
	}
	return g.belowSince == 0 || t < g.belowSince+holdLinger
}

// flagging reports whether two of g's guardian seats flag (not lingering).
func (g *routeGov) flagging() bool { return g.holdSince != 0 && g.belowSince == 0 }

// guardiansFlagging counts g's guardian seats with a live flag, in constant
// work.
func (g *routeGov) guardiansFlagging() int {
	n := 0
	for s := 0; s < GuardianSeats; s++ {
		if g.seatFlags[s] > 0 {
			n++
		}
	}
	return n
}

// updateHold re-reads g's hold after a flag change at t, and the global
// hold counters with it (ADR 0007 §6).
func updateHold(g *routeGov, t int64) {
	was := g.flagging()
	if g.holdSince != 0 && g.belowSince != 0 && t >= g.belowSince+holdLinger {
		g.holdSince, g.belowSince = 0, 0 // the last hold ended
	}
	if g.guardiansFlagging() >= 2 {
		if g.holdSince == 0 {
			g.holdSince = t
			chain.Emit("Hold", "route", g.key, "since", itoa(t))
		}
		g.belowSince = 0
		if !was {
			if !anyHeldAt(t) {
				globalHeldSince = t // a global hold starts
			}
			routesFlagging++
		}
		return
	}
	if was {
		g.belowSince = t
		routesFlagging--
		if end := t + holdLinger; end > lingerEnd {
			lingerEnd = end
		}
		chain.Emit("HoldEnding", "route", g.key, "at", itoa(t+holdLinger))
	}
}

// parseSuspects reads the packet keys a payouts flag names.
func parseSuspects(s string) []string {
	keys := splitList(s)
	if len(keys) > controls.MaxKeys {
		panic("ibcgov: a flag names at most " + strconv.Itoa(controls.MaxKeys) + " packets")
	}
	for _, k := range keys {
		if _, _, ok := controls.ParsePacketKey(k); !ok {
			panic("ibcgov: not a packet key: " + k)
		}
	}
	return keys
}

// SetFlag sets, or re-asserts, the caller's flag on fn of target, by its
// seat of route: target is route itself, or a candidate router client of it
// that belongs to no other route. keys names the packets a guardian's
// payouts flag suspects (comma-separated packet keys, "client/sequence"
// with 20 digits), "" otherwise; a re-assertion replaces them. The caller is
// cur.Previous(): the seat's key itself.
func SetFlag(cur realm, route, target, fn, keys string) {
	g := mustGov(route)
	seat := g.seatOf(cur.Previous().Address())
	if seat < 0 {
		panic("ibcgov: not a guardian or a watch key of route " + g.key + ": " + who(0, cur.Previous()))
	}
	target = routeKeyOf(target)
	if refusal := checkTarget(g, target); refusal != "" {
		panic("ibcgov: " + refusal)
	}
	if !isFn(fn) {
		panic("ibcgov: the function is sends, credits, payouts or refunds, not " + fn)
	}
	list := parseSuspects(keys)
	if len(list) > 0 && (fn != FnPayouts || !IsGuardianSeat(seat)) {
		panic("ibcgov: only a guardian's payouts flag names packets")
	}
	t := now()
	k := flagKey(target, fn, seat)
	if v := g.flags.Get(k); v != nil && g.live(v.(*flag)) {
		g.seatFlags[seat]-- // a re-assertion replaces the live flag
	} else if v != nil {
		pruneFlag(g, k, v.(*flag)) // a departed key's entry at the same place
	}
	g.flags.Set(k, &flag{seat: seat, gen: g.seatGen[seat], at: t, keys: list})
	g.seatFlags[seat]++
	updateHold(g, t)
	chain.Emit("Flag", "route", g.key, "target", target, "fn", fn, "seat", strconv.Itoa(seat), "packets", strconv.Itoa(len(list)))
}

// ClearFlag clears the caller's own flag on fn of target, by its seat of
// route. A route with losses that have no restoring decision stays closed in
// the transfer app whatever the flags (ADR pr6375 §7.9), so clearing a flag,
// ending a hold, never reopens it: the restoring decisions the hold would
// defer can then land.
func ClearFlag(cur realm, route, target, fn string) {
	g := mustGov(route)
	seat := g.seatOf(cur.Previous().Address())
	if seat < 0 {
		panic("ibcgov: not a guardian or a watch key of route " + g.key + ": " + who(0, cur.Previous()))
	}
	target = flagTarget(g, target)
	if v := g.flags.Get(flagKey(target, fn, seat)); v == nil || !g.live(v.(*flag)) {
		panic("ibcgov: no such flag of yours")
	}
	t := now()
	clearFlag(g, target, fn, seat, t)
	updateHold(g, t)
}

// clearFlag clears a live flag.
func clearFlag(g *routeGov, target, fn string, seat int, t int64) {
	g.flags.Remove(flagKey(target, fn, seat))
	g.seatFlags[seat]--
	if fn == FnPayouts && target == g.key {
		bumpPayoutsEpoch(g, t)
	}
	chain.Emit("Unflag", "route", g.key, "target", target, "fn", fn, "seat", strconv.Itoa(seat))
}

// pruneFlag removes the entry of a flag whose seat's key left: it stopped
// counting then; a payouts flag's clearing on the route is booked as of
// then, as PayoutsEpoch already reads it.
func pruneFlag(g *routeGov, k string, f *flag) {
	ended := g.endedAt(f)
	g.dropStale(k, f)
	parts := strings.Split(k, "|")
	if parts[1] == FnPayouts && parts[0] == g.key {
		g.payEpoch++
		if ended > g.payEpochAt {
			g.payEpochAt = ended
		}
	}
}

// PruneFlags removes up to n entries of route's flags whose seat's key left,
// visiting at most n entries of that route from where its last call stopped,
// and returns how many it removed; anyone may call it. A departed key's
// flags stop counting at once (seat generations); this only reclaims their
// storage. Each route has its own cursor and flags: pruning one never walks
// another's.
func PruneFlags(cur realm, route string, n int) int {
	if n <= 0 || n > controls.MaxKeys {
		panic("ibcgov: prune 1 to " + strconv.Itoa(controls.MaxKeys) + " entries a call")
	}
	g := mustGov(route)
	var stale []string
	visited := 0
	last := ""
	stopped := g.flags.Iterate(after(g.pruneAfter), "", func(k string, v any) bool {
		if visited == n {
			return true
		}
		visited++
		last = k
		if !g.live(v.(*flag)) {
			stale = append(stale, k)
		}
		return false
	})
	if !stopped {
		last = "" // the walk reached the end: the next starts over
	}
	g.pruneAfter = last
	for _, k := range stale {
		pruneFlag(g, k, g.flags.Get(k).(*flag))
	}
	return len(stale)
}

// after is the first key an iteration resumes at, past cursor ("" from the
// start).
func after(cursor string) string {
	if cursor == "" {
		return ""
	}
	return cursor + "\x00"
}

func bumpPayoutsEpoch(g *routeGov, t int64) {
	g.payEpoch++
	g.payEpochAt = t
}

// clearFns clears every seat's flags of fns on target in g and returns how
// many.
func clearFns(g *routeGov, target string, fns []string, t int64) int {
	n := 0
	for _, fn := range fns {
		var live []int
		stale := map[string]*flag{}
		g.flags.Iterate(flagPrefix(target, fn), flagPrefix(target, fn)+"~", func(k string, v any) bool {
			if f := v.(*flag); g.live(f) {
				live = append(live, f.seat)
			} else {
				stale[k] = f
			}
			return false
		})
		for k, f := range stale {
			pruneFlag(g, k, f)
		}
		for _, s := range live {
			clearFlag(g, target, fn, s, t)
			n++
		}
	}
	updateHold(g, t)
	return n
}

// clearSeat ends every flag of a seat of g (its key leaves), in constant
// work: the seat's generation grows, so its flags stop counting; their
// entries are pruned lazily.
func clearSeat(g *routeGov, seat int, t int64) {
	if g.seatFlags[seat] > 0 {
		g.genEnds.Set(genKey(seat, g.seatGen[seat]), &genEnd{at: t, left: g.seatFlags[seat]})
	}
	g.seatGen[seat]++
	g.seatFlags[seat] = 0
	chain.Emit("SeatFlagsEnded", "route", g.key, "seat", strconv.Itoa(seat))
	updateHold(g, t)
}

// Flags lists route's standing flags on target (route itself when target is
// "") as "fn seat <n> at <time>" lines, with the packets a payouts flag
// names.
func Flags(route, target string) []string {
	g := govOf(routeKeyOf(route))
	if g == nil {
		return nil
	}
	if target == "" {
		target = g.key
	}
	target = flagTarget(g, target)
	var out []string
	g.flags.Iterate(target+"|", target+"|~", func(k string, v any) bool {
		f := v.(*flag)
		if !g.live(f) {
			return false
		}
		line := strings.Split(k, "|")[1] + " seat " + strconv.Itoa(f.seat) + " at " + itoa(f.at)
		if len(f.keys) > 0 {
			line += " naming " + strings.Join(f.keys, ",")
		}
		out = append(out, line)
		return false
	})
	return out
}

// ------------------------------------------------------------------ seats

// holdBounded is implemented by a route-scoped decision its route's hold
// defers only to day 21 of the hold that first deferred it once it was due:
// a seat change. Global decisions are bounded the same way by the global
// hold (Execute).
type holdBounded interface{ boundedByHold() }

// seatsParams is a seat change of one route: each seat in order gets its
// address ("" to vacate). held records the seats' holders when the decision
// was made: a removal of a seat whose occupant changed since is skipped. A
// seat change naming a key no route record uses creates the route's
// provisional record when it applies (ADR 0007 §5).
type seatsParams struct {
	route   string
	seats   []int
	addrs   []address
	held    []address
	heldGen []uint64 // each seat's generation when the request was built
}

func (*seatsParams) boundedByHold() {}

// checkProvisional is why key cannot start a provisional route record, or
// "": a router client that is no transfer route's, not retired, belongs to
// no other route, and whose chain is free.
func checkProvisional(key string) string {
	switch {
	case !core.IsRouterClient(key):
		return key + " is no router client"
	case core.IsClientRetiredAny(key):
		return key + " is retired"
	}
	if rd := transferView(); rd.Valid() && (rd.RouteOf(key) != "" || rd.RetiredRouteOf(key) != "") {
		return key + " is a route's client already"
	}
	if refusal := checkClaim(key, key); refusal != "" {
		return refusal
	}
	return checkChainFree(key, key)
}

func (p *seatsParams) apply(cur realm, t int64) (string, string) {
	g := govOf(p.route)
	if g == nil {
		if refusal := checkProvisional(p.route); refusal != "" {
			return "", refusal
		}
	}
	// Re-check against live state: no address may end up in two seats.
	var cur6 [SeatCount]address
	var gens [SeatCount]uint64
	if g != nil {
		cur6, gens = g.seats, g.seatGen
	}
	next := cur6
	for i, s := range p.seats {
		// A vacancy removes the very tenure it was requested against: the
		// same key in the same generation. A seat that changed hands since,
		// even back to that key (a new generation), is left alone.
		if p.addrs[i] == "" && (cur6[s] != p.held[i] || gens[s] != p.heldGen[i]) {
			continue
		}
		next[s] = p.addrs[i]
	}
	for i := 0; i < SeatCount; i++ {
		for j := i + 1; j < SeatCount; j++ {
			if next[i] != "" && next[i] == next[j] {
				return "", "address " + string(next[i]) + " would hold seats " + strconv.Itoa(i) + " and " + strconv.Itoa(j) + " of route " + p.route
			}
		}
	}
	if next == cur6 {
		return "", "nothing to change"
	}
	// Only a change that applies creates the provisional record.
	created := false
	if g == nil {
		g = newRecord(p.route, core.ClientChainIdentity(p.route))
		created = true
	}
	var changed []string
	for i := 0; i < SeatCount; i++ {
		if next[i] != g.seats[i] {
			clearSeat(g, i, t)
			g.seats[i] = next[i]
			changed = append(changed, strconv.Itoa(i))
			chain.Emit("SeatSet", "route", g.key, "seat", strconv.Itoa(i), "address", string(next[i]))
		}
	}
	note := "seats " + strings.Join(changed, ",") + " of route " + g.key
	if created {
		note += " (a provisional route record)"
	}
	return note, ""
}

// NewSetSeatsRequest changes guardian and watch-key seats of route: changes
// is a comma-separated list of "seat:address" (seat 0–5; an empty address
// vacates the seat). At most two guardian seats per decision; no address in
// two seats of the route. Every seat change, a vacancy included (ADR pr6375
// §7.4), waits 7 days, and through the route's guardian hold no sooner than
// day 21 of it. route is a route key with a record, enrolled or
// provisional, or a router client no route uses yet: the decision then
// creates its provisional record when it applies, reserving its chain (ADR
// 0007 §5).
func NewSetSeatsRequest(cur realm, route, changes string) Request {
	key := routeKeyOf(route)
	g := govOf(key)
	if g == nil {
		if refusal := checkProvisional(key); refusal != "" {
			panic("ibcgov: " + refusal)
		}
	}
	var seats [SeatCount]address
	var gens [SeatCount]uint64
	if g != nil {
		seats, gens = g.seats, g.seatGen
	}
	items := splitList(changes)
	if len(items) == 0 || len(items) > SeatCount {
		panic("ibcgov: name 1 to 6 seat changes")
	}
	p := &seatsParams{route: key}
	seen := map[int]bool{}
	guardians := 0
	var parts []string
	for _, it := range items {
		i := strings.Index(it, ":")
		if i < 0 {
			panic("ibcgov: a seat change is seat:address, not " + it)
		}
		n, err := strconv.Atoi(it[:i])
		if err != nil || n < 0 || n >= SeatCount || seen[n] {
			panic("ibcgov: not a seat, or named twice: " + it[:i])
		}
		seen[n] = true
		var a address
		if raw := strings.TrimSpace(it[i+1:]); raw != "" {
			a = mustAddr(raw)
			if seats[n] == a {
				panic("ibcgov: seat " + strconv.Itoa(n) + " of route " + key + " holds " + string(a) + " already")
			}
		}
		if IsGuardianSeat(n) {
			guardians++
		}
		p.seats = append(p.seats, n)
		p.addrs = append(p.addrs, a)
		p.held = append(p.held, seats[n])
		p.heldGen = append(p.heldGen, gens[n])
		parts = append(parts, strconv.Itoa(n)+"="+string(a))
	}
	if guardians > 2 {
		panic("ibcgov: a decision changes at most two guardian seats")
	}
	// No address may end up in two seats of the route (re-checked when it
	// applies).
	next := seats
	for i, n := range p.seats {
		next[n] = p.addrs[i]
	}
	for i := 0; i < SeatCount; i++ {
		for j := i + 1; j < SeatCount; j++ {
			if next[i] != "" && next[i] == next[j] {
				panic("ibcgov: " + string(next[i]) + " would hold seats " + strconv.Itoa(i) + " and " + strconv.Itoa(j) + " of route " + key)
			}
		}
	}
	text := "set seats of route " + key + ": " + strings.Join(parts, ",")
	var sc scope
	if g == nil {
		sc = routeScope(key, key) // claims the client for the record it creates
	} else {
		sc = routeScope(key)
	}
	return propose(cur, "set seats", text, func(cur realm, made, t int64) {
		// Fresh parameters for every recording: each decision keeps its own
		// scope and hold anchor, so a Request governed twice makes two
		// decisions that never share one.
		q := &seatsParams{route: p.route, seats: p.seats, addrs: p.addrs, held: p.held, heldGen: p.heldGen}
		decide(cur, "set seats", text, q, made, t, true, sc)
	})
}

// ------------------------------------------------------------- unpausing

// unpauseRouteParams clears every seat's flags of fns on a target of a
// route.
type unpauseRouteParams struct {
	route  string
	target string
	fns    []string
}

func (*unpauseRouteParams) unpause() {}

func (p *unpauseRouteParams) apply(cur realm, t int64) (string, string) {
	g := govOf(p.route)
	if g == nil {
		return "", "no route " + p.route
	}
	// The client named may have become the route's alias since the decision.
	n := clearFns(g, flagTarget(g, p.target), p.fns, t)
	if n == 0 {
		return "", "no flag stood"
	}
	return "cleared " + strconv.Itoa(n) + " flags of route " + p.route, ""
}

// NewUnpauseRouteRequest clears every seat's flags of fns (comma-separated:
// sends, credits, payouts, refunds) of route on target (route itself, or a
// candidate client its seats flagged), at once (ADR pr6375 §7.4: on gno.land
// GovDAO unpauses immediately). Spent under the route's guardian hold. A
// route with losses that have no restoring decision stays closed in the
// transfer app all the same.
func NewUnpauseRouteRequest(cur realm, route, target, fns string) Request {
	g := mustGov(route)
	if target == "" {
		target = g.key
	}
	target = flagTarget(g, target)
	if !g.hasFlagsOn(target) {
		if refusal := checkTarget(g, target); refusal != "" {
			panic("ibcgov: " + refusal)
		}
	}
	list := splitList(fns)
	if len(list) == 0 {
		panic("ibcgov: name the functions to unpause")
	}
	for _, fn := range list {
		if !isFn(fn) {
			panic("ibcgov: not a function: " + fn)
		}
	}
	text := "unpause " + strings.Join(list, ",") + " of route " + g.key + " on " + target
	p := &unpauseRouteParams{route: g.key, target: target, fns: list}
	sc := routeScope(g.key)
	return propose(cur, "unpause route", text, func(cur realm, made, t int64) {
		decide(cur, "unpause route", text, p, made, t, false, sc)
	})
}

// ---------------------------------------------------------------- dropping

// dropParams removes a provisional route record.
type dropParams struct{ route string }

// checkDrop is why route g cannot be dropped now, or "" (ADR 0007 §5);
// others is how many of its pending decisions other than the drop itself
// are allowed: none.
func checkDrop(g *routeGov, others int64, t int64) string {
	if g.enrolled {
		return "route " + g.key + " is enrolled: only a provisional record is dropped"
	}
	for i := 0; i < SeatCount; i++ {
		if g.seats[i] != "" {
			return "seat " + strconv.Itoa(i) + " of route " + g.key + " is occupied: vacate every seat first"
		}
	}
	switch {
	case g.heldAt(t):
		return "route " + g.key + "'s hold stands, its 24-hour linger included"
	case g.flags.Size() > 0 || g.genEnds.Size() > 0:
		return "route " + g.key + " still has flag entries: clear or prune them first (PruneFlags)"
	case pendingOf(g.key, g.inc) > others:
		return "route " + g.key + " has pending decisions"
	}
	return ""
}

func (p *dropParams) apply(cur realm, t int64) (string, string) {
	g := govOf(p.route)
	if g == nil {
		return "", "no route " + p.route
	}
	// The drop itself is pending until it applies.
	if refusal := checkDrop(g, 1, t); refusal != "" {
		return "", refusal
	}
	routes.Remove(g.key)
	chains.Remove(g.chain)
	if c := claimOf(g.key); c != nil && c.route == g.key {
		govClients.Remove(g.key)
	}
	return "dropped the provisional record of route " + g.key + " (incarnation " + u64s(g.inc) + ")", ""
}

// NewDropRouteRequest removes route's provisional record after 7 days (ADR
// 0007 §5): its chain and client are free again, and a later record of the
// key is a new incarnation. Refused, when built and when it executes, while
// a seat is occupied, a hold or its linger stands, a flag entry of the route
// remains (stale ones included: PruneFlags), or another decision of this
// incarnation is pending. An enrolled route is never dropped.
func NewDropRouteRequest(cur realm, route string) Request {
	g := mustGov(route)
	if refusal := checkDrop(g, 0, now()); refusal != "" {
		panic("ibcgov: " + refusal)
	}
	text := "drop the provisional record of route " + g.key + " (incarnation " + u64s(g.inc) + ")"
	p := &dropParams{route: g.key}
	sc := routeScope(g.key)
	return propose(cur, "drop route", text, func(cur realm, made, t int64) {
		decide(cur, "drop route", text, p, made, t, true, sc)
	})
}
