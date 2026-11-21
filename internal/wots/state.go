package wots

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

var (
	ErrStateExhausted = errors.New("wots: tree exhausted")
	ErrStateTampered  = errors.New("wots: HMAC mismatch")
)

type StateManager struct {
	DB      *sql.DB
	HMACKey []byte
	TreeID  string
}

func (s *StateManager) ReserveNextLeaf(ctx context.Context) (uint32, error) {
	if len(s.HMACKey) < 32 {
		return 0, errors.New("wots: HMACKey must be >= 32 bytes")
	}
	tx, err := s.DB.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
	if err != nil {
		return 0, fmt.Errorf("wots: begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var next, max uint32
	var storedMAC []byte
	if err := tx.QueryRowContext(ctx,
		`SELECT next_leaf, max_leaf, hmac FROM wots_state WHERE tree_id = ?`,
		s.TreeID).Scan(&next, &max, &storedMAC); err != nil {
		return 0, fmt.Errorf("wots: read state: %w", err)
	}
	if !hmac.Equal(storedMAC, s.mac(s.TreeID, next)) {
		return 0, ErrStateTampered
	}
	if next >= max {
		return 0, ErrStateExhausted
	}

	claimed := next
	newNext := next + 1

	if _, err := tx.ExecContext(ctx,
		`UPDATE wots_state SET next_leaf = ?, last_updated = ?, hmac = ? WHERE tree_id = ?`,
		newNext, time.Now().UTC(), s.mac(s.TreeID, newNext), s.TreeID); err != nil {
		return 0, fmt.Errorf("wots: update: %w", err)
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO wots_leaf_log (tree_id, leaf_index, reserved_at) VALUES (?, ?, ?)`,
		s.TreeID, claimed, time.Now().UTC()); err != nil {
		return 0, fmt.Errorf("wots: log: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("wots: commit: %w", err)
	}
	return claimed, nil
}

func (s *StateManager) InitState(ctx context.Context, maxLeaf uint32) error {
	if maxLeaf == 0 {
		return errors.New("wots: maxLeaf must be > 0")
	}
	_, err := s.DB.ExecContext(ctx,
		`INSERT INTO wots_state (tree_id, next_leaf, max_leaf, last_updated, hmac)
		 VALUES (?, 0, ?, ?, ?)`,
		s.TreeID, maxLeaf, time.Now().UTC(), s.mac(s.TreeID, 0))
	return err
}

func (s *StateManager) mac(treeID string, next uint32) []byte {
	h := hmac.New(sha256.New, s.HMACKey)
	fmt.Fprintf(h, "%s|%d", treeID, next)
	return h.Sum(nil)
}
