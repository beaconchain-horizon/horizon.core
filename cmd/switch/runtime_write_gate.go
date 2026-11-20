package main

import (
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// runtimeWritesAllowed remains false until the configured chain ID and both
// persisted ledgers pass the locked v1.4 startup checks.
var runtimeWritesAllowed atomic.Bool

func configureRuntimeWriteReadiness(db *gorm.DB) error {
	runtimeWritesAllowed.Store(false)
	if db == nil {
		return fmt.Errorf("nil database")
	}

	var issues []string
	cfg := GetChainConfig()
	if cfg == nil || cfg.ChainID != "horizon-core-v1.4" {
		actual := "<nil>"
		if cfg != nil {
			actual = cfg.ChainID
		}
		issues = append(issues, fmt.Sprintf("configured Chain ID %q does not match locked horizon-core-v1.4", actual))
	}

	initErr := initLicenseChain(db)
	if initErr != nil {
		issues = append(issues, fmt.Sprintf("license registry initialization check failed: %v", initErr))
	}
	if err := validateMainBlockChainForWrite(db); err != nil {
		issues = append(issues, fmt.Sprintf("main ledger is not canonical: %v", err))
	}
	if initErr == nil {
		if err := validateLicenseChainForWrite(db); err != nil {
			issues = append(issues, fmt.Sprintf("license ledger is not canonical: %v", err))
		}
	}
	if len(issues) != 0 {
		return fmt.Errorf("%s", strings.Join(issues, "; "))
	}

	// Structural continuity is not cryptographic verification. Do not reopen
	// writes until every historical block hash and signature, plus transaction
	// membership, has been independently verified against locked v1.4 rules.
	return fmt.Errorf("cryptographic history verification is not yet implemented; recovery write gate remains closed")
}

// recoveryWriteGateMiddleware leaves read-only methods available and rejects
// all HTTP mutations until both ledgers and the Chain ID pass startup checks.
func recoveryWriteGateMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		if runtimeWritesAllowed.Load() {
			c.Next()
			return
		}
		switch c.Request.Method {
		case http.MethodGet, http.MethodHead, http.MethodOptions:
			c.Next()
			return
		default:
			c.AbortWithStatusJSON(http.StatusServiceUnavailable, gin.H{
				"error": "Horizon is in recovery read-only mode",
				"code":  "CANONICAL_CHAIN_VALIDATION_REQUIRED",
			})
			return
		}
	}
}
