package consumer

import (
	"strconv"

	"gno.land/p/nt/ufmt"
	"gno.land/p/onbloc/json"
)

// Render returns a human-readable Markdown representation of the
// consumer state. It is called when the realm is accessed via the web
// interface (e.g. https://gno.land/r/aib/ibc/apps/vaas/consumer).
func Render(path string) string {
	// Handle JSON render paths for e2e tests
	switch path {
	case "provider_client_id":
		return renderProviderClientID()
	case "highest_valset_update_id":
		return renderHighestValsetUpdateID()
	case "validator_count":
		return renderValidatorCount()
	case "total_voting_power":
		return renderTotalVotingPower()
	case "validators":
		return renderValidators()
	}

	// Default to human-readable Markdown
	return renderMarkdown()
}

// renderProviderClientID returns JSON with provider client ID.
func renderProviderClientID() string {
	providerClient, hasProvider := GetProviderClientID()
	if !hasProvider {
		providerClient = ""
	}
	return json.ObjectNode("", map[string]*json.Node{
		"provider_client_id": json.StringNode("", providerClient),
	}).String()
}

// renderHighestValsetUpdateID returns JSON with highest valset update ID.
func renderHighestValsetUpdateID() string {
	valsetID := GetHighestValsetUpdateID()
	return json.ObjectNode("", map[string]*json.Node{
		"highest_valset_update_id": json.StringNode("", strconv.FormatUint(valsetID, 10)),
	}).String()
}

// renderValidatorCount returns JSON with validator count.
func renderValidatorCount() string {
	count := GetCCValidatorCount()
	return json.ObjectNode("", map[string]*json.Node{
		"validator_count": json.StringNode("", strconv.Itoa(count)),
	}).String()
}

// renderTotalVotingPower returns JSON with total voting power.
func renderTotalVotingPower() string {
	totalPower := GetTotalVotingPower()
	return json.ObjectNode("", map[string]*json.Node{
		"total_voting_power": json.StringNode("", strconv.FormatInt(totalPower, 10)),
	}).String()
}

// renderValidators returns JSON with all validators.
func renderValidators() string {
	vals := GetAllCCValidators()
	validatorsNode := make([]*json.Node, len(vals))
	for i, v := range vals {
		validatorsNode[i] = json.ObjectNode("", map[string]*json.Node{
			"pub_key": json.StringNode("", v.PubKey),
			"power":  json.StringNode("", strconv.FormatInt(v.Power, 10)),
		})
	}
	return json.ObjectNode("", map[string]*json.Node{
		"validators": json.ArrayNode("", validatorsNode),
	}).String()
}

// renderMarkdown returns a human-readable Markdown representation of the current
// consumer state.
func renderMarkdown() string {
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
// For a canonical format "ed25519:<base64>", it shows the type and
// abbreviated base64 value. For other formats, it shows the first 10
// and last 6 characters separated by "...".
func abbreviatePubKey(pk string) string {
	if len(pk) <= 24 {
		return pk
	}
	return pk[:14] + "..." + pk[len(pk)-6:]
}
