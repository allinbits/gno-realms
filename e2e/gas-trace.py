#!/usr/bin/env python3
"""Parse gastrace store-gas output from gno docker logs into a per-operation
breakdown. See e2e/gas-trace-report.md for the full regeneration recipe.

Requires the e2e gno image built with GO_BUILD_TAGS=gastrace, which makes
gnodev emit (to stderr, hence into `docker compose logs gno`):

    GAS_TX_START mode=deliver gas_wanted=0
    GAS_STORE op=GET            gas=59000  vlen=431 info=depth=false  key_hex=... key_str=...
    GAS_STORE op=DECODE_OBJ     gas=1233   vlen=431 info=cached=false key_hex=... key_str=...
    ...
    GAS_TX_END gas_used=64608327 [meter_charges=... meter_refunds=... meter_net=...]

Each delivered tx is one GAS_TX_START..GAS_TX_END block. The trace lines carry
no operation identity, so we recover it by joining a block's `gas_used` against
the `GasUsed` of gnodev's `event="{...}"` TX_RESULT log, whose tx body / func
tells us which IBC operation ran. Labels are extracted by regex on the raw
escaped line (the MsgRun source bodies break json.loads — that is why
gas-report.md lists those ops with "~" estimates).

Usage:
    docker compose -f e2e/docker-compose.yml logs gno > /tmp/gno.log
    python3 e2e/gas-trace.py /tmp/gno.log            # or: ... | python3 e2e/gas-trace.py
    python3 e2e/gas-trace.py --markdown /tmp/gno.log  # emit a markdown table
"""
import sys
import re
from collections import defaultdict

# Cache I/O, then amino encode/decode, then direct IAVL ops. Order = report order.
CACHE_OPS = ["GET", "SET", "DELETE", "REFUND"]
AMINO_OPS = [
    "DECODE_OBJ", "ENCODE_OBJ", "DECODE_TYPE", "ENCODE_TYPE",
    "DECODE_REALM", "ENCODE_REALM", "DECODE_MEMPKG", "ENCODE_MEMPKG",
]
IAVL_OPS = ["IAVL_SET_ESCAPED", "IAVL_DEL_ESCAPED", "IAVL_SET_MEMPKG", "IAVL_GET_MEMPKG"]
OP_ORDER = CACHE_OPS + AMINO_OPS + IAVL_OPS

TX_START_RE = re.compile(r"GAS_TX_START mode=(\w+)")
TX_END_RE = re.compile(r"GAS_TX_END gas_used=(\d+)")
STORE_RE = re.compile(r"GAS_STORE op=(\S+)\s+gas=(-?\d+)\s+vlen=(\d+)")

# Labelling works directly on the raw escaped `event="{...}"` log line. The
# tx JSON embeds gno source bodies whose escape sequences break json.loads
# (that is also why gas-report.md lists the MsgRun ops with "~" estimates),
# so we extract fields by regex on the escaped text instead.
GAS_USED_RE = re.compile(r'GasUsed\\":(\d+)')
SUCCESS_RE = re.compile(r'Error\\":null')
FUNC_RE = re.compile(r'func\\":\\"([A-Za-z0-9_]+)')
# Lifecycle entry points, in priority order; matched as actual core.<Op>( calls
# so incidental mentions (imports, struct fields) don't mislabel.
CORE_OPS = ["CreateClient", "RegisterCounterparty", "UpdateClient",
            "RecvPacket", "Acknowledgement", "Timeout", "UpgradeClient",
            "RecoverClient", "Misbehaviour", "WriteAcknowledgement"]
CORE_RE = {op: re.compile(r"core\." + op + r"\(") for op in CORE_OPS}


def label_of(line):
    """Identify the IBC operation from a raw TX_RESULT event line."""
    m = FUNC_RE.search(line)
    if m:
        return f"call:{m.group(1)}"
    for op in CORE_OPS:
        if CORE_RE[op].search(line):
            return op
    return "unknown"


def parse(lines):
    # Pass 1: gas_used -> operation label, from successful tx-result events.
    gas_to_label = {}
    for line in lines:
        if "type=TX_RESULT" not in line or not SUCCESS_RE.search(line):
            continue
        m = GAS_USED_RE.search(line)
        if not m:
            continue
        gu = int(m.group(1))
        label = label_of(line)
        # Keep the first non-unknown label seen for a given gas_used.
        if gu not in gas_to_label or gas_to_label[gu] == "unknown":
            gas_to_label[gu] = label

    # Pass 2: walk deliver-mode trace blocks, attribute store gas per op.
    blocks = []  # list of (gas_used, {op: [gas_sum, count]})
    mode = None
    cur = None
    for line in lines:
        m = TX_START_RE.search(line)
        if m:
            mode = m.group(1)
            cur = defaultdict(lambda: [0, 0]) if mode == "deliver" else None
            continue
        m = STORE_RE.search(line)
        if m and cur is not None:
            op, gas = m.group(1), int(m.group(2))
            cur[op][0] += gas
            cur[op][1] += 1
            continue
        m = TX_END_RE.search(line)
        if m:
            if cur is not None:
                blocks.append((int(m.group(1)), dict(cur)))
            mode, cur = None, None

    # Group blocks by operation label.
    by_label = defaultdict(list)
    unknown = 0
    for gas_used, ops in blocks:
        label = gas_to_label.get(gas_used)
        if label is None or label == "unknown":
            unknown += 1
            continue
        by_label[label].append((gas_used, ops))
    return by_label, unknown


def net_store(ops):
    """Net store gas = charged ops minus REFUND (gas returned to the meter)."""
    return sum(g for op, (g, _) in ops.items() if op != "REFUND") - ops.get("REFUND", [0, 0])[0]


def families(op_gas):
    """Group per-op gas into the three trace families. REFUND (a cache-layer
    dedup credit) is netted into Cache I/O."""
    cache = sum(op_gas.get(op, 0) for op in ("GET", "SET", "DELETE")) - op_gas.get("REFUND", 0)
    amino = sum(op_gas.get(op, 0) for op in AMINO_OPS)
    iavl = sum(op_gas.get(op, 0) for op in IAVL_OPS)
    return cache, amino, iavl


def aggregate(blocks):
    """Average per-call totals across all txs sharing a label."""
    n = len(blocks)
    gas_used = sum(b[0] for b in blocks) / n
    op_gas = defaultdict(float)
    op_cnt = defaultdict(float)
    net = 0.0
    for _, ops in blocks:
        net += net_store(ops)
        for op, (g, c) in ops.items():
            op_gas[op] += g
            op_cnt[op] += c
    return {
        "calls": n,
        "gas_used": gas_used,
        "net_store": net / n,
        "op_gas": {op: op_gas[op] / n for op in op_gas},
        "op_cnt": {op: op_cnt[op] / n for op in op_cnt},
    }


def print_text(by_label, unknown):
    for label in sorted(by_label, key=lambda l: -aggregate(by_label[l])["gas_used"]):
        a = aggregate(by_label[label])
        gu, net = a["gas_used"], a["net_store"]
        cache, amino, iavl = families(a["op_gas"])
        print(f"\n=== {label}  (calls={a['calls']}) ===")
        print(f"  GasUsed (avg)       : {gu:>14,.0f}  (billed)")
        print(f"  Traced store gas    : {net:>14,.0f}  (gross cache-store gas)")
        print(f"    cache I/O (net)   : {cache:>14,.0f}  ({pct(cache, net)})")
        print(f"    amino enc/dec     : {amino:>14,.0f}  ({pct(amino, net)})")
        print(f"    IAVL direct       : {iavl:>14,.0f}  ({pct(iavl, net)})")
        for fam, ops in (("cache I/O", CACHE_OPS), ("amino", AMINO_OPS), ("IAVL", IAVL_OPS)):
            rows = [(op, a["op_gas"][op], a["op_cnt"][op]) for op in ops if op in a["op_gas"]]
            if not rows:
                continue
            print(f"  [{fam}]")
            for op, g, c in rows:
                print(f"    {op:<18} gas={g:>14,.0f}  n={c:>6,.1f}")
    if unknown:
        print(f"\n({unknown} deliver-mode tx blocks had no matching labelled "
              f"event — errored/duplicate txs — skipped)")


def pct(part, whole):
    return f"{100 * part / whole:.0f}%" if whole else "-"


def print_markdown(by_label, unknown):
    order = sorted(by_label, key=lambda l: -aggregate(by_label[l])["gas_used"])
    # Summary table: billed cost + traced store-gas families (per-call averages).
    print("| Operation | Calls | GasUsed (avg) | Traced store gas | Cache I/O | Amino | IAVL |")
    print("|---|---|---|---|---|---|---|")
    for label in order:
        a = aggregate(by_label[label])
        gu, net = a["gas_used"], a["net_store"]
        cache, amino, iavl = families(a["op_gas"])
        print(f"| {label} | {a['calls']} | {gu:,.0f} | {net:,.0f} "
              f"| {cache:,.0f} | {amino:,.0f} | {iavl:,.0f} |")
    # Per-category breakdown table (only columns that occur).
    cols = [op for op in OP_ORDER if any(op in aggregate(by_label[l])["op_gas"] for l in by_label)]
    print("\n| Operation | " + " | ".join(cols) + " |")
    print("|---|" + "---|" * len(cols))
    for label in order:
        a = aggregate(by_label[label])
        cells = [f"{a['op_gas'][op]:,.0f}" if op in a["op_gas"] else "·" for op in cols]
        print(f"| {label} | " + " | ".join(cells) + " |")
    if unknown:
        print(f"\n_{unknown} unlabelled deliver tx blocks skipped._")


def main():
    args = sys.argv[1:]
    md = "--markdown" in args
    args = [a for a in args if a != "--markdown"]
    if args:
        with open(args[0]) as f:
            lines = f.readlines()
    else:
        lines = sys.stdin.readlines()
    by_label, unknown = parse(lines)
    if not by_label:
        print("No labelled deliver-mode trace blocks found. Was the image built "
              "with GO_BUILD_TAGS=gastrace, and were the logs captured?",
              file=sys.stderr)
        sys.exit(1)
    (print_markdown if md else print_text)(by_label, unknown)


if __name__ == "__main__":
    main()
