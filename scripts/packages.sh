# The packages and realms of this repo, in deploy order. Sourced by deploy.sh
# (one addpkg per entry) and make-deploy-tx.sh (all entries in one tx), never
# executed:
#
#   source "$(dirname "$0")/packages.sh"
#
# ---- deploy order -----------------------------------------------------------
# Format: "<gno.land/pkgpath>:<local dir relative to repo root>"
# Order is topological: a package only depends on entries above it.
PACKAGES=(
  # leaf packages (no aib deps)
  "gno.land/p/aib/encoding:gno.land/p/aib/encoding"
  "gno.land/p/aib/encoding/proto:gno.land/p/aib/encoding/proto"
  "gno.land/p/aib/merkle:gno.land/p/aib/merkle"
  "gno.land/p/aib/jsonpage:gno.land/p/aib/jsonpage"
  "gno.land/p/aib/ibc/host:gno.land/p/aib/ibc/host"
  "gno.land/p/aib/authority:gno.land/p/aib/authority"

  # depends on encoding/proto
  "gno.land/p/aib/ics23:gno.land/p/aib/ics23"

  # depends on ics23
  "gno.land/p/aib/ibc/testing:gno.land/p/aib/ibc/testing"

  # depends on encoding, encoding/proto, ibc/host, ics23
  "gno.land/p/aib/ibc/types:gno.land/p/aib/ibc/types"

  # depends on ibc/types
  "gno.land/p/aib/ibc/app:gno.land/p/aib/ibc/app"

  # depends on ibc/types, ics23
  "gno.land/p/aib/ibc/lightclient:gno.land/p/aib/ibc/lightclient"

  # depends on encoding/proto, ibc/lightclient, ibc/types, ics23, merkle
  "gno.land/p/aib/ibc/lightclient/tendermint:gno.land/p/aib/ibc/lightclient/tendermint"

  # depends on lightclient/tendermint, ibc/types, ics23
  "gno.land/p/aib/ibc/lightclient/tendermint/testing:gno.land/p/aib/ibc/lightclient/tendermint/testing"

  # realms (stateful)
  # grc20test has no aib deps
  "gno.land/r/aib/ibc/apps/testing/grc20test:gno.land/r/aib/ibc/apps/testing/grc20test"

  # depends on ibc/app, ibc/types
  "gno.land/r/aib/ibc/apps/testing:gno.land/r/aib/ibc/apps/testing"

  # depends on ibc/app, ibc/host, ibc/lightclient, lightclient/tendermint,
  # lightclient/tendermint/testing (filetest), ibc/types, ics23, jsonpage
  "gno.land/r/aib/ibc/core:gno.land/r/aib/ibc/core"

  # depends on encoding/proto, ibc/app, ibc/host, lightclient/tendermint,
  # ibc/types, ics23, jsonpage, grc20test (filetest), r/aib/ibc/core
  "gno.land/r/aib/ibc/apps/transfer:gno.land/r/aib/ibc/apps/transfer"
)
