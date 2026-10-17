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

func verifierVersionOf(lc lightclient.Interface) string {
	if v, ok := lc.(VersionedVerifier); ok {
		return v.VerifierVersion()
	}
	return ""
}
