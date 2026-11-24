package ibcgov

import (
	"strconv"

	"gno.land/p/aib/decisions/v0"
	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
)

// One ibcgov governs several router routes, each as if it were the only one
// (ADR 0007). A route's governance lives in its record, routeGov: its
// guardians, flags and hold, its governance channel and its expected
// transitions. GovDAO and the governor decide for every route; the decision
// ledger is one. A record exists from a provisional seat change, or from the
// route's enrolment, whichever comes first, and a provisional record is
// dropped only by a governed drop.
//
// A route's key is the gno client it was enrolled with (or will be). Router
// client ids are the counterparty's and repeat across routes, so they are
// never resolved to a route: every entry point that names one takes the
// route too. Gno client ids are unique, and govClients maps each one
// governance handles to its route.

// routeGov is one route's governance record.
type routeGov struct {
	key      string
	inc      uint64 // its incarnation: a key used again after a drop starts a new one
	enrolled bool   // false for a provisional record (seats before the enrolment)
	chain    string // the counterparty chain it reserves (core.ClientChainIdentity)

	// The transfer route: its payouts epoch, which the transfer
	// implementation reads to empty its meters when a payouts flag is
	// cleared, and its identity, recorded at enrolment and never changed: the
	// history every client of the route must authenticate.
	payEpoch   int64
	payEpochAt int64
	identity   string

	// Guardians (ADR pr6375 §7.4, per route).
	seats      [SeatCount]address
	seatGen    [SeatCount]uint64
	seatFlags  [SeatCount]int64
	flags      avl.Tree // flagKey(target, fn, seat) -> *flag
	genEnds    avl.Tree // genKey(seat, gen) -> *genEnd
	pruneAfter string   // where PruneFlags resumes
	holdSince  int64    // when the current hold began, 0 if none
	belowSince int64    // when it fell below two guardian seats, 0 while it has two

	// The governance channel (ethereum.gno).
	epoch       uint32
	epochs      avl.Tree // epochKey -> *epochRec
	dispatches  avl.Tree // dispatchKey -> *dispatch
	govIdentity string
	cancels     avl.Tree // dispatchKey(e, from) -> *span: the numbers this realm's kind 1s cancelled, merged (rebind.gno)

	// The expected-transition graph (ethereum.gno).
	expected      avl.Tree // old router client id -> []expEdge
	awaitingGov   avl.Tree // gno client id -> true
	approvedLocal avl.Tree // gno client id -> true
	proven        avl.Tree // provenKey(epoch, client) -> *provenNotice
	tombstones    avl.Tree // tombKey(old, next, local) -> *tomb
	owned         avl.Tree // ownerKey -> true
	routerHistory avl.Tree // router client id -> true
	liveEdges     int
	intents       uint64
	govPruneAfter string
}

var (
	// routes are the route records, enrolled and provisional, by route key.
	routes avl.Tree // route key -> *routeGov
	// incarnations is the last incarnation given to each route key, kept
	// after a drop.
	incarnations avl.Tree // route key -> uint64
	// chains reserves each counterparty chain for one route.
	chains avl.Tree // chain identity -> route key
	// govClients is which route each gno client governance handles belongs
	// to (ADR 0007 §2).
	govClients avl.Tree // gno client id -> *claim
	// scopes is each decision's scope, by decision number.
	scopes avl.Tree // decision key -> *scope
	// pendings counts the pending decisions of each incarnation of a route
	// key, whether its record exists yet or not: a drop reads one number.
	pendings avl.Tree // incKey(key, inc) -> int64
)

func incKey(key string, inc uint64) string { return key + "#" + u64s(inc) }

// pendingOf is how many decisions of route key's incarnation inc are
// pending.
func pendingOf(key string, inc uint64) int64 {
	if v := pendings.Get(incKey(key, inc)); v != nil {
		return v.(int64)
	}
	return 0
}

func addPending(key string, inc uint64, n int64) {
	k := incKey(key, inc)
	if c := pendingOf(key, inc) + n; c > 0 {
		pendings.Set(k, c)
	} else {
		pendings.Remove(k)
	}
}

// govOf is the record of route key, nil if none.
func govOf(key string) *routeGov {
	if v := routes.Get(key); v != nil {
		return v.(*routeGov)
	}
	return nil
}

// enrolledGov is the record of an enrolled route key, nil otherwise.
func enrolledGov(key string) *routeGov {
	if g := govOf(key); g != nil && g.enrolled {
		return g
	}
	return nil
}

// IsRoute reports whether route is a route ibcgov enrolled.
func IsRoute(route string) bool { return enrolledGov(route) != nil }

// IsProvisionalRoute reports whether route has a provisional record: seats
// set before its enrolment.
func IsProvisionalRoute(route string) bool {
	g := govOf(route)
	return g != nil && !g.enrolled
}

// Routes lists the route keys with a record, enrolled and provisional, in
// key order, from the first key after from ("" from the start), at most n.
func Routes(from string, n int) []string {
	var out []string
	routes.Iterate(after(from), "", func(k string, _ any) bool {
		if len(out) == n {
			return true
		}
		out = append(out, k)
		return false
	})
	return out
}

// nextInc is the incarnation a new record of key would take.
func nextInc(key string) uint64 {
	if v := incarnations.Get(key); v != nil {
		return v.(uint64) + 1
	}
	return 1
}

// incOf is the incarnation a request about key is bound to: its record's,
// or the one a new record would take.
func incOf(key string) uint64 {
	if g := govOf(key); g != nil {
		return g.inc
	}
	return nextInc(key)
}

// Incarnation is route's current incarnation, 0 if it has no record.
func Incarnation(route string) uint64 {
	if g := govOf(route); g != nil {
		return g.inc
	}
	return 0
}

// newRecord creates the record of key, reserving its chain and claiming its
// client for good; its caller checked both are free.
func newRecord(key, chain string) *routeGov {
	inc := nextInc(key)
	incarnations.Set(key, inc)
	g := &routeGov{key: key, inc: inc, chain: chain}
	routes.Set(key, g)
	chains.Set(chain, key)
	claimFor(key, key)
	return g
}

// ------------------------------------------------------------- chains

// checkChainFree is why client cannot start or join route key's chain, or
// "": its verifier must name its chain, and no other route, enrolled or
// provisional, may be on that chain (ADR 0007 §4: one route per chain).
func checkChainFree(client, key string) string {
	ci := core.ClientChainIdentity(client)
	if ci == "" {
		return client + "'s verifier names no chain identity"
	}
	if v := chains.Get(ci); v != nil && v.(string) != key {
		return "route " + v.(string) + " is on " + ci + " already: one route per counterparty chain"
	}
	return ""
}

// ------------------------------------------------------------- claims

// claim is a gno client's route: tentative while only pending decisions
// hold it (owners), permanent once one of them applied.
type claim struct {
	route     string
	owners    int
	permanent bool
}

func claimOf(client string) *claim {
	if v := govClients.Get(client); v != nil {
		return v.(*claim)
	}
	return nil
}

// ClientRoute is the route the gno client belongs to, "" if none, and
// whether that claim is permanent.
func ClientRoute(client string) (route string, permanent bool) {
	if c := claimOf(client); c != nil {
		return c.route, c.permanent
	}
	return "", false
}

// checkClaim is why client cannot be named for route, or "": it belongs to
// another route, tentatively or for good.
func checkClaim(client, route string) string {
	if c := claimOf(client); c != nil && c.route != route {
		return client + " belongs to route " + c.route
	}
	return ""
}

// takeClaim adds a pending decision's hold on client for route.
func takeClaim(client, route string) {
	c := claimOf(client)
	if c == nil {
		c = &claim{route: route}
		govClients.Set(client, c)
	}
	c.owners++
}

// settleClaim removes a decision's hold on client: the claim becomes
// permanent when the decision applied, and goes with its last holder
// otherwise, unless it is permanent.
func settleClaim(client, route string, applied bool) {
	c := claimOf(client)
	if c == nil || c.route != route {
		return
	}
	if c.owners > 0 {
		c.owners--
	}
	if applied {
		c.permanent = true
	}
	if c.owners == 0 && !c.permanent {
		govClients.Remove(client)
	}
}

// claimFor claims client for route for good.
func claimFor(client, route string) {
	c := claimOf(client)
	if c == nil {
		govClients.Set(client, &claim{route: route, permanent: true})
		return
	}
	c.route, c.permanent = route, true
}

// routeOfClient is the record of the route a gno client belongs to, nil if
// none: what the packet callbacks read.
func routeOfClient(client string) *routeGov {
	if c := claimOf(client); c != nil {
		return govOf(c.route)
	}
	return nil
}

// ------------------------------------------------------------- scopes

// scope is a decision's scope (ADR 0007 §6): route-scoped (route set, bound
// to the incarnation it was built against) or global. claims are the gno
// clients the decision names for its route. clients are gno clients it
// names without claiming them: for a global decision, claimed by no route
// when it was built (a claim before it executes spends it); for a
// route-scoped one, a recovery's substitute, which must belong to no other
// route. A provisional route therefore holds only its own key client for
// good, which its drop releases. anchor is the start of the hold that first
// deferred it once due (a seat change, or a global decision), 0 before.
type scope struct {
	route   string
	inc     uint64
	claims  []string
	clients []string
	owned   []string // clients that must still belong to the route
	anchor  int64
	counted bool // counted among its incarnation's pending decisions
}

// routeScope is the scope of a decision about route, naming claims.
func routeScope(route string, claims ...string) scope {
	return scope{route: route, inc: incOf(route), claims: claims}
}

// globalScope is the scope of a decision about the shared core or transfer
// app.
func globalScope() scope { return scope{} }

// clientScope is the scope of a decision about the gno client subject: its
// route's when it belongs to one, global otherwise (ADR 0007 §6: no route's
// guardians own it). others are clients it names without claiming them (a
// recovery's substitute): each must belong to the same route, or to none,
// when the decision is built, recorded and executed; for a global decision,
// to none.
func clientScope(subject string, others ...string) scope {
	var sc scope
	if c := claimOf(subject); c != nil {
		// The subject is the route's already: the decision checks that it
		// still is, and never claims it, so administration never turns a
		// tentative claim (a pending enrolment's) permanent.
		sc = routeScope(c.route)
		sc.owned = []string{subject}
		sc.clients = others
	} else {
		sc = scope{clients: append([]string{subject}, others...)}
	}
	if refusal := sc.check(); refusal != "" {
		panic("ibcgov: " + refusal)
	}
	return sc
}

func scopeKey(id int64) string { return strconv.FormatInt(id, 36) }

func scopeOf(id int64) *scope {
	if v := scopes.Get(scopeKey(id)); v != nil {
		return v.(*scope)
	}
	return nil
}

// check is why a decision of this scope cannot be recorded or executed now,
// or "".
func (sc *scope) check() string {
	if sc.route != "" {
		g := govOf(sc.route)
		if (g != nil && g.inc != sc.inc) || (g == nil && nextInc(sc.route) != sc.inc) {
			return "route " + sc.route + "'s record changed since the request was built (incarnation " + u64s(sc.inc) + ")"
		}
		for _, c := range sc.claims {
			if refusal := checkClaim(c, sc.route); refusal != "" {
				return refusal
			}
		}
		for _, cl := range sc.owned {
			if c := claimOf(cl); c == nil || c.route != sc.route {
				return cl + " no longer belongs to route " + sc.route
			}
		}
		// Clients it names without claiming them (a recovery's substitute)
		// must belong to no other route.
		for _, c := range sc.clients {
			if refusal := checkClaim(c, sc.route); refusal != "" {
				return refusal
			}
		}
		return ""
	}
	for _, cl := range sc.clients {
		if c := claimOf(cl); c != nil {
			return cl + " belongs to route " + c.route + ": a decision of no route cannot name a route's client"
		}
	}
	return ""
}

// take records the scope of the just-recorded decision id: its claims and
// its place among its incarnation's pending decisions.
func (sc *scope) take(id int64) {
	for _, c := range sc.claims {
		takeClaim(c, sc.route)
	}
	if sc.route != "" {
		addPending(sc.route, sc.inc, 1)
		sc.counted = true
	}
	scopes.Set(scopeKey(id), sc)
}

// resolve releases what decision id held once it applied, was spent or was
// cancelled.
func resolve(d *decisions.Decision) {
	sc := scopeOf(d.ID)
	if sc == nil {
		return
	}
	applied := d.Applied != 0
	for _, c := range sc.claims {
		settleClaim(c, sc.route, applied)
	}
	sc.claims = nil
	if sc.counted {
		addPending(sc.route, sc.inc, -1)
		sc.counted = false
	}
}

// DecisionRoute is the route decision id is scoped to, "" for a global one.
func DecisionRoute(id int64) string {
	if sc := scopeOf(id); sc != nil {
		return sc.route
	}
	return ""
}

// ------------------------------------------------- holds across routes

// The global hold check is constant work, however many routes exist (ADR
// 0007 §6): routesFlagging counts the routes with two guardian seats
// flagging, lingerEnd is the latest end of any route's linger, and
// globalHeldSince the start of the current global hold (some route holding
// or lingering, without a gap).
var (
	routesFlagging  int
	lingerEnd       int64
	globalHeldSince int64
)

// anyHeldAt reports whether some route holds or lingers at t.
func anyHeldAt(t int64) bool { return routesFlagging > 0 || t < lingerEnd }

// AnyHeld reports whether some route's guardian hold stands now: what
// defers every global decision.
func AnyHeld() bool { return anyHeldAt(now()) }

// GlobalHoldSince is when the current global hold began, 0 if none.
func GlobalHoldSince() int64 {
	if !anyHeldAt(now()) {
		return 0
	}
	return globalHeldSince
}

// routeKeyOf is the stable key flags and route records are kept under for
// id: the route's key when id is a route key or one of a transfer route's
// clients, current or retired (a replacement keeps the first client's id as
// the key), and id itself otherwise.
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

// mustGov is the record of the route route names (a route key, or a client
// of a transfer route), enrolled or provisional; it panics if there is none.
func mustGov(route string) *routeGov {
	g := govOf(routeKeyOf(route))
	if g == nil {
		panic("ibcgov: no route " + route)
	}
	return g
}

// mustEnrolledGov is the record of an enrolled route route names.
func mustEnrolledGov(route string) *routeGov {
	g := enrolledGov(routeKeyOf(route))
	if g == nil {
		panic("ibcgov: no route " + route)
	}
	return g
}

// transferView is the transfer app's controls, read only; not Valid when the
// transfer app keeps none.
func transferView() controls.Reader {
	rd, _ := transfer.ExtView("controls").(controls.Reader)
	return rd
}
