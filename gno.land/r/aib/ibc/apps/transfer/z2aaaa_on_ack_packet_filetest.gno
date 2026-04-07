package main

import (
	"chain"
	"chain/runtime"
	"encoding/hex"
	"testing"
	"time"

	"gno.land/p/aib/ibc/lightclient/tendermint"
	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	"gno.land/r/aib/ibc/apps/testing/grc20test"
	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
)

// OnAcknowledgementPacket: success w/ refund of non-IBC GRC20 token
func main() {
	var (
		chainID       = "chain-id-2"
		trustedHeight = types.NewHeight(2, 2)
		clientState   = tmtesting.NewClientState(chainID, trustedHeight)
		apphash, _    = hex.DecodeString("ec53f57875853302c68a69e9b5c1353a16dbce77cdf7ec564301ddb0be0d9ec5")
		// priv=8a6cAbQSpDbebmcTEhCMPhhr/SkL/2pizo60yzHRkN9Uyk7RHOZm7g4xW+yeJh147/Z4/6HXF6gBwcFNkLsZ/A==
		val1 = tendermint.NewValidator("9DIBYr64rywKO3Kk6+743xDHcEU=",
			"VMpO0RzmZu4OMVvsniYdeO/2eP+h1xeoAcHBTZC7Gfw=", 10)
		// priv=nWg6ETc62tyxd94lh8fFaQnZKaAW6vlS0L/4lfseJuI14ZXUKp7AZROkflLFVF+SBg4wJVfzgzIKyWq3D066+g==
		val2 = tendermint.NewValidator("y+naL3ubs9q1bXrY9+uRxY9c+J8=",
			"NeGV1CqewGUTpH5SxVRfkgYOMCVX84MyCslqtw9Ouvo=", 10)
		trustedValset  = tendermint.NewValset(val1, val2)
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
		counterpartyID = "07-tendermint-2"
	)
	clientID := core.CreateClient(cross, clientState, consensusState)
	core.RegisterCounterparty(cross, clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, counterpartyID)
	relayer := runtime.OriginCaller()

	signer := runtime.CurrentRealm().Address()

	// Mint GRC20 tokens to signer and approve transfer app
	grc20test.Mint(cross, signer, 1000)
	transferAppAddr := chain.PackageAddress("gno.land/r/aib/ibc/apps/transfer")
	grc20test.Approve(cross, signer, transferAppAddr, 100)

	// Step 1: Transfer to escrow GRC20 tokens (chain A → chain B)
	grc20regKey := "gno.land/r/aib/ibc/apps/testing/grc20test." + grc20test.Slug
	testing.SetOriginCaller(signer)
	println("signer grc20 balance before Transfer:", grc20test.BalanceOf(signer))
	sendPacket, sequence := transfer.Transfer(cross, clientID, "atone1user", grc20regKey, 100, uint64(time.Now().Add(time.Hour).Unix()), "")
	println("\nsigner grc20 balance after Transfer:", grc20test.BalanceOf(signer))

	// UpdateClient to advance to height containing the ack proof
	testing.SetOriginCaller(relayer)
	apphash, _ = hex.DecodeString("7437e69c1edb7f177fb5fe9f6487f0dd0e2391d6f435d152a97110fb98b6df00")
	trustedHeight = clientState.LatestHeight
	specs := ics23.IavlSpec()
	var (
		commitTimestamp = tmtesting.ToTime("2025-09-25T07:55:57.306746166Z")
		newHeight       = uint64(12)
		newTimestamp    = consensusState.Timestamp.Add(time.Minute * time.Duration(1))
		valset          = tendermint.NewValset(val1, val2)
		nextValset      = tendermint.NewValset(val1, val2)

		signatures = []tendermint.CommitSig{
			{
				BlockIDFlag:      tendermint.BlockIDFlagCommit,
				ValidatorAddress: valset.Validators[0].Address,
				Timestamp:        commitTimestamp,
				Signature:        []byte("\xf1\xa4\xfd\xf3\xb1\x3b\x70\xfd\xbf\x01\x07\x7f\x0e\x4c\x46\xdc\x97\xd4\x19\xa8\x6f\x7e\x60\x94\x3a\xa9\x2a\x51\xd8\x8e\x51\x0a\xbe\x46\x13\xe3\x70\x6b\xcd\x42\x6e\x57\x41\xaa\x46\x47\xe6\x7c\xf3\xee\xa9\x99\x7e\x6c\x58\xe6\x40\xb0\x8d\xc8\x8f\xaa\x2a\x0c"),
			},
			{
				BlockIDFlag:      tendermint.BlockIDFlagCommit,
				ValidatorAddress: valset.Validators[1].Address,
				Timestamp:        commitTimestamp,
				Signature:        []byte("\xe2\x34\xcd\xf6\x6f\xbd\x35\xf8\xd0\x74\x14\xb6\x52\x27\xc8\x66\x48\x9c\xc3\x1c\x0e\xa7\xac\xab\xd9\x9a\x89\xae\x5c\x57\xa7\x1a\x36\x94\xce\x4f\x79\xdd\xd4\x28\xb2\x60\xc0\x50\x56\x27\xfd\x30\x36\x54\xe7\x03\x9d\x82\xdc\x59\x7e\xe2\x72\xd6\x9c\x3e\x57\x02"),
			},
		}

		msgHeader = tmtesting.NewMsgHeader(
			chainID, newTimestamp, apphash, newHeight, trustedHeight, valset,
			nextValset, trustedValset, signatures,
		)
	)
	core.UpdateClient(cross, clientID, msgHeader)

	// Acknowledge the packet with UNIVERSAL_ERROR_ACKNOWLEDGEMENT (triggers refund)
	proofAcked := []ics23.CommitmentProof{

		// iavl proof
		ics23.CommitmentProof_Exist{
			Exist: &ics23.ExistenceProof{
				Key:   []byte("\x70\x72\x65\x66\x69\x78\x32\x30\x37\x2d\x74\x65\x6e\x64\x65\x72\x6d\x69\x6e\x74\x2d\x32\x03\x00\x00\x00\x00\x00\x00\x00\x01"),
				Value: []byte("\xe2\xfb\x30\xdf\xbf\x7a\xbd\xea\xca\x82\xd4\x26\x53\x4d\x2b\x3a\x9d\x54\x44\xdd\x2a\x87\xfa\x16\xd3\x8b\x77\xba\x1a\x13\xce\xd7"),
				Leaf: &ics23.LeafOp{
					Hash:         specs.LeafSpec.Hash,
					PrehashKey:   specs.LeafSpec.PrehashKey,
					PrehashValue: specs.LeafSpec.PrehashValue,
					Length:       specs.LeafSpec.Length,
					Prefix:       []byte("\x00\x02\x02"),
				},
				Path: []*ics23.InnerOp{
					{
						Hash:   specs.InnerSpec.Hash,
						Prefix: []byte("\x02\x04\x02\x20\x35\xf8\xea\x80\x53\x90\xe0\x84\x85\x4f\x39\x9b\x42\xcc\xde\xae\xa3\x3a\x1d\xed\xc1\x15\x63\x8a\xc4\x8d\x06\x00\x63\x7d\xba\x1f\x20"),
						Suffix: []byte(""),
					},
					{
						Hash:   specs.InnerSpec.Hash,
						Prefix: []byte("\x04\x08\x02\x20"),
						Suffix: []byte("\x20\x79\x8e\x2c\xaa\x96\xfd\xfb\xa3\x76\xdd\xeb\x47\x99\x99\x54\xd2\xf4\x7e\x65\x16\x22\x64\xb0\x53\x6a\xb5\xdf\xf7\xfc\x0a\x2e\x07"),
					},
					{
						Hash:   specs.InnerSpec.Hash,
						Prefix: []byte("\x06\x0c\x02\x20\x9a\xf3\x7d\xd5\x95\xa0\x19\x08\x03\xb5\xe0\x5a\xae\xf4\x2a\xe3\xfa\xd4\x99\xe4\xfb\xe3\x7f\x7c\xd3\x1c\xad\xff\x22\xa9\xee\x74\x20"),
						Suffix: []byte(""),
					},
				},
			},
		},

		// rootmulti proof
		ics23.CommitmentProof_Exist{
			Exist: &ics23.ExistenceProof{
				Key:   []byte("\x69\x61\x76\x6c\x53\x74\x6f\x72\x65\x4b\x65\x79"),
				Value: []byte("\x9f\xf9\x57\xaa\x46\x80\xd4\xd6\x83\xff\x0e\x6f\x4c\x78\xd3\x11\xb7\x2b\x2e\xba\x18\x60\x13\x05\x16\x19\x49\xaf\xb7\xbe\x3e\x7b"),
				Leaf: &ics23.LeafOp{
					Hash:         specs.LeafSpec.Hash,
					PrehashKey:   specs.LeafSpec.PrehashKey,
					PrehashValue: specs.LeafSpec.PrehashValue,
					Length:       specs.LeafSpec.Length,
					Prefix:       []byte("\x00"),
				},
				Path: []*ics23.InnerOp{},
			},
		},
	}

	ackPacket := types.MsgAcknowledgement{
		Packet: types.Packet{
			Sequence:          sequence,
			SourceClient:      clientID,
			DestinationClient: counterpartyID,
			TimeoutTimestamp:  sendPacket.TimeoutTimestamp,
			Payloads:          sendPacket.Payloads,
		},
		Acknowledgement: types.Acknowledgement{
			// This UNIVERSAL_ERROR_ACKNOWLEDGEMENT error should trigger a refund
			AppAcknowledgements: [][]byte{types.UniversalErrorAcknowledgement()},
		},
		ProofAcked:  proofAcked,
		ProofHeight: msgHeader.GetHeight(),
	}

	res := core.Acknowledgement(cross, ackPacket)

	println("\nack res:", res)
	println("\nsigner grc20 balance after Acknowledgement:", grc20test.BalanceOf(signer))
}

// Output:
// signer grc20 balance before Transfer: 1000
//
// signer grc20 balance after Transfer: 900
//
// ack res: (2 gno.land/p/aib/ibc/types.ResponseResultType)
//
// signer grc20 balance after Acknowledgement: 1000
