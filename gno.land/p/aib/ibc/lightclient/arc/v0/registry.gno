package arc

import (
	"bytes"
	"errors"

	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/p/nt/ufmt/v0"
)

// The validator set is not in Arc's block header: the consensus layer reads
// it from the ValidatorRegistry (arc-node contracts/src/validator-manager),
// calling getActiveValidatorSet() on the state after block H-1 for height H
// and keeping the entries with status Active and positive power
// (crates/eth-engine/src/abi_utils.rs). The client reads the same entries
// straight from the registry's storage, proven by a pool of storage-trie
// nodes. With S the storage location (ERC-7201), the layout is:
//
//	S+0: mapping(uint256 => Validator) _validatorsByRegistrationId
//	S+1: EnumerableSet.UintSet _activeValidatorRegistrations
//	     (its _values array: length at S+1, element i at keccak256(S+1)+i)
//	S+2: the set's _positions; S+3: _registeredPublicKeys; S+4: _nextRegistrationId
//
// and a Validator{status uint8, publicKey bytes, votingPower uint64} at
// E = keccak256(abi.encode(id, S)) takes three slots: status at E, the
// publicKey's length word at E+1 (2*32+1 for a 32-byte key, whose bytes are
// at keccak256(E+1)), votingPower at E+2.

// statusActive is ValidatorStatus.Active.
const statusActive = 2

// implementationSlot is the ERC-1967 implementation slot,
// bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1), where the
// registry's proxy keeps its implementation's address.
var implementationSlot = []byte{
	0x36, 0x08, 0x94, 0xa1, 0x3b, 0xa1, 0xa3, 0x21, 0x06, 0x67, 0xc8, 0x28, 0x49, 0x2d, 0xb9, 0x8d,
	0xca, 0x3e, 0x20, 0x76, 0xcc, 0x37, 0x35, 0xa9, 0x20, 0xa3, 0xca, 0x50, 0x5d, 0x38, 0x2b, 0xbc,
}

// readImplementation reads the proxy's implementation address.
func readImplementation(r *ethereum.StorageReader) ([]byte, error) {
	w, err := r.Get(implementationSlot)
	if err != nil {
		return nil, ufmt.Errorf("registry implementation: %v", err)
	}
	if !isZero(w[:12]) || isZero(w[12:]) {
		return nil, errors.New("registry implementation slot holds no address")
	}
	return w[12:], nil
}

// readValidatorSet reads the active validator set from the registry storage
// r proves, at location, in the order getActiveValidatorSet returns it.
func readValidatorSet(r *ethereum.StorageReader, location []byte) (*ValidatorSet, error) {
	setSlot := slotAdd(location, 1)
	lengthWord, err := r.Get(setSlot)
	if err != nil {
		return nil, ufmt.Errorf("active registrations length: %v", err)
	}
	n, ok := smallUint(lengthWord)
	if !ok || n > MaxValidators {
		return nil, ufmt.Errorf("more than %d active registrations", MaxValidators)
	}
	values := ethereum.Keccak256(setSlot)
	vs := &ValidatorSet{}
	for i := uint64(0); i < n; i++ {
		id, err := r.Get(slotAdd(values, i))
		if err != nil {
			return nil, ufmt.Errorf("active registration %d: %v", i, err)
		}
		entry := ethereum.Keccak256(append(cloneBytes(id), location...))
		v, active, err := readValidator(r, entry)
		if err != nil {
			return nil, ufmt.Errorf("registration %x: %v", id, err)
		}
		if !active {
			continue
		}
		if err := vs.add(v.PubKey, v.Power); err != nil {
			return nil, err
		}
	}
	if len(vs.Validators) == 0 {
		return nil, errors.New("empty validator set")
	}
	return vs, nil
}

// readValidator reads the Validator at entry; active is false for one the
// consensus layer skips: not Active, no power, or a key that is not a
// 32-byte Ed25519 point (point.gno).
func readValidator(r *ethereum.StorageReader, entry []byte) (v Validator, active bool, err error) {
	status, err := r.Get(entry)
	if err != nil {
		return Validator{}, false, err
	}
	power, err := r.Get(slotAdd(entry, 2))
	if err != nil {
		return Validator{}, false, err
	}
	p, ok := smallUint(power)
	if !ok {
		return Validator{}, false, errors.New("voting power exceeds 64 bits")
	}
	if s, ok := smallUint(status); !ok || s != statusActive || p == 0 {
		return Validator{}, false, nil
	}
	keyLen, err := r.Get(slotAdd(entry, 1))
	if err != nil {
		return Validator{}, false, err
	}
	if l, ok := smallUint(keyLen); !ok || l != 2*pubKeySize+1 {
		return Validator{}, false, nil
	}
	key, err := r.Get(ethereum.Keccak256(slotAdd(entry, 1)))
	if err != nil {
		return Validator{}, false, err
	}
	if !isEdwardsPoint(key) {
		return Validator{}, false, nil
	}
	return Validator{PubKey: key, Power: p}, true, nil
}

// slotAdd is the 32-byte big-endian slot s+n, modulo 2^256.
func slotAdd(s []byte, n uint64) []byte {
	out := cloneBytes(s)
	carry := n
	for i := len(out) - 1; i >= 0 && carry > 0; i-- {
		sum := uint64(out[i]) + carry&0xff
		out[i] = byte(sum)
		carry = carry>>8 + sum>>8
	}
	return out
}

// smallUint reads a 32-byte word holding a uint64.
func smallUint(w []byte) (uint64, bool) {
	if len(w) != hashSize || !bytes.Equal(w[:24], make([]byte, 24)) {
		return 0, false
	}
	var v uint64
	for _, c := range w[24:] {
		v = v<<8 | uint64(c)
	}
	return v, true
}

// registryState proves the registry's storage root in the state with root
// stateRoot and, unless it equals known (whose set is knownSet: the same
// storage, implementation slot included, holds the same set), reads the set
// it holds from nodes, by the layout of cs.RegistryImplementation, which the
// proxy must still name. With cs.RegistryImplementation nil (a creation) it
// returns the implementation it reads.
func registryState(cs *ClientState, stateRoot []byte, accountProof, nodes [][]byte, known []byte, knownSet *ValidatorSet) (root []byte, set *ValidatorSet, impl []byte, err error) {
	root, err = ethereum.AccountStorageRoot(stateRoot, cs.RegistryAddress, accountProof)
	if err != nil {
		return nil, nil, nil, ufmt.Errorf("registry account proof: %v", err)
	}
	if known != nil && bytes.Equal(root, known) {
		return root, knownSet, cs.RegistryImplementation, nil
	}
	r := ethereum.NewStorageReader(root, nodes)
	impl, err = readImplementation(r)
	if err != nil {
		return nil, nil, nil, err
	}
	if cs.RegistryImplementation != nil && !bytes.Equal(impl, cs.RegistryImplementation) {
		return nil, nil, nil, ufmt.Errorf("the registry's implementation changed to %x: its layout is unknown to this client, which needs a governed recovery", impl)
	}
	set, err = readValidatorSet(r, cs.RegistryStorageLocation)
	if err != nil {
		return nil, nil, nil, ufmt.Errorf("registry storage: %v", err)
	}
	return root, set, impl, nil
}
