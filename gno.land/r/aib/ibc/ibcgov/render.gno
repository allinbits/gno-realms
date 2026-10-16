package ibcgov

import (
	"strconv"
	"strings"

	"gno.land/p/aib/jsonmd/v0"

	"gno.land/p/aib/decisions/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// Render serves the governance state:
//
//	""                   the page: governor, channel, seats, flags, holds, decisions
//	"decisions"          every decision, oldest first, as JSON
//	"dispatch/<e>/<seq>" an Ethereum-bound decision's packet state, as JSON
//
// The page's text comes from the builders, which take no free text: client
// ids, denoms and incidents pass character checks, addresses and keys are
// parsed, numbers are formatted here. The decision list is written as the
// ledger keeps it; single values are escaped for inline markdown.
func Render(path string) string {
	switch {
	case path == "":
		return home()
	case path == "decisions":
		return jsonmd.Inert(ledger.JSON())
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

func home() string {
	var b strings.Builder
	b.WriteString("# IBC governance\n\n")
	b.WriteString("- " + decisions.GovernorLine(LaunchGovernor, yielded) + "\n")
	b.WriteString("- " + decisions.Clocks() + "\n")
	if epoch == 0 {
		b.WriteString("- governance channel: not bound\n")
	} else {
		b.WriteString("- governance channel: epoch " + strconv.FormatUint(uint64(epoch), 10) + " over client " +
			sanitize.InlineText(EpochClient()) + ", last seq " + u64s(LastSeq(epoch)) + "\n")
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
		b.WriteString("- " + strconv.Itoa(i) + " (" + role + "): " + sanitize.InlineText(holder) + "\n")
	}
	b.WriteString("\n## Routes\n\n")
	if routes.Size() == 0 {
		b.WriteString("No route enrolled.\n")
	}
	routes.Iterate("", "", func(k string, v any) bool {
		r := v.(*routeRec)
		// Route keys are core client ids; flag lines are route keys,
		// function names, seats, times and parsed packet keys.
		b.WriteString("- " + k + " (payouts epoch " + itoa(r.epoch) + ")\n")
		for _, f := range Flags(k) {
			b.WriteString("  - flag: " + f + "\n")
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
		",\"body\":" + strconv.Quote(hexs(d.body)) + ",\"status\":" + strconv.Itoa(int(d.status)) +
		",\"redispatch\":" + strconv.FormatBool(d.redispatch) + ",\"in_flight\":" + strconv.FormatBool(d.inFlight) +
		",\"transport\":" + u64s(d.transport) + ",\"sends\":" + strconv.Itoa(d.sends) + ",\"event\":" + strconv.Quote(d.event) + "}"
}

const hexDigits = "0123456789abcdef"

func hexs(b []byte) string {
	out := make([]byte, 2*len(b))
	for i, c := range b {
		out[2*i], out[2*i+1] = hexDigits[c>>4], hexDigits[c&0xf]
	}
	return string(out)
}
