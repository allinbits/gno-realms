package consumer

import (
	"strconv"

	"gno.land/p/nt/ufmt"
)

// Render returns a human-readable Markdown representation of the current
// consumer state. It is called when the realm is accessed via the web
// interface (e.g. https://gno.land/r/aib/ibc/apps/vaas/consumer).
func Render(path string) string {
	var s string

	s += "# VAAS Consumer\n\n"

	// Provider info
	providerClient, hasProvider := GetProviderClientID()
	if hasProvider {
		s += ufmt.Sprintf("**Provider Client:** `%s`\n\n", providerClient)
	} else {
		s += "**Provider Client:** _not established_\n\n"
	}

	// Valset update ID
	valsetUpdateID := GetHighestValsetUpdateID()
	if valsetUpdateID > 0 {
		s += ufmt.Sprintf("**Valset Update ID:** %d\n\n", valsetUpdateID)
	} else {
		s += "**Valset Update ID:** _none_\n\n"
	}

	// Current validator set
	vals := GetAllCCValidators()
	s += ufmt.Sprintf("## Validator Set (%d validators)\n\n", len(vals))

	if len(vals) == 0 {
		s += "_No validators registered yet._\n\n"
	} else {
		totalPower := GetTotalVotingPower()
		s += ufmt.Sprintf("**Total Voting Power:** %s\n\n", strconv.FormatInt(totalPower, 10))
		s += "| PubKey | Power |\n"
		s += "| --- | --- |\n"
		for _, v := range vals {
			s += ufmt.Sprintf("| `%s` | %s |\n", abbreviatePubKey(v.PubKey), strconv.FormatInt(v.Power, 10))
		}
		s += "\n"
	}

	// IBC app info
	s += "---\n\n"
	s += "## IBC App Info\n\n"
	s += ufmt.Sprintf("- **Port ID:** `%s`\n", PortID)
	s += ufmt.Sprintf("- **Provider Port ID:** `%s`\n", ProviderPortID)
	s += ufmt.Sprintf("- **Version:** `%s`\n", Version)
	s += ufmt.Sprintf("- **Encoding:** `%s`\n", EncodingJSON)

	return s
}

// abbreviatePubKey shortens a public key string for display purposes.
// For the canonical format "ed25519:<base64>", it shows the type and
// abbreviated base64 value. For other formats, it shows the first 10
// and last 6 characters separated by "...".
func abbreviatePubKey(pk string) string {
	if len(pk) <= 24 {
		return pk
	}
	return pk[:14] + "..." + pk[len(pk)-6:]
}
