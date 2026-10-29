package ibcgov

import (
	"strings"

	"gno.land/p/aib/jsonmd/v0"

	"gno.land/p/aib/decisions/v0"
)

// Render serves the governance state:
//
//	""          the page: governor, decisions
//	"decisions" every decision, oldest first, as JSON
//
// The page's text comes from the builders, which take no free text: client
// ids pass character checks, addresses are parsed, numbers are formatted
// here. The decision list is written as the ledger keeps it.
func Render(path string) string {
	switch {
	case path == "":
		return home()
	case path == "decisions":
		return jsonmd.Inert(ledger.JSON())
	}
	return "# Not found\n"
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
