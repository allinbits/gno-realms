package core

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
)

// The registry operations through the entry points (registration, approval,
// replacement, unregistration and their gates) are covered by the z4* and z15*
// filetests. The tests below cover the refusal to strand an asynchronous
// acknowledgement, whose setup needs direct access to the store.

const (
	appTestPort      = "appID"
	appTestCurrent   = "gno.land/r/aib/apps/current"
	appTestSuccessor = "gno.land/r/third/party/successor"
)

// setupAppOwingAsyncAck installs appTestCurrent on appTestPort with a pending
// asynchronous acknowledgement, a pending registration of appTestSuccessor for
// the same port, and this realm as the only authority member.
func setupAppOwingAsyncAck(cur realm) *client {
	resetUpgradeState()
	c := newAsyncAckTestClient()
	store.routes[appTestPort] = App{PkgPath: appTestCurrent}
	store.pendingApps.Set(pendingKey(appTestPort, appTestSuccessor), App{PkgPath: appTestSuccessor})
	c.SavePendingAsyncAck(0, cur, newAsyncAckTestPacket(c.id, 3), appTestCurrent)
	AddAuthorityMember(cross(cur), cur.Address())
	return c
}

func TestReplaceAppRefusesWhileAsyncAckPending(cur realm, t *testing.T) {
	c := setupAppOwingAsyncAck(cur)
	defer resetUpgradeState()

	uassert.AbortsContains(t, cur, appTestCurrent+" owes an asynchronous acknowledgement on client "+c.id+" for sequence 3", func() {
		ReplaceApp(cross(cur), appTestPort, appTestSuccessor)
	})
	uassert.Equal(t, appTestCurrent, AppPkgPath(appTestPort))

	// Once the acknowledgement is written, the replacement goes through.
	c.DeletePendingAsyncAck(0, cur, 3)
	ReplaceApp(cross(cur), appTestPort, appTestSuccessor)
	uassert.Equal(t, appTestSuccessor, AppPkgPath(appTestPort))
}

func TestUnregisterAppRefusesWhileAsyncAckPending(cur realm, t *testing.T) {
	c := setupAppOwingAsyncAck(cur)
	defer resetUpgradeState()

	uassert.AbortsContains(t, cur, appTestCurrent+" owes an asynchronous acknowledgement on client "+c.id+" for sequence 3", func() {
		UnregisterApp(cross(cur), appTestPort)
	})
	uassert.Equal(t, appTestCurrent, AppPkgPath(appTestPort))

	c.DeletePendingAsyncAck(0, cur, 3)
	UnregisterApp(cross(cur), appTestPort)
	uassert.Equal(t, "", AppPkgPath(appTestPort))
}

// An acknowledgement owed by another realm does not block the port.
func TestReplaceAppIgnoresOtherAppsAsyncAcks(cur realm, t *testing.T) {
	c := setupAppOwingAsyncAck(cur)
	defer resetUpgradeState()

	c.DeletePendingAsyncAck(0, cur, 3)
	c.SavePendingAsyncAck(0, cur, newAsyncAckTestPacket(c.id, 4), "gno.land/r/aib/apps/other")
	ReplaceApp(cross(cur), appTestPort, appTestSuccessor)
	uassert.Equal(t, appTestSuccessor, AppPkgPath(appTestPort))
}
