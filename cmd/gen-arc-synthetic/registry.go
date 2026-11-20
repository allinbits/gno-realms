package main

// The ValidatorRegistry's storage (arc-node contracts/src/validator-manager),
// laid out by Solidity's storage rules: the contract keeps its state in an
// ERC-7201 namespace at S = registryLocation,
//
//	struct Storage {
//	    mapping(uint256 => Validator) _validatorsByRegistrationId; // S+0
//	    EnumerableSet.UintSet _activeValidatorRegistrations;       // S+1, S+2
//	    ... _registeredPublicKeys;                                 // S+3
//	    uint256 _nextRegistrationId;                               // S+4
//	}
//	struct Validator { ValidatorStatus status; bytes publicKey; uint64 votingPower; }
//
// A mapping entry for key k of a mapping at slot p is at keccak256(k . p);
// a Validator there takes three slots (status alone, as the bytes after it
// start a new slot; the key's length word, 2*len+1 for a key over 31 bytes,
// whose bytes are at keccak256 of that slot; votingPower). An
// EnumerableSet.UintSet is a Set{bytes32[] _values; mapping(bytes32 =>
// uint256) _positions}: the array's length at S+1 and element i at
// keccak256(S+1)+i, a value's position (index+1) in the mapping at S+2.
// Removal swaps the last value into the removed one's place. The proxy keeps
// its implementation's address in the ERC-1967 slot of the same storage.
// _registeredPublicKeys is left empty: nothing reads it.

import (
	"bytes"
	"math/big"
	"sort"
)

const (
	statusRegistered = 1 // any status but Active
	statusActive     = 2
)

// erc1967Implementation is bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1).
var erc1967Implementation = func() []byte {
	v := new(big.Int).SetBytes(keccak([]byte("eip1967.proxy.implementation")))
	return word(v.Sub(v, big.NewInt(1)))
}()

type registration struct {
	status uint64
	key    []byte
	power  uint64
}

type registry struct {
	impl   []byte
	regs   map[uint64]*registration
	active []uint64 // the EnumerableSet's values, in order
	nextID uint64
}

func newRegistry(impl []byte) *registry {
	return &registry{impl: impl, regs: map[uint64]*registration{}, nextID: 1}
}

func (r *registry) clone() *registry {
	c := &registry{impl: r.impl, regs: map[uint64]*registration{}, active: append([]uint64{}, r.active...), nextID: r.nextID}
	for id, reg := range r.regs {
		copied := *reg
		c.regs[id] = &copied
	}
	return c
}

func (r *registry) idOf(key []byte) uint64 {
	for id, reg := range r.regs {
		if bytes.Equal(reg.key, key) {
			return id
		}
	}
	panic("unregistered key")
}

// register registers key with power and activates it.
func (r *registry) register(key []byte, power uint64) {
	id := r.nextID
	r.nextID++
	r.regs[id] = &registration{status: statusActive, key: key, power: power}
	r.active = append(r.active, id)
}

// deactivate removes key's registration from the active set, as
// EnumerableSet.remove does: the last value takes its place.
func (r *registry) deactivate(key []byte) {
	id := r.idOf(key)
	r.regs[id].status = statusRegistered
	for i, v := range r.active {
		if v == id {
			last := len(r.active) - 1
			r.active[i] = r.active[last]
			r.active = r.active[:last]
			return
		}
	}
	panic("not active")
}

func (r *registry) setPower(key []byte, power uint64) { r.regs[r.idOf(key)].power = power }

// members is the set the consensus layer reads: getActiveValidatorSet()'s
// entries in order, those Active with positive power.
func (r *registry) members() []member {
	var out []member
	for _, id := range r.active {
		reg := r.regs[id]
		if reg.status != statusActive || reg.power == 0 {
			continue
		}
		for i := range keys {
			if bytes.Equal(pubKey(i), reg.key) {
				out = append(out, member{i, reg.power})
			}
		}
	}
	return out
}

func word(v *big.Int) []byte {
	m := new(big.Int).Lsh(big.NewInt(1), 256)
	return new(big.Int).Mod(v, m).FillBytes(make([]byte, 32))
}

func uintWord(v uint64) []byte { return word(new(big.Int).SetUint64(v)) }

func slotPlus(slot []byte, n uint64) []byte {
	return word(new(big.Int).Add(new(big.Int).SetBytes(slot), new(big.Int).SetUint64(n)))
}

// mappingSlot is the slot of key in a mapping at slot p.
func mappingSlot(key, p []byte) []byte { return keccak(append(append([]byte{}, key...), p...)) }

func (r *registry) storage() storage {
	s := newStorage()
	S := registryLocation
	s.setWord(erc1967Implementation, append(make([]byte, 12), r.impl...))
	for id, reg := range r.regs {
		e := mappingSlot(uintWord(id), S)
		s.setWord(e, uintWord(reg.status))
		if len(reg.key) <= 31 {
			panic("a short key is stored in place")
		}
		s.setWord(slotPlus(e, 1), uintWord(uint64(2*len(reg.key)+1)))
		data := keccak(slotPlus(e, 1))
		for i := 0; i < len(reg.key); i += 32 {
			chunk := make([]byte, 32)
			copy(chunk, reg.key[i:])
			s.setWord(slotPlus(data, uint64(i/32)), chunk)
		}
		s.setWord(slotPlus(e, 2), uintWord(reg.power))
	}
	values := slotPlus(S, 1)
	s.setWord(values, uintWord(uint64(len(r.active))))
	for i, id := range r.active {
		s.setWord(slotPlus(keccak(values), uint64(i)), uintWord(id))
		s.setWord(mappingSlot(uintWord(id), slotPlus(S, 2)), uintWord(uint64(i+1)))
	}
	s.setWord(slotPlus(S, 4), uintWord(r.nextID))
	return s
}

// slots are the storage's set slots, in order.
func (s storage) slots() [][]byte {
	var out [][]byte
	for k := range s.values {
		out = append(out, []byte(k))
	}
	sort.Slice(out, func(i, j int) bool { return bytes.Compare(out[i], out[j]) < 0 })
	return out
}
