package transfer

import (
	"bytes"
	"chain"
	"chain/banker"
	"chain/runtime"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"

	"gno.land/p/aib/ibc/app"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/nt/ufmt"
	"gno.land/r/aib/ibc/core"
)

type App struct{}

const (
	// NOTE we must use the same portID as the ibc-go transfer IBC app
	PortID = "transfer"
	// V1 defines first version of the IBC transfer module
	V1               = "ics20-1"
	EncodingProtobuf = "application/x-protobuf"

	denomPrefix          = "ibc"
	escrowAddressVersion = V1
)

func init() {
	// Register the app in the IBC router.
	core.RegisterApp(cross, PortID, &App{})
}

var _ app.IBCApp = &App{}

// Implements app.IBCApp
func (a *App) OnSendPacket(
	_ realm,
	banker banker.Banker,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	payload types.Payload,
) error {
	// TODO add parameter to disable the app
	// TODO add parameter to block sender addr

	// Enforce that the source and destination portIDs are the same and equal to
	// the transfer portID.
	// Enforce that the source and destination clientIDs are also in the clientID
	// format that transfer expects: {clientid}-{sequence}.
	// This is necessary for IBC v2 since the portIDs (and thus the
	// application-application connection) is not prenegotiated by the channel
	// handshake.
	// This restriction can be removed in a future where the trace hop on receive
	// commits to **both** the source and destination portIDs rather than just
	// the destination port.
	if payload.SourcePort != PortID || payload.DestinationPort != PortID {
		return ufmt.Errorf("payload port ID is invalid: expected %s, got sourcePort: %s destPort: %s", PortID, payload.SourcePort, payload.DestinationPort)
	}
	if !types.IsValidClientID(sourceClient) || !types.IsValidClientID(destinationClient) {
		return ufmt.Errorf("client IDs must be in valid format: {string}-{number}")
	}
	if payload.Version != V1 {
		return ufmt.Errorf("invalid ICS20 version: expected %s, got %s", V1, payload.Version)
	}
	if payload.Encoding != EncodingProtobuf {
		return ufmt.Errorf("invalid encoding: expected %s, got %s", EncodingProtobuf, payload.Encoding)
	}

	data, token, err := unmarshalPayload(payload.Value)
	if err != nil {
		return err
	}

	signer := runtime.OriginCaller().String()
	if data.Sender != signer {
		return ufmt.Errorf("invalid FungibleTokenPacketData: sender %s is different from signer %s", data.Sender, signer)
	}

	// TODO review comment: maybe not relevant in a pure IBCv2 impl.
	//
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
	if strings.Contains(token.Denom.Base, "/") {
		return ufmt.Errorf("base denomination %s cannot contain slashes for IBC v2 packet", token.Denom.Base)
	}

	if err := escrowCoin(banker, token); err != nil {
		return err
	}

	// Emit events
	chain.Emit(EventTypeTransfer,
		AttributeKeySender, data.Sender,
		AttributeKeyReceiver, data.Receiver,
		AttributeKeyDenom, token.Denom.Path(),
		AttributeKeyAmount, token.Amount,
		AttributeKeyMemo, data.Memo,
	)
	return nil
}

// Implements app.IBCApp
func (a *App) OnRecvPacket(
	_ realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	payload types.Payload,
) types.RecvPacketResult {
	// TODO add parameter to disable the app
	// TODO add parameter to block receiver addr

	// Enforce that the source and destination portIDs are the same and equal to
	// the transfer portID.
	// Enforce that the source and destination clientIDs are also in the clientID
	// format that transfer expects: {clientid}-{sequence}.
	// This is necessary for IBC v2 since the portIDs (and thus the
	// application-application connection) is not prenegotiated by the channel
	// handshake.
	// This restriction can be removed in a future where the trace hop on receive
	// commits to **both** the source and destination portIDs rather than just
	// the destination port.
	if payload.SourcePort != PortID || payload.DestinationPort != PortID {
		return types.RecvPacketResult{Status: types.PacketStatus_Failure}
	}
	if !types.IsValidClientID(sourceClient) || !types.IsValidClientID(destinationClient) {
		return types.RecvPacketResult{Status: types.PacketStatus_Failure}
	}
	if payload.Version != V1 {
		return types.RecvPacketResult{Status: types.PacketStatus_Failure}
	}
	if payload.Encoding != EncodingProtobuf {
		return types.RecvPacketResult{Status: types.PacketStatus_Failure}
	}

	var (
		data       FungibleTokenPacketData
		token      Token
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
			AttributeKeySender, data.Sender,
			AttributeKeyReceiver, data.Receiver,
			AttributeKeyDenom, token.Denom.Path(),
			AttributeKeyAmount, token.Amount,
			AttributeKeyMemo, data.Memo,
			AttributeKeyAckSuccess, strconv.FormatBool(ack.Success()),
		}
		if ackErr != nil {
			attrs = append(attrs,
				[]string{AttributeKeyAckError, ackErr.Error()}...,
			)
		}
		chain.Emit(EventTypePacket, attrs...)
	}()

	data, token, ackErr = unmarshalPayload(payload.Value)
	if ackErr != nil {
		ack = types.NewErrorAppAcknowledgement(ackErr)
		return types.RecvPacketResult{Status: types.PacketStatus_Failure}
	}
	// This is the prefix that would have been prefixed to the denomination
	// on sender chain IF and only if the token originally came from the
	// receiving chain.
	//
	// NOTE: We use SourcePort and SourceChannel here, because the counterparty
	// chain would have prefixed with DestPort and DestChannel when originally
	// receiving this token.
	if token.Denom.HasPrefix(payload.SourcePort, sourceClient) {
		panic("TODO handle when token is an IBC denom")
	} else {
		// sender chain is the source, mint vouchers

		// since SendPacket did not prefix the denomination, we must add the destination port and channel to the trace
		trace := []Hop{NewHop(payload.DestinationPort, destinationClient)}
		token.Denom.Trace = append(trace, token.Denom.Trace...)

		voucherDenom := token.Denom.IBCDenom()
		if !hasDenomMetadata(voucherDenom) {
			setDenomMetadata(voucherDenom, token.Denom)
		}

		chain.Emit(EventTypeDenom,
			AttributeKeyDenomHash, hex.EncodeToString(token.Denom.Hash()),
			AttributeKeyDenom, string(token.Denom.MarshalJSON()),
		)

		// mint new tokens if the source of the transfer is the same chain
		banker := banker.NewBanker(banker.BankerTypeRealmIssue)
		realmAddr := runtime.CurrentRealm().Address()
		var amount int64
		amount, ackErr = strconv.ParseInt(token.Amount, 10, 64)
		if ackErr != nil {
			ack = types.NewErrorAppAcknowledgement(ackErr)
			return types.RecvPacketResult{Status: types.PacketStatus_Failure}
		}
		banker.IssueCoin(realmAddr, voucherDenom, amount)

		// send to receiver
		banker.SendCoins(realmAddr, address(data.Receiver), chain.Coins{{
			Denom:  voucherDenom,
			Amount: amount,
		}})
	}

	return recvResult
}

// OnAcknowledgementPacket responds to the success or failure of a packet
// acknowledgment written on the receiving chain.
//
// If the acknowledgement was a success then nothing occurs. Otherwise,
// if the acknowledgement failed, then the sender is refunded their tokens.
// Implements app.IBCApp
func (a *App) OnAcknowledgementPacket(
	_ realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	acknowledgement []byte,
	payload types.Payload,
) error {
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
		if err := unescrowCoin(data.Sender, token); err != nil {
			return err
		}
	}

	// Emit events
	chain.Emit(EventTypePacket,
		AttributeKeySender, data.Sender,
		AttributeKeyReceiver, data.Receiver,
		AttributeKeyDenom, token.Denom.Path(),
		AttributeKeyAmount, token.Amount,
		AttributeKeyMemo, data.Memo,
		AttributeKeyAck, string(acknowledgement),
	)
	if ack.Success() {
		chain.Emit(EventTypePacket,
			AttributeKeyAckSuccess, string(ack.Response.Result),
		)
	} else {
		chain.Emit(EventTypePacket,
			AttributeKeyAckError, ack.Response.Error,
		)
	}
	return nil
}

// OnTimeoutPacket processes a transfer packet timeout by refunding the tokens
// to the sender
// Implements app.IBCApp
func (a *App) OnTimeoutPacket(
	_ realm,
	sourceClient string,
	destinationClient string,
	sequence uint64,
	payload types.Payload,
) error {

	data, token, err := unmarshalPayload(payload.Value)
	if err != nil {
		return err
	}
	if err := unescrowCoin(data.Sender, token); err != nil {
		return err
	}

	// Emit events
	chain.Emit(EventTypeTimeout,
		AttributeKeyReceiver, data.Sender,
		AttributeKeyDenom, token.Denom.Path(),
		AttributeKeyAmount, token.Amount,
		AttributeKeyMemo, data.Memo,
	)
	return nil
}

func unmarshalPayload(bz []byte) (FungibleTokenPacketData, Token, error) {
	var data FungibleTokenPacketData
	if err := data.ProtoUnmarshal(bz); err != nil {
		return data, Token{}, ufmt.Errorf("decoding FungibleTokenPacketData: %v", err)
	}
	if err := data.ValidateBasic(); err != nil {
		return data, Token{}, ufmt.Errorf("invalid FungibleTokenPacketData: %v", err)
	}
	denom := ExtractDenomFromPath(data.Denom)
	token := Token{Denom: denom, Amount: data.Amount}
	return data, token, nil
}
