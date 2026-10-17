package testing

import (
	"time"

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

// ShortVersion names ShortVerifier, a verifier version for filetests of a
// replacement that fails its checks after conversion.
const ShortVersion = "ethereum/testing-short"

// ShortTrust is ShortVerifier's trusting window, in slots past the latest
// trusted slot: far shorter than the v0 verifier's.
const ShortTrust = 100

// ShortVerifier is the v0 verifier with a shorter trusting window: it
// reports Expired once the block time passes ShortTrust slots after its
// latest slot, while the v0 verifier is still Active.
type ShortVerifier struct {
	*ethereum.EthLightClient
}

// VerifierVersion is ShortVersion.
func (*ShortVerifier) VerifierVersion() string { return ShortVersion }

// Status is Expired once the block time is ShortTrust slots past the latest
// slot, the v0 verifier's status before that.
func (v *ShortVerifier) Status() lightclient.Status {
	cs := v.ClientState
	now := uint64(time.Now().Unix())
	if now >= cs.GenesisTime && (now-cs.GenesisTime)/cs.SecondsPerSlot+cs.GenesisSlot > cs.LatestSlot+ShortTrust {
		return lightclient.Expired
	}
	return v.EthLightClient.Status()
}

// ToShortVerifier converts a v0 verifier to ShortVerifier.
func ToShortVerifier(lc lightclient.Interface) lightclient.Interface {
	old, ok := lc.(*ethereum.EthLightClient)
	if !ok {
		panic("ToShortVerifier converts an ethereum/v0 verifier")
	}
	return &ShortVerifier{EthLightClient: old}
}
