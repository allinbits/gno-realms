// PKGPATH: gno.land/r/aib/main
package main

import (
	"encoding/base64"
	"encoding/hex"
	"time"

	"gno.land/p/aib/ibc/ics20/abi/v0"
	"gno.land/p/aib/ibc/ics20/v0"
	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/aib/ics23/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	_ "gno.land/r/aib/ibc/apps/transfer/impl/v1"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

// OnRecvPacket: success with an ABI-encoded payload, as sent by the Solidity
// ICS20 application of solidity-ibc-eureka
func main(cur realm) {
	var (
		chainID       = "chain-id-2"
		trustedHeight = types.NewHeight(2, 2)
		clientState   = tmtesting.NewClientState(chainID, trustedHeight)
		// NOTE this apphash was provided by the gen-proof command below.
		apphash, _     = hex.DecodeString("8c42f512199daef386158b46b56e1998c31f82b7abfb91d49ae98ade8d44d9b0")
		trustedValset  = tmtesting.GenValset()
		consensusState = tmtesting.GenConsensusState(time.Now(), apphash, trustedValset.Hash())
		counterpartyID = "07-tendermint-42"
	)
	clientID := core.CreateClient(cross(cur), clientState, consensusState)
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, counterpartyID)

	receiver := testutils.TestAddress("receiver")
	payload := ics20.NewFungibleTokenPacketData("0x457df1a9866af7b6a78eeba9291fc3e58b4d864b", "100",
		"0x5f67a5398d91087d1b37a8a43436196a7830867f", receiver.String(), "")
	payloadBz, err := abi.Marshal(payload)
	if err != nil {
		panic(err)
	}
	// NOTE this base64 value is used in payload.value in the gen-proof command below.
	println("Payload abi:", base64.StdEncoding.EncodeToString(payloadBz))

	specs := ics23.IavlSpec()
	proof := []ics23.CommitmentProof{

		// iavl proof
		ics23.CommitmentProof_Exist{
			Exist: &ics23.ExistenceProof{
				Key:   []byte("\x70\x72\x65\x66\x69\x78\x32\x30\x37\x2d\x74\x65\x6e\x64\x65\x72\x6d\x69\x6e\x74\x2d\x34\x32\x01\x00\x00\x00\x00\x00\x00\x00\x01"),
				Value: []byte("\xe0\x4f\x24\x5d\x6f\xd2\xbb\x8f\xfd\xbf\xb7\x77\x7f\x0d\xf7\x2d\xf5\xcc\x34\xba\xbe\x60\xbd\x0b\x97\x58\x29\xcd\xfa\x91\xfc\x45"),
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
				Value: []byte("\x20\x89\x37\x8c\xcd\x9d\xcb\x6e\x28\xe4\xd3\xca\x7d\xea\x50\x53\x71\xb6\x10\xbb\xb2\xb4\x18\xf3\xd7\x7f\x06\x15\xfe\x03\xdf\xd6"),
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

	recvPacket := types.MsgRecvPacket{
		Packet: types.Packet{
			Sequence:          1,
			SourceClient:      counterpartyID,
			DestinationClient: clientID,
			TimeoutTimestamp:  uint64(time.Now().Add(time.Hour).Unix()),
			Payloads: []types.Payload{{
				SourcePort:      transfer.PortID,
				DestinationPort: transfer.PortID,
				Encoding:        abi.Encoding,
				Value:           payloadBz,
				Version:         transfer.V1,
			}},
		},
		ProofCommitment: proof,
		ProofHeight:     trustedHeight,
	}
	voucherDenom := ics20.NewDenom("0x457df1a9866af7b6a78eeba9291fc3e58b4d864b", ics20.NewHop(transfer.PortID, clientID)).IBCDenom()
	println("receiver voucher balance before RecvPacket:", transfer.VoucherBalanceOf(voucherDenom, receiver))

	res := core.RecvPacket(cross(cur), recvPacket)

	println("ack res:", res)
	println("receiver voucher balance after RecvPacket:", transfer.VoucherBalanceOf(voucherDenom, receiver))
}

// Output:
// Payload abi: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAWAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACoweDQ1N2RmMWE5ODY2YWY3YjZhNzhlZWJhOTI5MWZjM2U1OGI0ZDg2NGIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACoweDVmNjdhNTM5OGQ5MTA4N2QxYjM3YThhNDM0MzYxOTZhNzgzMDg2N2YAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAChnMXdmamt4ZXRmd2VqaHloNmx0YTA0N2g2bHRhMDQ3aDZsbG04MnlsAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
// receiver voucher balance before RecvPacket: 0
// ack res: (2 gno.land/p/aib/ibc/types/v0.ResponseResultType)
// receiver voucher balance after RecvPacket: 100
