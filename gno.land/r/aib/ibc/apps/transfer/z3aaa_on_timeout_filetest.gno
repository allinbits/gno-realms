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

// OnTimeout: success w/ non-IBC GRC20 token
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

	signer := runtime.CurrentRealm().Address()

	// Mint GRC20 tokens to signer and approve transfer app
	grc20test.Mint(cross, signer, 1000)
	transferAppAddr := chain.PackageAddress("gno.land/r/aib/ibc/apps/transfer")
	grc20test.Approve(cross, signer, transferAppAddr, 100)

	// Step 1: Transfer to escrow GRC20 tokens (chain A → chain B)
	grc20regKey := "gno.land/r/aib/ibc/apps/testing/grc20test." + grc20test.Slug
	testing.SetOriginCaller(signer)
	println("signer grc20 balance before Transfer:", grc20test.BalanceOf(signer))
	sendPacket, sequence := transfer.TransferGRC20(cross, clientID, "atone1user", grc20regKey, 100, uint64(time.Now().Add(10*time.Minute).Unix()))
	println("\nsigner grc20 balance after Transfer:", grc20test.BalanceOf(signer))

	// Change block time to after the timeout
	ctx := testing.GetContext()
	ctx.Time = time.Now().Add(12 * time.Minute)
	testing.SetContext(ctx)
	// Update client with a block created after the timeout
	apphash, _ = hex.DecodeString("82ea91f259352674360c621c4b0a1975cc076e3792b6d22a8bfbe8e7f7d0d2d7")
	trustedHeight = clientState.LatestHeight
	specs := ics23.IavlSpec()
	var (
		commitTimestamp = tmtesting.ToTime("2025-09-25T07:55:57.306746166Z")
		newHeight       = uint64(12)
		newTimestamp    = consensusState.Timestamp.Add(time.Minute * time.Duration(12))
		valset          = tendermint.NewValset(val1, val2)
		nextValset      = tendermint.NewValset(val1, val2)

		signatures = []tendermint.CommitSig{
			{
				BlockIDFlag:      tendermint.BlockIDFlagCommit,
				ValidatorAddress: valset.Validators[0].Address,
				Timestamp:        commitTimestamp,
				Signature:        []byte("\x7a\xa8\x84\xac\xac\x99\x9b\xd8\x07\xd4\x8d\xb1\x0b\x58\x87\xda\x78\xa9\x76\xcf\x8f\x01\x9f\xe8\x60\xf1\xf8\x09\x73\x91\xd7\x07\x48\x62\x87\xa5\x7e\xa1\x35\xe3\x47\x08\x3d\xef\x03\x99\x02\xcf\x33\x6e\x88\x63\x06\x29\x49\x26\x9a\x67\xdd\xc2\x97\x83\xb5\x0b"),
			},
			{
				BlockIDFlag:      tendermint.BlockIDFlagCommit,
				ValidatorAddress: valset.Validators[1].Address,
				Timestamp:        commitTimestamp,
				Signature:        []byte("\x5c\x24\x40\x0c\x93\xe3\x60\x30\x40\x00\x8f\xe6\xb4\x5f\x90\x2b\x82\x82\xcd\x14\x0f\x0a\xcf\x29\xe7\xa3\x05\xf4\x23\x03\xf0\x84\x7a\x59\x46\x5e\xca\x3f\xb0\x60\xf2\xe7\xe7\x8c\x85\xb8\x2d\x32\x8e\xdc\x07\xbb\x0b\x6b\xe7\x01\x71\x1d\xa2\x94\x47\xb6\x78\x03"),
			},
		}

		msgHeader = tmtesting.NewMsgHeader(
			chainID, newTimestamp, apphash, newHeight, trustedHeight, valset,
			nextValset, trustedValset, signatures,
		)
	)
	core.UpdateClient(cross, clientID, msgHeader)

	// Timeout the packet
	// Generate the proof that no RecvPacket has been received by the counterparty chain.
	proof := []ics23.CommitmentProof{

		// iavl proof
		ics23.CommitmentProof_Nonexist{
			Nonexist: &ics23.NonExistenceProof{
				Key: []byte("\x70\x72\x65\x66\x69\x78\x32\x30\x37\x2d\x74\x65\x6e\x64\x65\x72\x6d\x69\x6e\x74\x2d\x32\x02\x00\x00\x00\x00\x00\x00\x00\x01"),
				Left: &ics23.ExistenceProof{
					Key:   []byte("\x50"),
					Value: []byte("\x50"),
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
							Prefix: []byte("\x04\x06\x02\x20"),
							Suffix: []byte("\x20\x79\x8e\x2c\xaa\x96\xfd\xfb\xa3\x76\xdd\xeb\x47\x99\x99\x54\xd2\xf4\x7e\x65\x16\x22\x64\xb0\x53\x6a\xb5\xdf\xf7\xfc\x0a\x2e\x07"),
						},
						{
							Hash:   specs.InnerSpec.Hash,
							Prefix: []byte("\x06\x0a\x02\x20\x9a\xf3\x7d\xd5\x95\xa0\x19\x08\x03\xb5\xe0\x5a\xae\xf4\x2a\xe3\xfa\xd4\x99\xe4\xfb\xe3\x7f\x7c\xd3\x1c\xad\xff\x22\xa9\xee\x74\x20"),
							Suffix: []byte(""),
						},
					},
				},
				Right: &ics23.ExistenceProof{
					Key:   []byte("\x72"),
					Value: []byte("\x72"),
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
							Prefix: []byte("\x02\x04\x02\x20"),
							Suffix: []byte("\x20\xa3\x03\x93\x0c\xa8\x83\x16\x18\xac\x7e\x4d\xdd\x10\x54\x6c\xfc\x36\x6f\xb7\x30\xd6\x63\x0c\x03\x0a\x97\x22\x6b\xbe\xfc\x69\x35"),
						},
						{
							Hash:   specs.InnerSpec.Hash,
							Prefix: []byte("\x04\x06\x02\x20\x35\xf8\xea\x80\x53\x90\xe0\x84\x85\x4f\x39\x9b\x42\xcc\xde\xae\xa3\x3a\x1d\xed\xc1\x15\x63\x8a\xc4\x8d\x06\x00\x63\x7d\xba\x1f\x20"),
							Suffix: []byte(""),
						},
						{
							Hash:   specs.InnerSpec.Hash,
							Prefix: []byte("\x06\x0a\x02\x20\x9a\xf3\x7d\xd5\x95\xa0\x19\x08\x03\xb5\xe0\x5a\xae\xf4\x2a\xe3\xfa\xd4\x99\xe4\xfb\xe3\x7f\x7c\xd3\x1c\xad\xff\x22\xa9\xee\x74\x20"),
							Suffix: []byte(""),
						},
					},
				},
			},
		},

		// rootmulti proof
		ics23.CommitmentProof_Exist{
			Exist: &ics23.ExistenceProof{
				Key:   []byte("\x69\x61\x76\x6c\x53\x74\x6f\x72\x65\x4b\x65\x79"),
				Value: []byte("\x38\x22\xf3\x2f\x21\x66\x53\x63\x29\x4f\x96\xed\xda\x15\xa7\x81\x1a\x67\x6c\x2b\xa9\xdd\xcc\xec\x46\x63\x64\xf1\x00\x69\x82\x7d"),
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

	timeoutPacket := types.MsgTimeout{
		Packet: types.Packet{
			Sequence:          sequence,
			SourceClient:      clientID,
			DestinationClient: counterpartyID,
			TimeoutTimestamp:  sendPacket.TimeoutTimestamp,
			Payloads:          sendPacket.Payloads,
		},
		ProofUnreceived: proof,
		ProofHeight:     msgHeader.GetHeight(),
	}

	res := core.Timeout(cross, timeoutPacket)

	println("\ntimeout res:", res)
	println("\nsigner grc20 balance after Timeout:", grc20test.BalanceOf(signer))
}

// Output:
// signer grc20 balance before Transfer: 1000
//
// signer grc20 balance after Transfer: 900
//
// timeout res: (2 gno.land/p/aib/ibc/types.ResponseResultType)
//
// signer grc20 balance after Timeout: 1000
