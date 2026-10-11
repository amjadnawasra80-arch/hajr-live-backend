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

func TestWalletRequiresJWT(t *testing.T) {
	mux, _ := newTestMux(t)
	if got := do(mux, http.MethodGet, "/api/wallet", "", "").Code; got != http.StatusUnauthorized {
		t.Fatalf("got %d, want 401", got)
	}
}

func TestWSSubprotocolAuth(t *testing.T) {
	mux, am := newTestMux(t)
	tok, _, _ := am.GenerateToken(testUser, "+10000000001", false)

	// No credentials at all -> 401.
	if got := do(mux, http.MethodGet, "/ws", "", "").Code; got != http.StatusUnauthorized {
		t.Fatalf("no creds: got %d, want 401", got)
	}
	// Garbage token in the subprotocol -> 401.
	req := httptest.NewRequest(http.MethodGet, "/ws", nil)
	req.Header.Set("Sec-WebSocket-Protocol", "bearer, garbage")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("bad subprotocol token: got %d, want 401", rec.Code)
	}
	// Valid token in the subprotocol passes auth (the upgrade itself then fails with 400
	// because this is not a real WebSocket handshake, which proves auth succeeded).
	req = httptest.NewRequest(http.MethodGet, "/ws", nil)
	req.Header.Set("Sec-WebSocket-Protocol", "bearer, "+tok)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code == http.StatusUnauthorized || rec.Code == http.StatusForbidden {
		t.Fatalf("valid subprotocol token rejected: %d", rec.Code)
	}
}

func TestCORS(t *testing.T) {
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })

	// Disabled when the allow-list is empty.
	h := corsMiddleware([]string{""}, inner)
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	req.Header.Set("Origin", "http://evil.example")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Fatal("CORS headers must not be set when disabled")
	}

	h = corsMiddleware([]string{"http://localhost:3000"}, inner)
	for origin, want := range map[string]string{
		"http://localhost:3000": "http://localhost:3000",
		"http://evil.example":   "",
	} {
		req := httptest.NewRequest(http.MethodOptions, "/api/gift", nil)
		req.Header.Set("Origin", origin)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if got := rec.Header().Get("Access-Control-Allow-Origin"); got != want {
			t.Errorf("origin %q: got %q, want %q", origin, got, want)
		}
		if rec.Code != http.StatusNoContent {
			t.Errorf("preflight status %d, want 204", rec.Code)
		}
	}
}
