// PKGPATH: gno.land/r/aib/main
package main

import (
	"chain"
	"testing"

	"gno.land/r/aib/ibc/apps/transfer"
	ics20impl "gno.land/r/aib/ibc/apps/transfer/impl/ics20/v0"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/controls/v0"
	_ "gno.land/r/aib/ibc/core/impl/v0"
	"gno.land/r/aib/ibc/ibcgov"
)

const (
	wrapper = "gno.land/r/aib/ibc/apps/transfer/impl/v98"
	ics20v0 = "gno.land/r/aib/ibc/apps/transfer/impl/ics20/v0"
	ics20v1 = "gno.land/r/aib/ibc/apps/transfer/impl/ics20/v1" // a later plain app
)

type v98 struct{ transfer.Logic }

func (v98) Version() string { return "v98" }

func newV98(s transfer.Store) transfer.Logic { return v98{Logic: ics20impl.New(s)} }

// The library realms an implementation wraps register nothing, yet value can
// land at their addresses: the wrapper declares them (RegisterImpl's wraps)
// and they become realms of the bridge, whose credits are swept, never paid,
// without any list in ibcgov naming a version. They stay uninstallable, and
// a wrapped realm outside the implementations' namespace is refused.
func main(cur realm) {
	println("ics20/v0 (wrapped by impl/controls/v0):", ibcgov.BridgeRealm(chain.PackageAddress(ics20v0)))
	println("ics20/v1 before:", ibcgov.BridgeRealm(chain.PackageAddress(ics20v1)) != "")

	testing.SetRealm(testing.NewCodeRealm(wrapper))
	println("wrapping a realm outside impl/:", revive(func() {
		transfer.RegisterImpl(cross(cur), newV98, "v98", nil, true, "gno.land/r/aib/ibc/ethrelay")
	}))
	transfer.RegisterImpl(cross(cur), newV98, "v98", nil, true, ics20v1)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))

	println("ics20/v1 after:", ibcgov.BridgeRealm(chain.PackageAddress(ics20v1)))
	println("ics20/v1 installable:", transfer.IsRegisteredImpl(ics20v1), "| wrapper:", transfer.IsRegisteredImpl(wrapper))
}

// Output:
// ics20/v0 (wrapped by impl/controls/v0): a registered implementation
// ics20/v1 before: false
// wrapping a realm outside impl/: RegisterImpl: wrapped gno.land/r/aib/ibc/ethrelay is not under gno.land/r/aib/ibc/apps/transfer/impl/
// ics20/v1 after: a registered implementation
// ics20/v1 installable: false | wrapper: true
