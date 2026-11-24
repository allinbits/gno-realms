package ibcgov

import (
	"encoding/binary"
	"testing"

	"gno.land/p/aib/encoding/abi/v0"
)

func ackBytes(status, redispatch byte) []byte {
	b := binary.BigEndian.AppendUint32(nil, 3)
	b = binary.BigEndian.AppendUint64(b, 9)
	return append(b, status, redispatch)
}

// Status 6, cancelled, is an acknowledgement status; 7 is not.
func TestParseAckCancelled(t *testing.T) {
	e, seq, status, redispatch, ok := ParseAck(ackBytes(6, 0))
	if !ok || e != 3 || seq != 9 || status != StatusCancelled || redispatch {
		t.Fatalf("status 6: %v %d %d %d %v", ok, e, seq, status, redispatch)
	}
	for _, s := range []byte{0, 7, 255} {
		if _, _, _, _, ok := ParseAck(ackBytes(s, 0)); ok {
			t.Errorf("status %d parsed", s)
		}
	}
	if statusWord(StatusCancelled) != "cancelled" {
		t.Errorf("word %q", statusWord(StatusCancelled))
	}
}

// The cancelled ranges merge into disjoint ones, per epoch, and one lookup
// tells whether a number is covered.
func TestCancelledRanges(t *testing.T) {
	g := &routeGov{}
	addCancelled(g, 1, 5, 7)
	addCancelled(g, 1, 10, 12)
	addCancelled(g, 1, 20, 20)
	addCancelled(g, 2, 1, 100)
	if g.cancels.Size() != 4 {
		t.Fatalf("%d ranges", g.cancels.Size())
	}
	addCancelled(g, 1, 8, 9) // touches both neighbours: 5-12
	addCancelled(g, 1, 6, 6) // inside
	addCancelled(g, 1, 19, 25)
	if g.cancels.Size() != 3 {
		t.Fatalf("%d ranges after the merges", g.cancels.Size())
	}
	for s := uint64(1); s <= 30; s++ {
		if want := s >= 5 && s <= 12 || s >= 19 && s <= 25; cancelledHere(g, 1, s) != want {
			t.Errorf("epoch 1 seq %d: want %v", s, want)
		}
	}
	if !cancelledHere(g, 2, 100) || cancelledHere(g, 2, 101) || cancelledHere(g, 3, 1) {
		t.Errorf("epoch 2 or 3 misread")
	}
	addCancelled(g, 1, 1, ^uint64(0))
	if !cancelledHere(g, 1, ^uint64(0)) || g.cancels.Size() != 2 {
		t.Errorf("the whole epoch: %d ranges", g.cancels.Size())
	}
}

// indexDispatch reads this realm's own kind 1 encoding, and only it.
func TestIndexDispatch(t *testing.T) {
	g := &routeGov{}
	cancel := abi.Encode(abi.Array(abi.Tuple(abi.Uint64(2), abi.Uint64(3)), abi.Tuple(abi.Uint64(7), abi.Uint64(7))))
	indexDispatch(g, &dispatch{epoch: 1, seq: 8, kind: KindCancel, body: Envelope(1, 8, KindCancel, cancel)})
	for s, want := range map[uint64]bool{1: false, 2: true, 3: true, 4: false, 7: true, 8: false} {
		if cancelledHere(g, 1, s) != want {
			t.Errorf("seq %d", s)
		}
	}
	enrol := abi.Encode(abi.Uint64(1), abi.String("gnoland-2"))
	indexDispatch(g, &dispatch{epoch: 1, seq: 9, kind: KindClient, body: Envelope(1, 9, KindClient, enrol)})
	if g.cancels.Size() != 2 {
		t.Errorf("%d ranges: a kind 6 was indexed", g.cancels.Size())
	}
}
