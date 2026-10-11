package main

import (
	"net/http"
	"strings"
)

// wsSubprotocolAuth lets browser clients (which cannot set an Authorization
// header on a WebSocket) authenticate with the subprotocol list
// ["bearer", "<jwt>"]. When no Authorization header is present it is synthesised
// from that list, so the normal JWT middleware does all validation. The token is
// never placed in the URL (and therefore never ends up in access logs).
func wsSubprotocolAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") == "" {
			var parts []string
			for _, v := range r.Header.Values("Sec-WebSocket-Protocol") {
				for _, p := range strings.Split(v, ",") {
					if p = strings.TrimSpace(p); p != "" {
						parts = append(parts, p)
					}
				}
			}
			if len(parts) == 2 && strings.EqualFold(parts[0], "bearer") {
				r.Header.Set("Authorization", "Bearer "+parts[1])
			}
		}
		next.ServeHTTP(w, r)
	})
}

// corsMiddleware enables CORS for an explicit allow-list of browser origins
// (CORS_ALLOWED_ORIGINS, comma-separated). With an empty list it is a no-op:
// the Docker deployment serves the web app from the same origin via a reverse proxy.
func corsMiddleware(allowed []string, next http.Handler) http.Handler {
	set := make(map[string]struct{}, len(allowed))
	for _, o := range allowed {
		if o = strings.TrimSpace(o); o != "" {
			set[strings.ToLower(o)] = struct{}{}
		}
	}
	if len(set) == 0 {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if _, ok := set[strings.ToLower(origin)]; ok && origin != "" {
			h := w.Header()
			h.Set("Access-Control-Allow-Origin", origin)
			h.Add("Vary", "Origin")
			h.Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
			h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, Idempotency-Key")
			h.Set("Access-Control-Max-Age", "600")
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}
