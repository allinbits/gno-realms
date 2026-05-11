package testing

import (
	"gno.land/p/aib/ibc/app"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/core"
)

type (
	App struct {
		id    string
		Calls struct {
			OnSendPacket                  []Args
			OnSendPacketReturn            error
			OnRecvPacket                  []Args
			OnRecvPacketReturn            types.RecvPacketResult
			OnTimeoutPacket               []Args
			OnTimeoutPacketReturn         error
			OnAcknowledgementPacket       []Args
			OnAcknowledgementPacketReturn error
		}
		// pendingAsyncParent records the (clientID, sequence) captured by
		// OnRecvPacket when it returned PacketStatus_Async, so a later
		// OnAcknowledgementPacket can write the deferred ack.
		pendingAsyncParent *asyncParent
	}
	Args struct {
		SourceClient      string
		DestinationClient string
		Sequence          uint64
		Payload           types.Payload
		Ack               []byte
	}
	asyncParent struct {
		ClientID string
		Sequence uint64
	}
)

// asyncDeferredAck is the placeholder ack that the mock writes via
// core.WriteAcknowledgement when an OnAcknowledgementPacket fires while a
// parent packet is async-pending. The byte value is arbitrary - IBC core
// only stores the commitment hash and apps own the wire format.
var asyncDeferredAck = types.Acknowledgement{
	AppAcknowledgements: [][]byte{{0x02}},
}

var (
	_    app.IBCApp = &App{}
	apps []*App
)

func NewApp(_ realm) *App {
	app := &App{}
	// store the app in the realm is required to prevent the following panic:
	// "cannot directly modify readonly tainted object (w/o method)"
	// Other than that it is not used.
	apps = append(apps, app)
	return app
}

// RegisterApp registers the mock App with core from inside this realm so the
// stored ibcApp.pkgPath is "gno.land/r/aib/ibc/apps/testing". This is what
// later lets OnAcknowledgementPacket's call to core.WriteAcknowledgement pass
// the pkgPath authorization gate for the async-pending parent packet.
func (a *App) RegisterApp(_ realm, portID string) {
	core.RegisterApp(cross, portID, a)
}

// Implements app.IBCApp
func (a *App) OnSendPacket(
	_ realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	payload types.Payload,
) error {
	a.Calls.OnSendPacket = append(a.Calls.OnSendPacket,
		Args{
			SourceClient:      sourceClient,
			DestinationClient: destinationClient,
			Sequence:          sequence,
			Payload:           payload,
		})
	return a.Calls.OnSendPacketReturn
}

func (a *App) SetOnSendPacketReturn(err error) {
	a.Calls.OnSendPacketReturn = err
}

// Implements app.IBCApp
func (a *App) OnRecvPacket(
	_ realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	payload types.Payload,
) types.RecvPacketResult {
	a.Calls.OnRecvPacket = append(a.Calls.OnRecvPacket,
		Args{
			SourceClient:      sourceClient,
			DestinationClient: destinationClient,
			Sequence:          sequence,
			Payload:           payload,
		})
	// NOTE return a copy of the result to avoid annoying gno errors like
	// "illegal conversion of readonly or externally stored value"
	res := types.RecvPacketResult{
		Status:          a.Calls.OnRecvPacketReturn.Status,
		Acknowledgement: make([]byte, len(a.Calls.OnRecvPacketReturn.Acknowledgement)),
	}
	copy(res.Acknowledgement, a.Calls.OnRecvPacketReturn.Acknowledgement)
	if res.Status == types.PacketStatus_Async {
		a.pendingAsyncParent = &asyncParent{
			ClientID: destinationClient,
			Sequence: sequence,
		}
	}
	return res
}

func (a *App) SetOnRecvPacketReturn(res types.RecvPacketResult) {
	a.Calls.OnRecvPacketReturn = res
}

// Implements app.IBCApp
func (a *App) OnTimeoutPacket(
	_ realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	payload types.Payload,
) error {
	a.Calls.OnTimeoutPacket = append(a.Calls.OnTimeoutPacket,
		Args{
			SourceClient:      sourceClient,
			DestinationClient: destinationClient,
			Sequence:          sequence,
			Payload:           payload,
		})
	return a.Calls.OnTimeoutPacketReturn
}

// Implements app.IBCApp
func (a *App) OnAcknowledgementPacket(
	_ realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	acknowledgement []byte,
	payload types.Payload,
) error {
	a.Calls.OnAcknowledgementPacket = append(a.Calls.OnAcknowledgementPacket,
		Args{
			SourceClient:      sourceClient,
			DestinationClient: destinationClient,
			Sequence:          sequence,
			Payload:           payload,
			Ack:               acknowledgement,
		})
	// If a prior OnRecvPacket returned PacketStatus_Async, write the deferred
	// ack for that parent packet now. This is the canonical PFM/ZKGM flow:
	// the child's ack callback writes the parent's ack via
	// core.WriteAcknowledgement.
	if a.pendingAsyncParent != nil {
		parent := a.pendingAsyncParent
		a.pendingAsyncParent = nil
		core.WriteAcknowledgement(cross, parent.ClientID, parent.Sequence, asyncDeferredAck)
	}
	return a.Calls.OnAcknowledgementPacketReturn
}

func (a *App) Report() string {
	var s string
	s += ufmt.Sprintf("OnSendPacket (%d)\n", len(a.Calls.OnSendPacket))
	for _, args := range a.Calls.OnSendPacket {
		s += args.Report() + "\n"
	}
	s += ufmt.Sprintf("OnRecvPacket (%d)\n", len(a.Calls.OnRecvPacket))
	for _, args := range a.Calls.OnRecvPacket {
		s += args.Report() + "\n"
	}
	s += ufmt.Sprintf("OnTimeoutPacket (%d)\n", len(a.Calls.OnTimeoutPacket))
	for _, args := range a.Calls.OnTimeoutPacket {
		s += args.Report() + "\n"
	}
	s += ufmt.Sprintf("OnAcknowledgementPacket (%d)\n", len(a.Calls.OnAcknowledgementPacket))
	for _, args := range a.Calls.OnAcknowledgementPacket {
		s += args.Report() + "\n"
	}
	return s
}

func (a *Args) Report() string {
	var s string
	s += ufmt.Sprintf("- sourceClient: %s\n", a.SourceClient)
	s += ufmt.Sprintf("- destinationClient: %s\n", a.DestinationClient)
	s += ufmt.Sprintf("- sequence: %d\n", a.Sequence)
	s += "- payload:\n"
	s += ufmt.Sprintf("  - sourcePort: %s\n", a.Payload.SourcePort)
	s += ufmt.Sprintf("  - destinationPort: %s\n", a.Payload.DestinationPort)
	s += ufmt.Sprintf("  - version: %s\n", a.Payload.Version)
	s += ufmt.Sprintf("  - encoding: %s\n", a.Payload.Encoding)
	s += ufmt.Sprintf("  - value: %s\n", string(a.Payload.Value))
	if len(a.Ack) > 0 {
		s += ufmt.Sprintf("- ack: %s\n", string(a.Ack))
	}
	return s
}
