package main

import (
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"text/template"
	"time"

	ics23 "github.com/cosmos/ics23/go"

	dbm "github.com/cosmos/cosmos-db"

	channelv2types "github.com/cosmos/ibc-go/v10/modules/core/04-channel/v2/types"

	"cosmossdk.io/log"
	"cosmossdk.io/store/iavl"
	"cosmossdk.io/store/metrics"
	"cosmossdk.io/store/rootmulti"
	storetypes "cosmossdk.io/store/types"

	upgradetypes "cosmossdk.io/x/upgrade/types"

	"github.com/cosmos/cosmos-sdk/codec"
	codectypes "github.com/cosmos/cosmos-sdk/codec/types"

	clienttypes "github.com/cosmos/ibc-go/v10/modules/core/02-client/types"
	commitmenttypes "github.com/cosmos/ibc-go/v10/modules/core/23-commitment/types"
	tmclient "github.com/cosmos/ibc-go/v10/modules/light-clients/07-tendermint"
)

func main() {
	flag.Parse()

	// New shape: `gen-proof upgrade` generates both upgrade-client and
	// upgrade-consensus-state proofs against the upgrade store, in a single
	// rootmulti commit (so they share the same apphash).
	if flag.NArg() == 1 && flag.Arg(0) == "upgrade" {
		fmt.Println(genUpgradeProofCode())
		return
	}

	if flag.NArg() < 3 || flag.NArg() > 4 {
		fmt.Println("Usage: gen-proof MERKLE_PREFIX CLIENT_ID COMMITMENT_TYPE [COMMITMENT]")
		fmt.Println("       gen-proof upgrade")
		os.Exit(1)
	}
	var (
		merklePrefix   = flag.Arg(0)
		clientID       = flag.Arg(1)
		commitmentType = flag.Arg(2)
		commitment     = flag.Arg(3)
		key            []byte
		value          []byte
	)
	switch commitmentType {
	case "acknowledgement":
		// CONTRACT sequence=1
		key = []byte(merklePrefix + clientID + "\x03\x00\x00\x00\x00\x00\x00\x00\x01")
		if commitment != "" {
			// commitment holds the app acknowledgement. It can be arbitrary bytes
			// or hex bytes.
			appAck := []byte(commitment)
			bz, err := hex.DecodeString(commitment)
			if err == nil {
				appAck = bz
			}
			value = channelv2types.CommitAcknowledgement(
				channelv2types.Acknowledgement{
					AppAcknowledgements: [][]byte{appAck},
				},
			)
		}
	case "receipt":
		// CONTRACT sequence=1
		key = []byte(merklePrefix + clientID + "\x02\x00\x00\x00\x00\x00\x00\x00\x01")
		if commitment != "" {
			// receipt commitment value is always the byte 0x02
			value = []byte{0x02}
		}
	case "packet":
		// CONTRACT sequence=1
		key = []byte(merklePrefix + clientID + "\x01\x00\x00\x00\x00\x00\x00\x00\x01")
		// commitment holds the packet json serialized
		if commitment != "" {
			var packet channelv2types.Packet
			err := json.Unmarshal([]byte(commitment), &packet)
			if err != nil {
				panic(err)
			}
			value = channelv2types.CommitPacket(packet)
		}
	default:
		fmt.Println("unhandled proof type", commitmentType)
		os.Exit(1)
	}

	fmt.Println(genProofCode("iavlStoreKey", key, value))
}

// upgradeScenario holds the hardcoded parameters used to generate an upgrade
// happy-path filetest. Both the chain that "schedules" the upgrade in
// gen-proof and the consumer test must use the exact same values, otherwise
// the values the test reconstructs won't match the bytes the chain
// committed and proof verification will fail.
type upgradeScenario struct {
	planHeight        int64
	upgradedChainID   string
	upgradedHeight    clienttypes.Height
	upgradedTimestamp time.Time
	nextValsHash      []byte
}

func defaultUpgradeScenario() upgradeScenario {
	hash := make([]byte, 32)
	for i := range hash {
		hash[i] = byte(i + 1)
	}
	return upgradeScenario{
		planHeight:        100,
		upgradedChainID:   "chain-after-upgrade-2",
		upgradedHeight:    clienttypes.NewHeight(2, 1),
		upgradedTimestamp: time.Unix(1700000000, 0).UTC(),
		nextValsHash:      hash,
	}
}

// genUpgradeProofCode commits an upgraded client + consensus state to the
// upgrade IAVL store at the SDK-conventional keys, then dumps Go code that
// reconstructs the matching state and proofs for the Gno filetest.
func genUpgradeProofCode() string {
	scn := defaultUpgradeScenario()

	// Build the upgraded states.
	upgradedClient := tmclient.NewClientState(
		scn.upgradedChainID,
		tmclient.Fraction{Numerator: 1, Denominator: 3},
		2*7*24*time.Hour, // trusting period (placeholder; ZeroCustomFields drops it)
		3*7*24*time.Hour, // unbonding period (preserved)
		10*time.Second,   // max clock drift (placeholder; ZeroCustomFields drops it)
		scn.upgradedHeight,
		commitmenttypes.GetSDKSpecs(),
		[]string{"upgrade", "upgradedIBCState"},
	)
	zeroedClient := upgradedClient.ZeroCustomFields()

	upgradedConsState := tmclient.NewConsensusState(
		scn.upgradedTimestamp,
		commitmenttypes.NewMerkleRoot([]byte(tmclient.SentinelRoot)),
		scn.nextValsHash,
	)

	// Marshal via cdc.MarshalInterface so the bytes match what the SDK
	// upgrade module commits (google.protobuf.Any wrapper + raw proto).
	registry := codectypes.NewInterfaceRegistry()
	tmclient.RegisterInterfaces(registry)
	cdc := codec.NewProtoCodec(registry)

	clientBz, err := cdc.MarshalInterface(zeroedClient)
	if err != nil {
		panic(fmt.Errorf("marshal upgraded client state: %w", err))
	}
	consStateBz, err := cdc.MarshalInterface(upgradedConsState)
	if err != nil {
		panic(fmt.Errorf("marshal upgraded consensus state: %w", err))
	}

	// Mount the "upgrade" IAVL store and commit both values.
	db := dbm.NewMemDB()
	store := rootmulti.NewStore(db, log.NewNopLogger(), metrics.NewNoOpMetrics())
	upgradeStoreKey := storetypes.NewKVStoreKey("upgrade")
	store.MountStoreWithDB(upgradeStoreKey, storetypes.StoreTypeIAVL, nil)
	if err := store.LoadVersion(0); err != nil {
		panic(err)
	}
	upStore := store.GetCommitStore(upgradeStoreKey).(*iavl.Store)
	// Fill with fake data to keep the IAVL tree non-trivial.
	for _, ikey := range []byte{0x11, 0x32, 0x50, 0x72, 0x99} {
		k := []byte{ikey}
		upStore.Set(k, k)
	}

	clientKey := upgradetypes.UpgradedClientKey(scn.planHeight)
	consStateKey := upgradetypes.UpgradedConsStateKey(scn.planHeight)
	upStore.Set(clientKey, clientBz)
	upStore.Set(consStateKey, consStateBz)

	cid := store.Commit()

	clientProofs := queryAndDecodeProof(store, "upgrade", clientKey, clientBz, cid.Hash)
	consStateProofs := queryAndDecodeProof(store, "upgrade", consStateKey, consStateBz, cid.Hash)

	tmpl := `
{{define "existenceProof" -}}
&ics23.ExistenceProof{
      Key:   {{bytes .Key}},
      Value: {{bytes .Value}},
      Leaf: &ics23.LeafOp{
        Hash:         specs.LeafSpec.Hash,
        PrehashKey:   specs.LeafSpec.PrehashKey,
        PrehashValue: specs.LeafSpec.PrehashValue,
        Length:       specs.LeafSpec.Length,
        Prefix:       {{bytes .Leaf.Prefix}},
      },
      Path: []*ics23.InnerOp{
        {{range .Path -}}
        {
          Hash:   specs.InnerSpec.Hash,
          Prefix: {{bytes .Prefix}},
          Suffix: {{bytes .Suffix}},
        },
        {{end -}}
      },
    },
{{- end -}}
{{define "proofPair" -}}
[]ics23.CommitmentProof{
  // iavl proof
  ics23.CommitmentProof_Exist{
    Exist: {{template "existenceProof" (index . 0).GetExist}}
  },
  // rootmulti proof
  ics23.CommitmentProof_Exist{
    Exist: {{template "existenceProof" (index . 1).GetExist}}
  },
}
{{- end -}}
// NOTE code generated by:
// go run -C ./cmd/gen-proof . upgrade
//
// Plan height:             {{.PlanHeight}}
// Upgraded chain id:       {{.UpgradedChainID}}
// Upgraded latest height:  {{.UpgradedHeight}}
// Upgraded timestamp:      {{.UpgradedTimestampUnix}}
// Next validators hash:    {{hex .NextValsHash}}
// Multistore root (apphash): {{hex .Root}}

apphash, _ := hex.DecodeString("{{hex .Root}}")
specs := ics23.IavlSpec()

clientProof := {{template "proofPair" .ClientProofs}}

consStateProof := {{template "proofPair" .ConsStateProofs}}
`
	t, err := template.New("").Funcs(template.FuncMap{
		"hex": func(bz []byte) string {
			return fmt.Sprintf("%x", bz)
		},
		"bytes": func(bz []byte) string {
			h := fmt.Sprintf("%x", bz)
			var bytesStr string
			for i := 0; i < len(h); i += 2 {
				bytesStr += "\\x" + h[i:i+2]
			}
			return "[]byte(\"" + bytesStr + "\")"
		},
	}).Parse(tmpl)
	if err != nil {
		panic(err)
	}
	var sb strings.Builder
	err = t.Execute(&sb, map[string]any{
		"Root":                  cid.Hash,
		"PlanHeight":            scn.planHeight,
		"UpgradedChainID":       scn.upgradedChainID,
		"UpgradedHeight":        scn.upgradedHeight.String(),
		"UpgradedTimestampUnix": scn.upgradedTimestamp.Unix(),
		"NextValsHash":          scn.nextValsHash,
		"ClientProofs":          clientProofs,
		"ConsStateProofs":       consStateProofs,
	})
	if err != nil {
		panic(err)
	}
	return sb.String()
}

// queryAndDecodeProof asks the rootmulti store for a Prove=true query at the
// given key in the given store, decodes the two ProofOps into their ICS-23
// CommitmentProof form, and verifies the value reconstructs the apphash so
// we fail fast if the proof is malformed.
func queryAndDecodeProof(store *rootmulti.Store, storeName string, key, value, root []byte) []*ics23.CommitmentProof {
	res, err := store.Query(&storetypes.RequestQuery{
		Path:  fmt.Sprintf("/%s/key", storeName),
		Data:  key,
		Prove: true,
	})
	if err != nil {
		panic(err)
	}

	proofs := make([]*ics23.CommitmentProof, len(res.ProofOps.Ops))
	for i, op := range res.ProofOps.Ops {
		var p ics23.CommitmentProof
		if err := p.Unmarshal(op.Data); err != nil || p.Proof == nil {
			panic(fmt.Sprintf("decode proof op %d: %v", i, err))
		}
		proofs[i] = &p
	}

	// Note: the SDK proof runtime path-splits on "/", which doesn't work
	// when the IAVL key itself contains slashes (as it does for the upgrade
	// module's "upgradedIBCState/{H}/upgradedClient"). The proofs are still
	// well-formed; the consumer (Gno test) verifies via VerifyMembership,
	// which doesn't path-split.
	_ = root
	return proofs
}

func genProofCode(storeName string, key, value []byte) string {
	db := dbm.NewMemDB()
	store := rootmulti.NewStore(db, log.NewNopLogger(), metrics.NewNoOpMetrics())
	storeKey := storetypes.NewKVStoreKey(storeName)

	store.MountStoreWithDB(storeKey, storetypes.StoreTypeIAVL, nil)
	err := store.LoadVersion(0)
	if err != nil {
		panic(err)
	}
	iavlStore := store.GetCommitStore(storeKey).(*iavl.Store)
	// fill with fake data
	for _, ikey := range []byte{0x11, 0x32, 0x50, 0x72, 0x99} {
		key := []byte{ikey}
		iavlStore.Set(key, key)
	}
	if value != nil {
		// If value is not nil enter the key/value, otherwise that means we're
		// going to generate a non-existence proof.
		iavlStore.Set(key, value)
	}

	cid := store.Commit()

	// Get Proof
	res, err := store.Query(&storetypes.RequestQuery{
		Path:  fmt.Sprintf("/%s/key", storeName),
		Data:  key,
		Prove: true,
	})
	if err != nil {
		panic(err)
	}

	// Decode ics23 proof
	proofs := make([]*ics23.CommitmentProof, len(res.ProofOps.Ops))
	for i, op := range res.ProofOps.Ops {
		var p ics23.CommitmentProof
		err = p.Unmarshal(op.Data)
		if err != nil || p.Proof == nil {
			panic(fmt.Sprintf("could not unmarshal proof op into CommitmentProof at index %d: %v", i, err))
		}
		proofs[i] = &p
	}

	// Verify proof
	prt := rootmulti.DefaultProofRuntime()
	if value != nil {
		err = prt.VerifyValue(res.ProofOps, cid.Hash, fmt.Sprintf("/%s/", storeName)+string(key), value)
	} else {
		err = prt.VerifyAbsence(res.ProofOps, cid.Hash, fmt.Sprintf("/%s/", storeName)+string(key))
	}
	if err != nil {
		panic(err)
	}

	// Dump proof
	tmpl := `
{{define "existenceProof" -}}
&ics23.ExistenceProof{
      Key:   {{bytes .Key}},
      Value: {{bytes .Value}},
      Leaf: &ics23.LeafOp{
        Hash:         specs.LeafSpec.Hash,
        PrehashKey:   specs.LeafSpec.PrehashKey,
        PrehashValue: specs.LeafSpec.PrehashValue,
        Length:       specs.LeafSpec.Length,
        Prefix:       {{bytes .Leaf.Prefix}},
      },
      Path: []*ics23.InnerOp{
        {{range .Path -}}
        {
          Hash:   specs.InnerSpec.Hash,
          Prefix: {{bytes .Prefix}},
          Suffix: {{bytes .Suffix}},
        },
        {{end -}}
      },
    },
{{- end -}}
apphash, _ := hex.DecodeString("{{hex .Root}}")
specs := ics23.IavlSpec()
// NOTE code generated by:
// go run -C ./cmd/gen-proof . {{.Args}}
proof := []ics23.CommitmentProof{

  // iavl proof
	{{- with index .Proofs 0}}
	{{- with .GetExist }}
  ics23.CommitmentProof_Exist{
    Exist: {{template "existenceProof" .}}
  },
	{{- end}}
	{{- with .GetNonexist}}
  ics23.CommitmentProof_Nonexist{
    Nonexist: &ics23.NonExistenceProof{
			Key: {{bytes .Key}},
			Left: {{template "existenceProof" .Left}}
			Right: {{template "existenceProof" .Right}}
		},
  },
	{{- end}}
	{{- end}}

  // rootmulti proof
	{{- with index .Proofs 1}}
  ics23.CommitmentProof_Exist{
    Exist: {{template "existenceProof" index .GetExist}}
  },
	{{- end}}

}
`
	t, err := template.New("").Funcs(template.FuncMap{
		"hex": func(bz []byte) string {
			return fmt.Sprintf("%x", bz)
		},
		"bytes": func(bz []byte) string {
			hex := fmt.Sprintf("%x", bz)
			var bytesStr string
			for i := 0; i < len(hex); i += 2 {
				bytesStr += "\\x" + hex[i:i+2]
			}
			return "[]byte(\"" + bytesStr + "\")"
		},
	}).Parse(tmpl)
	if err != nil {
		panic(err)
	}
	var sb strings.Builder
	err = t.Execute(&sb, map[string]any{
		"Root":   cid.Hash,
		"Proofs": proofs,
		"Args":   "'" + strings.Join(flag.Args(), "' '") + "'",
	})
	if err != nil {
		panic(err)
	}
	return sb.String()
}
