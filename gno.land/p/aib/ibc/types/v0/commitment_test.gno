package types_test

import (
	"encoding/hex"
	"testing"

	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/urequire/v0"
)

// TestCommitPacket is primarily used to document the expected commitment output
// so that other implementations (such as the IBC Solidity) can replicate the
// same commitment output. But it is also useful to catch any changes in the commitment.
func TestCommitPacket(t *testing.T) {
	var packet types.Packet
	testCases := []struct {
		name         string
		malleate     func()
		expectedHash string
	}{
		{
			"json packet",
			func() {}, // default is json packet
			"a096722aa6534040a0efbdae05765132a7b223ad306d6512f3734821bd046505",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			transferData := `{"denom":"uatom","amount":"1000000","sender":"sender","receiver":"receiver","memo":"memo"}`
			packet = types.Packet{
				Sequence:          1,
				SourceClient:      "07-tendermint-0",
				DestinationClient: "07-tendermint-1",
				TimeoutTimestamp:  100,
				Payloads: []types.Payload{
					{
						SourcePort:      "transfer",
						DestinationPort: "transfer",
						Version:         "ics20-1",
						Encoding:        "application/json",
						Value:           []byte(transferData),
					},
				},
			}
			tc.malleate()

			commitment := types.CommitPacket(packet)

			urequire.Equal(t, tc.expectedHash, hex.EncodeToString(commitment))
			urequire.Equal(t, 32, len(commitment))
		})
	}
}

// TestCommitPacketReceipt documents the receipt value the core stores for a
// received packet. The expected hashes were computed independently (Python's
// hashlib) from the encoding documented on CommitPacketReceipt.
func TestCommitPacketReceipt(t *testing.T) {
	transferData := `{"denom":"uatom","amount":"1000000","sender":"sender","receiver":"receiver","memo":"memo"}`
	base := func() types.Packet {
		return types.Packet{
			Sequence:          1,
			SourceClient:      "07-tendermint-0",
			DestinationClient: "07-tendermint-1",
			TimeoutTimestamp:  100,
			Payloads: []types.Payload{{
				SourcePort: "transfer", DestinationPort: "transfer", Version: "ics20-1",
				Encoding: "application/json", Value: []byte(transferData),
			}},
		}
	}
	cases := []struct {
		name     string
		malleate func(p *types.Packet)
		want     string
	}{
		{"packet", func(p *types.Packet) {}, "149d890018aa558d56444db8254db1b5cdd008e80803ce359273f1e3b2d24727"},
		{"other sequence", func(p *types.Packet) { p.Sequence = 2 }, "e39e640ffa0230188b3f2e1e44bbc9d8723844e682e54cd2153e713d1bb2ad16"},
		{"other source client", func(p *types.Packet) { p.SourceClient = "07-tendermint-9" }, "f8beb43efb246824a51db7040d17a1cba2f090710db4b3f9697701be2c86aac6"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p := base()
			tc.malleate(&p)
			got := types.CommitPacketReceipt(p)
			urequire.Equal(t, tc.want, hex.EncodeToString(got))
		})
	}
	// Every field the commitment covers changes the receipt too.
	p := base()
	ref := hex.EncodeToString(types.CommitPacketReceipt(p))
	for _, m := range []func(p *types.Packet){
		func(p *types.Packet) { p.DestinationClient = "07-tendermint-2" },
		func(p *types.Packet) { p.TimeoutTimestamp = 101 },
		func(p *types.Packet) { p.Payloads[0].Value = []byte("x") },
		func(p *types.Packet) { p.Payloads[0].Encoding = "application/x-protobuf" },
	} {
		q := base()
		m(&q)
		urequire.NotEqual(t, ref, hex.EncodeToString(types.CommitPacketReceipt(q)))
	}
}
