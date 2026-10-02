package authority

import (
	"chain"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
	dao   = chain.PackageAddress(GovDAOPath)
)

// Crossing helpers: the gate reads cur.Previous(), which is what
// testing.SetRealm controls for the next cross from the test.
func assertOp(cur realm, a *Authority)                   { a.Assert(0, cur, "op") }
func addMember(cur realm, a *Authority, addr address)    { a.AddMember(0, cur, addr) }
func removeMember(cur realm, a *Authority, addr address) { a.RemoveMember(0, cur, addr) }

func TestNewWithDeployer(cur realm, t *testing.T) {
	a := New(alice)
	uassert.True(t, a.IsMember(alice))
	uassert.True(t, a.IsMember(dao))
	uassert.Equal(t, 2, len(a.Members()))
}

func TestMemberAndGovDAOPass(cur realm, t *testing.T) {
	a := New(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	assertOp(cross(cur), a)
	testing.SetRealm(testing.NewCodeRealm(GovDAOPath))
	assertOp(cross(cur), a)
}

func TestNonMemberRejected(cur realm, t *testing.T) {
	a := New(alice)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "op: caller "+bob.String()+" is not a member of the authority", func() {
		assertOp(cross(cur), a)
	})
}

func TestBootstrapWhenDeployerUnknown(cur realm, t *testing.T) {
	a := New("")
	uassert.Equal(t, 1, len(a.Members()))
	testing.SetRealm(testing.NewUserRealm(bob))
	addMember(cross(cur), a, alice) // ungated once: completes the bootstrap
	uassert.True(t, a.IsMember(alice))
	uassert.AbortsContains(t, cur, "is not a member of the authority", func() {
		addMember(cross(cur), a, bob) // now gated, and bob is not a member
	})
}

func TestRemoveMember(cur realm, t *testing.T) {
	a := New(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	removeMember(cross(cur), a, dao)
	uassert.False(t, a.IsMember(dao))
	uassert.AbortsContains(t, cur, "cannot remove the last member", func() {
		removeMember(cross(cur), a, alice)
	})
	uassert.AbortsContains(t, cur, "is not a member", func() {
		removeMember(cross(cur), a, bob)
	})
}
