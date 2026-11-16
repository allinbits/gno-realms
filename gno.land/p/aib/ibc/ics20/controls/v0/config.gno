package controls

import (
	"errors"

	"gno.land/p/aib/encoding/ethaddr/v0"
	"gno.land/p/nt/ufmt/v0"
)

// The two accountings of a route's denom (ADR pr6375 §7.1).
const (
	// KindUnescrow is a gno-native asset: sends escrow it here and returns
	// from Ethereum release it; its lock is its escrow, which caps payouts.
	KindUnescrow = "unescrow"
	// KindMint is an Ethereum-native asset: receives mint vouchers here and
	// sends back burn them; it has no lock, so it gets an absolute day cap and
	// a cap on its outstanding supply.
	KindMint = "mint"
)

// DenomConfig is the configuration of one denom on one route. Amounts are base
// units of the denom.
type DenomConfig struct {
	Kind string
	// CapFloor is, for KindUnescrow, the floor of the day cap
	// max(CapFloor, lock/10); for KindMint, the day cap itself.
	CapFloor int64
	// SupplyCap (KindMint only) bounds the vouchers outstanding plus the open
	// mint claims; a receive beyond it is refused with an error ack.
	SupplyCap int64
	// Fee is charged on every send of the denom (KindUnescrow) and is the
	// first installment of every claim, paid to the route's fee collector.
	Fee int64
	// FeeFloor is the least the fee may be (ADR pr6375 §9: 2 GNOT).
	FeeFloor int64
	// SendMax and SendMin bound a send (KindUnescrow only; 0 for KindMint,
	// whose sends are voucher returns and are never limited).
	SendMax int64
	SendMin int64
	// RefundCap is the refund meter's day cap (ADR pr6375 §7.13).
	RefundCap int64
	// Remote (KindUnescrow only) is the lower-case Ethereum address of the
	// denom's token on Ethereum (its GnoVoucher): a send to it is refused,
	// since that contract could never move what it receives (§7.8). A minted
	// denom's token is its base, refused the same way.
	Remote string
}

// Validate checks a configuration on its own.
func (c DenomConfig) Validate() error {
	switch c.Kind {
	case KindUnescrow:
		if c.SendMin <= 0 || c.SendMax < c.SendMin {
			return ufmt.Errorf("controls: send limits must satisfy 0 < min (%d) <= max (%d)", c.SendMin, c.SendMax)
		}
		if c.SupplyCap != 0 {
			return errors.New("controls: an unescrowed denom has no supply cap")
		}
		a, err := ethaddr.Parse(c.Remote)
		if err != nil || a.IsZero() || a.Lower() != c.Remote {
			return ufmt.Errorf("controls: an unescrowed denom names its Ethereum token, a lower-case address, not %q", c.Remote)
		}
	case KindMint:
		if c.SupplyCap <= 0 {
			return errors.New("controls: a minted denom needs a positive supply cap")
		}
		if c.SendMax != 0 || c.SendMin != 0 {
			return errors.New("controls: a minted denom's sends are voucher returns and take no send limits")
		}
		if c.Remote != "" {
			return errors.New("controls: a minted denom's Ethereum token is its base")
		}
	default:
		return ufmt.Errorf("controls: unknown accounting %q", c.Kind)
	}
	if c.CapFloor <= 0 {
		return errors.New("controls: the day cap must be positive")
	}
	if c.FeeFloor <= 0 || c.Fee < c.FeeFloor {
		return ufmt.Errorf("controls: the fee (%d) must be at least the fee floor (%d), which is positive", c.Fee, c.FeeFloor)
	}
	// The fee ceiling is cap/4 and the cap is never below CapFloor; equally,
	// the cap floor is never below 4 fees.
	if c.Fee > c.CapFloor/4 {
		return ufmt.Errorf("controls: the fee (%d) is above its ceiling of a quarter of the day cap (%d)", c.Fee, c.CapFloor/4)
	}
	if c.RefundCap <= 0 {
		return errors.New("controls: the refund cap must be positive")
	}
	return nil
}

// Loosens reports whether moving from old to new loosens anything, so the
// change waits for the 7-day delay (ADR pr6375 §7.5, §9): a higher cap, supply
// cap, fee, send maximum or refund cap, a lower send minimum, or any change of
// the fee floor or of the Ethereum token. Everything else (lowering a cap, a fee, a maximum, raising a
// minimum) tightens and applies at once.
func Loosens(old, new DenomConfig) bool {
	return new.Kind != old.Kind ||
		new.CapFloor > old.CapFloor ||
		new.SupplyCap > old.SupplyCap ||
		new.Fee > old.Fee ||
		new.FeeFloor != old.FeeFloor ||
		new.SendMax > old.SendMax ||
		new.SendMin < old.SendMin ||
		new.RefundCap > old.RefundCap ||
		new.Remote != old.Remote
}
