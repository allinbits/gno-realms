package impl

import (
	"chain"
	"chain/runtime"
	"time"

	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	ics20impl "gno.land/r/aib/ibc/apps/transfer/impl/ics20/v0"
)

const version = "v0"

// extKey is the proxy extension slot of the route controls.
const extKey = "controls"

// logic is the installed implementation: inner, the plain ICS-20 app, serves
// every client the controls do not cover; the embedded routes serves every
// Ethereum client and the route controls' own entry points.
type logic struct {
	*routes
	inner transfer.Logic // seen through its interface only
}

// routes is the Ethereum route logic: every callback and Transfer of an
// Ethereum client (one of no enrolled route carries nothing), and the
// controls' entry points (transfer.ControlsLogic).
type routes struct {
	store transfer.Store
}

var (
	_ transfer.Logic         = (*logic)(nil)
	_ transfer.ControlsLogic = (*logic)(nil)
)

// New wraps inner, built against the same store s.
func New(inner transfer.Logic, s transfer.Store) transfer.Logic {
	return &logic{routes: &routes{store: s}, inner: inner}
}

func init(cur realm) {
	transfer.RegisterImpl(cross(cur), func(s transfer.Store) transfer.Logic {
		return New(ics20impl.New(s), s)
	}, version, nil, true) // installs over any
}

func (l *logic) Version() string { return version }

// OnInstall creates the route controls in the proxy, empty: every meter
// starts empty (ADR pr6375 §7.1). This is the implementation a fresh
// deployment starts with; it also re-installs over itself and over an
// implementation without the controls (the proxy never installs one of
// those once a route exists), keeping the controls state already there.
func (l *logic) OnInstall(_ int, rlm realm, prevPath, prevVersion string) {
	l.inner.OnInstall(0, rlm, prevPath, prevVersion)
	l.store.InitExt(0, rlm, extKey, controls.NewRegistryAny)
}

// handler is the logic that serves client: the routes for an Ethereum
// client, the plain app for every other.
func (l *logic) handler(client string) transfer.Logic {
	if isEthereum(client) {
		return l.routes
	}
	return l.inner
}

func (l *logic) Transfer(_ int, rlm realm, sent []chain.Coin, clientID, receiver, denom string, amount uint256, timeoutTimestamp uint64, memo string) (
	packet types.MsgSendPacket, sequence uint64,
) {
	return l.handler(clientID).Transfer(0, rlm, sent, clientID, receiver, denom, amount, timeoutTimestamp, memo)
}

func (l *logic) OnSendPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) error {
	return l.handler(sourceClient).OnSendPacket(0, rlm, sourceClient, destinationClient, sequence, payload)
}

func (l *logic) OnRecvPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) types.RecvPacketResult {
	return l.handler(destinationClient).OnRecvPacket(0, rlm, sourceClient, destinationClient, sequence, payload)
}

func (l *logic) OnTimeoutPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) error {
	return l.handler(sourceClient).OnTimeoutPacket(0, rlm, sourceClient, destinationClient, sequence, payload)
}

func (l *logic) OnAcknowledgementPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, acknowledgement []byte, payload types.Payload) error {
	return l.handler(sourceClient).OnAcknowledgementPacket(0, rlm, sourceClient, destinationClient, sequence, acknowledgement, payload)
}

// Version and OnInstall make routes a transfer.Logic, which handler returns;
// the proxy only ever sees logic's.
func (l *routes) Version() string { return version }

func (l *routes) OnInstall(_ int, rlm realm, prevPath, prevVersion string) {}

// registry is the controls state, mutable: only for the proxy's live rlm.
func (l *routes) registry(_ int, rlm realm) *controls.Registry {
	return l.store.Ext(0, rlm, extKey).(*controls.Registry)
}

// reader is the controls state, read only.
func (l *routes) reader() controls.Reader {
	rd, _ := l.store.ExtView(extKey).(controls.Reader)
	return rd
}

func now() int64 { return time.Now().Unix() }

func chainHeight() int64 { return runtime.ChainHeight() }
