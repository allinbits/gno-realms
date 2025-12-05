package testing

import (
	"chain"
	"chain/banker"
	"chain/runtime"

	"gno.land/p/aib/ibc/app"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/nt/ufmt"
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
	}
	Args struct {
		Banker            banker.Banker
		SourceClient      string
		DestinationClient string
		Sequence          uint64
		Payload           types.Payload
		Ack               []byte
	}
)

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

// Implements app.IBCApp
func (a *App) OnSendPacket(
	_ realm,
	banker banker.Banker,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	payload types.Payload,
) error {
	a.Calls.OnSendPacket = append(a.Calls.OnSendPacket,
		Args{
			Banker:            banker,
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
	return a.Calls.OnAcknowledgementPacketReturn
}

func (a *App) Report() string {
	var s string
	// Report app realm balance
	s += ufmt.Sprintf("balance: %s\n",
		banker.NewBanker(banker.BankerTypeReadonly).GetCoins(
			runtime.CurrentRealm().Address(),
		))
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
	// if Banker provided (for OnSendPacket only), report spendable balance
	if a.Banker != nil {
		coins := banker.OriginSend()
		if len(coins) == 0 {
			coins = chain.NewCoins(chain.NewCoin("ugnot", 0))
		}
		s += ufmt.Sprintf("- spendable: %s\n", coins)
	}
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
