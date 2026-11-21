package wots

import (
	"context"
	"database/sql"
	"errors"
	"testing"

	_ "modernc.org/sqlite"
)

func newTestSM(t *testing.T, max uint32) *StateManager {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	if _, err := db.Exec(`
		CREATE TABLE wots_state (
			tree_id TEXT PRIMARY KEY, next_leaf INTEGER NOT NULL,
			max_leaf INTEGER NOT NULL, last_updated DATETIME NOT NULL,
			hmac BLOB NOT NULL);
		CREATE TABLE wots_leaf_log (
			tree_id TEXT, leaf_index INTEGER, reserved_at DATETIME,
			signature_hash BLOB, PRIMARY KEY (tree_id, leaf_index));
	`); err != nil {
		t.Fatalf("schema: %v", err)
	}

	sm := &StateManager{DB: db, HMACKey: make([]byte, 32), TreeID: "test"}
	if err := sm.InitState(context.Background(), max); err != nil {
		t.Fatalf("init: %v", err)
	}
	return sm
}

func TestReserveIsMonotonic(t *testing.T) {
	sm := newTestSM(t, 5)
	ctx := context.Background()
	prev := int64(-1)
	for i := 0; i < 5; i++ {
		leaf, err := sm.ReserveNextLeaf(ctx)
		if err != nil {
			t.Fatalf("iter %d: %v", i, err)
		}
		if int64(leaf) <= prev {
			t.Fatalf("non-monotonic: %d <= %d", leaf, prev)
		}
		prev = int64(leaf)
	}
}

func TestExhaustion(t *testing.T) {
	sm := newTestSM(t, 2)
	ctx := context.Background()
	_, _ = sm.ReserveNextLeaf(ctx)
	_, _ = sm.ReserveNextLeaf(ctx)
	if _, err := sm.ReserveNextLeaf(ctx); !errors.Is(err, ErrStateExhausted) {
		t.Fatalf("expected exhaustion, got %v", err)
	}
}

func TestTamperDetection(t *testing.T) {
	sm := newTestSM(t, 10)
	ctx := context.Background()
	_, _ = sm.ReserveNextLeaf(ctx)
	_, _ = sm.DB.ExecContext(ctx,
		`UPDATE wots_state SET next_leaf = 0 WHERE tree_id = ?`, sm.TreeID)
	if _, err := sm.ReserveNextLeaf(ctx); !errors.Is(err, ErrStateTampered) {
		t.Fatalf("expected tamper error, got %v", err)
	}
}

func TestHMACKeyTooShort(t *testing.T) {
	sm := newTestSM(t, 5)
	sm.HMACKey = []byte("short")
	if _, err := sm.ReserveNextLeaf(context.Background()); err == nil {
		t.Fatal("expected error for short HMAC key")
	}
}
