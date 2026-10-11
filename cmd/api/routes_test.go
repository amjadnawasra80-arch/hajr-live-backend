package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/hajr-live/backend/internal/auth"
	ws "github.com/hajr-live/backend/internal/websocket"
)

const (
	testUser     = "11111111-1111-4111-8111-111111111111"
	testReceiver = "22222222-2222-4222-8222-222222222222"
)

func newTestMux(t *testing.T) (*http.ServeMux, *auth.Manager) {
	t.Helper()
	am, err := auth.NewManager("test-secret-test-secret-123", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	registerAdminRoutes(mux, am)
	registerProtectedRoutes(mux, am, ws.NewHub(nil))
	return mux, am
}

func do(mux http.Handler, method, path, token, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

// Financial endpoints must be admin-only: 401 without a token, 403 for regular users.
func TestFinancialEndpointsRequireAdmin(t *testing.T) {
	mux, am := newTestMux(t)
	userTok, _, _ := am.GenerateToken(testUser, "+10000000001", false)

	for _, path := range []string{"/api/topup", "/api/grant", "/api/chargeback"} {
		if got := do(mux, http.MethodPost, path, "", `{}`).Code; got != http.StatusUnauthorized {
			t.Errorf("%s without token: got %d, want 401", path, got)
		}
		if got := do(mux, http.MethodPost, path, "garbage", `{}`).Code; got != http.StatusUnauthorized {
			t.Errorf("%s with bad token: got %d, want 401", path, got)
		}
		if got := do(mux, http.MethodPost, path, userTok, `{}`).Code; got != http.StatusForbidden {
			t.Errorf("%s with non-admin token: got %d, want 403", path, got)
		}
	}
}

func TestGiftRequiresJWT(t *testing.T) {
	mux, _ := newTestMux(t)
	if got := do(mux, http.MethodPost, "/api/gift", "", `{}`).Code; got != http.StatusUnauthorized {
		t.Fatalf("got %d, want 401", got)
	}
}

// All of these are rejected before any database call is made.
func TestGiftValidation(t *testing.T) {
	mux, am := newTestMux(t)
	tok, _, _ := am.GenerateToken(testUser, "+10000000001", false)

	cases := []struct {
		name, body string
		hdr        string
	}{
		{"empty body", `{}`, ""},
		{"bad receiver", `{"receiver_id":"nope","coin_type":"real_coins","amount":5}`, ""},
		{"self gift", `{"receiver_id":"` + testUser + `","coin_type":"real_coins","amount":5}`, ""},
		{"bad coin type", `{"receiver_id":"` + testReceiver + `","coin_type":"gold","amount":5}`, ""},
		{"zero amount", `{"receiver_id":"` + testReceiver + `","coin_type":"real_coins","amount":0}`, ""},
		{"negative amount", `{"receiver_id":"` + testReceiver + `","coin_type":"promo_coins","amount":-5}`, ""},
		{"huge amount", `{"receiver_id":"` + testReceiver + `","coin_type":"promo_coins","amount":1000000001}`, ""},
		{"sender in body rejected", `{"sender_id":"` + testReceiver + `","receiver_id":"` + testReceiver + `","coin_type":"real_coins","amount":5}`, ""},
		{"bad idempotency key", `{"receiver_id":"` + testReceiver + `","coin_type":"real_coins","amount":5}`, "not-a-uuid"},
	}
	for _, c := range cases {
		req := httptest.NewRequest(http.MethodPost, "/api/gift", strings.NewReader(c.body))
		req.Header.Set("Authorization", "Bearer "+tok)
		if c.hdr != "" {
			req.Header.Set(idempotencyHdr, c.hdr)
		}
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s: got %d (%s), want 400", c.name, rec.Code, rec.Body.String())
		}
	}
}

func TestGiftRejectsNonUUIDTokenSubject(t *testing.T) {
	mux, am := newTestMux(t)
	tok, _, _ := am.GenerateToken("not-a-uuid", "+10000000001", false)
	body := `{"receiver_id":"` + testReceiver + `","coin_type":"real_coins","amount":5}`
	if got := do(mux, http.MethodPost, "/api/gift", tok, body).Code; got != http.StatusUnauthorized {
		t.Fatalf("got %d, want 401", got)
	}
}
