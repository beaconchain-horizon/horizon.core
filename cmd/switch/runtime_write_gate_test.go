package main

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestRuntimeReadinessFailsClosedOnEmptySchema(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open isolated sqlite: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get isolated sqlite DB: %v", err)
	}
	defer sqlDB.Close()
	old := runtimeWritesAllowed.Load()
	runtimeWritesAllowed.Store(false)
	t.Cleanup(func() { runtimeWritesAllowed.Store(old) })
	if err := configureRuntimeWriteReadiness(db); err == nil {
		t.Fatal("empty schema unexpectedly passed runtime readiness")
	}
	if runtimeWritesAllowed.Load() {
		t.Fatal("runtime writes became enabled with empty schema")
	}
}

func TestRecoveryWriteGateBlocksMutationUntilReady(t *testing.T) {
	old := runtimeWritesAllowed.Load()
	runtimeWritesAllowed.Store(false)
	t.Cleanup(func() { runtimeWritesAllowed.Store(old) })
	gin.SetMode(gin.TestMode)
	called := false
	r := gin.New()
	r.Use(recoveryWriteGateMiddleware())
	r.POST("/mutate", func(c *gin.Context) { called = true; c.Status(http.StatusOK) })
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/mutate", nil))
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d, want 503", w.Code)
	}
	if called {
		t.Fatal("mutation handler ran while recovery gate was closed")
	}
}

func TestRecoveryWriteGateAllowsReadMethodsUntilReady(t *testing.T) {
	old := runtimeWritesAllowed.Load()
	runtimeWritesAllowed.Store(false)
	t.Cleanup(func() { runtimeWritesAllowed.Store(old) })
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(recoveryWriteGateMiddleware())
	r.GET("/read", func(c *gin.Context) { c.Status(http.StatusOK) })
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/read", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d, want 200", w.Code)
	}
}

func TestRecoveryWriteGateAllowsMutationAfterCanonicalReadiness(t *testing.T) {
	old := runtimeWritesAllowed.Load()
	runtimeWritesAllowed.Store(true)
	t.Cleanup(func() { runtimeWritesAllowed.Store(old) })
	gin.SetMode(gin.TestMode)
	called := false
	r := gin.New()
	r.Use(recoveryWriteGateMiddleware())
	r.POST("/mutate", func(c *gin.Context) { called = true; c.Status(http.StatusOK) })
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/mutate", nil))
	if w.Code != http.StatusOK || !called {
		t.Fatalf("status=%d called=%v, want 200/true", w.Code, called)
	}
}
