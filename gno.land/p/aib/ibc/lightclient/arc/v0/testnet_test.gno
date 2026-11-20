package arc

import (
	"encoding/hex"
	"strconv"
	"strings"
	"testing"
	"time"

	arctesting "gno.land/p/aib/ibc/lightclient/arc/testing/v0"
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/aib/ibc/types/v0"
)

func setTime(unix int64) {
	testing.SetContext(testing.Context{Time: time.Unix(unix, 0)})
}

// newTestnetClient creates a client from the fixture's creation message.
func newTestnetClient(t *testing.T) *ArcLightClient {
	t.Helper()
	cs, cons, err := DecodeCreation(arctesting.Creation)
	if err != nil {
		t.Fatalf("creation: %v", err)
	}
	if err := cs.ValidateBasic(); err != nil {
		t.Fatal(err)
	}
	if err := cons.ValidateBasic(); err != nil {
		t.Fatal(err)
	}
	if cons.Height != arctesting.CreationHeight {
		t.Fatalf("creation height %d, want %d", cons.Height, arctesting.CreationHeight)
	}
	c := NewArcLightClient()
	if err := c.Initialize(cs, cons); err != nil {
		t.Fatal(err)
	}
	return c
}

func update(c *ArcLightClient, h *Header) error {
	if err := c.VerifyClientMessage(h); err != nil {
		return err
	}
	if c.CheckForMisbehaviour(h) {
		panic("unexpected misbehaviour")
	}
	c.UpdateState(h)
	return nil
}

func TestTestnetCreation(t *testing.T) {
	setTime(arctesting.Time)
	c := newTestnetClient(t)
	cons, _ := c.GetConsensusState(c.LatestHeight())
	if n := len(cons.NextValidators.Validators); n == 0 || n > MaxValidators {
		t.Fatalf("read %d validators", n)
	}
	if c.Status() != lightclient.Active {
		t.Fatalf("status %s", c.Status())
	}
}

func TestTestnetUpdate(t *testing.T) {
	setTime(arctesting.Time)
	c := newTestnetClient(t)
	h, err := DecodeHeader(arctesting.Header)
	if err != nil {
		t.Fatal(err)
	}
	if err := update(c, h); err != nil {
		t.Fatalf("update: %v", err)
	}
	if got := c.LatestHeight(); got != types.NewHeight(0, arctesting.UpdateHeight) {
		t.Fatalf("latest height %s", got.String())
	}
	cons, _ := c.GetConsensusState(c.LatestHeight())
	trusted, _ := c.GetConsensusState(types.NewHeight(0, arctesting.CreationHeight))
	if arctesting.SameRegistry && cons.NextValidators != trusted.NextValidators {
		t.Fatal("an unchanged registry should share the trusted set")
	}
}

// TestTestnetUpdateReadsSet forgets the trusted registry root, so the update
// reads the set from its nodes (without them it fails); the set read equals
// the trusted one, so it counts as T's set and the stored state shares it.
func TestTestnetUpdateReadsSet(t *testing.T) {
	setTime(arctesting.Time)
	c := newTestnetClient(t)
	trusted, _ := c.GetConsensusState(c.LatestHeight())
	trusted.RegistryStorageRoot = make([]byte, 32)
	h, _ := DecodeHeader(arctesting.Header)
	noNodes, _ := DecodeHeader(arctesting.Header)
	noNodes.SetNodes = nil
	if _, _, err := c.derive(trusted, noNodes); err == nil {
		t.Fatal("the set was not read from the nodes")
	}
	if _, sameSet, err := c.derive(trusted, h); err != nil || !sameSet {
		t.Fatalf("derive: same set %v, %v", sameSet, err)
	}
	if err := update(c, h); err != nil {
		t.Fatalf("update: %v", err)
	}
	cons, _ := c.GetConsensusState(c.LatestHeight())
	if cons.NextValidators != trusted.NextValidators {
		t.Fatal("an equal set was stored again, not shared")
	}
}

func expectRefused(t *testing.T, name string, mutate func(h *Header), want string) {
	t.Helper()
	setTime(arctesting.Time)
	c := newTestnetClient(t)
	h, _ := DecodeHeader(arctesting.Header)
	mutate(h)
	err := c.VerifyClientMessage(h)
	if err == nil {
		t.Fatalf("%s: accepted", name)
	}
	if !strings.Contains(err.Error(), want) {
		t.Fatalf("%s: %v, want %q", name, err, want)
	}
}

func TestTestnetRefusals(t *testing.T) {
	expectRefused(t, "bad signature", func(h *Header) {
		s := cloneBytes(h.Certificate.Signatures[0].Signature)
		s[5] ^= 1
		h.Certificate.Signatures[0].Signature = s
	}, "invalid signature")
	expectRefused(t, "too few signatures", func(h *Header) {
		h.Certificate.Signatures = h.Certificate.Signatures[:len(h.Certificate.Signatures)/2]
	}, "not enough voting power")
	expectRefused(t, "duplicate signature", func(h *Header) {
		h.Certificate.Signatures = append(h.Certificate.Signatures, h.Certificate.Signatures[0])
	}, "duplicate signature")
	expectRefused(t, "other round", func(h *Header) { h.Certificate.Round++ }, "invalid signature")
	expectRefused(t, "other block hash", func(h *Header) {
		b := cloneBytes(h.Certificate.BlockHash)
		b[0] ^= 1
		h.Certificate.BlockHash = b
	}, "certified header hash")
	expectRefused(t, "block not the parent", func(h *Header) {
		h.BlockHeader = append(cloneBytes(h.BlockHeader[:len(h.BlockHeader)-1]), h.BlockHeader[len(h.BlockHeader)-1]^1)
	}, "")
	expectRefused(t, "stale anchor", func(h *Header) { h.TrustedHeight-- }, "latest trusted height")
	expectRefused(t, "wrong registry proof", func(h *Header) { h.RegistryProof = h.RegistryProof[1:] }, "registry account proof")
}

func TestTestnetExpiryAndDrift(t *testing.T) {
	setTime(arctesting.Time)
	c := newTestnetClient(t)
	setTime(arctesting.Time + int64(c.ClientState.TrustingPeriod) + 10)
	if c.Status() != lightclient.Expired {
		t.Fatalf("status %s, want Expired", c.Status())
	}
	h, _ := DecodeHeader(arctesting.Header)
	if err := c.VerifyClientMessage(h); err == nil || !strings.Contains(err.Error(), "expired") {
		t.Fatalf("expired update: %v", err)
	}
	setTime(arctesting.Time - 3600)
	c = newTestnetClient(t)
	if err := c.VerifyClientMessage(h); err == nil || !strings.Contains(err.Error(), "future") {
		t.Fatalf("future block: %v", err)
	}
}

// A set read that finds another registry implementation is refused: the
// client reads the set by the pinned implementation's layout.
func TestTestnetImplementationPinned(t *testing.T) {
	setTime(arctesting.Time)
	c := newTestnetClient(t)
	trusted, _ := c.GetConsensusState(c.LatestHeight())
	trusted.RegistryStorageRoot = make([]byte, 32) // force the set read
	cs := *c.ClientState
	cs.RegistryImplementation = cloneBytes(cs.RegistryImplementation)
	cs.RegistryImplementation[0] ^= 1
	c.ClientState = &cs
	h, _ := DecodeHeader(arctesting.Header)
	err := c.VerifyClientMessage(h)
	if err == nil || !strings.Contains(err.Error(), "implementation changed") {
		t.Fatalf("got %v", err)
	}
}

func TestClientStateBounds(t *testing.T) {
	cs, _, err := DecodeCreation(arctesting.Creation)
	if err != nil {
		t.Fatal(err)
	}
	for name, mutate := range map[string]func(*ClientState){
		"trust level 1":     func(c *ClientState) { c.TrustLevel = Fraction{1, 1} },
		"trust below 1/3":   func(c *ClientState) { c.TrustLevel = Fraction{1, 4} },
		"huge drift":        func(c *ClientState) { c.MaxClockDrift = ^uint64(0) },
		"no implementation": func(c *ClientState) { c.RegistryImplementation = nil },
		// A stalled client stays Active, and so unrecoverable, until it
		// expires: the trusting period is capped at 14 days.
		"trusting period past 14 days": func(c *ClientState) { c.TrustingPeriod = 14*24*3600 + 1 },
		"no trusting period":           func(c *ClientState) { c.TrustingPeriod = 0 },
	} {
		c := cs.clone()
		mutate(&c)
		if c.ValidateBasic() == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if err := cs.ValidateBasic(); err != nil {
		t.Fatal(err)
	}
	c := cs.clone()
	c.TrustingPeriod = 14 * 24 * 3600
	if err := c.ValidateBasic(); err != nil {
		t.Fatalf("a 14-day trusting period: %v", err)
	}
}

func TestTestnetMisbehaviourNeedsTwoBlocks(t *testing.T) {
	setTime(arctesting.Time)
	c := newTestnetClient(t)
	h1, _ := DecodeHeader(arctesting.Header)
	h2, _ := DecodeHeader(arctesting.Header)
	if err := c.VerifyClientMessage(&Misbehaviour{Header1: h1, Header2: h2}); err == nil {
		t.Fatal("one block twice is no misbehaviour")
	}
}

// TestValidatorSetValidateBounds checks a set built without NewValidatorSet
// (as a raw consensus state given to CreateClient is): its power sum cannot
// wrap, and its size is bounded.
func TestValidatorSetValidateBounds(t *testing.T) {
	setTime(arctesting.Time)
	c := newTestnetClient(t)
	cons, _ := c.GetConsensusState(c.LatestHeight())
	vals := cons.NextValidators.Validators
	if len(vals) < 2 {
		t.Fatal("the fixture needs two validators")
	}
	a, b := vals[0], vals[1]
	a.Power, b.Power = ^uint64(0), 2 // wraps to 1
	wrapped := &ValidatorSet{Validators: []Validator{a, b}, TotalPower: 1}
	if err := wrapped.validate(); err == nil || !strings.Contains(err.Error(), "overflows") {
		t.Fatalf("wrapping sum: %v", err)
	}
	big := &ValidatorSet{TotalPower: 1}
	for i := 0; i <= MaxValidators; i++ {
		big.Validators = append(big.Validators, vals[0])
	}
	if err := big.validate(); err == nil || !strings.Contains(err.Error(), "more than") {
		t.Fatalf("oversized set: %v", err)
	}
}

// TestTestnetRecoveryAdoptsLayout recovers a client from a substitute whose
// registry moved (another implementation and storage location): the subject
// takes both, with the substitute's latest state.
func TestTestnetRecoveryAdoptsLayout(t *testing.T) {
	setTime(arctesting.Time)
	subject := newTestnetClient(t)
	sub := newTestnetClient(t)
	h, _ := DecodeHeader(arctesting.Header)
	if err := update(sub, h); err != nil {
		t.Fatal(err)
	}
	cs := *sub.ClientState
	cs.RegistryImplementation = cloneBytes(cs.RegistryImplementation)
	cs.RegistryImplementation[0] ^= 1
	cs.RegistryStorageLocation = cloneBytes(cs.RegistryStorageLocation)
	cs.RegistryStorageLocation[0] ^= 1
	sub.ClientState = &cs
	if err := subject.RecoverClient(sub); err != nil {
		t.Fatalf("recovery: %v", err)
	}
	got := subject.ClientState
	if string(got.RegistryStorageLocation) != string(cs.RegistryStorageLocation) ||
		string(got.RegistryImplementation) != string(cs.RegistryImplementation) {
		t.Fatal("the subject kept its old registry layout")
	}
	if subject.LatestHeight() != sub.LatestHeight() {
		t.Fatalf("latest height %s", subject.LatestHeight().String())
	}

	// Another registry address is another chain's set: refused.
	other := newTestnetClient(t)
	ocs := *sub.ClientState
	ocs.RegistryAddress = cloneBytes(ocs.RegistryAddress)
	ocs.RegistryAddress[0] ^= 1
	sub.ClientState = &ocs
	if err := other.CheckRecovery(sub); err == nil {
		t.Fatal("a substitute with another registry was accepted")
	}
}

// laterVerifier stands for a later verifier version (arc/v1) that wraps the
// v0 one and exposes its state through Arc.
type laterVerifier struct{ *ArcLightClient }

// TestTestnetRecoveryFromLaterVersion recovers from a substitute of a later
// verifier version wrapping arc/v0, reading its state through Arc, and
// refuses one whose client state is invalid.
func TestTestnetRecoveryFromLaterVersion(t *testing.T) {
	setTime(arctesting.Time)
	subject := newTestnetClient(t)
	inner := newTestnetClient(t)
	h, _ := DecodeHeader(arctesting.Header)
	if err := update(inner, h); err != nil {
		t.Fatal(err)
	}
	sub := laterVerifier{inner}
	if err := subject.RecoverClient(sub); err != nil {
		t.Fatalf("recovery from a later version: %v", err)
	}
	if subject.LatestHeight() != inner.LatestHeight() {
		t.Fatalf("latest height %s", subject.LatestHeight().String())
	}

	other := newTestnetClient(t)
	bad := *inner.ClientState
	bad.TrustingPeriod = 0
	inner.ClientState = &bad
	err := other.CheckRecovery(sub)
	if err == nil || !strings.Contains(err.Error(), "substitute client state") {
		t.Fatalf("a substitute with an invalid client state: %v", err)
	}
}

// The chain identity names the chain id and registry, not the router: two
// routers on one Arc chain share it (ADR 0007, one route per chain).
func TestTestnetChainIdentity(t *testing.T) {
	c := newTestnetClient(t)
	cs := c.ClientState
	want := "arc chain " + strconv.FormatUint(cs.ChainID, 10) + ", registry 0x" + hex.EncodeToString(cs.RegistryAddress)
	if got := c.ChainIdentity(); got != want {
		t.Fatalf("chain identity %q, want %q", got, want)
	}
	other := *c
	ocs := *cs
	ocs.IBCContractAddress = append(make([]byte, 19), 0x09)
	other.ClientState = &ocs
	if other.ChainIdentity() != want {
		t.Fatalf("another router changed the chain identity")
	}
	if id, _ := other.RouteIdentity(); id == mustRoute(c) {
		t.Fatalf("another router kept the route identity")
	}
}

func mustRoute(c *ArcLightClient) string {
	id, _ := c.RouteIdentity()
	return id
}
