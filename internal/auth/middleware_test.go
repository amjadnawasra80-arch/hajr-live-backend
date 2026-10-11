package auth

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestAdminMiddleware(t *testing.T) {
	m, err := NewManager("0123456789abcdef-test-secret", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	ok := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })

	userTok, _, _ := m.GenerateToken("u-1", "+966500000001", false)
	adminTok, _, _ := m.GenerateToken("u-2", "+966500000002", true)

	cases := []struct {
		name   string
		header string
		admin  int // expected status on admin-only handler
		plain  int // expected status on regular-JWT handler
	}{
		{"no token", "", 401, 401},
		{"garbage token", "Bearer abc", 401, 401},
		{"regular user", "Bearer " + userTok, 403, 200},
		{"admin user", "Bearer " + adminTok, 200, 200},
	}

	for _, tc := range cases {
		for name, h := range map[string]http.Handler{
			"admin": m.AdminMiddleware(ok),
			"plain": m.Middleware(ok),
		} {
			want := tc.admin
			if name == "plain" {
				want = tc.plain
			}
			req := httptest.NewRequest(http.MethodGet, "/", nil)
			if tc.header != "" {
				req.Header.Set("Authorization", tc.header)
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != want {
				t.Errorf("%s/%s: got %d, want %d", tc.name, name, rec.Code, want)
			}
		}
	}
}
