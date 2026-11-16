Originally from gnolang/bridges, branch `ethereum-draft`, commit
a58efe81c9ebb8849ccc328d7abb0e025d63b90b, `solana/realm/p/decisions/v0`
(`decisions.gno`, `decisions_test.gno`), Copyright (C) 2026 NewTendermint, LLC,
licensed under the GNO Network General Public License (see that repository's
LICENSE.md, including its strong-attribution additional terms). Vendored here as
`gno.land/p/aib/decisions/v0` (ADR pr6375 open question 8: vendor under our own
namespace rather than import the bridge operator's deployment).

Local changes: package and constant documentation, `UnpauseDelay`,
`Decision.Copy` and `Ledger.Find`, `DAOPath` taken from
`gno.land/p/aib/authority/v0`, `Ledger.JSON` quoted as JSON (`jsonmd.Quote`,
not Go's `strconv.Quote`) and paged by decision number, and tests for them.
