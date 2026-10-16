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

// decisionDelay is the 7-day delay of a loosening ibcgov decision on the e2e
// devnet: its build divides the realms' delays by 60480 (e2e/gno/Dockerfile),
// so a decision is due 10 seconds after it is recorded.
const decisionDelay = 10 * time.Second

// TestGovernorUpdateImpl exercises the governance path of UpdateImpl (ADR
// pr6375 R14, §6.12): the proxies take an implementation switch only from
// gno.land/r/aib/ibc/ibcgov, where the launch governor (on the e2e devnet the
// test key, e2e/gno/Dockerfile) records the decision and anyone executes it
// once its delay has passed. Executing it before is refused and leaves it
// pending. Re-installing v0 keeps the chain usable by the other tests; the
// switch to another implementation is TestUpgradeRehearsal.
func (s *E2ETestSuite) TestGovernorUpdateImpl() {
	for _, tc := range upgradeTargets {
		s.Run(tc.name, func() {
			s.Require().Equal(tc.v0, s.implPath(tc), "impl/v0 must be active before the decision")
			s.governDecision(tc.updateRequest(tc.v0))
			err := s.gnoRun("test", executeLastDecision)
			s.Require().Error(err, "a decision executes only once its delay has passed")
			s.Require().Contains(err.Error(), "is due at")
			time.Sleep(decisionDelay + 2*time.Second)
			s.Require().NoError(s.gnoRun("test", executeLastDecision))
			s.Require().Equal(tc.v0, s.implPath(tc), "impl/v0 re-installed through ibcgov")
		})
	}
}

// TestUpgradeRehearsal is the upgrade runbook end to end on a running chain
// without Ethereum routes (on a chain whose transfer app keeps route
// controls, a switch to an implementation without them, such as this
// rehearsal's v99, is refused: the controls are never rolled back):
// deploy the v99 candidates with addpkg (their init registers them), switch
// both realms to them through ibcgov decisions, relay a transfer in each
// direction through the new implementations, roll back to v0, and relay
// again. The relayer is never told anything: paths, events and routes are the
// proxies'. The guardians' holds, which defer every queued decision, need an
// Ethereum route to flag and are covered by ibcgov's filetests instead
// (z1b_guardians_holds): this devnet pairs gno.land with AtomOne only.
func (s *E2ETestSuite) TestUpgradeRehearsal() {
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
		s.governAndExecute(tc.updateRequest(tc.v99))
		s.Require().Equal(tc.v99, s.implPath(tc))
		s.Require().Equal("v99", s.implVersion(tc))
	}
	s.Run("transfers through v99", func() {
		s.TestIBCTransferAtomOneToGno()
		s.TestIBCTransferGnoToAtomOne()
	})

	for _, tc := range upgradeTargets {
		s.governAndExecute(tc.updateRequest(tc.v0))
		s.Require().Equal(tc.v0, s.implPath(tc))
		s.Require().Equal("v0", s.implVersion(tc))
	}
	s.Run("transfers after rollback", func() {
		s.TestIBCTransferAtomOneToGno()
		s.TestIBCTransferGnoToAtomOne()
	})
}

// updateRequest is the ibcgov builder call that switches tc's realm to impl.
func (t upgradeTarget) updateRequest(impl string) string {
	builder := "NewCoreUpdateImplRequest"
	if t.name == "transfer" {
		builder = "NewTransferUpdateImplRequest"
	}
	return fmt.Sprintf("ibcgov.%s(cross(cur), %q)", builder, impl)
}

// executeLastDecision applies ibcgov's newest decision; anyone may.
const executeLastDecision = `package main

import "gno.land/r/aib/ibc/ibcgov"

func main(cur realm) {
	ibcgov.Execute(cross(cur), ibcgov.LastDecision())
}
`

// governDecision records a decision as the governor (the test key on this
// devnet) in a MsgRun: request is a builder call of gno.land/r/aib/ibc/ibcgov.
func (s *E2ETestSuite) governDecision(request string) {
	s.signAndBroadcastGnoRun("test", fmt.Sprintf(`package main

import "gno.land/r/aib/ibc/ibcgov"

func main(cur realm) {
	ibcgov.Govern(cross(cur), %s)
}
`, request))
}

// governAndExecute records a decision as the governor, waits for its delay
// and executes it.
func (s *E2ETestSuite) governAndExecute(request string) {
	s.governDecision(request)
	time.Sleep(decisionDelay + 2*time.Second)
	s.Require().NoError(s.gnoRun("test", executeLastDecision))
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
