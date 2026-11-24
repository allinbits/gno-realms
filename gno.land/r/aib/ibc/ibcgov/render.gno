package ibcgov

import (
	"encoding/hex"
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/aib/jsonmd/v0"

	"gno.land/p/aib/decisions/v0"
)

// Render serves the governance state:
//
//	""                    the page: governor, the global hold, then each route
//	                      (identity, channel, seats, flags, hold), 20 routes a
//	                      page from the first route key after ?from=<key>,
//	                      then the decisions
//	"decisions?from=<id>" the decisions as JSON, oldest first, 100 a page from
//	                      decision <id> (the first without from); the page's
//	                      "next" is the from of the following one (0 at the end)
//	"dispatch/<route>/<e>/<seq>" a route's Ethereum-bound decision's packet
//	                      state, as JSON: burned (acknowledged cancelled
//	                      by a cancel this realm never sent), rebound_to
//	                      (the number Rebind gave it, 0 if none) and
//	                      rebound_from (the number it is a copy of, 0 if
//	                      none) included
//
// The page's text comes from the builders, which take no free text: client
// ids, denoms and incidents pass character checks, addresses and keys are
// parsed, numbers are formatted here. The decision list is written as the
// ledger keeps it; single values are escaped for inline markdown.
func Render(path string) string {
	switch {
	case path == "" || strings.HasPrefix(path, "?"):
		return home(routeFromOf(path))
	case path == "decisions" || strings.HasPrefix(path, "decisions?"):
		return jsonmd.Inert(ledger.JSON(fromOf(path)))
	case strings.HasPrefix(path, "dispatch/"):
		parts := strings.Split(strings.TrimPrefix(path, "dispatch/"), "/")
		if len(parts) != 3 {
			return "null"
		}
		e, err1 := strconv.ParseUint(parts[1], 10, 32)
		s, err2 := strconv.ParseUint(parts[2], 10, 64)
		if err1 != nil || err2 != nil {
			return "null"
		}
		return jsonmd.Inert(dispatchJSON(parts[0], uint32(e), s))
	}
	return "# Not found\n"
}

// fromOf is a JSON path's ?from= decision number, 0 (the first) when absent
// or not a number; one out of range saturates, so it reads past the end (an
// empty page) or from the first.
func fromOf(path string) int64 {
	_, query, _ := strings.Cut(path, "?")
	v, _ := url.ParseQuery(query)
	n, _ := strconv.ParseInt(v.Get("from"), 10, 64)
	return n
}

// routesPerPage is how many routes the page shows.
const routesPerPage = 20

// routeFromOf is the page's ?from= route key, "" from the first.
func routeFromOf(path string) string {
	_, query, _ := strings.Cut(path, "?")
	v, _ := url.ParseQuery(query)
	return v.Get("from")
}

func home(from string) string {
	var b strings.Builder
	b.WriteString("# IBC governance\n\n")
	b.WriteString("- " + governorLine() + "\n")
	b.WriteString("- " + decisions.Clocks() + "\n")
	if AnyHeld() {
		b.WriteString("- **global hold** since " + itoa(globalHeldSince) + ": a route's guardian hold defers every global decision, to day 21 of the global hold at most\n")
	}
	b.WriteString("\n## Routes\n\n")
	if routes.Size() == 0 {
		b.WriteString("No route enrolled.\n")
	}
	// One route past the page tells whether there is a next page, so the
	// link never leads to an empty one.
	keys := Routes(from, routesPerPage+1)
	more := len(keys) > routesPerPage
	if more {
		keys = keys[:routesPerPage]
	}
	for _, k := range keys {
		writeRoute(&b, govOf(k))
	}
	if more {
		last := keys[len(keys)-1]
		b.WriteString("\n- more: [routes after " + jsonmd.Text(last) + "](:?from=" + url.QueryEscape(last) + ")\n")
	}
	b.WriteString("\n## Decisions\n\n")
	b.WriteString(ledger.Page())
	return b.String()
}

// writeRoute writes one route's section: its state, channel, hold, seats and
// flags. Every text that names a client or a flag line is escaped as inline
// Markdown (a flag line carries the packet keys a guardian named, whose
// client part is any text).
func writeRoute(b *strings.Builder, g *routeGov) {
	state := "enrolled"
	if !g.enrolled {
		state = "provisional"
	}
	b.WriteString("### " + jsonmd.Text(g.key) + "\n\n")
	b.WriteString("- " + state + ", incarnation " + u64s(g.inc) + ", payouts epoch " + itoa(g.payEpoch) + "\n")
	if g.identity != "" {
		b.WriteString("- identity: " + jsonmd.Text(g.identity) + "\n")
	}
	if g.enrolled {
		if g.epoch == 0 {
			b.WriteString("- governance channel: not bound\n")
		} else {
			b.WriteString("- governance channel: epoch " + strconv.FormatUint(uint64(g.epoch), 10) + " over client " +
				jsonmd.Text(epochClient(g)) + ", last seq " + u64s(lastSeq(g, g.epoch)) + "\n")
		}
	}
	if g.heldAt(now()) {
		b.WriteString("- **guardian hold** since " + itoa(g.holdSince) + ": the route's queued decisions are deferred, its unpauses are spent\n")
	}
	for i := 0; i < SeatCount; i++ {
		role := "guardian"
		if !IsGuardianSeat(i) {
			role = "watch key"
		}
		holder := string(g.seats[i])
		if holder == "" {
			holder = "empty"
		}
		b.WriteString("- seat " + strconv.Itoa(i) + " (" + role + "): " + jsonmd.Text(holder) + "\n")
	}
	// Every flag of the route, on itself or a candidate client (one that
	// joined another route since included): each counts toward its hold.
	// At most flagsShown lines; the count says how many stand.
	// Bounded: at most flagsShown entries are read, live or stale; the
	// total of live flags is the seats' counts.
	var live int64
	for i := 0; i < SeatCount; i++ {
		live += g.seatFlags[i]
	}
	shown, read := 0, 0
	g.flags.Iterate("", "", func(k string, v any) bool {
		if read == flagsShown {
			return true
		}
		read++
		f := v.(*flag)
		if !g.live(f) {
			return false
		}
		shown++
		parts := strings.Split(k, "|")
		line := parts[1] + " on " + parts[0] + " seat " + strconv.Itoa(f.seat) + " at " + itoa(f.at)
		if len(f.keys) > 0 {
			line += " naming " + strings.Join(f.keys, ",")
		}
		b.WriteString("- flag: " + jsonmd.Text(line) + "\n")
		return false
	})
	if live > int64(shown) {
		b.WriteString("- " + itoa(live) + " flags in all (Flags(route, target))\n")
	}
	// The expected-transition graph: at most maxLive transitions and
	// tombstones together, so it is shown whole.
	if g.enrolled && g.epoch != 0 {
		g.expected.Iterate("", "", func(old string, v any) bool {
			for _, x := range v.([]expEdge) {
				state := "intent"
				if x.active {
					state = "active"
				}
				b.WriteString("- transition: " + jsonmd.Text(old+" → "+x.to+" over "+x.local) + " (" + state + ")\n")
			}
			return false
		})
		g.tombstones.Iterate("", "", func(_ string, v any) bool {
			t := v.(*tomb)
			b.WriteString("- tombstone: " + jsonmd.Text(t.old+" → "+t.to+" over "+t.local) + "\n")
			return false
		})
		if n := g.awaitingGov.Size(); n > 0 {
			b.WriteString("- clients awaiting retirement for governance: " + strconv.Itoa(n) + "\n")
		}
	}
	b.WriteString("\n")
}

// flagsShown bounds the flag lines of a route's section.
const flagsShown = 64

func dispatchJSON(route string, e uint32, seq uint64) string {
	d := routeDispatch(route, e, seq)
	if d == nil {
		return "null"
	}
	return "{\"epoch\":" + strconv.FormatUint(uint64(d.epoch), 10) + ",\"seq\":" + u64s(d.seq) +
		",\"kind\":" + strconv.Itoa(int(d.kind)) + ",\"decision\":" + itoa(d.decision) +
		",\"body\":" + strconv.Quote(hex.EncodeToString(d.body)) + ",\"status\":" + strconv.Itoa(int(d.status)) +
		",\"redispatch\":" + strconv.FormatBool(d.redispatch) + ",\"in_flight\":" + strconv.FormatBool(d.inFlight) +
		",\"transport\":" + u64s(d.transport) + ",\"sends\":" + strconv.Itoa(d.sends) + ",\"event\":" + strconv.Quote(d.event) +
		",\"burned\":" + strconv.FormatBool(d.burned) + ",\"rebound_to\":" + u64s(d.reboundTo) + ",\"rebound_from\":" + u64s(d.reboundFrom) + "}"
}
