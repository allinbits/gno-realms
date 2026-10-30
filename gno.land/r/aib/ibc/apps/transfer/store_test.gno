package transfer

import (
	"chain"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

func TestGRC20AliasRoundTrip(t *testing.T) {
	testCases := []struct {
		name     string
		key      string
		expAlias string
	}{
		{
			"simple path without slug",
			"gno.land/r/demo/foo",
			"gno.land:r:demo:foo",
		},
		{
			"path with slug",
			"gno.land/r/demo/foo.FOO",
			"gno.land:r:demo:foo.FOO",
		},
		{
			"path with alphanumeric slug",
			"gno.land/r/demo/foo.Bar123",
			"gno.land:r:demo:foo.Bar123",
		},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			alias := GRC20Alias(tc.key)
			uassert.Equal(t, tc.expAlias, alias)

			got := ResolveGRC20Alias(alias)
			uassert.Equal(t, tc.key, got)
		})
	}
}

func TestIsGRC20Alias(t *testing.T) {
	testCases := []struct {
		name   string
		denom  string
		expect bool
	}{
		{"grc20 alias", "gno.land:r:demo:foo.FOO", true},
		{"native denom", "ugnot", false},
		{"ibc denom", "ibc/ABC123", false},
		{"gno path not aliased", "gno.land/r/demo/foo", false},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			uassert.Equal(t, tc.expect, IsGRC20Alias(tc.denom))
		})
	}
}

func TestEscrowIsolationPerClient(t *testing.T) {
	// Reset the escrow tree so the test is independent of ordering.
	totalEscrow = bptree.NewBPTree32()
	escrowByDenom = bptree.NewBPTree32()
	escrowTotals = bptree.NewBPTree32()

	// clientA escrows 100ugnot; clientB escrows nothing. The checks below
	// prove the accounting was recorded and isolated per client.
	addEscrowForClient("07-tendermint-1", "ugnot", 100)

	// clientA can release its own escrow.
	urequire.NoError(t, checkEscrowForClient("07-tendermint-1", "ugnot", 30))
	debitEscrowForClient("07-tendermint-1", "ugnot", 30)

	// clientB must NOT be able to release funds clientA locked: this is the
	// shared-escrow drain defense.
	err := checkEscrowForClient("07-tendermint-2", "ugnot", 10)
	urequire.ErrorContains(t, err, "insufficient escrow for client 07-tendermint-2")

	// clientA cannot release more than it escrowed (70 remaining after the 30
	// release above).
	err = checkEscrowForClient("07-tendermint-1", "ugnot", 71)
	urequire.ErrorContains(t, err, "insufficient escrow for client 07-tendermint-1 denom ugnot: have 70")

	// A denom clientA never escrowed is rejected even though clientA has ugnot.
	err = checkEscrowForClient("07-tendermint-1", "uatom", 1)
	urequire.ErrorContains(t, err, "insufficient escrow for client 07-tendermint-1 denom uatom")
}

func TestEscrowAccumulatesPerClientDenom(t *testing.T) {
	totalEscrow = bptree.NewBPTree32()
	escrowByDenom = bptree.NewBPTree32()
	escrowTotals = bptree.NewBPTree32()

	// Two sends over the same client accumulate, past int64 too: a GRC20 v1
	// escrow counts in uint256.
	addEscrowForClient("07-tendermint-1", "ugnot", 40)
	addEscrowForClient("07-tendermint-1", "ugnot", 60)
	const big = uint256(1) << 70
	addEscrowForClient("07-tendermint-1", "gno.land:r:demo:foo", big)
	addEscrowForClient("07-tendermint-1", "gno.land:r:demo:foo", big)
	if got := store.Escrowed("07-tendermint-1", "gno.land:r:demo:foo"); got != 2*big {
		t.Fatalf("escrowed %d", got)
	}

	// A single release of the full accumulated amount must succeed.
	urequire.NoError(t, checkEscrowForClient("07-tendermint-1", "ugnot", 100))
	debitEscrowForClient("07-tendermint-1", "ugnot", 100)

	// The pool is now empty for that (client, denom).
	err := checkEscrowForClient("07-tendermint-1", "ugnot", 1)
	urequire.ErrorContains(t, err, "insufficient escrow for client 07-tendermint-1 denom ugnot: have 0")
}

// TestCheckEscrowForClientDoesNotMutate verifies the check is read-only. The
// unescrow path relies on this: OnRecvPacket returning Failure does not roll
// back store writes, so a failed transfer after a successful check must leave
// the accounting intact.
func TestCheckEscrowForClientDoesNotMutate(t *testing.T) {
	totalEscrow = bptree.NewBPTree32()
	escrowByDenom = bptree.NewBPTree32()
	escrowTotals = bptree.NewBPTree32()
	addEscrowForClient("07-tendermint-1", "ugnot", 100)

	// A passing check must not change the balance.
	urequire.NoError(t, checkEscrowForClient("07-tendermint-1", "ugnot", 30))
	if got := store.Escrowed("07-tendermint-1", "ugnot"); got != 100 {
		t.Fatalf("escrowed %d", got)
	}

	// A failing check must not change the balance either.
	err := checkEscrowForClient("07-tendermint-1", "ugnot", 101)
	uassert.ErrorContains(t, err, "have 100")
	if got := store.Escrowed("07-tendermint-1", "ugnot"); got != 100 {
		t.Fatalf("escrowed %d", got)
	}

	// And a check against the wrong client must not create an empty entry for it.
	err = checkEscrowForClient("07-tendermint-2", "ugnot", 1)
	uassert.ErrorContains(t, err, "insufficient escrow for client 07-tendermint-2")
	uassert.Nil(t, totalEscrow.Get("07-tendermint-2"))
}

// TestDebitEscrowForClientMatchesCheck verifies debit applies the authorized
// subtraction without re-checking.
func TestDebitEscrowForClientMatchesCheck(t *testing.T) {
	totalEscrow = bptree.NewBPTree32()
	escrowByDenom = bptree.NewBPTree32()
	escrowTotals = bptree.NewBPTree32()
	addEscrowForClient("07-tendermint-1", "ugnot", 100)

	urequire.NoError(t, checkEscrowForClient("07-tendermint-1", "ugnot", 40))
	debitEscrowForClient("07-tendermint-1", "ugnot", 40)

	if got := store.Escrowed("07-tendermint-1", "ugnot"); got != 60 {
		t.Fatalf("escrowed %d", got)
	}
}

// A native release is refused above the chain's coin maximum: the boundary
// where a uint256 amount meets an int64 coin.
func TestCoinOfBoundary(t *testing.T) {
	c, err := coinOf("ugnot", 1<<63-1)
	urequire.NoError(t, err)
	uassert.Equal(t, int64(1<<63-1), c.Amount)
	_, err = coinOf("ugnot", 1<<63)
	urequire.ErrorContains(t, err, "above the chain's coin maximum")
	if got := CoinAmount(chain.NewCoin("ugnot", 7)); got != 7 {
		t.Fatalf("widened %d", got)
	}
}

// The per-denom views must stay in step with the per-client accounting, which
// they index: EscrowTotals sums every client, EscrowClients lists each one.
func TestEscrowIndexByDenom(t *testing.T) {
	totalEscrow = bptree.NewBPTree32()
	escrowByDenom = bptree.NewBPTree32()
	escrowTotals = bptree.NewBPTree32()

	addEscrowForClient("07-tendermint-1", "ugnot", 100)
	addEscrowForClient("07-tendermint-2", "ugnot", 50)
	addEscrowForClient("07-tendermint-2", "uatom", 7)
	addEscrowForClient("07-tendermint-1", "ugnot", 20)
	debitEscrowForClient("07-tendermint-2", "ugnot", 50)

	var s transferStore
	totals := []string{}
	s.EscrowTotals().Iterate("", "", func(denom string, v any) bool {
		totals = append(totals, denom+"="+strconv.FormatUint256(v.(uint256), 10))
		return false
	})
	uassert.Equal(t, "uatom=7,ugnot=120", strings.Join(totals, ","))

	clients := []string{}
	s.EscrowClients("ugnot").Iterate("", "", func(clientID string, v any) bool {
		clients = append(clients, clientID+"="+strconv.FormatUint256(v.(uint256), 10))
		return false
	})
	// A fully released client stays listed at 0, as in the per-client view.
	uassert.Equal(t, "07-tendermint-1=120,07-tendermint-2=0", strings.Join(clients, ","))
	uassert.Equal(t, 0, s.EscrowClients("uphoton").Size())

	// The index matches the per-client accounting.
	sums := map[string]uint256{}
	s.IterateEscrow(func(_, denom string, amount uint256) bool {
		sums[denom] += amount
		return false
	})
	uassert.True(t, sums["ugnot"] == 120)
	uassert.True(t, sums["uatom"] == 7)
}
