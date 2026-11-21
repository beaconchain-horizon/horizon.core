package main

import (
	"os"
	"strings"
	"testing"
)

func TestProductionLicenseIssuanceDoesNotUseExperimentalWOTS(t *testing.T) {
	source, err := os.ReadFile("admin.go")
	if err != nil {
		t.Fatalf("read admin.go: %v", err)
	}
	text := string(source)
	forbidden := []string{
		"wots.GenerateKeyPair(",
		"wots.Sign(",
		"horizon-pqc-fallback-seed-2026-11-13-authority",
		"D:/pqkey.txt",
	}
	for _, item := range forbidden {
		if strings.Contains(text, item) {
			t.Errorf("unsafe PQ signing reference remains in production license issuer: %q", item)
		}
	}
	if !strings.Contains(text, "lic.WOTSSignature = \"\"") || !strings.Contains(text, "lic.WOTSPubKey = \"\"") {
		t.Fatal("new license issuance must leave experimental WOTS fields empty")
	}
}
