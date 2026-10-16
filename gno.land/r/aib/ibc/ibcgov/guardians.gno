package ibcgov

import (
	"chain"
	"strconv"
	"strings"

	"gno.land/p/aib/decisions/v0"
	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
)

// The guardians on gno.land (ADR pr6375 §7.4, R10): six seats, 0–3 the
// guardians (2 and 3 the outsiders') and 4–5 the operator's watch keys, each
// holding one gno address. A seat flags a function of a route, keyed by the
// route key: sends (gno-native sends), credits (receives from Ethereum),
// payouts (claim payouts) or refunds (the refunds hold of §7.13, which
// delays error-ack and timeout refunds and the payout of queued refunds). One
// flag pauses the function at once. Flags never stop voucher returns (burns),
// acknowledgements or timeouts; only the refunds flag delays refunds, never
// cancels them. A seat clears its own flag; an unpause decision clears every
// seat's flags of a function. Clearing a payouts flag starts the route's
// meters empty (a new payouts epoch).
//
// Two guardian seats flagging (anything) make a hold: every queued decision is
// deferred and every unpause decision is spent. A hold ends 24 hours after
// fewer than two guardian seats flag. A guardian replacement lands through a
// hold, no sooner than day 21 of it. A guardian's payouts flag may name the
// packets it suspects, which makes their void immediate. Guardians delay;
// they never veto.

const (
	SeatCount     = 6
	GuardianSeats = 4 // seats 0–3

	FnSends   = "sends"
	FnCredits = "credits"
	FnPayouts = "payouts"
	FnRefunds = "refunds"

	// holdLinger is how long a hold outlives the second flag's clearing.
	holdLinger = decisions.Day / decisions.Factor
	// holdReplacementWait is how long into a hold a guardian replacement
	// waits before it can land (day 21).
	holdReplacementWait = 21 * decisions.Day / decisions.Factor
)

var (
	seats [SeatCount]address
	// flags holds the standing flags, keyed route|fn|seat.
	flags avl.Tree // flagKey -> *flag
	// routes are the routes ibcgov enrolled, keyed by route key.
	routes avl.Tree // route key -> *routeRec

	holdSince  int64 // when the current hold began, 0 if none
	belowSince int64 // when it fell below two guardian seats, 0 while it has two
)

type flag struct {
	seat int
	at   int64
	keys []string // a guardian's payouts flag: the packets it suspects
}

// routeRec is a route's record here: its payouts epoch, which the transfer
// implementation reads to empty its meters when a payouts flag is cleared.
type routeRec struct {
	epoch   int64
	epochAt int64
}

func flagKey(route, fn string, seat int) string { return route + "|" + fn + "|" + strconv.Itoa(seat) }
func flagPrefix(route, fn string) string        { return route + "|" + fn + "|" }

func isFn(fn string) bool {
	return fn == FnSends || fn == FnCredits || fn == FnPayouts || fn == FnRefunds
}

// Seat is the address in a seat, "" if empty or out of range.
func Seat(n int) address {
	if n < 0 || n >= SeatCount {
		return ""
	}
	return seats[n]
}

// SeatOf is the seat an address holds, -1 if none.
func SeatOf(a address) int {
	if a == "" {
		return -1
	}
	for i := 0; i < SeatCount; i++ {
		if seats[i] == a {
			return i
		}
	}
	return -1
}

// IsGuardianSeat reports whether seat n is a guardian's (0–3).
func IsGuardianSeat(n int) bool { return n >= 0 && n < GuardianSeats }

// IsRoute reports whether ibcgov enrolled route.
func IsRoute(route string) bool { return routes.Has(route) }

// routeKeyOf is the stable key flags and route records are kept under for
// id: the route's key when id is a route key or one of a route's clients,
// current or retired (a replacement keeps the first client's id as the key),
// and id itself otherwise (an Ethereum client no route uses yet, which a
// legacy fallback route takes as its key). Every flag operation and check
// resolves its route through it, so a flag on a client and the transfer app's
// check on its route meet.
func routeKeyOf(id string) string {
	if routes.Has(id) {
		return id
	}
	if rd, ok := transfer.ExtView("controls").(controls.Reader); ok {
		if k := rd.RouteOf(id); k != "" {
			return k
		}
		if k := rd.RetiredRouteOf(id); k != "" {
			return k
		}
	}
	return id
}

// foldFlags moves the flags standing under from to the route key to, when
// from becomes one of the route's clients (a replacement), and returns how
// many it moved. A seat's flag of a function standing under both is kept
// once, with the earlier time and the packets both name.
func foldFlags(from, to string, t int64) int {
	if from == to {
		return 0
	}
	var keys []string
	flags.Iterate(from+"|", from+"|~", func(k string, _ any) bool {
		keys = append(keys, k)
		return false
	})
	for _, k := range keys {
		v, _ := flags.Remove(k)
		f := v.(*flag)
		fn := strings.Split(k, "|")[1]
		if w := flags.Get(flagKey(to, fn, f.seat)); w != nil {
			g := w.(*flag)
			if f.at < g.at {
				g.at = f.at
			}
			for _, key := range f.keys {
				if !contains(g.keys, key) && len(g.keys) < controls.MaxKeys {
					g.keys = append(g.keys, key)
				}
			}
			continue
		}
		flags.Set(flagKey(to, fn, f.seat), f)
	}
	if len(keys) > 0 {
		chain.Emit("FlagsMoved", "from", from, "to", to, "flags", strconv.Itoa(len(keys)))
		updateHold(t)
	}
	return len(keys)
}

// flaggable reports whether a flag may stand on route: a route ibcgov
// enrolled, or any Ethereum client, whose key a legacy fallback route of the
// transfer app takes from the moment a voucher return makes it (ADR pr6375
// R17). Every effective Ethereum route is thus flaggable before its first
// refund, and its flags stay when a decision later enrolls it.
func flaggable(route string) bool {
	return routes.Has(route) || core.ClientType(route) == ethereum.ClientType
}

// Flagged reports whether any seat's flag for fn stands on route: what the
// transfer implementation asks before sending, crediting, paying out or
// refunding.
func Flagged(route, fn string) bool {
	route = routeKeyOf(route)
	found := false
	flags.Iterate(flagPrefix(route, fn), flagPrefix(route, fn)+"~", func(_ string, _ any) bool {
		found = true
		return true
	})
	return found
}

// PayoutsEpoch is how many times a standing payouts flag on route was
// cleared, and when the last was: the route's meters empty when it changes.
func PayoutsEpoch(route string) (epoch, at int64) {
	v := routes.Get(routeKeyOf(route))
	if v == nil {
		return 0, 0
	}
	r := v.(*routeRec)
	return r.epoch, r.epochAt
}

// NamedSuspect reports whether a guardian's standing payouts flag on route
// names the packet key: what makes its void immediate.
func NamedSuspect(route, key string) bool {
	route = routeKeyOf(route)
	found := false
	flags.Iterate(flagPrefix(route, FnPayouts), flagPrefix(route, FnPayouts)+"~", func(_ string, v any) bool {
		f := v.(*flag)
		if !IsGuardianSeat(f.seat) {
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

// Held reports whether a guardian hold stands now.
func Held() bool { return heldAt(now()) }

// HoldSince is when the current hold began, 0 if none stands.
func HoldSince() int64 {
	if !heldAt(now()) {
		return 0
	}
	return holdSince
}

func heldAt(t int64) bool {
	if holdSince == 0 {
		return false
	}
	return belowSince == 0 || t < belowSince+holdLinger
}

// guardiansFlagging counts the guardian seats with a standing flag.
func guardiansFlagging() int {
	var flagging [GuardianSeats]bool
	n := 0
	flags.Iterate("", "", func(_ string, v any) bool {
		f := v.(*flag)
		if IsGuardianSeat(f.seat) && !flagging[f.seat] {
			flagging[f.seat] = true
			n++
		}
		return false
	})
	return n
}

// updateHold re-reads the hold after a flag change at t.
func updateHold(t int64) {
	if holdSince != 0 && belowSince != 0 && t >= belowSince+holdLinger {
		holdSince, belowSince = 0, 0 // the last hold ended
	}
	if guardiansFlagging() >= 2 {
		if holdSince == 0 {
			holdSince = t
			chain.Emit("Hold", "since", itoa(t))
		}
		belowSince = 0
		return
	}
	if holdSince != 0 && belowSince == 0 {
		belowSince = t
		chain.Emit("HoldEnding", "at", itoa(t+holdLinger))
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

// SetFlag sets, or re-asserts, the caller's flag on fn of route. keys names
// the packets a guardian's payouts flag suspects (comma-separated packet
// keys, "client/sequence" with 20 digits), "" otherwise; a re-assertion
// replaces them. The caller is cur.Previous(): the seat's key itself.
func SetFlag(cur realm, route, fn, keys string) {
	seat := SeatOf(cur.Previous().Address())
	if seat < 0 {
		panic("ibcgov: not a guardian or a watch key: " + who(0, cur.Previous()))
	}
	route = routeKeyOf(route)
	if !flaggable(route) {
		panic("ibcgov: no route or Ethereum client " + route)
	}
	if !isFn(fn) {
		panic("ibcgov: the function is sends, credits, payouts or refunds, not " + fn)
	}
	list := parseSuspects(keys)
	if len(list) > 0 && (fn != FnPayouts || !IsGuardianSeat(seat)) {
		panic("ibcgov: only a guardian's payouts flag names packets")
	}
	t := now()
	flags.Set(flagKey(route, fn, seat), &flag{seat: seat, at: t, keys: list})
	updateHold(t)
	chain.Emit("Flag", "route", route, "fn", fn, "seat", strconv.Itoa(seat), "packets", strconv.Itoa(len(list)))
}

// ClearFlag clears the caller's own flag on fn of route. A route with losses
// that have no restoring decision stays closed in the transfer app whatever
// the flags (ADR pr6375 §7.9), so clearing a flag, ending a hold, never
// reopens it: the restoring decisions the hold would defer can then land.
func ClearFlag(cur realm, route, fn string) {
	seat := SeatOf(cur.Previous().Address())
	if seat < 0 {
		panic("ibcgov: not a guardian or a watch key: " + who(0, cur.Previous()))
	}
	route = routeKeyOf(route)
	if !flags.Has(flagKey(route, fn, seat)) {
		panic("ibcgov: no such flag of yours")
	}
	t := now()
	clearFlag(route, fn, seat, t)
	updateHold(t)
}

func clearFlag(route, fn string, seat int, t int64) {
	flags.Remove(flagKey(route, fn, seat))
	if fn == FnPayouts {
		bumpPayoutsEpoch(route, t)
	}
	chain.Emit("Unflag", "route", route, "fn", fn, "seat", strconv.Itoa(seat))
}

func bumpPayoutsEpoch(route string, t int64) {
	if v := routes.Get(route); v != nil {
		r := v.(*routeRec)
		r.epoch++
		r.epochAt = t
	}
}

// clearFns clears every seat's flags of fns on route and returns how many.
func clearFns(route string, fns []string, t int64) int {
	n := 0
	for _, fn := range fns {
		var seatsFlagging []int
		flags.Iterate(flagPrefix(route, fn), flagPrefix(route, fn)+"~", func(_ string, v any) bool {
			seatsFlagging = append(seatsFlagging, v.(*flag).seat)
			return false
		})
		for _, s := range seatsFlagging {
			clearFlag(route, fn, s, t)
			n++
		}
	}
	updateHold(t)
	return n
}

// clearSeat clears every flag of a seat (its key leaves).
func clearSeat(seat int, t int64) {
	var keys []string
	flags.Iterate("", "", func(k string, v any) bool {
		if v.(*flag).seat == seat {
			keys = append(keys, k)
		}
		return false
	})
	for _, k := range keys {
		parts := strings.Split(k, "|")
		clearFlag(parts[0], parts[1], seat, t)
	}
	updateHold(t)
}

// Flags lists the standing flags of a route as "fn seat <n> at <time>" lines,
// with the packets a payouts flag names.
func Flags(route string) []string {
	route = routeKeyOf(route)
	var out []string
	flags.Iterate(route+"|", route+"|~", func(k string, v any) bool {
		f := v.(*flag)
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

// seatsParams is a seat change: each seat in order gets its address ("" to
// vacate). held records the seats' holders when the decision was made: a
// removal of a seat whose occupant changed since is skipped.
type seatsParams struct {
	seats []int
	addrs []address
	held  []address
}

func (p *seatsParams) apply(cur realm, t int64) (string, string) {
	// Re-check against live state: no address may end up in two seats.
	next := seats
	for i, s := range p.seats {
		if p.addrs[i] == "" && seats[s] != p.held[i] {
			continue // the seat changed hands since: leave it
		}
		next[s] = p.addrs[i]
	}
	for i := 0; i < SeatCount; i++ {
		for j := i + 1; j < SeatCount; j++ {
			if next[i] != "" && next[i] == next[j] {
				return "", "address " + string(next[i]) + " would hold seats " + strconv.Itoa(i) + " and " + strconv.Itoa(j)
			}
		}
	}
	var changed []string
	for i := 0; i < SeatCount; i++ {
		if next[i] != seats[i] {
			clearSeat(i, t)
			seats[i] = next[i]
			changed = append(changed, strconv.Itoa(i))
			chain.Emit("SeatSet", "seat", strconv.Itoa(i), "address", string(next[i]))
		}
	}
	if len(changed) == 0 {
		return "", "nothing to change"
	}
	return "seats " + strings.Join(changed, ","), ""
}

// NewSetSeatsRequest changes guardian and watch-key seats: changes is a
// comma-separated list of "seat:address" (seat 0–5; an empty address vacates
// the seat). At most two guardian seats per decision; no address in two
// seats. Vacating seats only applies at once; any addition or replacement
// waits 7 days, and through a guardian hold no sooner than day 21 of it.
func NewSetSeatsRequest(cur realm, changes string) Request {
	items := splitList(changes)
	if len(items) == 0 || len(items) > SeatCount {
		panic("ibcgov: name 1 to 6 seat changes")
	}
	p := &seatsParams{}
	seen := map[int]bool{}
	guardians, removalsOnly := 0, true
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
				panic("ibcgov: seat " + strconv.Itoa(n) + " holds " + string(a) + " already")
			}
			removalsOnly = false
		}
		if IsGuardianSeat(n) {
			guardians++
		}
		p.seats = append(p.seats, n)
		p.addrs = append(p.addrs, a)
		p.held = append(p.held, seats[n])
		parts = append(parts, strconv.Itoa(n)+"="+string(a))
	}
	if guardians > 2 {
		panic("ibcgov: a decision changes at most two guardian seats")
	}
	// No address may end up in two seats (re-checked when it applies).
	next := seats
	for i, n := range p.seats {
		next[n] = p.addrs[i]
	}
	for i := 0; i < SeatCount; i++ {
		for j := i + 1; j < SeatCount; j++ {
			if next[i] != "" && next[i] == next[j] {
				panic("ibcgov: " + string(next[i]) + " would hold seats " + strconv.Itoa(i) + " and " + strconv.Itoa(j))
			}
		}
	}
	text := "set seats " + strings.Join(parts, ",")
	return propose(cur, "set seats", text, func(cur realm, made, t int64) {
		decide(cur, "set seats", text, p, made, t, !removalsOnly)
	})
}

// ------------------------------------------------------------- unpausing

// unpauseRouteParams clears every seat's flags of fns on a route.
type unpauseRouteParams struct {
	route string
	fns   []string
}

func (*unpauseRouteParams) unpause() {}

func (p *unpauseRouteParams) apply(cur realm, t int64) (string, string) {
	// The client named may have become a route's alias since the decision.
	n := clearFns(routeKeyOf(p.route), p.fns, t)
	if n == 0 {
		return "", "no flag stood"
	}
	return "cleared " + strconv.Itoa(n) + " flags", ""
}

// NewUnpauseRouteRequest clears every seat's flags of fns (comma-separated:
// sends, credits, payouts, refunds) on route, at once (ADR pr6375 §7.4: on
// gno.land GovDAO unpauses immediately). Spent under a guardian hold. A route
// with losses that have no restoring decision stays closed in the transfer
// app all the same.
func NewUnpauseRouteRequest(cur realm, route, fns string) Request {
	route = routeKeyOf(route)
	if !flaggable(route) {
		panic("ibcgov: no route or Ethereum client " + route)
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
	text := "unpause " + strings.Join(list, ",") + " on route " + route
	p := &unpauseRouteParams{route: route, fns: list}
	return propose(cur, "unpause route", text, func(cur realm, made, t int64) {
		decide(cur, "unpause route", text, p, made, t, false)
	})
}
