package main

// The justification state of the attested beacon states, produced by running
// weigh_justification_and_finalization (phase0 beacon-chain.md, unchanged
// through Gloas) over a history, as process_justification_and_finalization
// calls it at every epoch transition from epoch 2 on.

type ffgCheckpoint struct{ epoch uint64 }

type ffgState struct {
	bits                                       [4]bool
	previousJustified, currentJustified, final ffgCheckpoint
}

// weigh is weigh_justification_and_finalization at the transition out of
// currentEpoch, the previous and current epoch targets having (or not) a 2/3
// supermajority.
func (s *ffgState) weigh(currentEpoch uint64, previousTarget, currentTarget bool) {
	previousEpoch := currentEpoch - 1
	oldPrevious, oldCurrent := s.previousJustified, s.currentJustified
	s.previousJustified = s.currentJustified
	s.bits = [4]bool{false, s.bits[0], s.bits[1], s.bits[2]}
	if previousTarget {
		s.currentJustified = ffgCheckpoint{previousEpoch}
		s.bits[1] = true
	}
	if currentTarget {
		s.currentJustified = ffgCheckpoint{currentEpoch}
		s.bits[0] = true
	}
	b := s.bits
	if b[1] && b[2] && b[3] && oldPrevious.epoch+3 == currentEpoch {
		s.final = oldPrevious
	}
	if b[1] && b[2] && oldPrevious.epoch+2 == currentEpoch {
		s.final = oldPrevious
	}
	if b[0] && b[1] && b[2] && oldCurrent.epoch+2 == currentEpoch {
		s.final = oldCurrent
	}
	if b[0] && b[1] && oldCurrent.epoch+1 == currentEpoch {
		s.final = oldCurrent
	}
}

func (s ffgState) bitsByte() byte {
	var out byte
	for i, b := range s.bits {
		if b {
			out |= 1 << uint(i)
		}
	}
	return out
}

// ffgAfter is the justification state once the transition out of epoch has
// run, for the synthetic history: every epoch target justified by its own
// epoch's attestations up to epoch 18; in epoch 19 the current target falls
// short of 2/3 and only the previous one (18) is reached. So the Fulu state at
// slot 152 (after epoch 18) has finalized 17, justified 17 and 18, bits 0x0f;
// the Gloas state at slot 160 (after epoch 19) keeps finalized 17, with both
// justified checkpoints at 18 and bits 0x0e.
func ffgAfter(epoch uint64) ffgState {
	var s ffgState
	for e := uint64(2); e <= epoch; e++ {
		s.weigh(e, true, e != 19)
	}
	if s.final.epoch != finalizedEpoch {
		panic("the history must finalize epoch 17")
	}
	return s
}
