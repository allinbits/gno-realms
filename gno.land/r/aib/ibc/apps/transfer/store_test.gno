package transfer

import (
	"chain"
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

			got := resolveGRC20Alias(alias)
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
			uassert.Equal(t, tc.expect, isGRC20Alias(tc.denom))
		})
	}
}

func TestEscrowIsolationPerClient(t *testing.T) {
	// Reset the escrow tree so the test is independent of ordering.
	totalEscrow = bptree.NewBPTree32()

	// clientA escrows 100ugnot; clientB escrows nothing. The checks below
	// prove the accounting was recorded and isolated per client.
	addEscrowForClient("07-tendermint-1", chain.NewCoin("ugnot", 100))

	// clientA can release its own escrow.
	coin := chain.NewCoin("ugnot", 30)
	urequire.NoError(t, checkEscrowForClient("07-tendermint-1", coin))
	debitEscrowForClient("07-tendermint-1", coin)

	// clientB must NOT be able to release funds clientA locked: this is the
	// shared-escrow drain defense.
	err := checkEscrowForClient("07-tendermint-2", chain.NewCoin("ugnot", 10))
	urequire.ErrorContains(t, err, "insufficient escrow for client 07-tendermint-2")

	// clientA cannot release more than it escrowed (70 remaining after the 30
	// release above).
	err = checkEscrowForClient("07-tendermint-1", chain.NewCoin("ugnot", 71))
	urequire.ErrorContains(t, err, "insufficient escrow for client 07-tendermint-1 denom ugnot: have 70")

	// A denom clientA never escrowed is rejected even though clientA has ugnot.
	err = checkEscrowForClient("07-tendermint-1", chain.NewCoin("uatom", 1))
	urequire.ErrorContains(t, err, "insufficient escrow for client 07-tendermint-1 denom uatom")
}

func TestEscrowAccumulatesPerClientDenom(t *testing.T) {
	totalEscrow = bptree.NewBPTree32()

	// Two sends over the same client accumulate.
	addEscrowForClient("07-tendermint-1", chain.NewCoin("ugnot", 40))
	addEscrowForClient("07-tendermint-1", chain.NewCoin("ugnot", 60))

	// A single release of the full accumulated amount must succeed.
	coin := chain.NewCoin("ugnot", 100)
	urequire.NoError(t, checkEscrowForClient("07-tendermint-1", coin))
	debitEscrowForClient("07-tendermint-1", coin)

	// The pool is now empty for that (client, denom).
	err := checkEscrowForClient("07-tendermint-1", chain.NewCoin("ugnot", 1))
	urequire.ErrorContains(t, err, "insufficient escrow for client 07-tendermint-1 denom ugnot: have 0")
}

// TestCheckEscrowForClientDoesNotMutate verifies the check is read-only. The
// unescrow path relies on this: OnRecvPacket returning Failure does not roll
// back store writes, so a failed transfer after a successful check must leave
// the accounting intact.
func TestCheckEscrowForClientDoesNotMutate(t *testing.T) {
	totalEscrow = bptree.NewBPTree32()
	addEscrowForClient("07-tendermint-1", chain.NewCoin("ugnot", 100))

	// A passing check must not change the balance.
	urequire.NoError(t, checkEscrowForClient("07-tendermint-1", chain.NewCoin("ugnot", 30)))
	t1 := escrowForClient("07-tendermint-1")
	uassert.Equal(t, int64(100), t1.Get("ugnot").(chain.Coin).Amount)

	// A failing check must not change the balance either.
	err := checkEscrowForClient("07-tendermint-1", chain.NewCoin("ugnot", 101))
	uassert.ErrorContains(t, err, "have 100")
	uassert.Equal(t, int64(100), t1.Get("ugnot").(chain.Coin).Amount)

	// And a check against the wrong client must not create an empty entry for it.
	err = checkEscrowForClient("07-tendermint-2", chain.NewCoin("ugnot", 1))
	uassert.ErrorContains(t, err, "insufficient escrow for client 07-tendermint-2")
	uassert.Nil(t, totalEscrow.Get("07-tendermint-2"))
}

// TestDebitEscrowForClientMatchesCheck verifies debit applies the authorized
// subtraction without re-checking.
func TestDebitEscrowForClientMatchesCheck(t *testing.T) {
	totalEscrow = bptree.NewBPTree32()
	addEscrowForClient("07-tendermint-1", chain.NewCoin("ugnot", 100))
	coin := chain.NewCoin("ugnot", 40)

	urequire.NoError(t, checkEscrowForClient("07-tendermint-1", coin))
	debitEscrowForClient("07-tendermint-1", coin)

	t1 := escrowForClient("07-tendermint-1")
	uassert.Equal(t, int64(60), t1.Get("ugnot").(chain.Coin).Amount)
}
