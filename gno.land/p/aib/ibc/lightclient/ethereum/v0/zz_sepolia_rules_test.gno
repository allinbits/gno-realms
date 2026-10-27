package ethereum_test

import (
	"testing"
	"time"

	ethereum "gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/urequire/v0"
)

// sepoliaAt returns a client initialized from the Sepolia snapshot that
// applied its first n updates, the block time set for update n, and update n.
func sepoliaAt(t *testing.T, n int) (*ethereum.EthLightClient, *ethereum.Header) {
	c := ethereum.NewEthLightClient()
	urequire.NoError(t, c.Initialize(sepoliaClientState(), sepoliaConsensusState()))
	times, ups := sepoliaUpdates()
	for i := 0; i < n; i++ {
		setTime(times[i])
		urequire.NoError(t, c.VerifyClientMessage(ups[i]))
		c.UpdateState(ups[i])
	}
	setTime(times[n])
	return c, ups[n]
}

func setTime(sec uint64) {
	testing.SetContext(testing.Context{Time: time.Unix(int64(sec), 0)})
}

func flipped(b []byte, i int) []byte {
	out := append([]byte{}, b...)
	out[i] ^= 1
	return out
}

// Tampering with the Gloas parts of a live finality update is refused: the
// execution block hash and its branch to the body root, the RLP execution
// header bound to that hash, and a non-signer proven at another index.
func TestSepoliaFinalityUpdateTampering(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(u *ethereum.LightClientUpdate)
		err    string
	}{
		{"finalized execution header", func(u *ethereum.LightClientUpdate) {
			u.FinalizedExecutionHeader = flipped(u.FinalizedExecutionHeader, 40)
		}, "finalized execution header does not match the execution block hash"},
		{"finalized execution branch", func(u *ethereum.LightClientUpdate) {
			b := append([][]byte{}, u.FinalizedHeader.ExecutionBranch...)
			b[len(b)-1] = flipped(b[len(b)-1], 0)
			u.FinalizedHeader.ExecutionBranch = b
		}, "finalized header: invalid execution branch"},
		{"attested execution block hash", func(u *ethereum.LightClientUpdate) {
			u.AttestedHeader.ExecutionBlockHash = flipped(u.AttestedHeader.ExecutionBlockHash, 0)
		}, "attested header: invalid execution branch"},
		{"short execution block hash", func(u *ethereum.LightClientUpdate) {
			u.AttestedHeader.ExecutionBlockHash = u.AttestedHeader.ExecutionBlockHash[:31]
		}, "execution block hash must be 32 bytes"},
		{"payload header on a Gloas header", func(u *ethereum.LightClientUpdate) {
			u.AttestedHeader.ExecutionBlockHash = nil
			u.AttestedHeader.Execution.ParentHash = make([]byte, 32)
		}, "execution block hash must be 32 bytes"},
		{"both forms", func(u *ethereum.LightClientUpdate) {
			u.FinalizedHeader.Execution.ParentHash = make([]byte, 32)
		}, "carries both an execution payload header and an execution block hash"},
		{"non-signer at another index", func(u *ethereum.LightClientUpdate) {
			bits := append([]byte{}, u.SyncAggregate.SyncCommitteeBits...)
			i := 0
			for bits[i/8]&(1<<uint(i%8)) != 0 {
				i++
			}
			j := (i + 1) % (len(bits) * 8)
			bits[i/8] |= 1 << uint(i%8)
			bits[j/8] &^= 1 << uint(j%8)
			u.SyncAggregate.SyncCommitteeBits = bits
		}, "invalid branch for non-signer"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c, hdr := sepoliaAt(t, 1)
			h := *hdr
			tc.mutate(&h.ConsensusUpdate)
			urequire.ErrorContains(t, c.VerifyClientMessage(&h), tc.err)
		})
	}
	c, hdr := sepoliaAt(t, 1)
	urequire.NoError(t, c.VerifyClientMessage(hdr), "the untampered update verifies")
}

// A verified header that finalizes a slot the client stores with another
// execution state root is misbehaviour: checked, it freezes the client.
// The live next-committee-only update finalizes slot 11354112; a state with
// another root is planted there.
func TestSepoliaConflictingRootFreezes(t *testing.T) {
	c, hdr := sepoliaAt(t, 0)
	cons := sepoliaConsensusState()
	cons.Slot = hdr.ConsensusUpdate.FinalizedHeader.Beacon.Slot
	cons.StateRoot = flipped(cons.StateRoot, 0)
	c.ConsensusStateByHeight.Set(types.NewHeight(0, cons.Slot).StringNatSort(), &cons)

	urequire.NoError(t, c.VerifyClientMessage(hdr))
	urequire.True(t, c.CheckForMisbehaviour(hdr), "a conflicting root is misbehaviour")
	c.UpdateStateOnMisbehaviour(hdr)
	urequire.Equal(t, "Frozen", string(c.Status()))
}
