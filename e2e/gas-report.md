# E2E Gas Cost Report

| Operation | Old gas model | New gas model | Ratio |
|---|---|---|---|
| CreateClient | 36,634,635 | 64,608,327 | 1.76x |
| RegisterCounterparty | 23,896,178 | 44,306,191 | 1.85x |
| UpdateClient | ~45,000,000 | ~72,100,000 | 1.60x |
| RecvPacket | ~60,000,000 | ~103,000,000 | 1.72x |
| RecvPacket (ack) | ~50,000,000 | ~87,000,000 | 1.74x |
| call:Transfer (IBC) | ~37,000,000 | ~55,000,000 | 1.49x |
| call:Mint (GRC20) | 4,901,238 | 4,915,434 | 1.00x |
| call:Approve (GRC20) | 3,792,999 | 4,853,243 | 1.28x |

The "Old gas model" column is the baseline measured before the merge of
gas-model-improvements-storage2; the "New gas model" column reflects the
current gno `ibc-fork` branch.

## How to regenerate this report

1. Start the e2e services (rebuilds the gno image from the local `../gno` repo
   on the `ibc-fork` branch):

   ```bash
   make e2e-up
   ```

2. Run the e2e test suite:

   ```bash
   cd e2e && go test -v -timeout 10m -count=1 ./...
   ```

3. Extract the per-operation gas usage from the gno container logs:

   ```bash
   COMPOSE_PROJECT_NAME=e2e docker compose -f e2e/docker-compose.yml logs gno 2>&1 | python3 -c "
   import sys, re, json
   for line in sys.stdin:
       m = re.search(r'event=\"(\{.*?\})\"', line)
       if not m: continue
       try:
           s = m.group(1).replace('\\\\\"','\"').replace('\\\"','\"')
           d = json.loads(s)
           r = d.get('response',{})
           gw = r.get('GasWanted')
           gu = r.get('GasUsed')
           err = r.get('Error')
           if gw and not err:
               msgs = d.get('tx',{}).get('msg',[])
               label = 'unknown'
               for msg in msgs:
                   pkg = msg.get('package',{})
                   for f in pkg.get('files',[]):
                       body = f.get('body','')
                       if 'CreateClient' in body: label = 'CreateClient'
                       elif 'RegisterCounterparty' in body: label = 'RegisterCounterparty'
                       elif 'RecvPacket' in body: label = 'RecvPacket'
                       elif 'Acknowledgement' in body: label = 'Acknowledgement'
                       elif 'UpdateClient' in body: label = 'UpdateClient'
                       elif 'Timeout' in body: label = 'Timeout'
                   func = msg.get('func','')
                   if func: label = f'call:{func}'
               print(f'{label:30s} GasWanted={gw:>12,}  GasUsed={gu:>12,}')
       except: pass
   "
   ```

4. Update the table above with the new `GasUsed` values, then stop the services:

   ```bash
   make e2e-down
   ```
