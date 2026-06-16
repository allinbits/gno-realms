# E2E Store-Gas Trace Report

A per-operation breakdown of **store-level gas** for the IBC v2 lifecycle,
produced with the gno fork's build-tag gas tracer
([gastrace ADR](https://github.com/gnolang/gno/blob/master/gno.land/adr/gastrace.md)).
Where `gas-report.md` reports the *total* `GasUsed` per operation, this report
shows *where inside the store layer* that gas goes — cache I/O (`GET`/`SET`/
`DELETE`), amino encode/decode, and direct IAVL ops — so optimization work has a
target.

Measured on the `ibc-fork-allowall-v4` gno fork, gnodev built with
`-tags gastrace`, running the full `e2e` suite (transfer + VAAS). Numbers are
**per-call averages** (a label's `Calls` column is how many txs were observed).

## Per-operation summary

`GasUsed` is the billed total (from the tx result). The remaining columns are
*traced store gas* split into the three trace families; see
[Reading the numbers](#reading-the-numbers) before comparing them to `GasUsed`.

| Operation | Calls | GasUsed (avg) | Traced store gas | Cache I/O | Amino | IAVL |
|---|---|---|---|---|---|---|
| RecvPacket | 8 | 119,617,232 | 82,785,993 | 75,015,675 | 7,770,318 | 0 |
| Acknowledgement | 3 | 91,060,997 | 75,263,442 | 67,968,245 | 7,295,197 | 0 |
| UpdateClient | 11 | 79,493,952 | 61,535,922 | 55,226,615 | 6,309,307 | 0 |
| CreateClient | 1 | 66,947,361 | 63,111,756 | 56,850,207 | 6,261,549 | 0 |
| call:Transfer | 3 | 61,422,424 | 50,552,943 | 46,862,260 | 3,690,683 | 0 |
| RegisterCounterparty | 1 | 50,433,644 | 56,199,423 | 50,290,881 | 5,908,542 | 0 |
| call:AddRelayer | 1 | 18,290,209 | 25,891,244 | 24,302,678 | 1,588,566 | 0 |
| call:VoucherSend | 1 | 10,870,177 | 18,329,928 | 17,466,606 | 863,322 | 0 |
| call:VoucherApprove | 1 | 10,469,695 | 18,011,256 | 17,227,551 | 783,705 | 0 |
| call:Mint | 1 | 5,224,176 | 12,777,367 | 12,313,582 | 463,785 | 0 |
| call:Approve | 1 | 5,199,011 | 12,776,946 | 12,383,727 | 393,219 | 0 |

## Per-category breakdown

Traced store gas split by individual op (per-call average). `·` = op never
fired for that operation; columns that never occur in the run are omitted.

| Operation | GET | SET | DELETE | REFUND | DECODE_OBJ | ENCODE_OBJ | DECODE_TYPE | DECODE_REALM | ENCODE_REALM | DECODE_MEMPKG |
|---|---|---|---|---|---|---|---|---|---|---|
| RecvPacket | 70,262,179 | 6,074,372 | 126,000 | 1,446,877 | 2,182,872 | 203,766 | 1,808,866 | 1,074 | 1,397 | 3,572,343 |
| Acknowledgement | 65,772,519 | 2,279,274 | 367,600 | 451,148 | 1,670,905 | 72,981 | 1,978,233 | 498 | 237 | 3,572,343 |
| UpdateClient | 52,807,661 | 2,775,208 | 120,000 | 476,254 | 1,251,652 | 112,551 | 1,372,050 | 237 | 474 | 3,572,343 |
| CreateClient | 53,817,847 | 3,507,746 | · | 475,386 | 1,198,248 | 139,641 | 1,350,609 | 234 | 474 | 3,572,343 |
| call:Transfer | 43,048,182 | 5,158,366 | 64,000 | 1,408,288 | 1,573,140 | 210,046 | 1,905,644 | 756 | 1,097 | · |
| RegisterCounterparty | 48,658,365 | 2,108,770 | · | 476,254 | 977,919 | 73,803 | 1,283,766 | 237 | 474 | 3,572,343 |
| call:AddRelayer | 22,855,364 | 1,922,784 | · | 475,470 | 595,071 | 65,325 | 927,468 | 234 | 468 | · |
| call:VoucherSend | 16,215,984 | 1,678,932 | 48,000 | 476,310 | 385,752 | 12,882 | 463,905 | 261 | 522 | · |
| call:VoucherApprove | 16,148,943 | 1,554,918 | · | 476,310 | 311,898 | 7,119 | 463,905 | 261 | 522 | · |
| call:Mint | 11,235,548 | 1,554,442 | · | 476,408 | 265,794 | 6,975 | 190,170 | 282 | 564 | · |
| call:Approve | 11,305,105 | 1,555,030 | · | 476,408 | 195,102 | 7,101 | 190,170 | 282 | 564 | · |

(`ENCODE_TYPE`, `IAVL_*` other than the negligible `IAVL_SET_ESCAPED`, and
`ENCODE_MEMPKG` did not occur for any operation in this run.)

## Observations

- **`GET` dominates everything.** Cache reads are 90–97% of traced store gas for
  every operation. The biggest spenders — `RecvPacket` (~70M), `Acknowledgement`
  (~66M), `CreateClient`/`RegisterCounterparty`/`UpdateClient` (~49–54M) — are
  spending almost all of it loading the realm's persistent object/type graph from
  the store on each call. `SET` (writes) is an order of magnitude smaller.
- **`RecvPacket` is the most expensive operation** (~120M billed), driven by
  proof verification touching the most state, then `Acknowledgement` (~91M) and
  `UpdateClient` (~79.5M, run 11× by the relayer).
- **Amino encode/decode is a distant second** (~5–12% of store gas for the core
  ops, less for the small GRC20 calls). `DECODE_TYPE` + `DECODE_OBJ` lead it.
- **`DECODE_MEMPKG` is a fixed ~3.57M for every relayer `MsgRun` tx** and absent
  from `MsgCall` txs (`Transfer`, `Mint`, …) — it is the cost of decoding the
  submitted `run.gno` program's mempackage. A flat per-`MsgRun` tax.
- **Direct IAVL ops are negligible** here (only escaped-object hash writes, ~0).

## Reading the numbers

`gastrace` traces **store-level gas only** — cache I/O, amino encode/decode, and
direct IAVL ops. It does **not** trace VM compute, the ante handler, or the block
gas meter (see the ADR's *Scope* and *Limitations*).

"Traced store gas" is therefore **not a strict subset of billed `GasUsed`**, and
the two columns should not be divided. The tracer logs the *gross* gas a cache
access would cost (the cache gas config's flat + per-byte + depth-read price) at
**every** access; the gas meter bills less when a read is served from a warm
higher-layer cache. For small txs dominated by realm object-graph reads the
traced figure exceeds the billed total (e.g. `call:Approve`: 12.8M traced vs 5.2M
billed). Concretely, the meter reconciles as `gas_used = meter_charges −
meter_refunds` (`AddRelayer`: 18,765,679 − 475,470 = 18,290,209), and even the
gross `meter_charges` (18.77M) sits below the traced store gas (25.89M).

So use this report for **relative** analysis — which operations and which store
categories dominate — not as a literal fraction of `GasUsed`. (The ADR notes
traced gas is typically ~40–70% of total; under this gas model the gross trace
runs higher, and exceeds 100% for the cheapest txs.) `REFUND` is a cache-layer
dedup credit and is netted out of the Cache I/O column.

## How to regenerate this report

1. Build the e2e gno image with the tracer enabled and start the services. The
   `GO_BUILD_TAGS` opt-in (default empty) adds `-tags gastrace` to the `gnodev`
   build; gastrace writes `GAS_STORE`/`GAS_TX_*` lines to stderr, captured by
   `docker compose logs gno`:

   ```bash
   GO_BUILD_TAGS=gastrace make e2e-up
   ```

2. Run the e2e test suite (exercises the full lifecycle: client setup by the
   relayer + token transfers + VAAS):

   ```bash
   cd e2e && go test -v -timeout 10m -count=1 ./...
   ```

3. Capture the gno logs and parse them into the tables above:

   ```bash
   COMPOSE_PROJECT_NAME=e2e docker compose -f e2e/docker-compose.yml logs gno > /tmp/gno.log
   python3 e2e/gas-trace.py --markdown /tmp/gno.log   # markdown tables for this file
   python3 e2e/gas-trace.py /tmp/gno.log              # detailed per-op text breakdown
   ```

4. Update the tables above, then stop the services:

   ```bash
   make e2e-down
   ```

`e2e/gas-trace.py` recovers per-operation labels by joining each deliver-mode
`GAS_TX_END gas_used=N` block against the `GasUsed=N` of gnodev's `TX_RESULT`
event log. Deliver blocks with no matching labelled event (startup package
deployments, errored relayer retries) are reported as skipped.
