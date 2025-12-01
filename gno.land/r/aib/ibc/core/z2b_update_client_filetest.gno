package main

import (
	"time"

	tmtesting "gno.land/p/aib/ibc/lightclient/tendermint/testing"
	"gno.land/p/aib/ibc/types"
	"gno.land/r/aib/ibc/core"
)

// UpdateClient w/o existing client
func main() {
	var (
		clientID     = "07-tendermint-1"
		chainID      = "chain-id-2"
		apphash      = tmtesting.Hash("apphash")
		latestHeight = types.Height{2, 3}
		newHeight    = uint64(5)
		newTimestamp = time.Now()
		valset       = tmtesting.GenValset()
		msgHeader    = tmtesting.GenMsgHeader(
			chainID, newTimestamp, apphash, newHeight, latestHeight, valset, valset, valset,
		)
	)

	core.UpdateClient(cross, clientID, msgHeader)
}

// Error:
// client 07-tendermint-1 not found
