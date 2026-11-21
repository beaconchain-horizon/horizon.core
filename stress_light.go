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
	LicenseID     = "HORIZON-TEST-001"
	Concurrency   = 10      // کاهش برای جلوگیری از خطای پورت ویندوز
	TotalRequests = 10000   // ۱۰ هزار برای تست سریع
	BatchSize     = 1000
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
	if err != nil { return "", err }
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("session error %d: %s", resp.StatusCode, string(body))
	}
	var sResp SessionResp
	json.NewDecoder(resp.Body).Decode(&sResp)
	if sResp.SessionToken != "" { return sResp.SessionToken, nil }
	return sResp.Token, nil
}

func main() {
	fmt.Printf("🚀 شروع تست با %d تراکنش و %d همزمانی...\n", TotalRequests, Concurrency)
	var success int64
	var failed int64
	var printedError int64
	
	// تنظیمات پیشرفته برای مدیریت کانکشن‌ها در ویندوز
	tr := &http.Transport{
		MaxIdleConns:        100,
		MaxIdleConnsPerHost: 100,
		IdleConnTimeout:     90 * time.Second,
	}
	client := &http.Client{ Transport: tr, Timeout: 30 * time.Second }
	
	startTime := time.Now()

	for start := 0; start < TotalRequests; start += BatchSize {
		end := start + BatchSize
		if end > TotalRequests { end = TotalRequests }
		var wg sync.WaitGroup
		sem := make(chan struct{}, Concurrency)

		for i := start; i < end; i++ {
			wg.Add(1)
			go func(id int) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()

				// ۱. گرفتن توکن جدید برای این تراکنش
				token, err := getSessionToken(client)
				if err != nil {
					atomic.AddInt64(&failed, 1)
					if atomic.AddInt64(&printedError, 1) <= 3 {
						fmt.Printf("\n❌ خطا در ساخت توکن: %v\n", err)
					}
					return
				}

				// ۲. ارسال تراکنش
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
					if atomic.AddInt64(&printedError, 1) <= 5 {
						body, _ := io.ReadAll(resp.Body)
						fmt.Printf("\n❌ خطای تراکنش HTTP %d: %s\n", resp.StatusCode, string(body))
					}
				}
			}(i)
		}
		wg.Wait()
		// استراحت کوتاه بین دسته‌ها برای آزادسازی پورت‌های ویندوز
		time.Sleep(500 * time.Millisecond) 
	}

	duration := time.Since(startTime).Seconds()
	fmt.Println("\n══════════ نتیجه ══════════")
	fmt.Printf("✅ موفق: %d | ❌ ناموفق: %d | زمان: %.2f ثانیه\n", success, failed, duration)
	fmt.Printf("⚡ TPS: %.2f\n", float64(success)/duration)
}
