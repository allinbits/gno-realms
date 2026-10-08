package impl

import (
	"bytes"
	"encoding/hex"
	"time"

	"gno.land/p/aib/ibc/host/v0"
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/aib/ibc/core"
)

const maxTimeoutDelta time.Duration = 24 * time.Hour

func (l *logic) SendPacket(_ int, rlm realm, msg types.MsgSendPacket) (sequence uint64) {
	if err := msg.ValidateBasic(); err != nil {
		panic(err)
	}
	clientID := msg.SourceClient
	c := l.mustClient(clientID)
	lc := c.LightClient()
	if status := lc.Status(); status != lightclient.Active {
		panic(ufmt.Sprintf("client (%s) status is %s", clientID, status))
	}

	// Ensure counterparty has been registered
	counterpartyClientID := c.CounterpartyClientID()
	if counterpartyClientID == "" {
		panic(ufmt.Sprintf("counterparty not found for client %s", clientID))
	}

	// timeoutTimestamp must be greater than current block time and less or equal
	// to current block time + maxTimeoutDelta.
	var (
		timeout    = time.Unix(int64(msg.TimeoutTimestamp), 0)
		minTimeout = time.Now()
		maxTimeout = minTimeout.Add(maxTimeoutDelta)
	)
	if !timeout.After(minTimeout) {
		panic(ufmt.Sprintf(
			"timeout is less than or equal the current block timestamp, %d <= %d",
			msg.TimeoutTimestamp, minTimeout.Unix(),
		))
	}
	if timeout.After(maxTimeout) {
		panic(ufmt.Sprintf(
			"timeout is after the max allowed timeout, %d > %d",
			msg.TimeoutTimestamp, maxTimeout.Unix(),
		))
	}

	// check if the latest consensus timestamp is lower than timeoutTimestamp
	latestTimestamp, err := lc.TimestampAtHeight(lc.LatestHeight())
	if err != nil {
		panic(err)
	}
	if latestTimestamp >= msg.TimeoutTimestamp {
		panic(ufmt.Errorf("latest timestamp: %d, timeout timestamp: %d",
			latestTimestamp, msg.TimeoutTimestamp))
	}

	// construct packet from given fields
	sequence = c.AllocateSendSequence(0, rlm)
	packet := types.NewPacket(sequence, msg.SourceClient, counterpartyClientID, msg.TimeoutTimestamp, msg.Payloads...)
	if err := packet.ValidateBasic(); err != nil {
		panic(ufmt.Errorf("constructed packet failed basic validation: %v", err))
	}

	// set the packet commitment
	c.SetPacketCommitment(0, rlm, packet)

	// emit events
	core.EmitSendPacket(0, rlm, packet)

	// Invoke registed app OnSendPacket() for each payload.SourcePort.
	for i, payload := range msg.Payloads {
		app := l.store.Route(payload.SourcePort)
		if app.Paused {
			panic(ufmt.Sprintf("app %q is paused", payload.SourcePort))
		}
		err := app.OnSendPacket(
			cross(rlm), msg.SourceClient, counterpartyClientID, sequence, payload,
		)
		if err != nil {
			panic(ufmt.Sprintf(
				"send packet failed for payload #%d app %q: %v", i, payload.SourcePort, err,
			))
		}
	}

	return sequence
}

func (l *logic) RecvPacket(_ int, rlm realm, msg types.MsgRecvPacket) types.ResponseResultType {
	if err := msg.ValidateBasic(); err != nil {
		panic(err)
	}

	clientID := msg.Packet.DestinationClient
	c := l.mustClient(clientID)
	lc := c.LightClient()
	// check client is active
	if status := lc.Status(); status != lightclient.Active {
		panic(ufmt.Sprintf("client (%s) status is %s", clientID, status))
	}
	// check counterparty
	if c.CounterpartyClientID() != msg.Packet.SourceClient {
		panic(ufmt.Sprintf(
			"counterparty id (%s) does not match packet source id (%s)",
			c.CounterpartyClientID(), msg.Packet.SourceClient,
		))
	}
	currentTimestamp := uint64(time.Now().Unix())
	if currentTimestamp >= msg.Packet.TimeoutTimestamp {
		panic(ufmt.Sprintf(
			"current timestamp: %d, timeout timestamp: %d",
			currentTimestamp, msg.Packet.TimeoutTimestamp,
		))
	}

	// REPLAY PROTECTION: Packet receipts will indicate that a packet has already
	// been received.
	// Packet receipts must not be pruned, unless it has been marked stale by the
	// increase of the recvStartSequence. TODO check relevancy of comment
	if c.HasPacketReceipt(msg.Packet.Sequence) {
		// This error indicates that the packet has already been relayed. Core IBC
		// will treat this error as a no-op in order to prevent an entire relay
		// transaction from failing and consuming unnecessary fees.
		return types.RESPONSE_NOOP
	}

	// Verify existence of the commitment bytes in the proofs.
	var (
		key        = host.PacketCommitmentKey(msg.Packet.SourceClient, msg.Packet.Sequence)
		merklePath = types.BuildMerklePath(c.CounterpartyMerklePrefix(), key)
		value      = types.CommitPacket(msg.Packet)
	)
	if err := lc.VerifyMembership(
		msg.ProofHeight, msg.ProofCommitment, merklePath, value,
	); err != nil {
		panic(ufmt.Sprintf(
			"failed packet commitment verification for client (%s): %v",
			clientID, err,
		))
	}

	// Set Packet Receipt to prevent timeout from occurring on counterparty
	c.SetPacketReceipt(0, rlm, msg.Packet.Sequence)

	// Emit events
	core.EmitRecvPacket(0, rlm, msg.Packet)

	l.writeRecvPacketAcknowledgement(0, rlm, c, msg.Packet)

	return types.RESPONSE_SUCCESS
}

// writeRecvPacketAcknowledgement invokes the app of each payload and writes
// the resulting acknowledgement, unless the app answers asynchronously.
func (l *logic) writeRecvPacketAcknowledgement(_ int, rlm realm, c core.Client, packet types.Packet) {
	var (
		// build up the recv results for each application callback.
		ack = types.Acknowledgement{
			AppAcknowledgements: [][]byte{},
		}
		isSuccess = true
	)

	// Invoke registed app OnRecvPacket() for each payload.DestinationPort.
	//
	// Packet.ValidateBasic() guarantees exactly one payload, so the loop never
	// runs more than once. It matters: the loop breaks on the first failure
	// without reverting the callbacks that already succeeded, so with several
	// payloads the packet could commit a partial state change while being
	// acknowledged (and refunded by the counterparty) as failed. Any move to
	// multi-payload packets has to make this loop atomic first.
	for i, payload := range packet.Payloads {
		app := l.store.Route(payload.DestinationPort)
		if app.Paused {
			// Refused without reaching the app: the counterparty sees the
			// sentinel error acknowledgement and refunds its sender.
			isSuccess = false
			ack = types.Acknowledgement{
				AppAcknowledgements: [][]byte{types.UniversalErrorAcknowledgement()},
			}
			break
		}
		res := app.OnRecvPacket(
			cross(rlm), packet.SourceClient, packet.DestinationClient,
			packet.Sequence, payload,
		)
		if res.Status == types.PacketStatus_Failure {
			isSuccess = false
			// construct acknowledgement with single app acknowledgement that is the
			// sentinel error acknowledgement
			ack = types.Acknowledgement{
				AppAcknowledgements: [][]byte{types.UniversalErrorAcknowledgement()},
			}
			break
		}
		if res.Status == types.PacketStatus_Async {
			if len(packet.Payloads) > 1 {
				panic("async ack not supported for multi-payload packets")
			}
			c.SavePendingAsyncAck(0, rlm, packet, app.PkgPath)
			return
		}

		// successful app acknowledgement cannot equal sentinel error
		// acknowledgement
		if bytes.Equal(res.Acknowledgement, types.UniversalErrorAcknowledgement()) {
			panic(ufmt.Sprintf(
				"callback error for payload #%d app %q: application acknowledgement cannot be sentinel error acknowledgement",
				i, payload.DestinationPort,
			))
		}

		// append app acknowledgement to the overall acknowledgement
		ack.AppAcknowledgements = append(ack.AppAcknowledgements, res.Acknowledgement)
	}

	// Sanity check to ensure returned acknowledgement and calculated isSuccess
	// boolean matches
	if ack.Success() != isSuccess {
		panic("acknowledgement success flag mismatch")
	}
	if err := ack.Validate(); err != nil {
		panic(err)
	}
	// set the acknowledgement so that it can be verified on the other side
	c.SetPacketAcknowledgement(0, rlm, packet.Sequence, types.CommitAcknowledgement(ack))
	core.EmitWriteAck(0, rlm, packet, ack)
}

func (l *logic) WriteAcknowledgement(_ int, rlm realm, clientID string, sequence uint64, ack types.Acknowledgement) {
	c := l.mustClient(clientID)

	packet, appPkgPath, found := c.PendingAsyncAck(sequence)
	if !found {
		panic(ufmt.Sprintf("no pending async ack for client=%s sequence=%d", clientID, sequence))
	}

	// rlm is the proxy's live cur, so rlm.Previous() is the proxy's caller.
	callerPath := rlm.Previous().PkgPath()
	if callerPath != appPkgPath {
		panic(ufmt.Sprintf(
			"caller %s is not authorized to write ack for sequence %d (expected %s)",
			callerPath, sequence, appPkgPath,
		))
	}

	if c.HasPacketAcknowledgement(sequence) {
		panic(ufmt.Sprintf("acknowledgement already written for sequence %d", sequence))
	}
	if err := ack.Validate(); err != nil {
		panic(err)
	}

	c.SetPacketAcknowledgement(0, rlm, sequence, types.CommitAcknowledgement(ack))
	c.DeletePendingAsyncAck(0, rlm, sequence)
	core.EmitWriteAck(0, rlm, packet, ack)
}

func (l *logic) Acknowledgement(_ int, rlm realm, msg types.MsgAcknowledgement) types.ResponseResultType {
	if err := msg.ValidateBasic(); err != nil {
		panic(err)
	}

	clientID := msg.Packet.SourceClient
	c := l.mustClient(clientID)
	lc := c.LightClient()
	// check client is active
	if status := lc.Status(); status != lightclient.Active {
		panic(ufmt.Sprintf("client (%s) status is %s", clientID, status))
	}
	// check counterparty
	if c.CounterpartyClientID() != msg.Packet.DestinationClient {
		panic(ufmt.Sprintf(
			"counterparty id (%s) does not match packet destination id (%s)",
			c.CounterpartyClientID(), msg.Packet.DestinationClient,
		))
	}

	commitment := c.PacketCommitment(msg.Packet.Sequence)
	if len(commitment) == 0 {
		// This error indicates that the acknowledgement has already been relayed
		// or there is a misconfigured relayer attempting to prove an
		// acknowledgement for a packet never sent. Core IBC will treat this error
		// as a no-op in order to prevent an entire relay transaction from failing
		// and consuming unnecessary fees.
		return types.RESPONSE_NOOP
	}
	packetCommitment := types.CommitPacket(msg.Packet)
	// ensure integrity of commitment
	if !bytes.Equal(commitment, packetCommitment) {
		h1, h2 := hex.EncodeToString(packetCommitment), hex.EncodeToString(commitment)
		panic(ufmt.Sprintf(
			"commitment bytes are not equal: got (%v), expected (%v)", h1, h2,
		))
	}

	// Verify existence of the acknowledgement commitment bytes in the proofs.
	var (
		key        = host.PacketAcknowledgementKey(msg.Packet.DestinationClient, msg.Packet.Sequence)
		merklePath = types.BuildMerklePath(c.CounterpartyMerklePrefix(), key)
		value      = types.CommitAcknowledgement(msg.Acknowledgement)
	)
	if err := lc.VerifyMembership(
		msg.ProofHeight, msg.ProofAcked, merklePath, value,
	); err != nil {
		panic(ufmt.Sprintf(
			"failed packet acknowledgement verification for client (%s): %v",
			clientID, err,
		))
	}

	c.DeletePacketCommitment(0, rlm, msg.Packet.Sequence)

	core.EmitAcknowledgePacket(0, rlm, msg.Packet)

	// Invoke registed app OnAcknowledgementPacket() for each payload.SourcePort.
	recvSuccess := !bytes.Equal(msg.Acknowledgement.AppAcknowledgements[0],
		types.UniversalErrorAcknowledgement())
	for i, payload := range msg.Packet.Payloads {
		app := l.store.Route(payload.SourcePort)
		// if recv was successful, each payload should have its own acknowledgement
		// so we send each individual acknowledgment to the application otherwise,
		// the acknowledgement only contains the sentinel error acknowledgement
		// which we send to the application. The application is responsible for
		// knowing that this is an error acknowledgement and executing the
		// appropriate logic.
		var ack []byte
		if recvSuccess {
			ack = msg.Acknowledgement.AppAcknowledgements[i]
		} else {
			ack = types.UniversalErrorAcknowledgement()
		}
		err := app.OnAcknowledgementPacket(
			cross(rlm), msg.Packet.SourceClient, msg.Packet.DestinationClient,
			msg.Packet.Sequence, ack, payload,
		)
		if err != nil {
			panic(ufmt.Sprintf(
				"acknowledgement packet failed for payload #%d app %q: %v",
				i, payload.SourcePort, err,
			))
		}
	}

	return types.RESPONSE_SUCCESS
}

func (l *logic) Timeout(_ int, rlm realm, msg types.MsgTimeout) types.ResponseResultType {
	if err := msg.ValidateBasic(); err != nil {
		panic(err)
	}

	clientID := msg.Packet.SourceClient
	c := l.mustClient(clientID)
	lc := c.LightClient()
	// check client is active
	if status := lc.Status(); status != lightclient.Active {
		panic(ufmt.Sprintf("client (%s) status is %s", clientID, status))
	}
	// check counterparty
	if c.CounterpartyClientID() != msg.Packet.DestinationClient {
		panic(ufmt.Sprintf(
			"counterparty id (%s) does not match packet destination id (%s)",
			c.CounterpartyClientID(), msg.Packet.DestinationClient,
		))
	}
	// check that timeout timestamp has passed on the other end
	proofTimestamp, err := lc.TimestampAtHeight(msg.ProofHeight)
	if err != nil {
		panic(err)
	}
	if proofTimestamp < msg.Packet.TimeoutTimestamp {
		panic(ufmt.Errorf("proof timestamp: %d, timeout timestamp: %d",
			proofTimestamp, msg.Packet.TimeoutTimestamp))
	}

	commitment := c.PacketCommitment(msg.Packet.Sequence)
	if len(commitment) == 0 {
		// This error indicates that the timeout has already been relayed or there
		// is a misconfigured relayer attempting to prove a timeout for a packet
		// never sent. Core IBC will treat this error as a no-op in order to
		// prevent an entire relay transaction from failing and consuming
		// unnecessary fees.
		return types.RESPONSE_NOOP
	}
	packetCommitment := types.CommitPacket(msg.Packet)
	// ensure integrity of commitment
	if !bytes.Equal(commitment, packetCommitment) {
		h1, h2 := hex.EncodeToString(packetCommitment), hex.EncodeToString(commitment)
		panic(ufmt.Sprintf(
			"commitment bytes are not equal: got (%v), expected (%v)", h1, h2,
		))
	}

	// Verify packet receipt absence
	var (
		key        = host.PacketReceiptKey(msg.Packet.DestinationClient, msg.Packet.Sequence)
		merklePath = types.BuildMerklePath(c.CounterpartyMerklePrefix(), key)
	)
	if err := lc.VerifyNonMembership(
		msg.ProofHeight, msg.ProofUnreceived, merklePath,
	); err != nil {
		panic(ufmt.Sprintf(
			"failed packet receipt absence verification for client (%s): %v",
			clientID, err,
		))
	}

	c.DeletePacketCommitment(0, rlm, msg.Packet.Sequence)

	core.EmitTimeoutPacket(0, rlm, msg.Packet)

	for i, payload := range msg.Packet.Payloads {
		app := l.store.Route(payload.SourcePort)
		err := app.OnTimeoutPacket(
			cross(rlm), msg.Packet.SourceClient, msg.Packet.DestinationClient,
			msg.Packet.Sequence, payload,
		)
		if err != nil {
			panic(ufmt.Sprintf(
				"timeout packet failed for payload #%d app %q: %v",
				i, payload.SourcePort, err,
			))
		}
	}

	return types.RESPONSE_SUCCESS
}
