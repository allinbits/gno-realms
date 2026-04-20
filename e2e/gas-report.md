# E2E Gas Cost Report

| Operation | GasUsed master branch | GasUsed gas-model-improvements-storage2 | Ratio |
|---|---|---|---|
| CreateClient | 36,634,635 | 73,236,297 | 2.00x |
| RegisterCounterparty | 23,896,178 | 51,679,103 | 2.16x |
| UpdateClient | ~45,000,000 | ~80,000,000 | 1.78x |
| RecvPacket | ~60,000,000 | ~112,000,000 | 1.87x |
| RecvPacket (ack) | ~50,000,000 | ~95,000,000 | 1.90x |
| call:Transfer (IBC) | ~37,000,000 | ~58,000,000 | 1.57x |
| call:Mint (GRC20) | 4,901,238 | 6,301,003 | 1.29x |
| call:Approve (GRC20) | 3,792,999 | 6,238,411 | 1.64x |
