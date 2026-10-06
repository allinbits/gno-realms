package e2e

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// upgradeTarget is one of the two upgradeable realms and its implementations.
type upgradeTarget struct {
	name, realm, v0, v99 string
}

var upgradeTargets = []upgradeTarget{
	{"core", "gno.land/r/aib/ibc/core", "gno.land/r/aib/ibc/core/impl/v0", "gno.land/r/aib/ibc/core/impl/v99"},
	{"transfer", "gno.land/r/aib/ibc/apps/transfer", "gno.land/r/aib/ibc/apps/transfer/impl/v0", "gno.land/r/aib/ibc/apps/transfer/impl/v99"},
}

func (t upgradeTarget) rel() string { return strings.TrimPrefix(t.realm, "gno.land/") }

// TestGovDAOUpdateImpl exercises the governance path of UpdateImpl against the
// real r/gov/dao of the gno chain: the test key is seeded as a GovDAO member
// (possible on dev chains only), proposes through each proxy's request
// constructor the re-installation of its impl/v0, votes, and executes. The
// callback then runs with the DAO proxy as caller, which the realms'
// authority accepts. Re-installing v0 keeps the chain usable by the other
// tests; the switch to another implementation is TestUpgradeRehearsal.
func (s *E2ETestSuite) TestGovDAOUpdateImpl() {
	s.ensureGovDAOMember()
	for _, tc := range upgradeTargets {
		s.Run(tc.name, func() {
			s.Require().Equal(tc.v0, s.implPath(tc), "impl/v0 must be active before the proposal")
			s.govDAOUpdateImpl(tc, tc.v0)
			s.Require().Equal(tc.v0, s.implPath(tc), "impl/v0 re-installed through GovDAO")
		})
	}
}

// TestUpgradeRehearsal is the upgrade runbook end to end on a running chain:
// deploy the v99 candidates with addpkg (their init registers them), switch
// both realms to them through GovDAO, relay a transfer in each direction
// through the new implementations, roll back to v0, and relay again. The
// relayer is never told anything: paths, events and routes are the proxies'.
func (s *E2ETestSuite) TestUpgradeRehearsal() {
	s.ensureGovDAOMember()

	for _, tc := range upgradeTargets {
		// The candidates live outside the gno workspace of the container, so
		// this addpkg is a real deployment onto the running chain.
		dir := "/tmp/rehearsal/" + tc.name + "-v99"
		s.Require().NoError(dockerCp("gno/rehearsal/"+tc.name+"-v99", s.gnoContainer+":"+dir), "copy %s candidate into the gno container", tc.name)
		s.signAndBroadcastGnoAddPkg("test", tc.v99, dir)
		registered, err := gnoEval(s.gnoContainer, tc.rel(), "RegisteredImplPaths()")
		s.Require().NoError(err, "query RegisteredImplPaths")
		s.Require().Contains(registered, tc.v99, "the candidate registers itself at deploy")
		s.Require().Equal(tc.v0, s.implPath(tc), "registration alone activates nothing")
	}

	for _, tc := range upgradeTargets {
		s.govDAOUpdateImpl(tc, tc.v99)
		s.Require().Equal(tc.v99, s.implPath(tc))
		s.Require().Equal("v99", s.implVersion(tc))
	}
	s.Run("transfers through v99", func() {
		s.TestIBCTransferAtomOneToGno()
		s.TestIBCTransferGnoToAtomOne()
	})

	for _, tc := range upgradeTargets {
		s.govDAOUpdateImpl(tc, tc.v0)
		s.Require().Equal(tc.v0, s.implPath(tc))
		s.Require().Equal("v0", s.implVersion(tc))
	}
	s.Run("transfers after rollback", func() {
		s.TestIBCTransferAtomOneToGno()
		s.TestIBCTransferGnoToAtomOne()
	})
}

// ensureGovDAOMember seeds the DAO with the test key as T1 member, once per
// chain: InitWithUsers locks AllowedDAOs afterwards.
func (s *E2ETestSuite) ensureGovDAOMember() {
	allowed, err := gnoEval(s.gnoContainer, "r/gov/dao", "AllowedDAOs()")
	s.Require().NoError(err, "query AllowedDAOs")
	if strings.Contains(allowed, "gno.land/r/gov/dao/impl/v0") {
		return
	}
	s.signAndBroadcastGnoRun("test", fmt.Sprintf(`package main

import daoinit "gno.land/r/gov/dao/init/v0"

func main(cur realm) {
	daoinit.InitWithUsers(cross(cur), address(%q))
}
`, s.gnoSenderAddress))
}

// govDAOUpdateImpl proposes, votes and executes in one MsgRun the activation
// of impl on tc's realm. A single T1 member reaches the supermajority. The
// proxy panics if impl is not registered, which aborts the transaction.
func (s *E2ETestSuite) govDAOUpdateImpl(tc upgradeTarget, impl string) {
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
`, tc.realm, impl))
}

func (s *E2ETestSuite) implPath(tc upgradeTarget) string {
	out, err := gnoEval(s.gnoContainer, tc.rel(), "ImplPath()")
	s.Require().NoError(err, "query ImplPath")
	return evalString(out)
}

func (s *E2ETestSuite) implVersion(tc upgradeTarget) string {
	out, err := gnoEval(s.gnoContainer, tc.rel(), "ImplVersion()")
	s.Require().NoError(err, "query ImplVersion")
	return evalString(out)
}

// evalString extracts the value of a qeval string result: ("..." string).
func evalString(out string) string {
	out = strings.TrimSpace(out)
	out = strings.TrimPrefix(out, "(")
	out = strings.TrimSuffix(out, " string)")
	return strings.Trim(out, `"`)
}

// signAndBroadcastGnoAddPkg deploys the package at pkgDir (a path inside the
// gno container) under pkgPath with gnokey maketx addpkg. The filetests/
// subdirectory is uploaded too, like deploy.sh does.
func (s *E2ETestSuite) signAndBroadcastGnoAddPkg(keyName, pkgPath, pkgDir string) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	stdout, stderr, err := dockerExecStdin(ctx, s.gnoContainer, "\n",
		"gnokey", "maketx", "addpkg",
		"-pkgpath", pkgPath,
		"-pkgdir", pkgDir,
		"-gas-fee", "1000000ugnot",
		"-gas-wanted", "200000000",
		"-max-deposit", "100000000ugnot",
		"-broadcast",
		"-chainid", s.cfg.GnoChainID,
		"-remote", "localhost:26657",
		"-insecure-password-stdin",
		keyName,
	)
	s.Require().NoError(err, "gnokey maketx addpkg %s: stdout=%s stderr=%s", pkgPath, stdout, stderr)
}
