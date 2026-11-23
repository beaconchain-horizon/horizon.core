package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
)

// ============================================================
// ADMIN SESSION STORE (in-memory)
// ============================================================

var (
	adminSessions = make(map[string]time.Time)
	adminMutex    sync.RWMutex

	auditLog   []AuditEntry
	auditMutex sync.Mutex
)

type AuditEntry struct {
	ID        int64  `json:"id"`
	Timestamp int64  `json:"timestamp"`
	Action    string `json:"action"`
	Target    string `json:"target"`
	Details   string `json:"details"`
	IP        string `json:"ip"`
}

func sessionTTL() int {
	s := os.Getenv("ADMIN_SESSION_TTL")
	if s == "" {
		return 3600
	}
	v, err := strconv.Atoi(s)
	if err != nil || v <= 0 {
		return 3600
	}
	return v
}

func checkAdminPassword(input string) bool {
	envHash := os.Getenv("ADMIN_PASSWORD_HASH")
	if envHash == "" {
		return false
	}
	return bcrypt.CompareHashAndPassword([]byte(envHash), []byte(input)) == nil
}

func createAdminSession() string {
	b := make([]byte, 32)
	rand.Read(b)
	tok := hex.EncodeToString(b)
	adminMutex.Lock()
	adminSessions[tok] = time.Now().Add(time.Duration(sessionTTL()) * time.Second)
	adminMutex.Unlock()
	return tok
}

func validateAdminSession(tok string) bool {
	adminMutex.RLock()
	exp, ok := adminSessions[tok]
	adminMutex.RUnlock()
	return ok && time.Now().Before(exp)
}

func revokeAdminSession(tok string) {
	adminMutex.Lock()
	delete(adminSessions, tok)
	adminMutex.Unlock()
}

// ============================================================
// AUDIT
// ============================================================

func addAudit(action, target, details, ip string) {
	auditMutex.Lock()
	defer auditMutex.Unlock()
	auditLog = append(auditLog, AuditEntry{
		ID:        int64(len(auditLog) + 1),
		Timestamp: time.Now().Unix(),
		Action:    action,
		Target:    target,
		Details:   details,
		IP:        ip,
	})
	if len(auditLog) > 500 {
		auditLog = auditLog[len(auditLog)-500:]
	}
}

// ============================================================
// MIDDLEWARE
// ============================================================

func adminAuthRequired() gin.HandlerFunc {
	envToken := os.Getenv("ADMIN_TOKEN")
	return func(c *gin.Context) {
		tok := c.GetHeader("X-Admin-Token")
		if tok == "" {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "no token"})
			return
		}

		// Check 1: env ADMIN_TOKEN (master token)
		isValid := false
		if envToken != "" && tok == envToken {
			isValid = true
		}
		// Check 2: session token (from adminLoginHandler)
		if !isValid && validateAdminSession(tok) {
			isValid = true
		}

		if !isValid {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid or expired token"})
			return
		}

		stateMutex.RLock()
		key := unlockedKey
		stateMutex.RUnlock()
		if key == nil {
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"error": "key is locked — call /api/v1/key/unlock first"})
			return
		}
		c.Next()
	}
}

// ============================================================
// HANDLERS
// ============================================================

func adminLoginHandler(c *gin.Context) {
	var req struct {
		Password string `json:"password" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if !checkAdminPassword(req.Password) {
		addAudit("login_fail", "-", "wrong password", c.ClientIP())
		c.JSON(http.StatusUnauthorized, gin.H{"error": "wrong password"})
		return
	}
	tok := createAdminSession()
	addAudit("login", "-", "admin logged in", c.ClientIP())
	c.JSON(http.StatusOK, gin.H{
		"status":     "ok",
		"token":      tok,
		"expires_in": sessionTTL(),
	})
}

func adminLogoutHandler(c *gin.Context) {
	tok := c.GetHeader("X-Admin-Token")
	revokeAdminSession(tok)
	addAudit("logout", "-", "admin logged out", c.ClientIP())
	c.JSON(http.StatusOK, gin.H{"status": "logged out"})
}

func listBanksHandler(c *gin.Context) {
	var banks []BankAccount
	db.Order("created_at desc").Find(&banks)

	type bankWithLicense struct {
		BankAccount
		Balance float64  `json:"balance"`
		License *License `json:"license,omitempty"`
	}

	out := make([]bankWithLicense, 0, len(banks))
	for _, b := range banks {
		var lic License
		var ptr *License
		if err := db.Where("user_id = ?", b.BankID).
			Order("created_at desc").
			First(&lic).Error; err == nil {
			ptr = &lic
		}

		var acc Account
		db.Where("bank_id = ?", b.BankID).First(&acc)

		out = append(out, bankWithLicense{
			BankAccount: b,
			Balance:     acc.Balance,
			License:     ptr,
		})
	}

	c.JSON(http.StatusOK, gin.H{
		"total": len(out),
		"banks": out,
	})
}

func adminAuditHandler(c *gin.Context) {
	auditMutex.Lock()
	defer auditMutex.Unlock()
	out := make([]AuditEntry, len(auditLog))
	for i, e := range auditLog {
		out[len(auditLog)-1-i] = e
	}
	c.JSON(http.StatusOK, gin.H{
		"total":   len(out),
		"entries": out,
	})
}

func adminIssueLicenseHandler(c *gin.Context) {
	var req struct {
		OrganizationID string `json:"organization_id" binding:"required"`
		LicenseID      string `json:"license_id" binding:"required"`
		UserID         string `json:"user_id" binding:"required"`
		ProductID      string `json:"product_id"`
		Volume         int    `json:"volume"`
		Duration       int    `json:"duration"`
		LicenseType    string `json:"license_type"`
		MerkleRoot     string `json:"merkle_root"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	stateMutex.RLock()
	key := unlockedKey
	stateMutex.RUnlock()
	if key == nil {
		c.JSON(http.StatusForbidden, gin.H{"error": "key locked"})
		return
	}
	if req.ProductID == "" {
		req.ProductID = "horizon-core"
	}
	if req.Duration == 0 {
		req.Duration = 8760
	}
	if req.LicenseType == "" {
		req.LicenseType = "client"
	}
	if req.Volume <= 0 || req.Duration < 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "volume must be positive and duration non-negative"})
		return
	}

	now := time.Now().Unix()
	lic := &License{
		LicenseID: req.LicenseID, OrganizationID: req.OrganizationID,
		UserID: req.UserID, ProductID: req.ProductID, Volume: req.Volume,
		Duration: req.Duration, MerkleRoot: req.MerkleRoot,
		IssuedAt: now, ExpiresAt: now + int64(req.Duration*86400),
		Status: "active", LicenseType: req.LicenseType,
	}
	if lic.MerkleRoot == "" {
		lic.MerkleRoot = licenseMerkleRoot(lic)
	}
	sig, err := signData(key, []byte(licenseCanonicalMessage(lic)))
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "sign failed: " + err.Error()})
		return
	}
	lic.Signature = sig
	// WOTS remains intentionally empty: the current implementation is not
	// a production-safe stateful one-time signature system.
	lic.WOTSSignature = ""
	lic.WOTSPubKey = ""

	input := OrganizationLicenseInput{
		LicenseID: lic.LicenseID, UserID: lic.UserID, ProductID: lic.ProductID,
		Volume: lic.Volume, Duration: lic.Duration, Signature: lic.Signature,
		MerkleRoot: lic.MerkleRoot, IssuedAt: lic.IssuedAt, ExpiresAt: lic.ExpiresAt,
		HardwareID: lic.HardwareID, LicenseType: lic.LicenseType,
		WOTSSignature: lic.WOTSSignature, WOTSPubKey: lic.WOTSPubKey,
	}
	block, err := CreateOrganizationBlockWithLicenses(db, key, req.OrganizationID, []OrganizationLicenseInput{input})
	if err != nil {
		c.JSON(http.StatusConflict, gin.H{"error": "organization license block was not created", "reason": err.Error()})
		return
	}
	lic.BlockNum = block.BlockNum

	addAudit("issue_license", lic.LicenseID, "organization="+req.OrganizationID+" block="+fmt.Sprint(block.BlockNum), c.ClientIP())
	checkLicenseNow()
	c.JSON(http.StatusCreated, gin.H{"license": lic, "block": block})
}

func revokeLicenseHandler(c *gin.Context) {
	// Revocation currently has no canonical organization-block event contract.
	// Refuse the legacy direct status update rather than changing registry state
	// without an immutable, verifiable chain record.
	c.JSON(http.StatusServiceUnavailable, gin.H{
		"error": "license revocation is paused until the canonical organization event is implemented",
		"code": "V15_CANONICAL_REVOCATION_REQUIRED",
	})
}
