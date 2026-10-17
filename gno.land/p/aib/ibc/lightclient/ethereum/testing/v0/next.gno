package testing

import (
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/lightclient/v0"
)

// NextVersion names NextVerifier, a second Ethereum verifier version for
// filetests of a governed verifier replacement (ADR pr6375 R16): it is the
// v0 verifier under another package and type, so a replacement visibly
// changes the stored verifier while every consensus state and proof keeps
// verifying.
const NextVersion = "ethereum/testing-next"

// NextVerifier is the v0 verifier converted to the next version.
type NextVerifier struct {
	*ethereum.EthLightClient
}

// VerifierVersion is NextVersion.
func (*NextVerifier) VerifierVersion() string { return NextVersion }

// ToNextVerifier converts a v0 verifier, keeping its client state and every
// consensus state; it is the conversion a replacement runs at installation.
func ToNextVerifier(lc lightclient.Interface) lightclient.Interface {
	old, ok := lc.(*ethereum.EthLightClient)
	if !ok {
		panic("ToNextVerifier converts an ethereum/v0 verifier")
	}
	return &NextVerifier{EthLightClient: old}
}
