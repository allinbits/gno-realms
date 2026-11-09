package core

import (
	"gno.land/p/aib/ibc/lightclient/v0"
)

// VersionedVerifier is a verifier that names its package and version, which
// a verifier replacement converts from and to (ADR pr6375 R16). The
// conversions themselves are code of a core implementation, installed by a
// governed implementation upgrade: no other code converts a verifier.
type VersionedVerifier interface {
	VerifierVersion() string
}

// VerifierVersion is the version clientID's verifier names, "" if the
// client is unknown or its verifier names none.
func VerifierVersion(clientID string) string {
	c := store.getClient(clientID)
	if c == nil {
		return ""
	}
	return verifierVersionOf(c.lightClient)
}

// IdentifiedVerifier is a verifier that names the history it authenticates,
// what a route keeps across replacements (ADR pr6375 §7.12): the Ethereum
// verifier, and any later version embedding it.
type IdentifiedVerifier interface {
	RouteIdentity() (identity, router string)
}

// ClientRouteIdentity is the history clientID's verifier authenticates and
// the router it reads ("", "" if the client is unknown or its verifier names
// none): for an Ethereum client its chain id, genesis validators root, ICS26
// router and commitments slot.
func ClientRouteIdentity(clientID string) (identity, router string) {
	c := store.getClient(clientID)
	if c == nil {
		return "", ""
	}
	if v, ok := c.lightClient.(IdentifiedVerifier); ok {
		return v.RouteIdentity()
	}
	return "", ""
}

func verifierVersionOf(lc lightclient.Interface) string {
	if v, ok := lc.(VersionedVerifier); ok {
		return v.VerifierVersion()
	}
	return ""
}
