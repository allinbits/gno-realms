package main

// The chain is a minimal-preset chain: every preset value the generator
// uses is the consensus specs' minimal preset's (presets/minimal/*.yaml),
// which TestPresetIsMinimal checks against a consensus-specs checkout.
const (
	presetSyncCommitteeSize               = 32
	presetSlotsPerEpoch                   = 8
	presetEpochsPerSyncCommitteePeriod    = 8
	presetSlotsPerHistoricalRoot          = 64
	presetEpochsPerEth1VotingPeriod       = 4
	presetMaxTransactionsPerPayload       = 1 << 20
	presetMaxWithdrawalsPerPayload        = 4
	presetMaxProposerSlashings            = 16
	presetMaxAttesterSlashingsElectra     = 1
	presetMaxAttestationsElectra          = 8
	presetMaxDeposits                     = 16
	presetMaxVoluntaryExits               = 16
	presetMaxBLSToExecutionChanges        = 16
	presetMaxBlobCommitmentsPerBlock      = 4096
	presetMaxDepositRequestsPerPayload    = 8192
	presetMaxWithdrawalRequestsPerPayload = 16
	presetMaxConsolidationRequests        = 2
	presetBytesPerLogsBloom               = 256
	presetMaxExtraDataBytes               = 32
)

// presetNames maps each value to its name in the presets.
var presetNames = map[string]uint64{
	"SYNC_COMMITTEE_SIZE":                    presetSyncCommitteeSize,
	"SLOTS_PER_EPOCH":                        presetSlotsPerEpoch,
	"EPOCHS_PER_SYNC_COMMITTEE_PERIOD":       presetEpochsPerSyncCommitteePeriod,
	"SLOTS_PER_HISTORICAL_ROOT":              presetSlotsPerHistoricalRoot,
	"EPOCHS_PER_ETH1_VOTING_PERIOD":          presetEpochsPerEth1VotingPeriod,
	"MAX_TRANSACTIONS_PER_PAYLOAD":           presetMaxTransactionsPerPayload,
	"MAX_WITHDRAWALS_PER_PAYLOAD":            presetMaxWithdrawalsPerPayload,
	"MAX_PROPOSER_SLASHINGS":                 presetMaxProposerSlashings,
	"MAX_ATTESTER_SLASHINGS_ELECTRA":         presetMaxAttesterSlashingsElectra,
	"MAX_ATTESTATIONS_ELECTRA":               presetMaxAttestationsElectra,
	"MAX_DEPOSITS":                           presetMaxDeposits,
	"MAX_VOLUNTARY_EXITS":                    presetMaxVoluntaryExits,
	"MAX_BLS_TO_EXECUTION_CHANGES":           presetMaxBLSToExecutionChanges,
	"MAX_BLOB_COMMITMENTS_PER_BLOCK":         presetMaxBlobCommitmentsPerBlock,
	"MAX_DEPOSIT_REQUESTS_PER_PAYLOAD":       presetMaxDepositRequestsPerPayload,
	"MAX_WITHDRAWAL_REQUESTS_PER_PAYLOAD":    presetMaxWithdrawalRequestsPerPayload,
	"MAX_CONSOLIDATION_REQUESTS_PER_PAYLOAD": presetMaxConsolidationRequests,
	"BYTES_PER_LOGS_BLOOM":                   presetBytesPerLogsBloom,
	"MAX_EXTRA_DATA_BYTES":                   presetMaxExtraDataBytes,
}

// depth is log2 of a power-of-two list limit: the depth of its chunk tree.
func depth(limit uint64) int {
	d := 0
	for uint64(1)<<uint(d) < limit {
		d++
	}
	if uint64(1)<<uint(d) != limit {
		panic("limit is not a power of two")
	}
	return d
}
