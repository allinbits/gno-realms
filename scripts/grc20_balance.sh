set -euox pipefail

ADDR="${ADDR:-g1z437dpuh5s4p64vtq09dulg6jzxpr2hd4q8r5x}" # relayer
REMOTE="${REMOTE:-https://rpc.test13.testnets.gno.land/}"
GRC20KEY="${GRC20KEY:-gno.land/r/aib/ibc/apps/transfer.542B346608DE032752AF0B21D165190090CD3194F6D177CF35025E39596ABC16}"

gnokey query vm/qeval \
	--data "gno.land/r/demo/defi/grc20reg.MustGet(\"$GRC20KEY\").BalanceOf(\"$ADDR\")" \
	-remote $REMOTE
