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
//	""                    the page: governor, channel, seats, flags, holds, decisions
//	"decisions?from=<id>" the decisions as JSON, oldest first, 100 a page from
//	                      decision <id> (the first without from); the page's
//	                      "next" is the from of the following one (0 at the end)
//	"dispatch/<e>/<seq>"  an Ethereum-bound decision's packet state, as JSON
//
// The page's text comes from the builders, which take no free text: client
// ids, denoms and incidents pass character checks, addresses and keys are
// parsed, numbers are formatted here. The decision list is written as the
// ledger keeps it; single values are escaped for inline markdown.
func Render(path string) string {
	switch {
	case path == "":
		return home()
	case path == "decisions" || strings.HasPrefix(path, "decisions?"):
		return jsonmd.Inert(ledger.JSON(fromOf(path)))
	case strings.HasPrefix(path, "dispatch/"):
		parts := strings.Split(strings.TrimPrefix(path, "dispatch/"), "/")
		if len(parts) != 2 {
			return "null"
		}
		e, err1 := strconv.ParseUint(parts[0], 10, 32)
		s, err2 := strconv.ParseUint(parts[1], 10, 64)
		if err1 != nil || err2 != nil {
			return "null"
		}
		return jsonmd.Inert(dispatchJSON(uint32(e), s))
	}
	return "# Not found\n"
}

// fromOf is a JSON path's ?from= decision number, 0 (the first) when absent
// or not a number.
func fromOf(path string) int64 {
	_, query, _ := strings.Cut(path, "?")
	v, _ := url.ParseQuery(query)
	n, _ := strconv.ParseInt(v.Get("from"), 10, 64)
	return n
}

func home() string {
	var b strings.Builder
	b.WriteString("# IBC governance\n\n")
	b.WriteString("- " + decisions.GovernorLine(LaunchGovernor, yielded) + "\n")
	b.WriteString("- " + decisions.Clocks() + "\n")
	if epoch == 0 {
		b.WriteString("- governance channel: not bound\n")
	} else {
		b.WriteString("- governance channel: epoch " + strconv.FormatUint(uint64(epoch), 10) + " over client " +
			jsonmd.Text(EpochClient()) + ", last seq " + u64s(LastSeq(epoch)) + "\n")
	}
	if Held() {
		b.WriteString("- **guardian hold** since " + itoa(holdSince) + ": queued decisions are deferred, unpauses are spent\n")
	}
	b.WriteString("\n## Seats\n\n")
	for i := 0; i < SeatCount; i++ {
		role := "guardian"
		if !IsGuardianSeat(i) {
			role = "watch key"
		}
		holder := string(seats[i])
		if holder == "" {
			holder = "empty"
		}
		b.WriteString("- " + strconv.Itoa(i) + " (" + role + "): " + jsonmd.Text(holder) + "\n")
	}
	b.WriteString("\n## Routes\n\n")
	if routes.Size() == 0 {
		b.WriteString("No route enrolled.\n")
	}
	routes.Iterate("", "", func(k string, v any) bool {
		r := v.(*routeRec)
		// A flag line carries the packet keys a guardian named, whose client
		// part is any text: every line is escaped as inline Markdown.
		b.WriteString("- " + jsonmd.Text(k) + " (payouts epoch " + itoa(r.epoch) + ")\n")
		for _, f := range Flags(k) {
			b.WriteString("  - flag: " + jsonmd.Text(f) + "\n")
		}
		return false
	})
	b.WriteString("\n## Decisions\n\n")
	b.WriteString(ledger.Page())
	return b.String()
}

func dispatchJSON(e uint32, seq uint64) string {
	d := dispatchOf(e, seq)
	if d == nil {
		return "null"
	}
	return "{\"epoch\":" + strconv.FormatUint(uint64(d.epoch), 10) + ",\"seq\":" + u64s(d.seq) +
		",\"kind\":" + strconv.Itoa(int(d.kind)) + ",\"decision\":" + itoa(d.decision) +
		",\"body\":" + strconv.Quote(hex.EncodeToString(d.body)) + ",\"status\":" + strconv.Itoa(int(d.status)) +
		",\"redispatch\":" + strconv.FormatBool(d.redispatch) + ",\"in_flight\":" + strconv.FormatBool(d.inFlight) +
		",\"transport\":" + u64s(d.transport) + ",\"sends\":" + strconv.Itoa(d.sends) + ",\"event\":" + strconv.Quote(d.event) + "}"
}
