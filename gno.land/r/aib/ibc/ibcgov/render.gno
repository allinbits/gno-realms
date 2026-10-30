package ibcgov

import (
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/aib/jsonmd/v0"

	"gno.land/p/aib/decisions/v0"
)

// Render serves the governance state:
//
//	""                    the page: governor, decisions
//	"decisions?from=<id>" the decisions as JSON, oldest first, 100 a page from
//	                      decision <id> (the first without from); the page's
//	                      "next" is the from of the following one (0 at the end)
//
// The page's text comes from the builders, which take no free text: client
// ids pass character checks, addresses are parsed, numbers are formatted
// here. The decision list is written as the ledger keeps it.
func Render(path string) string {
	switch {
	case path == "":
		return home()
	case path == "decisions" || strings.HasPrefix(path, "decisions?"):
		return jsonmd.Inert(ledger.JSON(fromOf(path)))
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
	b.WriteString("\n## Decisions\n\n")
	b.WriteString(ledger.Page())
	return b.String()
}
