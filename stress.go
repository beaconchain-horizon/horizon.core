package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sync"
	"sync/atomic"
	"time"
)

const (
	TargetURL     = "http://127.0.0.1:8091/api/v1/tx"
	SessionURL    = "http://127.0.0.1:8091/api/v1/signing/session"
	AdminToken    = "bench0000000000000000000000000000000000000000000000000000000bench"
	LicenseID     = "HORIZON-GOLD-001"
	Concurrency   = 200             // افزایش همزمانی برای سرعت بیشتر
	TotalRequests = 10000000        // ۱۰ میلیون تراکنش
)

type SessionResp struct {
	SessionToken string `json:"session_token"`
	Token        string `json:"token"`
}

func getSessionToken(client *http.Client) (string, error) {
	req, _ := http.NewRequest("POST", SessionURL, nil)
	req.Header.Set("X-Admin-Token", AdminToken)
	req.Header.Set("X-License-ID", LicenseID)

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("session error %d: %s", resp.StatusCode, string(body))
	}

	var sResp SessionResp
	if err := json.NewDecoder(resp.Body).Decode(&sResp); err != nil {
		return "", err
	}

	if sResp.SessionToken != "" {
		return sResp.SessionToken, nil
	}
	if sResp.Token != "" {
		return sResp.Token, nil
	}
	return "", fmt.Errorf("no token in response")
}

func main() {
	fmt.Printf("🚀 شروع تست سنگین TPS با %d تراکنش و %d همزمانی...\n", TotalRequests, Concurrency)
	fmt.Printf("🔑 لایسنس استفاده شده: %s\n", LicenseID)

	var success int64
	var failed int64
	var wg sync.WaitGroup

	client := &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			MaxIdleConns:        Concurrency,
			MaxIdleConnsPerHost: Concurrency,
			IdleConnTimeout:     30 * time.Second,
		},
	}
	sem := make(chan struct{}, Concurrency)
	startTime := time.Now()

	// گزارش‌گر پیشرفت در پس‌زمینه
	go func() {
		for {
			time.Sleep(10 * time.Second)
			s := atomic.LoadInt64(&success)
			f := atomic.LoadInt64(&failed)
			total := s + f
			if total >= TotalRequests {
				break
			}
			fmt.Printf("⏳ پیشرفت: %d موفق، %d ناموفق (کل: %d از %d) - زمان سپری شده: %.0f ثانیه\n", s, f, total, TotalRequests, time.Since(startTime).Seconds())
		}
	}()

	for i := 0; i < TotalRequests; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			token, err := getSessionToken(client)
			if err != nil {
				atomic.AddInt64(&failed, 1)
				return
			}

			payload := fmt.Sprintf(`{"from":"bank-01","to":"bank-02","amount":1,"tx_id":"tx-%d"}`, id)
			req, _ := http.NewRequest("POST", TargetURL, bytes.NewBufferString(payload))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("X-Admin-Token", AdminToken)
			req.Header.Set("X-License-ID", LicenseID)
			req.Header.Set("X-Session-Token", token)

			resp, err := client.Do(req)
			if err != nil {
				atomic.AddInt64(&failed, 1)
				return
			}
			defer resp.Body.Close()

			if resp.StatusCode == 200 || resp.StatusCode == 201 || resp.StatusCode == 202 {
				atomic.AddInt64(&success, 1)
			} else {
				atomic.AddInt64(&failed, 1)
			}
		}(i)
	}

	wg.Wait()
	duration := time.Since(startTime).Seconds()
	tps := float64(success) / duration

	fmt.Println("\n══════════ نتیجه نهایی تست ۱۰ میلیونی ══════════")
	fmt.Printf("⏱  زمان کل:     %.2f ثانیه (حدود %.1f دقیقه)\n", duration, duration/60)
	fmt.Printf("✅ موفق:        %d تراکنش\n", success)
	fmt.Printf("❌ ناموفق:      %d تراکنش\n", failed)
	fmt.Printf("⚡ TPS واقعی:   %.2f تراکنش بر ثانیه\n", tps)
	fmt.Println("═══════════════════════════════════════════════")
}
