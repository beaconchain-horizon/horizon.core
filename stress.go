package main

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"sync"
	"sync/atomic"
	"time"
)

const (
	TargetURL     = "http://127.0.0.1:8091/api/v1/tx"
	// ⚠️ توکن واقعی سرور (از لاگ start-all.bat) را اینجا بگذارید
	AdminToken    = "test-admin-token-12345678901234567890"
	// ⚠️ شناسه لایسنس تولید شده را اینجا بگذارید
	LicenseKey    = "HORIZON-GOLD-001"
	Concurrency   = 100
	TotalRequests = 10000
)

func main() {
	fmt.Printf("🚀 شروع تست TPS با %d تراکنش و %d همزمانی...\n", TotalRequests, Concurrency)
	fmt.Printf("🔑 لایسنس استفاده شده: %s\n", LicenseKey)
	var success int64
	var failed int64
	var wg sync.WaitGroup

	client := &http.Client{Timeout: 5 * time.Second}
	sem := make(chan struct{}, Concurrency)
	startTime := time.Now()

	for i := 0; i < TotalRequests; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			payload := fmt.Sprintf(`{"from":"bank-01","to":"bank-02","amount":1,"tx_id":"tx-%d"}`, id)
			req, _ := http.NewRequest("POST", TargetURL, bytes.NewBufferString(payload))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("X-Admin-Token", AdminToken)
			req.Header.Set("X-License-Key", LicenseKey)

			resp, err := client.Do(req)
			if err != nil {
				atomic.AddInt64(&failed, 1)
				if atomic.LoadInt64(&failed) <= 5 {
					fmt.Printf("\n⚠️ خطای شبکه: %v\n", err)
				}
				return
			}
			defer resp.Body.Close()

			if resp.StatusCode == 200 || resp.StatusCode == 201 || resp.StatusCode == 202 {
				atomic.AddInt64(&success, 1)
			} else {
				atomic.AddInt64(&failed, 1)
				if atomic.LoadInt64(&failed) <= 5 {
					body, _ := io.ReadAll(resp.Body)
					fmt.Printf("\n❌ خطای HTTP %d: %s\n", resp.StatusCode, string(body))
				}
			}
		}(i)
	}

	wg.Wait()
	duration := time.Since(startTime).Seconds()
	tps := float64(success) / duration

	fmt.Println("\n══════════ نتیجه تست ══════════")
	fmt.Printf("⏱  زمان کل:     %.2f ثانیه\n", duration)
	fmt.Printf("✅ موفق:        %d تراکنش\n", success)
	fmt.Printf("❌ ناموفق:      %d تراکنش\n", failed)
	fmt.Printf("⚡ TPS واقعی:   %.2f تراکنش بر ثانیه\n", tps)
	fmt.Println("═══════════════════════════════")
}
