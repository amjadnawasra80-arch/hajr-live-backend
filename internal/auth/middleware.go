package auth

import (
	"encoding/json"
	"net/http"
	"strings"
)

func unauthorized(w http.ResponseWriter, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("WWW-Authenticate", `Bearer realm="hajr-live"`)
	w.WriteHeader(http.StatusUnauthorized)
	_ = json.NewEncoder(w).Encode(map[string]any{"success": false, "error": msg})
}

func forbidden(w http.ResponseWriter, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusForbidden)
	_ = json.NewEncoder(w).Encode(map[string]any{"success": false, "error": msg})
}

// AdminMiddleware requires a valid Bearer token (401 otherwise) AND an
// is_admin=true claim (403 otherwise). It already includes Middleware, so do
// not stack the two.
func (m *Manager) AdminMiddleware(next http.Handler) http.Handler {
	return m.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		claims, ok := ClaimsFromContext(r.Context())
		if !ok {
			unauthorized(w, "unauthenticated")
			return
		}
		if !claims.IsAdmin {
			forbidden(w, "admin privileges required")
			return
		}
		next.ServeHTTP(w, r)
	}))
}

// Middleware requires a valid "Authorization: Bearer <jwt>" header and stores
// the claims in the request context (see ClaimsFromContext).
func (m *Manager) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := r.Header.Get("Authorization")
		scheme, token, ok := strings.Cut(h, " ")
		if !ok || !strings.EqualFold(scheme, "Bearer") || strings.TrimSpace(token) == "" {
			unauthorized(w, "missing or malformed Authorization header (expected: Bearer <token>)")
			return
		}
		claims, err := m.ValidateToken(strings.TrimSpace(token))
		if err != nil {
			unauthorized(w, "invalid or expired token")
			return
		}
		next.ServeHTTP(w, r.WithContext(ContextWithClaims(r.Context(), claims)))
	})
}
