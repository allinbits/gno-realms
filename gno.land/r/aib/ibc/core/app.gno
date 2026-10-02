package core

import (
	"gno.land/p/aib/ibc/app"
	"gno.land/p/aib/ibc/host"
	"gno.land/p/nt/ufmt/v0"
)

// reservedPorts maps a port to the only realm allowed to register it.
//
// The transfer port is reserved for the transfer realm: on a chain that enables
// packages one at a time (mainnet's inert code-submission policy), core goes
// live before transfer, and without this any realm could register the port in
// between. Ports are never freed, so a squatted port would be lost for good.
var reservedPorts = map[string]string{
	"transfer": "gno.land/r/aib/ibc/apps/transfer",
}

// RegisterApp registers an IBCApp, the portID is determined using the package
// path of the caller, hence it must an other realm.
func RegisterApp(cur realm, portID string, app app.IBCApp) {
	caller := cur.Previous()
	if caller.IsUser() {
		panic("RegisterApp can only be called from an other realm")
	}
	if err := host.PortIdentifierValidator(portID); err != nil {
		panic(ufmt.Errorf("invalid portID: %v", err))
	}
	if want, ok := reservedPorts[portID]; ok && caller.PkgPath() != want {
		panic(ufmt.Errorf("portID %s is reserved for %s", portID, want))
	}
	if _, ok := store.routes[portID]; ok {
		panic(ufmt.Errorf("portID %s has already been registered", portID))
	}
	store.routes[portID] = ibcApp{
		IBCApp:  app,
		pkgPath: caller.PkgPath(),
		address: caller.Address(),
	}
}
