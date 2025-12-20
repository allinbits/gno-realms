package tendermint_test

import (
	"strings"
	"testing"
	"time"

	"gno.land/p/aib/ibc/lightclient/tendermint"
	"gno.land/p/aib/ibc/types"
)

func TestMisbehaviourValidateBasic(t *testing.T) {
	var misbehaviour *tendermint.Misbehaviour
	tests := []struct {
		name     string
		malleate func()
		expErr   string
	}{
		{
			name:     "valid misbehaviour, two headers of different height same time",
			malleate: func() {},
			expErr:   "",
		},
		// TODO continue
		/*
			{
				name:     "valid fork misbehaviour, two headers at same height have different time",
				malleate: func() {},
				expErr:   "",
			},
				{
					"valid time misbehaviour, both headers at different heights are at same time",
					&tendermint.Misbehaviour{
						Header1:  s.chainA.CreateTMClientHeader(chainID, int64(height.RevisionHeight+5), heightMinus1, s.now, s.valSet, s.valSet, s.valSet, s.signers),
						Header2:  s.header,
						ClientId: clientID,
					},
					func(misbehaviour *tendermint.Misbehaviour) error { return nil },
					nil,
				},
				{
					"misbehaviour Header1 is nil",
					NewMisbehaviour(clientID, nil, s.header),
					func(m *Misbehaviour) error { return nil },
					errorsmod.Wrap(ErrInvalidHeader, "misbehaviour Header1 cannot be nil"),
				},
				{
					"misbehaviour Header2 is nil",
					NewMisbehaviour(clientID, s.header, nil),
					func(m *Misbehaviour) error { return nil },
					errorsmod.Wrap(ErrInvalidHeader, "misbehaviour Header2 cannot be nil"),
				},
				{
					"valid misbehaviour with different trusted headers",
					&Misbehaviour{
						Header1:  s.header,
						Header2:  s.chainA.CreateTMClientHeader(chainID, int64(height.RevisionHeight), clienttypes.NewHeight(0, height.RevisionHeight-3), s.now.Add(time.Minute), s.valSet, s.valSet, bothValSet, s.signers),
						ClientId: clientID,
					},
					func(misbehaviour *Misbehaviour) error { return nil },
					nil,
				},
				{
					"trusted height is 0 in Header1",
					&Misbehaviour{
						Header1:  s.chainA.CreateTMClientHeader(chainID, int64(height.RevisionHeight), clienttypes.ZeroHeight(), s.now.Add(time.Minute), s.valSet, s.valSet, s.valSet, s.signers),
						Header2:  s.header,
						ClientId: clientID,
					},
					func(misbehaviour *Misbehaviour) error { return nil },
					errorsmod.Wrap(ErrInvalidHeaderHeight, "misbehaviour Header1 cannot have zero revision height"),
				},
				{
					"trusted height is 0 in Header2",
					&Misbehaviour{
						Header1:  s.header,
						Header2:  s.chainA.CreateTMClientHeader(chainID, int64(height.RevisionHeight), clienttypes.ZeroHeight(), s.now.Add(time.Minute), s.valSet, s.valSet, s.valSet, s.signers),
						ClientId: clientID,
					},
					func(misbehaviour *Misbehaviour) error { return nil },
					errorsmod.Wrap(ErrInvalidHeaderHeight, "misbehaviour Header2 cannot have zero revision height"),
				},
				{
					"trusted valset is nil in Header1",
					&Misbehaviour{
						Header1:  s.chainA.CreateTMClientHeader(chainID, int64(height.RevisionHeight), heightMinus1, s.now.Add(time.Minute), s.valSet, s.valSet, nil, s.signers),
						Header2:  s.header,
						ClientId: clientID,
					},
					func(misbehaviour *Misbehaviour) error { return nil },
					errorsmod.Wrap(ErrInvalidValidatorSet, "trusted validator set in Header1 cannot be empty"),
				},
				{
					"trusted valset is nil in Header2",
					&Misbehaviour{
						Header1:  s.header,
						Header2:  s.chainA.CreateTMClientHeader(chainID, int64(height.RevisionHeight), heightMinus1, s.now.Add(time.Minute), s.valSet, s.valSet, nil, s.signers),
						ClientId: clientID,
					},
					func(misbehaviour *Misbehaviour) error { return nil },
					errorsmod.Wrap(ErrInvalidValidatorSet, "trusted validator set in Header2 cannot be empty"),
				},
				{
					"invalid client ID ",
					&Misbehaviour{
						Header1:  s.header,
						Header2:  s.chainA.CreateTMClientHeader(chainID, int64(height.RevisionHeight), heightMinus1, s.now, s.valSet, s.valSet, s.valSet, s.signers),
						ClientId: "GAI",
					},
					func(misbehaviour *Misbehaviour) error { return nil },
					errors.New("identifier GAI has invalid length"),
				},
				{
					"chainIDs do not match",
					&Misbehaviour{
						Header1:  s.header,
						Header2:  s.chainA.CreateTMClientHeader("ethermint", int64(height.RevisionHeight), heightMinus1, s.now, s.valSet, s.valSet, s.valSet, s.signers),
						ClientId: clientID,
					},
					func(misbehaviour *Misbehaviour) error { return nil },
					errorsmod.Wrap(clienttypes.ErrInvalidMisbehaviour, "headers must have identical chainIDs"),
				},
				{
					"header2 height is greater",
					&Misbehaviour{
						Header1:  s.header,
						Header2:  s.chainA.CreateTMClientHeader(chainID, 6, clienttypes.NewHeight(0, height.RevisionHeight+1), s.now, s.valSet, s.valSet, s.valSet, s.signers),
						ClientId: clientID,
					},
					func(misbehaviour *Misbehaviour) error { return nil },
					errors.New("Header1 height is less than Header2 height"),
				},
				{
					"header 1 doesn't have 2/3 majority",
					&Misbehaviour{
						Header1:  s.chainA.CreateTMClientHeader(chainID, int64(height.RevisionHeight), heightMinus1, s.now, bothValSet, bothValSet, s.valSet, bothSigners),
						Header2:  s.header,
						ClientId: clientID,
					},
					func(misbehaviour *Misbehaviour) error {
						// voteSet contains only altVal which is less than 2/3 of total power (height/1height)
						wrongVoteSet := cmttypes.NewVoteSet(chainID, int64(misbehaviour.Header1.GetHeight().GetRevisionHeight()), 1, cmtproto.PrecommitType, altValSet)
						blockID, err := cmttypes.BlockIDFromProto(&misbehaviour.Header1.Commit.BlockID)
						if err != nil {
							return err
						}

						extCommit, err := cmttypes.MakeExtCommit(*blockID, int64(misbehaviour.Header2.GetHeight().GetRevisionHeight()), misbehaviour.Header1.Commit.Round, wrongVoteSet, altSignerArr, s.now, false)
						misbehaviour.Header1.Commit = extCommit.ToCommit().ToProto()
						return err
					},
					errors.New("validator set did not commit to header"),
				},
				{
					"header 2 doesn't have 2/3 majority",
					&Misbehaviour{
						Header1:  s.header,
						Header2:  s.chainA.CreateTMClientHeader(chainID, int64(height.RevisionHeight), heightMinus1, s.now, bothValSet, bothValSet, s.valSet, bothSigners),
						ClientId: clientID,
					},
					func(misbehaviour *Misbehaviour) error {
						// voteSet contains only altVal which is less than 2/3 of total power (height/1height)
						wrongVoteSet := cmttypes.NewVoteSet(chainID, int64(misbehaviour.Header2.GetHeight().GetRevisionHeight()), 1, cmtproto.PrecommitType, altValSet)
						blockID, err := cmttypes.BlockIDFromProto(&misbehaviour.Header2.Commit.BlockID)
						if err != nil {
							return err
						}

						extCommit, err := cmttypes.MakeExtCommit(*blockID, int64(misbehaviour.Header2.GetHeight().GetRevisionHeight()), misbehaviour.Header2.Commit.Round, wrongVoteSet, altSignerArr, s.now, false)
						misbehaviour.Header2.Commit = extCommit.ToCommit().ToProto()
						return err
					},
					errors.New("validator set did not commit to header"),
				},
				{
					"validators sign off on wrong commit",
					&Misbehaviour{
						Header1:  s.header,
						Header2:  s.chainA.CreateTMClientHeader(chainID, int64(height.RevisionHeight), heightMinus1, s.now, bothValSet, bothValSet, s.valSet, bothSigners),
						ClientId: clientID,
					},
					func(misbehaviour *Misbehaviour) error {
						tmBlockID := ibctesting.MakeBlockID(tmhash.Sum([]byte("other_hash")), 3, tmhash.Sum([]byte("other_partset")))
						misbehaviour.Header2.Commit.BlockID = tmBlockID.ToProto()
						return nil
					},
					errors.New("header 2 failed validation"),
				},
		*/
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var header1, header2 *tendermint.MsgHeader
			// NOTE code generated by:
			// go run -C ./cmd/gen-block-signatures . -chainid=gno.land -header-time-shift=0 -height=3 -new-validators=0 -privkeys=JR6fAmf/x02hJxbgPlOUlEw82K1g5L6t7T0ochto3n/IQH0mFRpgSOtSqy3rxrjQmFKzT36uAKK7mHczlEvg0w==,uUowEMik5bYqOuxT8xXS6+vhmeJ1ogEoG7lUuKColILehBmNNm2bNvn7IQmuyrnkIhRFVI2XQ6tO4HWVxCFoOA==
			{
				var (
					apphash = hash("apphash-3")
					// priv=JR6fAmf/x02hJxbgPlOUlEw82K1g5L6t7T0ochto3n/IQH0mFRpgSOtSqy3rxrjQmFKzT36uAKK7mHczlEvg0w==
					val1 = tendermint.NewValidator("ZekR7Mi3r4Uewt3lPS3YmWPr81o=", "yEB9JhUaYEjrUqst68a40JhSs09+rgCiu5h3M5RL4NM=", 10)
					// priv=uUowEMik5bYqOuxT8xXS6+vhmeJ1ogEoG7lUuKColILehBmNNm2bNvn7IQmuyrnkIhRFVI2XQ6tO4HWVxCFoOA==
					val2            = tendermint.NewValidator("mdEIzF8KCHUrBT16vM7dhc/nZ4Q=", "3oQZjTZtmzb5+yEJrsq55CIURVSNl0OrTuB1lcQhaDg=", 10)
					valset          = tendermint.NewValset(val1, val2)
					commitTimestamp = toTime("2025-09-25T07:55:57.306746166Z")
					newHeight       = uint64(3)
					newTimestamp    = time.Now()
					nextValset      = tendermint.NewValset(val1, val2)
					trustedValset   = tendermint.NewValset(val1, val2)
					trustedHeight   = types.NewHeight(0, 2)

					signatures = []tendermint.CommitSig{
						{
							BlockIDFlag:      tendermint.BlockIDFlagCommit,
							ValidatorAddress: valset.Validators[0].Address,
							Timestamp:        commitTimestamp,
							Signature:        []byte("\x70\x47\xa3\x9d\x70\xe7\x8b\x61\x51\xb8\x76\xfb\x0a\xf1\xd8\xb9\x98\x54\x57\x68\xe5\x5a\x93\x9d\x6a\x4e\x1e\x0f\x1e\xa7\xce\x8c\x58\x93\xfc\xe7\x58\x85\xb2\x7a\x8d\xe1\x1f\xde\xda\x10\x0f\x85\xcd\x42\x0a\xa1\xff\x20\xb3\x8b\x7c\x20\xc6\x56\x83\xf9\xf5\x09"),
						},
						{
							BlockIDFlag:      tendermint.BlockIDFlagCommit,
							ValidatorAddress: valset.Validators[1].Address,
							Timestamp:        commitTimestamp,
							Signature:        []byte("\x80\x31\x76\x91\x4f\x71\x3e\xe5\x4f\xcf\xd1\x9e\xff\x49\x90\xbb\x09\x81\x22\x6d\xb0\x23\x85\xc3\x07\x49\x3a\x20\x75\x7e\x10\x4f\x98\x97\xb0\x0b\xa2\xdb\x49\x8c\x4c\x6d\xc6\x40\xd6\x6f\x16\xad\x0f\xf6\xff\xa6\x9f\x8e\x51\x95\xc1\x39\x78\x74\x24\x0e\x80\x02"),
						},
					}
				)

				header1 = newMsgHeader(
					chainID, newTimestamp, apphash, newHeight, trustedHeight, valset,
					nextValset, trustedValset, signatures,
				)
			}
			// NOTE code generated by:
			// go run -C ./cmd/gen-block-signatures . -chainid=gno.land -header-time-shift=0 -height=2 -new-validators=0 -privkeys=JR6fAmf/x02hJxbgPlOUlEw82K1g5L6t7T0ochto3n/IQH0mFRpgSOtSqy3rxrjQmFKzT36uAKK7mHczlEvg0w==,uUowEMik5bYqOuxT8xXS6+vhmeJ1ogEoG7lUuKColILehBmNNm2bNvn7IQmuyrnkIhRFVI2XQ6tO4HWVxCFoOA==
			{
				var (
					apphash = hash("apphash-2")
					// priv=JR6fAmf/x02hJxbgPlOUlEw82K1g5L6t7T0ochto3n/IQH0mFRpgSOtSqy3rxrjQmFKzT36uAKK7mHczlEvg0w==
					val1 = tendermint.NewValidator("ZekR7Mi3r4Uewt3lPS3YmWPr81o=", "yEB9JhUaYEjrUqst68a40JhSs09+rgCiu5h3M5RL4NM=", 10)
					// priv=uUowEMik5bYqOuxT8xXS6+vhmeJ1ogEoG7lUuKColILehBmNNm2bNvn7IQmuyrnkIhRFVI2XQ6tO4HWVxCFoOA==
					val2            = tendermint.NewValidator("mdEIzF8KCHUrBT16vM7dhc/nZ4Q=", "3oQZjTZtmzb5+yEJrsq55CIURVSNl0OrTuB1lcQhaDg=", 10)
					valset          = tendermint.NewValset(val1, val2)
					commitTimestamp = toTime("2025-09-25T07:55:57.306746166Z")
					newHeight       = uint64(2)
					newTimestamp    = time.Now()
					nextValset      = tendermint.NewValset(val1, val2)
					trustedValset   = tendermint.NewValset(val1, val2)
					trustedHeight   = types.NewHeight(0, 1)

					signatures = []tendermint.CommitSig{
						{
							BlockIDFlag:      tendermint.BlockIDFlagCommit,
							ValidatorAddress: valset.Validators[0].Address,
							Timestamp:        commitTimestamp,
							Signature:        []byte("\x05\x93\x46\x01\x51\x5e\x42\xd2\xdc\xef\xd4\x07\xc2\x13\x92\x03\xb2\x5c\x1a\xae\xf8\x45\x98\x5d\xea\xc1\x7a\xb8\xec\x8b\x48\x82\xf6\x76\xfe\xf6\xbd\x26\xc9\xb2\x59\x8c\xf3\xa1\xdc\x6e\xa5\xf5\xef\x3b\x7a\x5d\xa0\xa9\xb9\xcc\x8f\x62\xc7\xa6\x95\xae\xdc\x09"),
						},
						{
							BlockIDFlag:      tendermint.BlockIDFlagCommit,
							ValidatorAddress: valset.Validators[1].Address,
							Timestamp:        commitTimestamp,
							Signature:        []byte("\x8d\xe9\x5c\x39\xdf\x3f\x15\xe8\xa8\x20\x90\x6f\xa1\x2f\xf1\x04\xb6\x1e\xd1\xbf\x9b\xd3\xc9\x3f\x0b\xcc\x81\x76\xdc\x0f\xf7\x75\x0a\x5a\xed\x9f\x7d\xb9\x9e\x37\x3c\xcc\x5b\x38\x6d\x5d\x34\x32\x45\x85\x9d\xb0\x6c\x09\x49\x89\x39\x8f\xe8\x00\x82\x0f\x2f\x04"),
						},
					}
				)

				header2 = newMsgHeader(
					chainID, newTimestamp, apphash, newHeight, trustedHeight, valset,
					nextValset, trustedValset, signatures,
				)
			}
			misbehaviour = &tendermint.Misbehaviour{
				Header1: header1,
				Header2: header2,
			}
			if tt.malleate != nil {
				tt.malleate()
			}

			err := misbehaviour.ValidateBasic()

			if tt.expErr == "" && err != nil {
				t.Errorf("expected no error got %v", err)
				return
			}
			if tt.expErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.expErr) {
					t.Errorf("expected error %s, got %s", tt.expErr, err)
				}
			}
		})
	}
}
