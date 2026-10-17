package transfer

import (
	"gno.land/p/aib/ibc/app/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/core"
)

// App is the IBCApp value registered in the IBC core for PortID. It is this
// realm's forever (the core refuses a second registration for the port), so
// its callbacks forward to the active implementation.
type App struct{}

const (
	// NOTE we must use the same portID as the ibc-go transfer IBC app
	PortID = "transfer"
	// V1 defines first version of the IBC transfer module
	V1               = "ics20-1"
	EncodingProtobuf = "application/x-protobuf"
)

func init(cur realm) {
	// Register the app in the IBC router. On chain init runs once; the guard
	// is for the gno test harness, which instantiates this realm a second
	// time when it loads the implementation realm (whose import of this realm
	// resolves outside the package under test), and the core refuses a
	// second registration of the port.
	if core.AppPkgPath(PortID) == PkgPath {
		return
	}
	core.RegisterApp(cross(cur), PortID, &App{})
}

var _ app.IBCApp = &App{}

// corePkgPath is the only realm allowed to invoke the IBCApp callbacks below.
const corePkgPath = "gno.land/r/aib/ibc/core"

// assertCoreCaller panics unless the callback is being invoked by the IBC core
// realm. The App methods are exported, and any realm can obtain a usable *App
// (a zero-value `var app transfer.App` needs no composite literal), so without
// this check a foreign realm could call OnRecvPacket to mint vouchers, or the
// refund paths of OnTimeoutPacket and OnAcknowledgementPacket to release
// escrow, with no proof and no core involvement. Core crosses into the app, so
// cur.Previous() is the core realm on every legitimate call.
func assertCoreCaller(_ int, rlm realm) {
	if caller := rlm.Previous().PkgPath(); caller != corePkgPath {
		panic(ufmt.Sprintf("transfer: callback must be invoked by %s, got %s", corePkgPath, caller))
	}
}

// Implements app.IBCApp
func (a *App) OnSendPacket(
	cur realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	payload types.Payload,
) error {
	assertCoreCaller(0, cur)
	return mustImpl().OnSendPacket(0, cur, sourceClient, destinationClient, sequence, payload)
}

// Implements app.IBCApp
func (a *App) OnRecvPacket(
	cur realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	payload types.Payload,
) types.RecvPacketResult {
	assertCoreCaller(0, cur)
	return mustImpl().OnRecvPacket(0, cur, sourceClient, destinationClient, sequence, payload)
}

// Implements app.IBCApp
func (a *App) OnAcknowledgementPacket(
	cur realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	acknowledgement []byte,
	payload types.Payload,
) error {
	assertCoreCaller(0, cur)
	return mustImpl().OnAcknowledgementPacket(0, cur, sourceClient, destinationClient, sequence, acknowledgement, payload)
}

// Implements app.IBCApp
func (a *App) OnTimeoutPacket(
	cur realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	payload types.Payload,
) error {
	assertCoreCaller(0, cur)
	return mustImpl().OnTimeoutPacket(0, cur, sourceClient, destinationClient, sequence, payload)
}
