package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// The committed data file is what the generator writes.
func TestGeneratedFileIsCurrent(t *testing.T) {
	want, err := generate()
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile("../../gno.land/p/aib/ibc/lightclient/ethereum/v0/zz_synthetic_test.gno")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatal("zz_synthetic_test.gno is stale: regenerate it (see main.go)")
	}
}

// The justification states the history gives, which a run of the spec's
// weigh_justification_and_finalization over the same history reproduces.
func TestJustification(t *testing.T) {
	for _, tc := range []struct {
		epoch, previous, current uint64
		bits                     byte
	}{{18, 17, 18, 0x0f}, {19, 18, 18, 0x0e}} {
		s := ffgAfter(tc.epoch)
		if s.previousJustified.epoch != tc.previous || s.currentJustified.epoch != tc.current || s.bitsByte() != tc.bits || s.final.epoch != 17 {
			t.Fatalf("after epoch %d: %+v", tc.epoch, s)
		}
	}
}

// Every preset value the generator uses is the minimal preset's. Set
// CONSENSUS_SPECS to a consensus-specs checkout to check.
func TestPresetIsMinimal(t *testing.T) {
	dir := os.Getenv("CONSENSUS_SPECS")
	if dir == "" {
		t.Skip("CONSENSUS_SPECS is not set")
	}
	files, err := filepath.Glob(filepath.Join(dir, "presets", "minimal", "*.yaml"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no presets under %s: %v", dir, err)
	}
	found := map[string]uint64{}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, line := range strings.Split(string(b), "\n") {
			name, value, ok := strings.Cut(line, ":")
			if !ok || strings.HasPrefix(name, "#") || strings.HasPrefix(name, " ") {
				continue
			}
			if v, err := strconv.ParseUint(strings.TrimSpace(value), 10, 64); err == nil {
				found[strings.TrimSpace(name)] = v
			}
		}
	}
	for name, want := range presetNames {
		got, ok := found[name]
		if !ok || got != want {
			t.Errorf("%s: minimal preset %d (found %v), generator %d", name, got, ok, want)
		}
	}
}
