// PKGPATH: gno.land/r/aib/main
package main

import (
	"testing"
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"
	"gno.land/p/aib/ibc/types/v0"
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
	_ "gno.land/r/aib/ibc/core/impl/v0"
)

const successorPath = "gno.land/r/third/party/successor"

// ReplaceApp hands an active port to a pending registration in one step. The
// successor keeps the pause state of the port, and once resumed it receives the
// port's packets instead of the previous app.
func main(cur realm) {
	core.AddAuthorityMember(cross(cur), cur.Address())
	clientID := core.CreateClient(cross(cur),
		tmtesting.NewClientState("chain-id-2", types.NewHeight(2, 2)),
		tmtesting.GenConsensusState(time.Now(), tmtesting.Hash("apphash"), tmtesting.GenValset().Hash()),
	)
	core.RegisterCounterparty(cross(cur), clientID, [][]byte{[]byte("iavlStoreKey"), []byte("prefix2")}, "07-tendermint-2")

	previous := appstesting.NewApp(cross(cur))
	core.RegisterApp(cross(cur), "app1", previous)
	core.PauseApp(cross(cur), "app1")

	successor := appstesting.NewApp(cross(cur))
	testing.SetRealm(testing.NewCodeRealm(successorPath))
	core.RegisterApp(cross(cur), "app1", successor)
	println("queued:", core.IsAppPending("app1", successorPath), "active:", core.AppPkgPath("app1"))

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/aib/main"))
	core.ReplaceApp(cross(cur), "app1", successorPath)
	println("pending:", core.IsAppPending("app1", successorPath), "active:", core.AppPkgPath("app1"), "paused:", core.IsAppPaused("app1"))
	println("apps:", core.Render("apps"))

	core.UnpauseApp(cross(cur), "app1")
	core.SendPacket(cross(cur), types.MsgSendPacket{
		SourceClient:     clientID,
		TimeoutTimestamp: uint64(time.Now().Add(time.Hour).Unix()),
		Payloads: []types.Payload{{
			SourcePort:      "app1",
			DestinationPort: "destinationPort",
			Encoding:        "application/json",
			Value:           []byte("{}"),
			Version:         "v1",
		}},
	})
	println("previous app:", previous.Report())
	println("successor app:", successor.Report())
}

// Output:
// queued: true active: gno.land/r/aib/main
// pending: false active: gno.land/r/third/party/successor paused: true
// apps: [{"port_id":"app1","pkg_path":"gno.land/r/third/party/successor","address":"g1nd0m8dglnjwdt2r32z4mljhwaxwxf00vnr9xm7","paused":true}]
// previous app: OnSendPacket (0)
// OnRecvPacket (0)
// OnTimeoutPacket (0)
// OnAcknowledgementPacket (0)
//
// successor app: OnSendPacket (1)
// - sourceClient: 07-tendermint-1
// - destinationClient: 07-tendermint-2
// - sequence: 1
// - payload:
//   - sourcePort: app1
//   - destinationPort: destinationPort
//   - version: v1
//   - encoding: application/json
//   - value: {}
//
// OnRecvPacket (0)
// OnTimeoutPacket (0)
// OnAcknowledgementPacket (0)

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
//     "type": "app_registered",
//     "attrs": [
//       {
//         "key": "port",
//         "value": "app1"
//       },
//       {
//         "key": "pkg_path",
//         "value": "gno.land/r/aib/main"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "app_paused",
//     "attrs": [
//       {
//         "key": "port",
//         "value": "app1"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "app_registration_pending",
//     "attrs": [
//       {
//         "key": "port",
//         "value": "app1"
//       },
//       {
//         "key": "pkg_path",
//         "value": "gno.land/r/third/party/successor"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "app_replaced",
//     "attrs": [
//       {
//         "key": "port",
//         "value": "app1"
//       },
//       {
//         "key": "old_pkg_path",
//         "value": "gno.land/r/aib/main"
//       },
//       {
//         "key": "new_pkg_path",
//         "value": "gno.land/r/third/party/successor"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "app_unpaused",
//     "attrs": [
//       {
//         "key": "port",
//         "value": "app1"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   },
//   {
//     "type": "send_packet",
//     "attrs": [
//       {
//         "key": "packet_source_client",
//         "value": "07-tendermint-1"
//       },
//       {
//         "key": "packet_dest_client",
//         "value": "07-tendermint-2"
//       },
//       {
//         "key": "packet_sequence",
//         "value": "1"
//       },
//       {
//         "key": "packet_timeout_timestamp",
//         "value": "1234571490"
//       },
//       {
//         "key": "encoded_packet_hex",
//         "value": "0801120f30372d74656e6465726d696e742d311a0f30372d74656e6465726d696e742d3220e2a1d8cc042a310a0461707031120f64657374696e6174696f6e506f72741a02763122106170706c69636174696f6e2f6a736f6e2a027b7d"
//       }
//     ],
//     "pkg_path": "gno.land/r/aib/ibc/core"
//   }
// ]
