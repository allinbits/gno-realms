package main

// The client's wire format (gno.land/p/aib/encoding/wire): a Uint is 8
// big-endian bytes, a blob an unsigned LEB128 length then its bytes, a list
// an unsigned LEB128 count then its elements.

import "encoding/binary"

type wireWriter struct{ buf []byte }

func (w *wireWriter) uint(v uint64) *wireWriter {
	w.buf = binary.BigEndian.AppendUint64(w.buf, v)
	return w
}

func (w *wireWriter) uvarint(v uint64) *wireWriter {
	w.buf = binary.AppendUvarint(w.buf, v)
	return w
}

func (w *wireWriter) blob(b []byte) *wireWriter {
	w.uvarint(uint64(len(b)))
	w.buf = append(w.buf, b...)
	return w
}

func (w *wireWriter) blobs(bs [][]byte) *wireWriter {
	w.uvarint(uint64(len(bs)))
	for _, b := range bs {
		w.blob(b)
	}
	return w
}
