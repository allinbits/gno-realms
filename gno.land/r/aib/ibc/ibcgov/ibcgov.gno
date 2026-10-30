// Package ibcgov is the governance realm of the IBC realms for the Ethereum
// route (ADR pr6375 R9, R10, R11, R14, §5.4, §7.4–§7.7, §7.12):
//
//   - the decision ledger (gno.land/p/aib/decisions/v0): every change is a
//     decision built by one of the New…Request builders, which take no free
//     text (the parameters are the record), recorded with a number and either
//     applied at once (tightening, removals, cancels, unpauses) or queued for
//     7 days (every loosening change), then applied by anyone with Execute;
//   - the governor: a compiled key decides through the same builders, checks
//     and delays (Govern) until it calls Yield once, after which only GovDAO's
//     proposals decide;
//   - the sole holder of the loosening powers over the IBC core and the
//     transfer app (core.IBCGovPath, transfer.IBCGovPath).
//
// Builders are called in a MsgRun: before the yield the governor runs
//
//	ibcgov.Govern(cross(cur), ibcgov.NewCoreUpdateImplRequest(cross(cur), path))
//
// and after it a GovDAO member proposes
//
//	dao.MustCreateProposal(cross(cur), ibcgov.NewCoreUpdateImplRequest(cross(cur), path).Proposal())
//
// The decision ledger of gnolang/bridges (solana/realm/p/decisions/v0) and
// the governor, flag and dispatch patterns of its ethereum/realm/hlmailbox and
// ethereum/realm/hlgov realms (Copyright (C) 2026 NewTendermint, LLC, GNO
// Network General Public License) are the model for this realm.
package ibcgov

import (
	"chain/runtime"
	"strconv"
	"strings"
	"time"

	"gno.land/p/aib/decisions/v0"
)

const (
	// PkgPath is this realm's path, which the IBC core and the transfer app
	// gate their loosening powers on.
	PkgPath      = "gno.land/r/aib/ibc/ibcgov"
	CorePath     = "gno.land/r/aib/ibc/core"
	TransferPath = "gno.land/r/aib/ibc/apps/transfer"

	// LaunchGovernor is the governor key (ADR pr6375 §7.7). PLACEHOLDER: a
	// test address (testutils.TestAddress("ibcgov-governor")); the deployed
	// source carries the real key, which members read before the launch. ""
	// would mean GovDAO decides from the first block.
	LaunchGovernor = address("g1d93xxem0wckkwmmkv4exummjta047h6lhqp9y5")

	titlePrefix = "gno.land/r/aib/ibc/ibcgov: "
)

var (
	// yielded is the block height of the governor's yield, 0 before.
	yielded int64
	// ledger numbers every decision.
	ledger decisions.Ledger
)

func now() int64 { return time.Now().Unix() }

func chainHeight() int64 {
	h := runtime.ChainHeight()
	if h < 1 {
		h = 1
	}
	return h
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func u64s(n uint64) string { return strconv.FormatUint(n, 10) }

// who names a previous realm in a refusal: its pkgpath, or a user's address.
func who(_ int, r realm) string {
	if p := r.PkgPath(); p != "" {
		return p
	}
	return string(r.Address())
}

// isIdent reports whether s is a short identifier: 1 to max characters of
// a-z, 0-9 and '-' (incidents, causes: builders take no free text).
func isIdent(s string, max int) bool {
	if len(s) == 0 || len(s) > max {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return true
}

// isDenom reports whether s may name a denom: 1 to 128 characters of letters,
// digits and "/:._-".
func isDenom(s string) bool {
	if len(s) == 0 || len(s) > 128 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.IndexByte("/:._-", c) >= 0) {
			return false
		}
	}
	return true
}

// splitList splits a comma-separated argument, trimming spaces and dropping
// empty items.
func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}
