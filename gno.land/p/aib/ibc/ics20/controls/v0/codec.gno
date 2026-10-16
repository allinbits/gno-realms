package controls

import (
	"errors"

	"gno.land/p/aib/encoding/wire/v0"
	"gno.land/p/nt/ufmt/v0"
)

// The governance operations a transfer implementation applies on a decision
// of gno.land/r/aib/ibc/ibcgov (through the transfer proxy's GovApply). Their
// parameters travel as Params in the wire format.
const (
	OpEnroll          = "enroll"            // Route, To (fee collector)
	OpDenom           = "denom"             // Route, Denom, Config
	OpCollector       = "collector"         // Route, To
	OpRefuse          = "refuse"            // Route, Keys (Ethereum addresses)
	OpUnrefuse        = "unrefuse"          // Route, Keys (Ethereum addresses)
	OpVoid            = "void"              // Route, Keys, Forged, Incident
	OpRestore         = "restore"           // Route, Keys
	OpCredit          = "credit"            // Route, Key, Denom, To, Amount
	OpSweep           = "sweep"             // Route, Keys, To
	OpLoss            = "loss"              // Route, Key, Denom, Amount, Chain, Incident, Cause
	OpRecapitalize    = "recapitalize"      // Route, Denom, Amount, Incident
	OpRevokeRecap     = "revoke recap"      // Route, Amount (the authorization id)
	OpReduce          = "reduce"            // Route, Key, Amount, Incident
	OpAccept          = "accept"            // Route, Denom, Amount, Incident
	OpSettle          = "settle"            // Route, Client (the retired client), Items, Incident
	OpReplace         = "replace"           // Route, Client (the new client), Height (the suspect interval start)
	OpReopen          = "reopen"            // Route
	OpLegacyRefundCap = "legacy refund cap" // Amount
	OpBridge          = "bridge"            // Route (an Ethereum client), Keys (its router, ICS20 transfer, IBCAdmin)
)

// Params are the parameters of a governance operation; each operation reads
// the fields its comment above names.
type Params struct {
	Route    string
	Denom    string
	Key      string
	Client   string
	Chain    string
	Incident string
	Cause    string
	To       address
	Keys     []string
	Forged   bool
	Amount   int64
	Config   DenomConfig
	Items    []SettleItem
	Height   int64
}

// Encode writes p in the wire format, every field in a fixed order.
func (p Params) Encode() []byte {
	w := wire.NewWriter()
	w.Str(p.Route).Str(p.Denom).Str(p.Key).Str(p.Client).Str(p.Chain).Str(p.Incident).Str(p.Cause).Addr(p.To)
	w.Uvarint(uint64(len(p.Keys)))
	for _, k := range p.Keys {
		w.Str(k)
	}
	w.Bool(p.Forged).Int(p.Amount)
	c := p.Config
	w.Str(c.Kind).Int(c.CapFloor).Int(c.SupplyCap).Int(c.Fee).Int(c.FeeFloor).Int(c.SendMax).Int(c.SendMin).Int(c.RefundCap).Str(c.Remote)
	w.Uvarint(uint64(len(p.Items)))
	for _, it := range p.Items {
		w.Uvarint(it.Seq).Uvarint(uint64(it.Action)).Int(it.Amount)
	}
	w.Int(p.Height)
	return w.Bytes()
}

// DecodeParams reads what Encode writes, refusing trailing bytes.
func DecodeParams(bz []byte) (Params, error) {
	var p Params
	r := wire.NewReader(bz)
	p.Route, p.Denom, p.Key, p.Client, p.Chain, p.Incident, p.Cause = r.Str(), r.Str(), r.Str(), r.Str(), r.Str(), r.Str(), r.Str()
	p.To = r.Addr()
	n := r.Uvarint()
	if r.Err() == nil && n > MaxKeys {
		return Params{}, ufmt.Errorf("controls: more than %d keys", MaxKeys)
	}
	for i := uint64(0); i < n && r.Err() == nil; i++ {
		p.Keys = append(p.Keys, r.Str())
	}
	p.Forged = r.Bool()
	p.Amount = r.Int()
	p.Config.Kind = r.Str()
	p.Config.CapFloor, p.Config.SupplyCap, p.Config.Fee, p.Config.FeeFloor = r.Int(), r.Int(), r.Int(), r.Int()
	p.Config.SendMax, p.Config.SendMin, p.Config.RefundCap, p.Config.Remote = r.Int(), r.Int(), r.Int(), r.Str()
	n = r.Uvarint()
	if r.Err() == nil && n > MaxKeys {
		return Params{}, ufmt.Errorf("controls: more than %d items", MaxKeys)
	}
	for i := uint64(0); i < n && r.Err() == nil; i++ {
		seq, action, amount := r.Uvarint(), r.Uvarint(), r.Int()
		if action > 255 {
			return Params{}, errors.New("controls: params: action out of range")
		}
		p.Items = append(p.Items, SettleItem{Seq: seq, Action: uint8(action), Amount: amount})
	}
	p.Height = r.Int()
	if err := r.Err(); err != nil {
		return Params{}, ufmt.Errorf("controls: params: %v", err)
	}
	if !r.Done() {
		return Params{}, errors.New("controls: params: trailing bytes")
	}
	return p, nil
}
