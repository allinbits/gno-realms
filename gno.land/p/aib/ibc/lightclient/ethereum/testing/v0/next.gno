package testing

import (
	"time"

	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/aib/ibc/types/v0"
)

// NextVersion names NextVerifier, a second Ethereum verifier version for
// filetests of a governed verifier replacement (ADR pr6375 R16): a v0
// verifier continuing the retired one (ethereum.NewFrom) under another
// package and type, so a replacement visibly changes the stored verifier
// while every consensus state and proof keeps verifying. A test core
// implementation compiles its conversion in (implv1.NewWithConversions).
const NextVersion = "ethereum/testing-next"

// NextVerifier is the v0 verifier converted to the next version.
type NextVerifier struct {
	*ethereum.EthLightClient
}

// VerifierVersion is NextVersion.
func (*NextVerifier) VerifierVersion() string { return NextVersion }

// ToNextVerifier converts a v0 verifier, given as a read-only view: a new
// verifier continuing it, its client state copied and its consensus states
// served read only.
func ToNextVerifier(r *ethereum.Retired) lightclient.Interface {
	return &NextVerifier{EthLightClient: ethereum.NewFrom(r)}
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
func ToShortVerifier(r *ethereum.Retired) lightclient.Interface {
	return &ShortVerifier{EthLightClient: ethereum.NewFrom(r)}
}

// ToNilVerifier is a broken conversion for filetests: it returns a typed-nil
// NextVerifier, which names NextVersion but panics on its first state read.
func ToNilVerifier(*ethereum.Retired) lightclient.Interface {
	var v *NextVerifier
	return v
}

// PanicStatusVersion and PanicHeightVersion name PanicStatusVerifier and
// PanicHeightVerifier, broken verifier versions for filetests.
const (
	PanicStatusVersion = "ethereum/testing-panic-status"
	PanicHeightVersion = "ethereum/testing-panic-height"
)

// PanicStatusVerifier panics when asked its status.
type PanicStatusVerifier struct {
	*ethereum.EthLightClient
}

// VerifierVersion is PanicStatusVersion.
func (*PanicStatusVerifier) VerifierVersion() string { return PanicStatusVersion }

// Status panics.
func (*PanicStatusVerifier) Status() lightclient.Status { panic("status unavailable") }

// ToPanicStatusVerifier converts to PanicStatusVerifier.
func ToPanicStatusVerifier(r *ethereum.Retired) lightclient.Interface {
	return &PanicStatusVerifier{EthLightClient: ethereum.NewFrom(r)}
}

// PanicHeightVerifier panics when asked its latest height.
type PanicHeightVerifier struct {
	*ethereum.EthLightClient
}

// VerifierVersion is PanicHeightVersion.
func (*PanicHeightVerifier) VerifierVersion() string { return PanicHeightVersion }

// LatestHeight panics.
func (*PanicHeightVerifier) LatestHeight() types.Height { panic("height unavailable") }

// ToPanicHeightVerifier converts to PanicHeightVerifier.
func ToPanicHeightVerifier(r *ethereum.Retired) lightclient.Interface {
	return &PanicHeightVerifier{EthLightClient: ethereum.NewFrom(r)}
}

// TamperVersion names the result of ToTamperingVerifier.
const TamperVersion = "ethereum/testing-tamper"

// ToTamperingVerifier is a conversion that tries to write to the verifier it
// converts: all it holds is a read-only view, so it can only change copies
// (here, raising the copied client state's latest slot and dropping a
// copied consensus state's root), and it then panics. The live verifier is
// untouched.
func ToTamperingVerifier(r *ethereum.Retired) lightclient.Interface {
	cs := r.ClientState()
	cs.LatestSlot += 1000
	cs.IBCContractAddress[0] ^= 0xff
	if cons, ok := r.ConsensusState(r.LatestHeight()); ok {
		cons.StateRoot[0] ^= 0xff
	}
	panic("tampering conversion")
}

// RewriteVersion and RewritePanicVersion name the results of ToRootRewriter
// and ToRootRewriterPanicking, conversions that try to rewrite a retired
// verifier's trusted root through NewFrom and then refuse (a nil verifier)
// or panic.
const (
	RewriteVersion      = "ethereum/testing-rewrite"
	RewritePanicVersion = "ethereum/testing-rewrite-panic"
)

func rewriteRoot(r *ethereum.Retired) {
	n := ethereum.NewFrom(r)
	if cons, ok := n.GetConsensusState(r.LatestHeight()); ok {
		cons.StateRoot[0] ^= 0xff
	}
}

// ToRootRewriter rewrites the root NewFrom serves for the latest height, then
// returns no verifier.
func ToRootRewriter(r *ethereum.Retired) lightclient.Interface {
	rewriteRoot(r)
	return nil
}

// ToRootRewriterPanicking rewrites the same root, then panics.
func ToRootRewriterPanicking(r *ethereum.Retired) lightclient.Interface {
	rewriteRoot(r)
	panic("rewrote a root")
}

// OpaqueVersion names OpaqueVerifier, a verifier version that keeps its
// state behind the light-client interface alone: it exposes no Ethereum()
// state, so no conversion can read it.
const OpaqueVersion = "ethereum/testing-opaque"

// OpaqueVerifier is a v0 verifier seen only through lightclient.Interface.
type OpaqueVerifier struct {
	lightclient.Interface
}

// VerifierVersion is OpaqueVersion.
func (*OpaqueVerifier) VerifierVersion() string { return OpaqueVersion }

// ToOpaqueVerifier converts a v0 verifier to OpaqueVerifier.
func ToOpaqueVerifier(r *ethereum.Retired) lightclient.Interface {
	return &OpaqueVerifier{Interface: ethereum.NewFrom(r)}
}

// FreezingVersion names FreezingVerifier, a verifier version for filetests
// of a client that is Frozen when a verifier replacement executes.
const FreezingVersion = "ethereum/testing-freezing"

// FreezingVerifier is the v0 verifier reporting Frozen once the block time is
// ShortTrust slots past its latest slot, as if a misbehaviour had frozen it,
// and the v0 verifier's status before that.
type FreezingVerifier struct {
	*ethereum.EthLightClient
}

// VerifierVersion is FreezingVersion.
func (*FreezingVerifier) VerifierVersion() string { return FreezingVersion }

// Status is Frozen once the block time is ShortTrust slots past the latest
// slot.
func (v *FreezingVerifier) Status() lightclient.Status {
	cs := v.ClientState
	now := uint64(time.Now().Unix())
	if now >= cs.GenesisTime && (now-cs.GenesisTime)/cs.SecondsPerSlot+cs.GenesisSlot > cs.LatestSlot+ShortTrust {
		return lightclient.Frozen
	}
	return v.EthLightClient.Status()
}

// ToFreezingVerifier converts a v0 verifier to FreezingVerifier.
func ToFreezingVerifier(r *ethereum.Retired) lightclient.Interface {
	return &FreezingVerifier{EthLightClient: ethereum.NewFrom(r)}
}

// ForkRewriteVersion names the result of ToForkRewriter, a conversion that
// changes the version of a fork already active: the core refuses its result
// (ethereum.Retired.CheckSuccessor).
const ForkRewriteVersion = "ethereum/testing-fork-rewrite"

// ForkRewriter is the v0 verifier with its Fulu version changed.
type ForkRewriter struct {
	*ethereum.EthLightClient
}

// VerifierVersion is ForkRewriteVersion.
func (*ForkRewriter) VerifierVersion() string { return ForkRewriteVersion }

// ToForkRewriter converts a v0 verifier, changing its active Fulu fork.
func ToForkRewriter(r *ethereum.Retired) lightclient.Interface {
	v := ethereum.NewFrom(r)
	cs := *v.ClientState
	cs.ForkParameters.Fulu.Version[0] ^= 0xff
	v.ClientState = &cs
	return &ForkRewriter{EthLightClient: v}
}
