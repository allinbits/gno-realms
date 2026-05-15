package main

import (
	"gno.land/r/aib/ibc/core"
)

func main() {
	// Bootstrap so the test caller is the admin (RecoverClient is
	// admin-gated; in production this is the deployer or, eventually,
	// govDAO).
	core.SetAdmin(cross, "g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")

	// RecoverClient revives a Frozen or Expired subject client by copying
	// state from a healthy substitute that tracks the same counterparty.
	// Admin-gated. See recover-client.md for the full flow.
	//
	// Preconditions (panic otherwise):
	//   - caller is the admin
	//   - subject and substitute IDs differ
	//   - both clients exist and have the same `typ` (e.g. 07-tendermint)
	//   - subject.Status() ∈ {Frozen, Expired}
	//   - substitute.Status() == Active
	//   - their ClientStates match on TrustLevel, UnbondingPeriod,
	//     MaxClockDrift, ProofSpecs, UpgradePath
	//
	// On success, ChainID / LatestHeight / TrustingPeriod from the
	// substitute are copied into the subject, FrozenHeight is reset, and
	// the substitute's consensus state at its LatestHeight is stored in
	// the subject. Packet commitments, receipts, acks, sequence counters
	// and counterparty registration on the subject are untouched.
	subjectClientID := "07-tendermint-1"    // XXX update — Frozen/Expired client to revive
	substituteClientID := "07-tendermint-2" // XXX update — healthy client tracking the same chain

	core.RecoverClient(cross, subjectClientID, substituteClientID)
}

// Error:
// subject client 07-tendermint-1 not found
