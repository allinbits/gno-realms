package ethereum

import (
	"encoding/hex"
	"math"
	"strconv"
	"testing"
	"time"

	"gno.land/p/aib/ibc/host/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/nt/urequire/v0"
)

// fixture is a recorded devnet run, see cmd/gen-eth-fixtures.
type fixture struct {
	clientState    ClientState
	consensusState ConsensusState
	steps          []fixtureStep
}

// fixtureStep is either a client update or a storage proof check.
type fixtureStep struct {
	update *Header
	proof  *fixtureProof
}

// fixtureProof proves, at height, the router's commitment for packet: the
// packet commitment, or its ack commitment when ack is set, or the absence of
// its receipt when absent is set.
type fixtureProof struct {
	height types.Height
	proof  MembershipProof
	packet types.Packet
	ack    *types.Acknowledgement
	absent bool
}

func h(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

// uint256BE returns the minimal big-endian bytes of a decimal or 0x-hex
// number below 2^64.
func uint256BE(s string) []byte {
	v, err := strconv.ParseUint(s, 0, 64)
	if err != nil {
		panic(err)
	}
	var out []byte
	for ; v > 0; v >>= 8 {
		out = append([]byte{byte(v)}, out...)
	}
	return out
}

// setNow sets the block time seen by the client.
func setNow(t uint64) {
	if t > math.MaxInt64 {
		panic("time overflow")
	}
	testing.SetContext(testing.Context{Time: time.Unix(int64(t), 0)})
}

// runFixture replays f: every update must verify and apply, every proof must
// verify against the consensus state the updates established.
func runFixture(t *testing.T, f fixture) {
	c := NewEthLightClient()
	urequire.NoError(t, f.clientState.ValidateBasic())
	urequire.NoError(t, f.consensusState.ValidateBasic())
	urequire.NoError(t, c.Initialize(f.clientState, f.consensusState))

	updates, proofs := 0, 0
	for i, s := range f.steps {
		switch {
		case s.update != nil:
			u := s.update.ConsensusUpdate
			// Verify a little after the signature slot, as a relayer would.
			setNow(f.clientState.GenesisTime + (u.SignatureSlot-f.clientState.GenesisSlot+1)*f.clientState.SecondsPerSlot)
			urequire.NoError(t, s.update.ValidateBasic(), ufmt.Sprintf("step %d", i))
			urequire.NoError(t, c.VerifyClientMessage(s.update), ufmt.Sprintf("step %d", i))
			urequire.False(t, c.CheckForMisbehaviour(s.update), ufmt.Sprintf("step %d", i))
			heights := c.UpdateState(s.update)
			urequire.Equal(t, 1, len(heights))
			urequire.Equal(t, u.FinalizedHeader.Beacon.Slot, c.LatestHeight().RevisionHeight)
			updates++
		case s.proof != nil:
			p := s.proof
			var err error
			switch {
			case p.ack != nil:
				key := host.PacketAcknowledgementKey(p.packet.DestinationClient, p.packet.Sequence)
				err = c.VerifyMembershipProof(p.height, p.proof, ethPath(key), types.CommitAcknowledgement(*p.ack))
			case p.absent:
				key := host.PacketReceiptKey(p.packet.DestinationClient, p.packet.Sequence)
				err = c.VerifyNonMembershipProof(p.height, p.proof, ethPath(key))
			default:
				key := host.PacketCommitmentKey(p.packet.SourceClient, p.packet.Sequence)
				err = c.VerifyMembershipProof(p.height, p.proof, ethPath(key), types.CommitPacket(p.packet))
			}
			urequire.NoError(t, err, ufmt.Sprintf("step %d", i))
			proofs++
		}
	}
	if updates == 0 {
		t.Fatal("fixture has no update")
	}
	t.Logf("%d updates, %d proofs", updates, proofs)
}

// ethPath is the merkle path of key under the router's empty prefix.
func ethPath(key []byte) types.MerklePath {
	return types.BuildMerklePath([][]byte{{}}, key)
}
