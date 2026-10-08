// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/r/aib/ibc/core"
	implv0 "gno.land/r/aib/ibc/core/impl/v0"
)

const (
	v0Path  = "gno.land/r/aib/ibc/core/impl/v0"
	v99Path = "gno.land/r/aib/ibc/core/impl/v99"
)

// v99 is a candidate implementation: v0's logic under a new version, with a
// home page of its own and every other route reused from v0's Renderer.
type v99 struct {
	core.Logic
	store core.Store
}

func (v99) Version() string { return "v99" }

func (v v99) Render(path string) string {
	router := mux.NewRouter()
	router.HandleFunc("", func(w *mux.ResponseWriter, r *mux.Request) {
		w.Write("# IBC core, rendered by v99\n\n" + implv0.RenderImplDisclosure())
	})
	implv0.NewRenderer(v.store).Register(router)
	return router.Render(path)
}

func newV99(s core.Store) core.Logic { return v99{Logic: implv0.New(s), store: s} }

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

// Implementation switch and rollback: state created before the switch stays
// usable, the new implementation emits under the proxy's pkg_path, and
// rollback is a plain UpdateImpl.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	println("at genesis:", core.ImplPath(), core.ImplVersion())

	registerV99(cur)
	println("after register:", core.ImplPath(), core.ImplVersion())
	println("registered:", core.RegisteredImplPaths())

	before := createClient(cur, "chainA-2")

	core.UpdateImpl(cross(cur), v99Path)
	println("after update:", core.ImplPath(), core.ImplVersion())
	println("client before switch:", before, core.ClientStatus(before))
	after := createClient(cur, "chainB-2")
	println("client after switch:", after, core.ClientStatus(after))
	println(core.Render(""))
	println(core.Render("clients/" + before + "/status"))

	core.UpdateImpl(cross(cur), v0Path)
	println("after rollback:", core.ImplPath(), core.ImplVersion())
	println("clients:", core.ClientIDs())
	println(core.Render("admin"))
}

// Output:
// at genesis: gno.land/r/aib/ibc/core/impl/v0 v0
// after register: gno.land/r/aib/ibc/core/impl/v0 v0
// registered: slice[("gno.land/r/aib/ibc/core/impl/v0" string),("gno.land/r/aib/ibc/core/impl/v99" string)]
// after update: gno.land/r/aib/ibc/core/impl/v99 v99
// client before switch: 07-tendermint-1 Active
// client after switch: 07-tendermint-2 Active
// # IBC core, rendered by v99
//
// **Upgradeable realm**: the client and packet lifecycle runs in the implementation [`gno.land/r/aib/ibc/core/impl/v99`](/r/aib/ibc/core/impl/v99) (version v99), replaceable by the authority with `UpdateImpl` (see [`admin`](/r/aib/ibc/core:admin)).
//
//
// {"status":"Active"}
// after rollback: gno.land/r/aib/ibc/core/impl/v0 v0
// clients: slice[("07-tendermint-1" string),("07-tendermint-2" string)]
// ## Authority & Relayers
//
// - **Authority members**:
//   - [g1gjs8…qxd9](/u/g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9)
//   - [g1p84d…zv5r](/u/g1p84dvfh4wrplyxx4zsmy77a8rxcnjup2j7zv5r)
// - **Paused**: false
// - **Implementation**: [`gno.land/r/aib/ibc/core/impl/v0`](/r/aib/ibc/core/impl/v0) (version v0)
// - **Registered implementations**:
//   - [`gno.land/r/aib/ibc/core/impl/v0`](/r/aib/ibc/core/impl/v0)
//   - [`gno.land/r/aib/ibc/core/impl/v99`](/r/aib/ibc/core/impl/v99)
// - **Relayers**: any (whitelist empty)

// Events:
// [
//   {
//     "type": "authority_member_added",
//     "attrs": [
//       {
//         "key": "address",
//         "value": "g1gjs8nfdrd55z3xu9gjcatnj29vkwuyx4ffqxd9"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "create_client",
//     "attrs": [
//       {
//         "key": "client_id",
//         "value": "07-tendermint-1"
//       },
//       {
//         "key": "client_type",
//         "value": "07-tendermint"
//       },
//       {
//         "key": "consensus_heights",
//         "value": "2/2"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "impl_updated",
//     "attrs": [
//       {
//         "key": "old_path",
//         "value": "gno.land/r/aib/ibc/core/impl/v0"
//       },
//       {
//         "key": "new_path",
//         "value": "gno.land/r/aib/ibc/core/impl/v99"
//       },
//       {
//         "key": "version",
//         "value": "v99"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "create_client",
//     "attrs": [
//       {
//         "key": "client_id",
//         "value": "07-tendermint-2"
//       },
//       {
//         "key": "client_type",
//         "value": "07-tendermint"
//       },
//       {
//         "key": "consensus_heights",
//         "value": "2/2"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "impl_updated",
//     "attrs": [
//       {
//         "key": "old_path",
//         "value": "gno.land/r/aib/ibc/core/impl/v99"
//       },
//       {
//         "key": "new_path",
//         "value": "gno.land/r/aib/ibc/core/impl/v0"
//       },
//       {
//         "key": "version",
//         "value": "v0"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   }
// ]
