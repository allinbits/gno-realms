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
  "gno.land/p/aib/jsonmd/v0:gno.land/p/aib/jsonmd/v0"
  "gno.land/p/aib/ibc/host/v0:gno.land/p/aib/ibc/host/v0"
  "gno.land/p/aib/authority/v0:gno.land/p/aib/authority/v0"
  "gno.land/p/aib/encoding/wire/v0:gno.land/p/aib/encoding/wire/v0"
  "gno.land/p/aib/encoding/ethaddr/v0:gno.land/p/aib/encoding/ethaddr/v0"
  "gno.land/p/aib/decisions/v0:gno.land/p/aib/decisions/v0"

  # depends on encoding/proto
  "gno.land/p/aib/ics23/v0:gno.land/p/aib/ics23/v0"

  # depends on ics23
  "gno.land/p/aib/ibc/testing/v0:gno.land/p/aib/ibc/testing/v0"

  # depends on encoding, encoding/proto, ibc/host, ics23
  "gno.land/p/aib/ibc/types/v0:gno.land/p/aib/ibc/types/v0"

  # depends on encoding/proto, ibc/host, ibc/types (ICS-20 types of the transfer app)
  "gno.land/p/aib/ibc/ics20/v0:gno.land/p/aib/ibc/ics20/v0"

  # depends on ics20 (Solidity ABI payloads), then the general ABI encoder
  # (whose tests compare with it)
  "gno.land/p/aib/ibc/ics20/abi/v0:gno.land/p/aib/ibc/ics20/abi/v0"
  "gno.land/p/aib/encoding/abi/v0:gno.land/p/aib/encoding/abi/v0"

  # depends on ibc/types
  "gno.land/p/aib/ibc/app/v0:gno.land/p/aib/ibc/app/v0"
  "gno.land/p/aib/ibc/lightclient/extproof/v0:gno.land/p/aib/ibc/lightclient/extproof/v0"

  # depends on encoding/wire, ibc/host, ibc/types (the Ethereum route controls)
  "gno.land/p/aib/ibc/ics20/controls/v0:gno.land/p/aib/ibc/ics20/controls/v0"

  # depends on ibc/types, ics23
  "gno.land/p/aib/ibc/lightclient/v0:gno.land/p/aib/ibc/lightclient/v0"

  # depends on encoding/proto, ibc/lightclient, ibc/types, ics23, merkle
  "gno.land/p/aib/ibc/lightclient/tendermint/v0:gno.land/p/aib/ibc/lightclient/tendermint/v0"

  # depends on lightclient/tendermint, ibc/types, ics23
  "gno.land/p/aib/ibc/lightclient/tendermint/testing/v0:gno.land/p/aib/ibc/lightclient/tendermint/testing/v0"

  # depends on encoding/wire, ibc/lightclient, lightclient/extproof, ibc/types,
  # ics23 (and the crypto/bls12381 native)
  "gno.land/p/aib/ibc/lightclient/ethereum/v0:gno.land/p/aib/ibc/lightclient/ethereum/v0"
  "gno.land/p/aib/ibc/lightclient/ethereum/testing/v0:gno.land/p/aib/ibc/lightclient/ethereum/testing/v0"

  # realms (stateful)
  # grc20test has no aib deps
  "gno.land/r/aib/ibc/apps/testing/grc20test:gno.land/r/aib/ibc/apps/testing/grc20test"

  # depends on ibc/app, ibc/types
  "gno.land/r/aib/ibc/apps/testing:gno.land/r/aib/ibc/apps/testing"

  # depends on ibc/app, ibc/host, ibc/lightclient, lightclient/tendermint,
  # lightclient/ethereum, lightclient/tendermint/testing (filetest),
  # ibc/types, ics23, jsonpage
  "gno.land/r/aib/ibc/core:gno.land/r/aib/ibc/core"

  # depends on r/aib/ibc/core (registers itself as the core logic at init)
  "gno.land/r/aib/ibc/core/impl/v0:gno.land/r/aib/ibc/core/impl/v0"

  # depends on encoding/proto, ibc/app, ibc/host, lightclient/tendermint,
  # ibc/types, ics23, jsonpage, grc20test (filetest), r/aib/ibc/core
  "gno.land/r/aib/ibc/apps/transfer:gno.land/r/aib/ibc/apps/transfer"

  # depends on r/aib/ibc/apps/transfer: the ICS-20 logic of non-Ethereum
  # clients, which transfer impl/v1 embeds; it registers nothing
  "gno.land/r/aib/ibc/apps/transfer/impl/v0:gno.land/r/aib/ibc/apps/transfer/impl/v0"

  # depends on r/aib/ibc/core, lightclient/ethereum, encoding/wire, extproof
  "gno.land/r/aib/ibc/ethrelay:gno.land/r/aib/ibc/ethrelay"

  # the governance realm: depends on decisions, encoding/abi, encoding/ethaddr,
  # ics20/controls, lightclient/ethereum, r/aib/ibc/core,
  # r/aib/ibc/apps/transfer, r/gov/dao; registers port gov at init
  "gno.land/r/aib/ibc/ibcgov:gno.land/r/aib/ibc/ibcgov"

  # core impl/v1 (client migration), a candidate activated by an ibcgov
  # decision (UpdateImpl, 7 days)
  "gno.land/r/aib/ibc/core/impl/v1:gno.land/r/aib/ibc/core/impl/v1"

  # transfer impl/v1 (route controls; depends on impl/v0 and ibcgov): the
  # transfer app's first registration, so its initial implementation on a
  # fresh deployment. The proxy carries no transfer until it is deployed.
  "gno.land/r/aib/ibc/apps/transfer/impl/v1:gno.land/r/aib/ibc/apps/transfer/impl/v1"
)
