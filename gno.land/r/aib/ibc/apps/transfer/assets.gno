package transfer

import (
	"chain"

	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/r/aib/ibc/core"
)

// clientAssets counts the transfer state a client holds, kept as it changes
// so that the staged activation and a route replacement read it in constant
// work, whatever the number of denoms (ADR pr6375 R17, R18, §7.12): escrow
// denoms with a positive balance under the client, voucher denoms that came
// over it with a positive supply, and the transfer packets an Ethereum client
// sent that are still outstanding (their payloads, which the activation reads
// to stage the denoms they carry). The counters live in the proxy from its
// deployment, so no state predates them.
type clientAssets struct {
	escrowed int64
	vouchers int64
	inFlight *bptree.BPTree // seqid(sequence) -> types.Payload
}

var assetsByClient = bptree.NewBPTree32() // client id -> *clientAssets

func assetsOf(clientID string, create bool) *clientAssets {
	if v := assetsByClient.Get(clientID); v != nil {
		return v.(*clientAssets)
	}
	if !create {
		return nil
	}
	a := &clientAssets{inFlight: bptree.NewBPTree32()}
	assetsByClient.Set(clientID, a)
	return a
}

// voucherClient is the client a voucher denom came over (its first hop), or
// "" if it has none on the transfer port.
func voucherClient(ibcDenom string) string {
	d, ok := getDenom(ibcDenom)
	if !ok || len(d.Trace) == 0 || d.Trace[0].PortId != PortID {
		return ""
	}
	return d.Trace[0].ClientId
}

// noteEscrow keeps the escrowed count as clientID's balance of a denom moves
// from before to after.
func noteEscrow(clientID string, before, after int64) {
	switch {
	case before <= 0 && after > 0:
		assetsOf(clientID, true).escrowed++
	case before > 0 && after <= 0:
		assetsOf(clientID, true).escrowed--
	}
}

// noteSupply keeps the vouchers count as a voucher denom's supply moves from
// before to after.
func noteSupply(ibcDenom string, before, after int64) {
	client := voucherClient(ibcDenom)
	if client == "" {
		return
	}
	switch {
	case before <= 0 && after > 0:
		assetsOf(client, true).vouchers++
	case before > 0 && after <= 0:
		assetsOf(client, true).vouchers--
	}
}

// isEthereumClient reports whether the core's client clientID is an Ethereum
// client: the clients whose outstanding packets the activation reads.
func isEthereumClient(clientID string) bool { return core.ClientType(clientID) == ethereum.ClientType }

func noteSent(clientID string, sequence uint64, payload types.Payload) {
	p := payload
	p.Value = append([]byte{}, payload.Value...)
	assetsOf(clientID, true).inFlight.Set(seqid.ID(sequence).String(), p)
}

func noteSettled(clientID string, sequence uint64) {
	if a := assetsOf(clientID, false); a != nil {
		a.inFlight.Remove(seqid.ID(sequence).String())
	}
}

// ClientAssetCount is how many denoms of transfer state clientID holds: its
// escrow denoms with a positive balance and the voucher denoms that came over
// it with a positive supply. Constant work.
func ClientAssetCount(clientID string) int64 {
	a := assetsOf(clientID, false)
	if a == nil {
		return 0
	}
	return a.escrowed + a.vouchers
}

// HoldsAsset reports whether clientID holds transfer state of denom: an
// escrow balance of it, or (an IBC voucher denom) vouchers of it in
// circulation that came over clientID. Constant work.
func HoldsAsset(clientID, denom string) bool {
	if t := getEscrowForClient(clientID); t != nil {
		if v := t.Get(denom); v != nil && v.(chain.Coin).IsPositive() {
			return true
		}
	}
	if inst := getVoucher(denom); inst != nil && voucherClient(denom) == clientID {
		return inst.token.TotalSupply() > 0
	}
	return false
}

// InFlightPayloads is the payloads of up to max transfer packets clientID (an
// Ethereum client) sent that are still outstanding, in sequence order, and
// whether those are all of them.
func InFlightPayloads(clientID string, max int) ([]types.Payload, bool) {
	a := assetsOf(clientID, false)
	if a == nil {
		return nil, true
	}
	var out []types.Payload
	complete := true
	a.inFlight.Iterate("", "", func(_ string, v any) bool {
		if len(out) == max {
			complete = false
			return true
		}
		out = append(out, v.(types.Payload))
		return false
	})
	return out, complete
}
