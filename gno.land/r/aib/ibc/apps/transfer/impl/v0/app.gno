package impl

import (
	"bytes"
	"chain"
	"chain/runtime/unsafe"
	"errors"
	"strconv"
	"strings"

	"gno.land/p/aib/ibc/ics20/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/apps/transfer"
)

// validatePayload enforces that the source and destination portIDs are the
// same and equal to the transfer portID, that the clientIDs are in the
// {clientid}-{sequence} format transfer expects, and the ICS20 version and
// encoding. This is necessary for IBC v2 since the portIDs (and thus the
// application-application connection) are not prenegotiated by a channel
// handshake. This restriction can be removed in a future where the trace hop
// on receive commits to **both** the source and destination portIDs rather
// than just the destination port.
func validatePayload(sourceClient, destinationClient string, payload types.Payload) error {
	if payload.SourcePort != transfer.PortID || payload.DestinationPort != transfer.PortID {
		return ufmt.Errorf("payload port ID is invalid: expected %s, got sourcePort: %s destPort: %s", transfer.PortID, payload.SourcePort, payload.DestinationPort)
	}
	if !types.IsValidClientID(sourceClient) || !types.IsValidClientID(destinationClient) {
		return ufmt.Errorf("client IDs must be in valid format: {string}-{number}")
	}
	if payload.Version != transfer.V1 {
		return ufmt.Errorf("invalid ICS20 version: expected %s, got %s", transfer.V1, payload.Version)
	}
	if payload.Encoding != transfer.EncodingProtobuf {
		return ufmt.Errorf("invalid encoding: expected %s, got %s", transfer.EncodingProtobuf, payload.Encoding)
	}
	return nil
}

func (l *logic) OnSendPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) error {
	if err := validatePayload(sourceClient, destinationClient, payload); err != nil {
		return err
	}

	data, token, err := unmarshalPayload(payload.Value)
	if err != nil {
		return err
	}

	// Mirror Transfer: the packet Sender is the EOA that signed the tx.
	// unsafe.OriginCaller is tx-level identity (no cur equivalent).
	signer := unsafe.OriginCaller().String()
	if data.Sender != signer {
		return ufmt.Errorf("invalid FungibleTokenPacketData: sender %s is different from signer %s", data.Sender, signer)
	}
	if transfer.IsBlocked(address(data.Sender)) {
		return ufmt.Errorf("sender %s is blocked", data.Sender)
	}

	// Enforce that the base denom does not contain any slashes
	// Since IBC v2 packets will no longer have channel identifiers, we cannot
	// rely on the channel format to easily divide the trace from the base
	// denomination in ICS20 v1 packets.
	// The simplest way to prevent any potential issues from arising is to simply
	// disallow any slashes in the base denomination.
	// This prevents such denominations from being sent with IBCV v2 packets,
	// however we can still support them in IBC v1 packets.
	// If we enforce that IBC v2 packets are sent with ICS20 v2 and above
	// versions that separate the trace from the base denomination in the packet
	// data, then we can remove this restriction.
	// Non-IBC GRC20 tokens use aliases (slashes replaced with colons)
	// so they pass this check naturally.
	if err := validateBaseDenomNoSlash(token); err != nil {
		return err
	}

	coin, err := token.ToCoin()
	if err != nil {
		return ufmt.Errorf("token to coin error: %v", err)
	}
	if token.Denom.HasPrefix(payload.SourcePort, sourceClient) {
		expected, ok := l.store.ConsumePendingVoucherSend(0, rlm)
		if !ok {
			return ufmt.Errorf("voucher packet must be initiated through transfer.Transfer")
		}
		if err := validatePendingSend(expected, data.Sender, sourceClient, token.Denom.Path(), coin.Amount); err != nil {
			return ufmt.Errorf("voucher packet %v", err)
		}

		// Burn the voucher tokens from sender
		if err := l.store.BurnVoucher(0, rlm, coin.Denom, address(data.Sender), coin.Amount); err != nil {
			if l.store.VoucherToken(coin.Denom) == nil {
				return err
			}
			return ufmt.Errorf("burn voucher %s error: %v", coin.String(), err)
		}
	} else if transfer.IsGRC20Alias(token.Denom.Base) {
		expected, ok := l.store.ConsumePendingGRC20Send(0, rlm)
		if !ok {
			return ufmt.Errorf("GRC20 packet must be initiated through transfer.Transfer")
		}
		if err := validatePendingSend(expected, data.Sender, sourceClient, token.Denom.Path(), coin.Amount); err != nil {
			return ufmt.Errorf("GRC20 packet %v", err)
		}

		// Non-IBC GRC20 token: escrow via TransferFrom.
		// The caller must have approved the transfer app realm address.
		denomKey := transfer.ResolveGRC20Alias(token.Denom.Base)
		if err := l.store.EscrowGRC20(0, rlm, sourceClient, denomKey, address(data.Sender), coin); err != nil {
			return err
		}
	} else {
		// Native token: OnSendPacket cannot safely read banker.OriginSend()
		// here because PreviousRealm() is the core realm (not the EOA), so
		// the escrow envelope is verified upstream by Transfer() and handed
		// off through the store. A direct caller of core.SendPacket for a
		// native packet will find the slot empty and be rejected.
		expected, ok := l.store.PendingNativeEscrow()
		if !ok {
			return ufmt.Errorf("native packet must be initiated through transfer.Transfer")
		}
		if coin.Denom != expected.Denom || coin.Amount != expected.Amount {
			return ufmt.Errorf(
				"escrowed coin %s is not equal to fungible packet data token %s",
				expected, coin,
			)
		}
		// Escrow the coin on the proxy's balance, accounted under sourceClient.
		l.store.AddEscrow(0, rlm, sourceClient, coin)
	}

	transfer.EmitTransfer(0, rlm, data.Sender, data.Receiver, token.Denom.Path(), token.Amount, data.Memo)
	return nil
}

func validatePendingSend(expected transfer.PendingSend, sender, sourceClient, denom string, amount int64) error {
	if expected.Sender != sender ||
		expected.SourceClient != sourceClient ||
		expected.Denom != denom ||
		expected.Amount != amount {
		return ufmt.Errorf("does not match transfer.Transfer")
	}
	return nil
}

func (l *logic) OnRecvPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) types.RecvPacketResult {
	if err := validatePayload(sourceClient, destinationClient, payload); err != nil {
		return types.RecvPacketResult{Status: types.PacketStatus_Failure}
	}

	var (
		data       ics20.FungibleTokenPacketData
		token      ics20.Token
		ackErr     error
		ack        = types.NewResultAppAcknowledgement([]byte{byte(1)})
		recvResult = types.RecvPacketResult{
			Status:          types.PacketStatus_Success,
			Acknowledgement: ack.MarshalJSON(),
		}
	)
	// we are explicitly wrapping this emit event call in an anonymous function
	// so that the packet data is evaluated after it has been assigned a value.
	defer func() {
		attrs := []string{
			transfer.AttributeKeySender, data.Sender,
			transfer.AttributeKeyReceiver, data.Receiver,
			transfer.AttributeKeyDenom, token.Denom.Path(),
			transfer.AttributeKeyAmount, token.Amount,
			transfer.AttributeKeyMemo, data.Memo,
			transfer.AttributeKeyAckSuccess, strconv.FormatBool(ack.Success()),
		}
		if ackErr != nil {
			attrs = append(attrs,
				[]string{transfer.AttributeKeyAckError, ackErr.Error()}...,
			)
		}
		transfer.EmitPacket(0, rlm, attrs...)
	}()

	data, token, ackErr = unmarshalPayload(payload.Value)
	if ackErr != nil {
		ack = types.NewErrorAppAcknowledgement(ackErr)
		return types.RecvPacketResult{Status: types.PacketStatus_Failure}
	}
	if ackErr = validateBaseDenomNoSlash(token); ackErr != nil {
		ack = types.NewErrorAppAcknowledgement(ackErr)
		return types.RecvPacketResult{Status: types.PacketStatus_Failure}
	}
	// A blocked receiver gets an error acknowledgement, so the counterparty
	// refunds its sender; nothing is minted or released here.
	if transfer.IsBlocked(address(data.Receiver)) {
		ackErr = ufmt.Errorf("receiver %s is blocked", data.Receiver)
		ack = types.NewErrorAppAcknowledgement(ackErr)
		return types.RecvPacketResult{Status: types.PacketStatus_Failure}
	}
	// This is the prefix that would have been prefixed to the denomination
	// on sender chain IF and only if the token originally came from the
	// receiving chain.
	//
	// NOTE: We use SourcePort and SourceClient here, because the counterparty
	// chain would have prefixed with DestPort and DestClient when originally
	// receiving this token.
	if token.Denom.HasPrefix(payload.SourcePort, sourceClient) {
		// sender chain is not the source, unescrow tokens

		// remove prefix added by sender chain
		token.Denom.Trace = token.Denom.Trace[1:]
		var transferAmount int64
		transferAmount, ackErr = token.AmountInt64()
		if ackErr != nil {
			ack = types.NewErrorAppAcknowledgement(ackErr)
			return types.RecvPacketResult{Status: types.PacketStatus_Failure}
		}

		coin := chain.NewCoin(token.Denom.IBCDenom(), transferAmount)

		// The escrow being released was recorded under destinationClient when
		// this chain originally sent the token out (the packet now arrives on
		// destinationClient carrying the counterparty's prefix on the denom).
		// Debiting destinationClient, not sourceClient, is what prevents a
		// packet arriving on a different client from draining escrow that
		// belongs to another client.
		if transfer.IsGRC20Alias(coin.Denom) {
			ackErr = l.store.UnescrowGRC20(0, rlm, destinationClient, data.Receiver, coin)
		} else {
			ackErr = l.store.UnescrowNative(0, rlm, destinationClient, data.Receiver, coin)
		}
		if ackErr != nil {
			ack = types.NewErrorAppAcknowledgement(ackErr)
			return types.RecvPacketResult{Status: types.PacketStatus_Failure}
		}

	} else {
		// sender chain is the source, mint vouchers

		// since SendPacket did not prefix the denomination, we must add the
		// destination port and client to the trace
		trace := []ics20.Hop{ics20.NewHop(payload.DestinationPort, destinationClient)}
		token.Denom.Trace = append(trace, token.Denom.Trace...)

		voucherDenom := token.Denom.IBCDenom()
		if !l.store.HasDenom(voucherDenom) {
			l.store.SetDenom(0, rlm, token.Denom)
		}

		transfer.EmitDenom(0, rlm, token.Denom.HashHex(), string(token.Denom.MarshalJSON()))

		// Mint voucher tokens to the receiver
		var amount int64
		amount, ackErr = token.AmountInt64()
		if ackErr != nil {
			ack = types.NewErrorAppAcknowledgement(ackErr)
			return types.RecvPacketResult{Status: types.PacketStatus_Failure}
		}
		l.store.GetOrCreateVoucher(0, rlm, token.Denom.Base, voucherDenom)
		if err := l.store.MintVoucher(0, rlm, voucherDenom, address(data.Receiver), amount); err != nil {
			ackErr = ufmt.Errorf("mint voucher error: %v", err)
			ack = types.NewErrorAppAcknowledgement(ackErr)
			return types.RecvPacketResult{Status: types.PacketStatus_Failure}
		}
	}

	return recvResult
}

// validateBaseDenomNoSlash rejects base denominations containing a slash.
// IBC v2 packets do not carry channel identifiers, so denomination traces
// cannot be unambiguously separated from a slashed base denomination.
func validateBaseDenomNoSlash(token ics20.Token) error {
	if strings.Contains(token.Denom.Base, "/") {
		return ufmt.Errorf("base denomination %s cannot contain slashes for IBC v2 packet", token.Denom.Base)
	}
	return nil
}

// OnAcknowledgementPacket responds to the success or failure of a packet
// acknowledgment written on the receiving chain.
//
// If the acknowledgement was a success then nothing occurs. Otherwise,
// if the acknowledgement failed, then the sender is refunded their tokens.
func (l *logic) OnAcknowledgementPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, acknowledgement []byte, payload types.Payload) error {
	var ack types.AppAcknowledgement
	// Construct an error acknowledgement if the acknowledgement bytes are the
	// sentinel error acknowledgement so we can use the shared transfer logic
	if bytes.Equal(acknowledgement, types.UniversalErrorAcknowledgement()) {
		// the specific error does not matter
		ack = types.NewErrorAppAcknowledgement(errors.New("receive packet failed"))
	} else {
		if err := ack.UnmarshalJSON(acknowledgement); err != nil {
			return ufmt.Errorf("cannot unmarshal ICS-20 transfer packet acknowledgement: %v", err)
		}
		if !ack.Success() {
			return ufmt.Errorf("cannot pass in a custom error acknowledgement with IBC v2")
		}
	}

	data, token, err := unmarshalPayload(payload.Value)
	if err != nil {
		return err
	}

	if ack.Success() {
		// the acknowledgement succeeded on the receiving chain so nothing
		// needs to be executed and no error needs to be returned
	} else {
		// refund sender in case of ack error
		if err := l.refundPacketToken(0, rlm, payload.SourcePort, sourceClient, data.Sender, token); err != nil {
			return err
		}
	}

	transfer.EmitPacket(0, rlm,
		transfer.AttributeKeySender, data.Sender,
		transfer.AttributeKeyReceiver, data.Receiver,
		transfer.AttributeKeyDenom, token.Denom.Path(),
		transfer.AttributeKeyAmount, token.Amount,
		transfer.AttributeKeyMemo, data.Memo,
		transfer.AttributeKeyAck, string(acknowledgement),
	)
	if ack.Success() {
		transfer.EmitPacket(0, rlm,
			transfer.AttributeKeyAckSuccess, string(ack.Response.Result),
		)
	} else {
		transfer.EmitPacket(0, rlm,
			transfer.AttributeKeyAckError, ack.Response.Error,
		)
	}
	return nil
}

// OnTimeoutPacket processes a transfer packet timeout by refunding the tokens
// to the sender.
func (l *logic) OnTimeoutPacket(_ int, rlm realm, sourceClient, destinationClient string, sequence uint64, payload types.Payload) error {
	data, token, err := unmarshalPayload(payload.Value)
	if err != nil {
		return err
	}
	if err := l.refundPacketToken(0, rlm, payload.SourcePort, sourceClient, data.Sender, token); err != nil {
		return err
	}
	transfer.EmitTimeout(0, rlm, data.Sender, token.Denom.Path(), token.Amount, data.Memo)
	return nil
}

// refundPacketToken returns to sender what OnSendPacket took: it re-mints
// burnt vouchers, or releases the escrow recorded under sourceClient.
func (l *logic) refundPacketToken(_ int, rlm realm, sourcePort, sourceClient, sender string, token ics20.Token) error {
	coin, err := token.ToCoin()
	if err != nil {
		return ufmt.Errorf("token to coin error: %v", err)
	}
	if token.Denom.HasPrefix(sourcePort, sourceClient) {
		// Re-mint voucher tokens that were burnt during OnSendPacket
		if err := l.store.MintVoucher(0, rlm, coin.Denom, address(sender), coin.Amount); err != nil {
			if l.store.VoucherToken(coin.Denom) == nil {
				return err
			}
			return ufmt.Errorf("re-mint voucher error: %v", err)
		}
	} else if transfer.IsGRC20Alias(coin.Denom) {
		// Non-IBC GRC20: return escrowed tokens to sender. These tokens were
		// escrowed under sourceClient on OnSendPacket, so release there.
		if err := l.store.UnescrowGRC20(0, rlm, sourceClient, sender, coin); err != nil {
			return err
		}
	} else {
		// Native: return escrowed coins to sender. These coins were escrowed
		// under sourceClient on OnSendPacket, so release there.
		if err := l.store.UnescrowNative(0, rlm, sourceClient, sender, coin); err != nil {
			return err
		}
	}
	return nil
}

func unmarshalPayload(bz []byte) (ics20.FungibleTokenPacketData, ics20.Token, error) {
	var data ics20.FungibleTokenPacketData
	if err := data.ProtoUnmarshal(bz); err != nil {
		return data, ics20.Token{}, ufmt.Errorf("decoding FungibleTokenPacketData: %v", err)
	}
	if err := data.ValidateBasic(); err != nil {
		return data, ics20.Token{}, ufmt.Errorf("invalid FungibleTokenPacketData: %v", err)
	}
	denom := ics20.ExtractDenomFromPath(data.Denom)
	token := ics20.Token{Denom: denom, Amount: data.Amount}
	return data, token, nil
}
