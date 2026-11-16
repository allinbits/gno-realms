package ics20

import "gno.land/p/aib/ibc/types/v0"

// SuccessAck is the ICS-20 success acknowledgement, {"result":"AQ=="}: what
// every receive answers, what a credit by vote writes, and what the Ethereum
// ICS20 contract writes (ICS20Lib.SUCCESSFUL_ACKNOWLEDGEMENT_JSON).
func SuccessAck() types.AppAcknowledgement {
	return types.NewResultAppAcknowledgement([]byte{byte(1)})
}
