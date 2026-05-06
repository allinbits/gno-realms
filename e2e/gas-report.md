# E2E Gas Cost Report

| Operation | Old gas model | New gas model | Ratio |
|---|---|---|---|
| CreateClient | 36,634,635 | 40,203,012 | 1.10x |
| RegisterCounterparty | 23,896,178 | 27,414,330 | 1.15x |
| UpdateClient | ~45,000,000 | ~48,700,000 | 1.08x |
| RecvPacket | ~60,000,000 | ~64,000,000 | 1.06x |
| RecvPacket (ack) | ~50,000,000 | ~54,000,000 | 1.08x |
| call:Transfer (IBC) | ~37,000,000 | ~36,000,000 | 0.97x |
| call:Mint (GRC20) | 4,901,238 | 4,901,228 | 1.00x |
| call:Approve (GRC20) | 3,792,999 | 3,792,989 | 1.00x |
