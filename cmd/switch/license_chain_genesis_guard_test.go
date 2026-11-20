package main

import "testing"

func TestLicenseChainSafetyGatesFailClosed(t *testing.T) {

	schemaCases := []struct {
		value string
		want  bool
	}{
		{"", false}, {"false", false}, {"TRUE", false}, {"true", true},
	}
	for _, tc := range schemaCases {
		t.Run("schema_"+tc.value, func(t *testing.T) {
			t.Setenv(licenseChainSchemaMigrationEnv, tc.value)
			if got := licenseChainSchemaMigrationAllowed(); got != tc.want {
				t.Fatalf("schema migration gate = %v, want %v", got, tc.want)
			}
		})
	}
	for _, value := range []string{"", "false", "TRUE", "true"} {
		t.Run("genesis_never_enabled_"+value, func(t *testing.T) {
			t.Setenv(licenseChainGenesisBootstrapEnv, value)
			if licenseChainGenesisBootstrapAllowed() {
				t.Fatal("runtime Genesis bootstrap must never be enabled")
			}
		})
	}

}
