package e2e

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/cosmos/gogoproto/proto"

	"github.com/cosmos/cosmos-sdk/codec"
	codectypes "github.com/cosmos/cosmos-sdk/codec/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	txtypes "github.com/cosmos/cosmos-sdk/types/tx"
	transfertypes "github.com/cosmos/ibc-go/v10/modules/apps/transfer/types"
	channeltypesv2 "github.com/cosmos/ibc-go/v10/modules/core/04-channel/v2/types"
)

// signAndBroadcastGnoCall executes a gnokey maketx call inside the gno container.
func (s *E2ETestSuite) signAndBroadcastGnoCall(keyName, pkgPath, funcName, sendCoins string, args ...string) {
	cmdArgs := []string{
		"gnokey", "maketx", "call",
		"-pkgpath", pkgPath,
		"-func", funcName,
		"-gas-fee", "1000000ugnot",
		"-gas-wanted", "90000000",
		"-broadcast",
		"-chainid", s.cfg.GnoChainID,
		"-remote", "localhost:26657",
		"-insecure-password-stdin",
	}
	if sendCoins != "" {
		cmdArgs = append(cmdArgs, "-send", sendCoins)
	}
	for _, arg := range args {
		cmdArgs = append(cmdArgs, "-args", arg)
	}
	cmdArgs = append(cmdArgs, keyName)

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	stdout, stderr, err := dockerExecStdin(ctx, s.gnoContainer, "\n", cmdArgs...)
	s.Require().NoError(err, "gnokey maketx call: stdout=%s stderr=%s", stdout, stderr)
}

// signAndBroadcastAtomOneTx signs and broadcasts messages on the AtomOne chain.
// It retries on account sequence mismatch (the relayer shares the same account).
// It returns the tx hash.
func (s *E2ETestSuite) signAndBroadcastAtomOneTx(msgs ...proto.Message) string {
	unsignedTx := buildUnsignedTx(msgs, channeltypesv2.RegisterInterfaces)

	ctx := context.Background()

	// Write unsigned tx to container
	_, stderr, err := dockerExecStdin(ctx, s.atomoneContainer, unsignedTx,
		"bash", "-c", "cat > /tmp/unsigned_tx.json")
	s.Require().NoError(err, "write unsigned tx: %s", stderr)

	// Retry sign+broadcast on sequence mismatch (relayer may race with us)
	const maxRetries = 5
	for attempt := range maxRetries {
		txHash, err := s.trySignAndBroadcast(ctx)
		if err == nil {
			return txHash
		}
		if !strings.Contains(err.Error(), "account sequence mismatch") {
			s.Require().NoError(err, "tx failed")
		}
		s.T().Logf("Sequence mismatch (attempt %d/%d), retrying...", attempt+1, maxRetries)
		time.Sleep(time.Second)
	}
	s.Require().Fail("tx failed after retries: account sequence mismatch")
	return ""
}

func (s *E2ETestSuite) trySignAndBroadcast(ctx context.Context) (string, error) {
	// Sign
	signCtx, signCancel := context.WithTimeout(ctx, 30*time.Second)
	defer signCancel()
	_, stderr, err := dockerExec(signCtx, s.atomoneContainer,
		"atomoned", "tx", "sign", "/tmp/unsigned_tx.json",
		"--from", "validator",
		"--chain-id", s.cfg.AtomoneChainID,
		"--keyring-backend", "test",
		"--home", "/root/.atomone",
		"--node", "tcp://localhost:26657",
		"--output-document", "/tmp/signed_tx.json",
	)
	if err != nil {
		return "", fmt.Errorf("sign tx: %s", stderr)
	}

	// Broadcast
	bcastCtx, bcastCancel := context.WithTimeout(ctx, 30*time.Second)
	defer bcastCancel()
	stdout, stderr, err := dockerExec(bcastCtx, s.atomoneContainer,
		"atomoned", "tx", "broadcast", "/tmp/signed_tx.json",
		"--node", "tcp://localhost:26657",
		"--output", "json",
	)
	if err != nil {
		return "", fmt.Errorf("broadcast tx: %s", stderr)
	}

	var txResult struct {
		Code   int    `json:"code"`
		TxHash string `json:"txhash"`
		RawLog string `json:"raw_log"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(stdout)), &txResult); err != nil {
		return "", fmt.Errorf("parse broadcast result: %w", err)
	}
	if txResult.Code != 0 {
		return "", fmt.Errorf("%s", txResult.RawLog)
	}
	return txResult.TxHash, nil
}

// buildMsgSendPacket creates a MsgSendPacket for an IBC v2 token transfer.
func buildMsgSendPacket(sourceClient, sender, receiver, denom, amount string, timeoutTimestamp int64) *channeltypesv2.MsgSendPacket {
	packetData := transfertypes.NewFungibleTokenPacketData(denom, amount, sender, receiver, "")
	bz, err := proto.Marshal(&packetData)
	if err != nil {
		panic(fmt.Sprintf("marshal FungibleTokenPacketData: %v", err))
	}

	payload := channeltypesv2.NewPayload(
		transfertypes.PortID, transfertypes.PortID,
		transfertypes.V1, transfertypes.EncodingProtobuf, bz,
	)
	return channeltypesv2.NewMsgSendPacket(
		sourceClient, uint64(timeoutTimestamp), sender, payload,
	)
}

// buildUnsignedTx wraps messages into an unsigned Cosmos SDK Tx and returns its JSON representation.
func buildUnsignedTx(msgs []proto.Message, registerInterfaces ...func(codectypes.InterfaceRegistry)) string {
	ir := codectypes.NewInterfaceRegistry()
	for _, register := range registerInterfaces {
		register(ir)
	}
	cdc := codec.NewProtoCodec(ir)

	anyMsgs := make([]*codectypes.Any, len(msgs))
	for i, msg := range msgs {
		anyMsg, err := codectypes.NewAnyWithValue(msg)
		if err != nil {
			panic(fmt.Sprintf("pack message: %v", err))
		}
		anyMsgs[i] = anyMsg
	}

	tx := txtypes.Tx{
		Body: &txtypes.TxBody{
			Messages: anyMsgs,
		},
		AuthInfo: &txtypes.AuthInfo{
			Fee: &txtypes.Fee{
				Amount:   sdk.NewCoins(sdk.NewInt64Coin("uphoton", 10000)),
				GasLimit: 300000,
			},
		},
		Signatures: [][]byte{},
	}

	txJSON, err := cdc.MarshalJSON(&tx)
	if err != nil {
		panic(fmt.Sprintf("marshal tx: %v", err))
	}
	return string(txJSON)
}
