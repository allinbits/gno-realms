// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/r/aib/ibc/core"
	implv0 "gno.land/r/aib/ibc/core/impl/v0"
)

const (
	v0Path  = "gno.land/r/aib/ibc/core/impl/v0"
	v99Path = "gno.land/r/aib/ibc/core/impl/v99"
)

// v99 is a candidate implementation: v0's logic under a new version.
type v99 struct{ core.Logic }

func (v99) Version() string { return "v99" }

func newV99(s core.Store) core.Logic { return v99{Logic: implv0.New(s)} }

// registerV99 registers the candidate as if from its own realm.
func registerV99(cur realm) {
	testing.SetRealm(testing.NewCodeRealm(v99Path))
	core.RegisterImpl(cross(cur), newV99)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
}

func createClient(cur realm, chainID string) string {
	return core.CreateClient(cross(cur),
		tmtesting.NewClientState(chainID, types.NewHeight(2, 2)),
		tmtesting.GenConsensusState(time.Now(), []byte("apphash"), tmtesting.GenValset().Hash()),
	)
}

// RegisterImpl refuses a realm outside the proxy's impl namespace.
func main(cur realm) {
	core.RegisterImpl(cross(cur), newV99)
}

// Error:
// RegisterImpl: caller gno.land/r/aib/main is not under gno.land/r/aib/ibc/core/impl/
