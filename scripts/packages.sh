# The packages and realms of this repo, in deploy order. Sourced by deploy.sh
# (one addpkg per entry) and make-deploy-tx.sh (all entries in one tx), never
# executed:
#
#   source "$(dirname "$0")/packages.sh"
#
# ---- deploy order -----------------------------------------------------------
# Format: "<gno.land/pkgpath>:<local dir relative to repo root>"
# Order is topological: a package only depends on entries above it.
# The impl/v99 realms (upgrade rehearsal, e2e only) are deliberately absent.
PACKAGES=(
  # leaf packages (no aib deps)
  "gno.land/p/aib/encoding/v0:gno.land/p/aib/encoding/v0"
  "gno.land/p/aib/encoding/proto/v0:gno.land/p/aib/encoding/proto/v0"
  "gno.land/p/aib/merkle/v0:gno.land/p/aib/merkle/v0"
  "gno.land/p/aib/jsonpage/v0:gno.land/p/aib/jsonpage/v0"
  "gno.land/p/aib/ibc/host/v0:gno.land/p/aib/ibc/host/v0"
  "gno.land/p/aib/authority/v0:gno.land/p/aib/authority/v0"

  # depends on encoding/proto
  "gno.land/p/aib/ics23/v0:gno.land/p/aib/ics23/v0"

  # depends on ics23
  "gno.land/p/aib/ibc/testing/v0:gno.land/p/aib/ibc/testing/v0"

  # depends on encoding, encoding/proto, ibc/host, ics23
  "gno.land/p/aib/ibc/types/v0:gno.land/p/aib/ibc/types/v0"

  # depends on encoding/proto, ibc/host, ibc/types (ICS-20 types of the transfer app)
  "gno.land/p/aib/ibc/ics20/v0:gno.land/p/aib/ibc/ics20/v0"

  # depends on ibc/types
  "gno.land/p/aib/ibc/app/v0:gno.land/p/aib/ibc/app/v0"

  # depends on ibc/types, ics23
  "gno.land/p/aib/ibc/lightclient/v0:gno.land/p/aib/ibc/lightclient/v0"

  # depends on encoding/proto, ibc/lightclient, ibc/types, ics23, merkle
  "gno.land/p/aib/ibc/lightclient/tendermint/v0:gno.land/p/aib/ibc/lightclient/tendermint/v0"

  # depends on lightclient/tendermint, ibc/types, ics23
  "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0:gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"

  # realms (stateful)
  # grc20test has no aib deps
  "gno.land/r/aib/ibc/apps/testing/grc20test:gno.land/r/aib/ibc/apps/testing/grc20test"

  # depends on ibc/app, ibc/types
  "gno.land/r/aib/ibc/apps/testing:gno.land/r/aib/ibc/apps/testing"

  # depends on ibc/app, ibc/host, ibc/lightclient, lightclient/tendermint,
  # lightclient/tendermint/testing (filetest), ibc/types, ics23, jsonpage
  "gno.land/r/aib/ibc/core:gno.land/r/aib/ibc/core"

  # depends on r/aib/ibc/core (registers itself as the core logic at init)
  "gno.land/r/aib/ibc/core/impl/v0:gno.land/r/aib/ibc/core/impl/v0"

  # depends on encoding/proto, ibc/app, ibc/host, lightclient/tendermint,
  # ibc/types, ics23, jsonpage, grc20test (filetest), r/aib/ibc/core
  "gno.land/r/aib/ibc/apps/transfer:gno.land/r/aib/ibc/apps/transfer"

  # depends on r/aib/ibc/apps/transfer (registers itself as the transfer logic at init)
  "gno.land/r/aib/ibc/apps/transfer/impl/v0:gno.land/r/aib/ibc/apps/transfer/impl/v0"
)
