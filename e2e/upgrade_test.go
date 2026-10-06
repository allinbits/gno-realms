package e2e

import (
	"fmt"
	"strings"
)

// TestGovDAOUpdateImpl exercises the governance path of UpdateImpl against the
// real r/gov/dao of the gno chain: the test key is seeded as a GovDAO member
// (possible on dev chains only), proposes through each proxy's request
// constructor the re-installation of its impl/v0, votes, and executes. The
// callback then runs with the DAO proxy as caller, which the realms'
// authority accepts. Re-installing v0 keeps the chain usable by the other
// tests; a switch to another implementation is the upgrade rehearsal's job.
func (s *E2ETestSuite) TestGovDAOUpdateImpl() {
	// Seed the DAO once per chain: InitWithUsers locks AllowedDAOs afterwards,
	// so a second run against the same chain must skip it.
	allowed, err := gnoEval(s.gnoContainer, "r/gov/dao", "AllowedDAOs()")
	s.Require().NoError(err, "query AllowedDAOs")
	if !strings.Contains(allowed, "gno.land/r/gov/dao/impl/v0") {
		s.signAndBroadcastGnoRun("test", fmt.Sprintf(`package main

import daoinit "gno.land/r/gov/dao/init/v0"

func main(cur realm) {
	daoinit.InitWithUsers(cross(cur), address(%q))
}
`, s.gnoSenderAddress))
	}

	for _, tc := range []struct {
		name, realm, impl string
	}{
		{"core", "gno.land/r/aib/ibc/core", "gno.land/r/aib/ibc/core/impl/v0"},
		{"transfer", "gno.land/r/aib/ibc/apps/transfer", "gno.land/r/aib/ibc/apps/transfer/impl/v0"},
	} {
		s.Run(tc.name, func() {
			rel := strings.TrimPrefix(tc.realm, "gno.land/")
			before, err := gnoEval(s.gnoContainer, rel, "ImplPath()")
			s.Require().NoError(err, "query ImplPath")
			s.Require().Contains(before, tc.impl, "impl/v0 must be active before the proposal")

			// One MsgRun: propose with the proxy's constructor, vote YES (a
			// single T1 member reaches the supermajority) and execute. The
			// proxy panics if the implementation is not registered, which
			// would abort the transaction and fail the test.
			s.signAndBroadcastGnoRun("test", fmt.Sprintf(`package main

import (
	proxy %q
	"gno.land/r/gov/dao"
)

func main(cur realm) {
	pid := dao.MustCreateProposal(cross(cur), proxy.NewUpdateImplProposalRequest(cross(cur), %q))
	dao.MustVoteOnProposal(cross(cur), dao.NewVoteRequest(dao.YesVote, pid))
	if !dao.ExecuteProposal(cross(cur), pid) {
		panic("proposal not executed")
	}
}
`, tc.realm, tc.impl))

			after, err := gnoEval(s.gnoContainer, rel, "ImplPath()")
			s.Require().NoError(err, "query ImplPath")
			s.Require().Equal(before, after, "impl/v0 re-installed through GovDAO")
		})
	}
}
