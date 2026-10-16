package impl

import (
	"chain"
	"math"
	"chain/runtime/unsafe"
	"strings"

	"gno.land/p/aib/encoding/ethaddr/v0"
	"gno.land/p/aib/ibc/ics20/abi/v0"
	"gno.land/p/aib/ibc/ics20/controls/v0"
	"gno.land/p/aib/ibc/ics20/v0"
	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
	"gno.land/r/aib/ibc/ibcgov"
	"gno.land/r/nt/grc20reg/v0"
)

// isEthereum reports whether clientID is an Ethereum client of the core: the
// clients the route controls cover.
func isEthereum(clientID string) bool {
	return core.ClientType(clientID) == ethereum.ClientType
}

// routeOf resolves a client: covered is false for a client the controls do
// not cover (impl/v0's path); otherwise rt is the route whose current client
// it is, or nil for an Ethereum client no enrolled route has as its current
// client, which carries no transfer.
func (l *logic) routeOf(_ int, rlm realm, clientID string) (rt *controls.Route, covered bool) {
	if !isEthereum(clientID) {
		return nil, false
	}
	return l.registry(0, rlm).RouteOf(clientID), true
}

func mustRoute(rt *controls.Route, clientID string) *controls.Route {
	if rt == nil {
		panic(ufmt.Sprintf("client %s is an Ethereum client of no enrolled route: it carries no transfer", clientID))
	}
	return rt
}

// toWire rewrites the first hop of a voucher's trace from the route key to the
// route's current client id: the denom a counterparty knows.
func toWire(d ics20.Denom, rt *controls.Route) ics20.Denom {
	if d.HasPrefix(transfer.PortID, rt.Key) {
		trace := append([]ics20.Hop{ics20.NewHop(transfer.PortID, rt.Client)}, d.Trace[1:]...)
		return ics20.Denom{Base: d.Base, Trace: trace}
	}
	return d
}

// toInternal rewrites the first hop from the current client id to the route
// key: the denom this chain keys its vouchers by.
func toInternal(d ics20.Denom, rt *controls.Route) ics20.Denom {
	if d.HasPrefix(transfer.PortID, rt.Client) {
		trace := append([]ics20.Hop{ics20.NewHop(transfer.PortID, rt.Key)}, d.Trace[1:]...)
		return ics20.Denom{Base: d.Base, Trace: trace}
	}
	return d
}

// checkRecipient applies the send-side recipient filters (ADR pr6375 §7.8):
// the receiver is an Ethereum address, not the zero address, not one reserved
// at or below 0xffff, not one of the route's refused bridge contracts and not
// the token itself.
func checkRecipient(rt *controls.Route, receiver, token string) {
	a, err := ethaddr.Parse(receiver)
	if err != nil {
		panic("the receiver is " + err.Error())
	}
	switch {
	case a.IsZero():
		panic("the receiver is the zero address")
	case a.Reserved():
		panic("the receiver is a reserved address (at or below 0xffff)")
	case rt.IsRefused(a.Lower()):
		panic("the receiver is a contract of the bridge")
	case strings.EqualFold(a.Lower(), token):
		panic("the receiver is the token itself")
	}
}

// Transfer is impl/v0's Transfer for clients the controls do not cover. On a
// route it applies the send-side controls, builds an ABI packet, sends it and
// writes the send record.
func (l *logic) Transfer(_ int, rlm realm, sent []chain.Coin, clientID, receiver, denom string, amount int64, timeoutTimestamp uint64, memo string) (
	packet types.MsgSendPacket, sequence uint64,
) {
	rt, covered := l.routeOf(0, rlm, clientID)
	if !covered {
		return l.Logic.Transfer(0, rlm, sent, clientID, receiver, denom, amount, timeoutTimestamp, memo)
	}
	if rt == nil && strings.HasPrefix(denom, "ibc/") {
		// impl/v0's vouchers go back over a client no decision enrolled
		// yet: the legacy path records and meters the return (ADR pr6375
		// R17).
		rt = l.registry(0, rlm).Legacy(clientID)
	}
	rt = mustRoute(rt, clientID)
	if rt.IsClosed() {
		panic(ufmt.Sprintf("route %s is closed until a governed reopening: it carries no send", rt.Key))
	}
	sender := unsafe.OriginCaller()
	var (
		wireDenom string // the denom path in the packet
		accDenom  string // the accounting denom of the send record
		kind      string
		fee       int64
	)
	switch {
	case strings.HasPrefix(denom, "ibc/"):
		// A voucher returning to Ethereum: burnt in OnSendPacket; never
		// limited, charged or paused.
		if len(sent) > 0 {
			panic("voucher transfer must not include native coins")
		}
		if l.store.VoucherToken(denom) == nil {
			panic(ufmt.Errorf("voucher token not found for denom %s", denom))
		}
		d, found := l.store.Denom(denom)
		if !found {
			panic(ufmt.Sprintf("denom %s not found in store", denom))
		}
		if !d.HasPrefix(transfer.PortID, rt.Key) {
			panic(ufmt.Sprintf("voucher %s did not come over route %s", denom, rt.Key))
		}
		// Every send on a route is recorded, a return too, so its refund is
		// metered and held like any other (ADR pr6375 §7.13). A voucher of a
		// denom no decision enabled yet goes back through the legacy path:
		// recorded, its refund queued until the denom is enabled.
		acc := rt.Denom(denom)
		if acc == nil {
			acc = rt.LegacyDenom(denom, controls.KindMint, l.store.VoucherToken(denom).TotalSupply(), now())
		}
		if acc.Config.Kind != controls.KindMint {
			panic(ufmt.Sprintf("denom %s is accounted as %s on route %s", denom, acc.Config.Kind, rt.Key))
		}
		checkRecipient(rt, receiver, strings.ToLower(d.Base))
		wireDenom = toWire(d, rt).Path()
		l.store.SetPendingVoucherSend(0, rlm, sender.String(), clientID, wireDenom, amount)
		accDenom, kind = denom, controls.KindMint
	case grc20reg.Get(denom) != nil:
		if len(sent) > 0 {
			panic("GRC20 transfer must not include native coins")
		}
		alias := transfer.GRC20Alias(denom)
		acc := l.mustSendable(rt, alias, amount)
		checkRecipient(rt, receiver, acc.Config.Remote)
		fee = acc.Config.Fee
		if fee > 0 {
			c := chain.NewCoin(alias, fee)
			if err := l.store.EscrowGRC20(0, rlm, rt.Key, denom, sender, c); err != nil {
				panic(err)
			}
			if err := l.store.UnescrowGRC20(0, rlm, rt.Key, string(rt.FeeCollector), c); err != nil {
				panic(err)
			}
		}
		l.store.SetPendingGRC20Send(0, rlm, sender.String(), clientID, alias, amount)
		wireDenom, accDenom, kind = alias, alias, controls.KindUnescrow
	case strings.Contains(denom, "/"):
		panic(ufmt.Sprintf("GRC20 token %s not found in grc20reg", denom))
	default:
		acc := l.mustSendable(rt, denom, amount)
		checkRecipient(rt, receiver, acc.Config.Remote)
		fee = acc.Config.Fee
		if amount > math.MaxInt64-fee {
			panic("the amount plus the route fee overflows")
		}
		if len(sent) != 1 || sent[0].Denom != denom || sent[0].Amount != amount+fee {
			panic(ufmt.Sprintf("send exactly %d%s: the amount plus the route fee of %d", amount+fee, denom, fee))
		}
		l.store.SetPendingNativeEscrow(0, rlm, chain.NewCoin(denom, amount))
		if fee > 0 {
			// The fee landed here with the amount: book it to the route and
			// pay it to the collector, so the escrow accounting stays exact.
			c := chain.NewCoin(denom, fee)
			l.store.AddEscrow(0, rlm, rt.Key, c)
			if err := l.store.UnescrowNative(0, rlm, rt.Key, string(rt.FeeCollector), c); err != nil {
				panic(err)
			}
		}
		wireDenom, accDenom, kind = denom, denom, controls.KindUnescrow
	}

	data := ics20.NewFungibleTokenPacketData(wireDenom, ufmt.Sprintf("%d", amount), sender.String(), receiver, memo)
	value, err := abi.Marshal(data)
	if err != nil {
		panic(err)
	}
	payload := types.Payload{
		SourcePort: transfer.PortID, DestinationPort: transfer.PortID,
		Encoding: abi.Encoding, Value: value, Version: transfer.V1,
	}
	packet = types.MsgSendPacket{SourceClient: clientID, Payloads: []types.Payload{payload}, TimeoutTimestamp: timeoutTimestamp}
	sequence = core.SendPacket(cross(rlm), packet)

	// The send record (ADR pr6375 §7.13), in the transaction of the send.
	full := types.NewPacket(sequence, clientID, core.CounterpartyClientID(clientID), timeoutTimestamp, payload)
	err = rt.RecordSend(controls.SendRecord{
		Key: controls.PacketKey(clientID, sequence), Packet: full, Commitment: types.CommitPacket(full),
		Sender: sender, Receiver: receiver, Denom: accDenom, Kind: kind, Amount: amount, Fee: fee,
		SentHeight: chainHeight(), SentAt: now(),
	})
	if err != nil {
		panic(err)
	}
	return packet, sequence
}

// mustSendable is the accounting of a gno-native denom a send may carry on
// rt: enabled, not paused by a sends flag, within the send limits.
func (l *logic) mustSendable(rt *controls.Route, denom string, amount int64) *controls.Denom {
	acc := rt.Denom(denom)
	if rt.Legacy || acc == nil || acc.Legacy || acc.Config.Kind != controls.KindUnescrow {
		panic(ufmt.Sprintf("denom %s is not enabled for sends on route %s", denom, rt.Key))
	}
	if rt.ExposureClosed() {
		panic(ufmt.Sprintf("route %s has a loss without a restoring decision: it takes no gno-native send", rt.Key))
	}
	if ibcgov.Flagged(rt.Key, ibcgov.FnSends) {
		panic(ufmt.Sprintf("sends are paused on route %s", rt.Key))
	}
	if err := acc.CheckSend(amount); err != nil {
		panic(err)
	}
	return acc
}

// OnSendPacket is impl/v0's for clients the controls do not cover. On a route
// it takes what Transfer authorized: it burns a returning voucher (its
// internal denom keyed by the route key) or escrows a gno-native token under
// the route key.
func (l *logic) OnSendPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) error {
	rt, covered := l.routeOf(0, rlm, sourceClient)
	if !covered {
		return l.Logic.OnSendPacket(0, rlm, sourceClient, destinationClient, sequence, payload)
	}
	if rt == nil {
		return ufmt.Errorf("client %s is an Ethereum client of no enrolled route", sourceClient)
	}
	if err := validatePayload(sourceClient, destinationClient, payload); err != nil {
		return err
	}
	data, token, err := unmarshalPayload(payload)
	if err != nil {
		return err
	}
	signer := unsafe.OriginCaller().String()
	if data.Sender != signer {
		return ufmt.Errorf("invalid FungibleTokenPacketData: sender %s is different from signer %s", data.Sender, signer)
	}
	if transfer.IsBlocked(address(data.Sender)) {
		return ufmt.Errorf("sender %s is blocked", data.Sender)
	}
	if err := validateBaseDenomNoSlash(token); err != nil {
		return err
	}
	coin, err := token.ToCoin()
	if err != nil {
		return ufmt.Errorf("token to coin error: %v", err)
	}
	switch {
	case token.Denom.HasPrefix(payload.SourcePort, sourceClient):
		expected, ok := l.store.ConsumePendingVoucherSend(0, rlm)
		if !ok {
			return ufmt.Errorf("voucher packet must be initiated through transfer.Transfer")
		}
		if err := validatePendingSend(expected, data.Sender, sourceClient, token.Denom.Path(), coin.Amount); err != nil {
			return ufmt.Errorf("voucher packet %v", err)
		}
		internal := toInternal(token.Denom, rt).IBCDenom()
		if err := l.store.BurnVoucher(0, rlm, internal, address(data.Sender), coin.Amount); err != nil {
			return ufmt.Errorf("burn voucher %s error: %v", internal, err)
		}
	case transfer.IsGRC20Alias(token.Denom.Base):
		expected, ok := l.store.ConsumePendingGRC20Send(0, rlm)
		if !ok {
			return ufmt.Errorf("GRC20 packet must be initiated through transfer.Transfer")
		}
		if err := validatePendingSend(expected, data.Sender, sourceClient, token.Denom.Path(), coin.Amount); err != nil {
			return ufmt.Errorf("GRC20 packet %v", err)
		}
		denomKey := transfer.ResolveGRC20Alias(token.Denom.Base)
		if err := l.store.EscrowGRC20(0, rlm, rt.Key, denomKey, address(data.Sender), coin); err != nil {
			return err
		}
	default:
		expected, ok := l.store.PendingNativeEscrow()
		if !ok {
			return ufmt.Errorf("native packet must be initiated through transfer.Transfer")
		}
		if coin.Denom != expected.Denom || coin.Amount != expected.Amount {
			return ufmt.Errorf("escrowed coin %s is not equal to fungible packet data token %s", expected, coin)
		}
		l.store.AddEscrow(0, rlm, rt.Key, coin)
	}
	transfer.EmitTransfer(0, rlm, data.Sender, data.Receiver, token.Denom.Path(), token.Amount, data.Memo)
	return nil
}
