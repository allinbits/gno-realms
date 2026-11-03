package impl

import (
	"chain/runtime"
	"time"

	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/r/aib/ibc/apps/transfer"
)

// extKey is the proxy extension slot of the route controls.
const extKey = "controls"

type logic struct {
	transfer.Logic // base, for every client the controls do not cover
	store          transfer.Store
}

var (
	_ transfer.Logic         = (*logic)(nil)
	_ transfer.ControlsLogic = (*logic)(nil)
)

// New builds the implementation against the proxy's store.
func New(s transfer.Store) transfer.Logic {
	return &logic{Logic: &base{store: s}, store: s}
}

func init(cur realm) {
	transfer.RegisterImpl(cross(cur), New, version, nil, true) // installs over any
}

func (l *logic) Version() string { return version }

// OnInstall creates the route controls in the proxy, empty: every meter
// starts empty (ADR pr6375 §7.1). This is the implementation a fresh
// deployment starts with; it also re-installs over itself and over an
// implementation without the controls (the proxy never installs one of
// those once a route exists), keeping the controls state already there.
func (l *logic) OnInstall(_ int, rlm realm, prevPath, prevVersion string) {
	l.store.InitExt(0, rlm, extKey, controls.NewRegistryAny)
}

// registry is the controls state, mutable: only for the proxy's live rlm.
func (l *logic) registry(_ int, rlm realm) *controls.Registry {
	return l.store.Ext(0, rlm, extKey).(*controls.Registry)
}

// reader is the controls state, read only.
func (l *logic) reader() controls.Reader {
	rd, _ := l.store.ExtView(extKey).(controls.Reader)
	return rd
}

func now() int64 { return time.Now().Unix() }

func chainHeight() int64 { return runtime.ChainHeight() }
