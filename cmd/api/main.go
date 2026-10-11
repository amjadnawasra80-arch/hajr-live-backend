package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/hajr-live/backend/internal/auth"
	"github.com/hajr-live/backend/internal/database"
	ws "github.com/hajr-live/backend/internal/websocket"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

const (
	maxBodyBytes   = 1 << 20 // 1 MiB
	dbCallTimeout  = 5 * time.Second
	idempotencyHdr = "Idempotency-Key"
	tokenTTL       = 24 * time.Hour
)

var (
	uuidRe     = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
	currencyRe = regexp.MustCompile(`^[A-Z]{3}$`)

	allowedGrantReasons = map[string]bool{
		"welcome_pack": true,
		"admin_gift":   true,
		"event_reward": true,
		"compensation": true,
	}
)

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]any{"success": false, "error": msg})
}

// decodeBody strictly decodes a single JSON object (size-limited, no unknown fields, no trailing data).
func decodeBody(w http.ResponseWriter, r *http.Request, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			writeError(w, http.StatusRequestEntityTooLarge, "request body too large")
			return false
		}
		writeError(w, http.StatusBadRequest, "invalid JSON body: "+err.Error())
		return false
	}
	if _, err := dec.Token(); err != io.EOF {
		writeError(w, http.StatusBadRequest, "request body must contain a single JSON object")
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// Idempotency helpers
// The ledgers require a NOT NULL UNIQUE idempotency_key (uuid). Callers may
// pass it via the "Idempotency-Key" header; otherwise we derive a deterministic
// one from the natural business key (so retries can never double-credit/debit).
// ---------------------------------------------------------------------------

func uuidFromBytes(b []byte, version byte) string {
	var u [16]byte
	copy(u[:], b)
	u[6] = (u[6] & 0x0f) | (version << 4)
	u[8] = (u[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", u[0:4], u[4:6], u[6:8], u[8:10], u[10:16])
}

func deterministicKey(parts ...string) string {
	sum := sha256.Sum256([]byte(strings.Join(parts, "\x1f")))
	return uuidFromBytes(sum[:16], 5)
}

func randomKey() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return uuidFromBytes(b, 4), nil
}

// resolveKey returns the header key if supplied (validated), else the fallback.
func resolveKey(r *http.Request, fallback func() (string, error)) (string, error) {
	if h := strings.TrimSpace(r.Header.Get(idempotencyHdr)); h != "" {
		if !uuidRe.MatchString(h) {
			return "", fmt.Errorf("%s header must be a valid UUID", idempotencyHdr)
		}
		return strings.ToLower(h), nil
	}
	return fallback()
}

// ---------------------------------------------------------------------------
// Postgres error mapping
// ---------------------------------------------------------------------------

func handleDBError(w http.ResponseWriter, endpoint string, err error) {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		switch pgErr.Code {
		case "23505": // unique_violation (e.g. same provider_txn_id with a different idempotency key)
			writeError(w, http.StatusConflict, "duplicate record: "+pgErr.ConstraintName)
			return
		case "23503": // foreign_key_violation (unknown user / wallet / admin)
			writeError(w, http.StatusNotFound, pgErr.Message)
			return
		case "23514": // check_violation (amount limits, insufficient funds, ...)
			writeError(w, http.StatusUnprocessableEntity, pgErr.Message)
			return
		case "42501": // insufficient_privilege (granted_by_admin_id is not an admin)
			writeError(w, http.StatusForbidden, pgErr.Message)
			return
		case "22P02", "22003", "23502": // invalid text representation / out of range / not null
			writeError(w, http.StatusBadRequest, pgErr.Message)
			return
		}
	}
	if errors.Is(err, context.DeadlineExceeded) {
		writeError(w, http.StatusGatewayTimeout, "database timeout")
		return
	}
	log.Printf("[%s] database error: %v", endpoint, err)
	writeError(w, http.StatusInternalServerError, "internal server error")
}

func requireUUID(field, v string) error {
	if !uuidRe.MatchString(v) {
		return fmt.Errorf("%s must be a valid UUID", field)
	}
	return nil
}

// ---------------------------------------------------------------------------
// POST /api/topup
// ---------------------------------------------------------------------------

type topupRequest struct {
	UserID          string `json:"user_id"`
	FiatAmount      int64  `json:"fiat_amount"`
	FiatCurrency    string `json:"fiat_currency"`
	RealCoinsMinted int64  `json:"real_coins_minted"`
	PaymentProvider string `json:"payment_provider"`
	ProviderTxnID   string `json:"provider_txn_id"`
}

func topupHandler(w http.ResponseWriter, r *http.Request) {
	var req topupRequest
	if !decodeBody(w, r, &req) {
		return
	}

	req.FiatCurrency = strings.ToUpper(strings.TrimSpace(req.FiatCurrency))
	req.PaymentProvider = strings.TrimSpace(req.PaymentProvider)
	req.ProviderTxnID = strings.TrimSpace(req.ProviderTxnID)

	switch {
	case requireUUID("user_id", req.UserID) != nil:
		writeError(w, http.StatusBadRequest, "user_id must be a valid UUID")
		return
	case req.FiatAmount <= 0:
		writeError(w, http.StatusBadRequest, "fiat_amount must be > 0 (minor units)")
		return
	case !currencyRe.MatchString(req.FiatCurrency):
		writeError(w, http.StatusBadRequest, "fiat_currency must be a 3-letter ISO code")
		return
	case req.RealCoinsMinted <= 0 || req.RealCoinsMinted > 1_000_000_000:
		writeError(w, http.StatusBadRequest, "real_coins_minted must be between 1 and 1000000000")
		return
	case req.PaymentProvider == "":
		writeError(w, http.StatusBadRequest, "payment_provider is required")
		return
	case req.ProviderTxnID == "":
		writeError(w, http.StatusBadRequest, "provider_txn_id is required")
		return
	}

	key, err := resolveKey(r, func() (string, error) {
		return deterministicKey("topup", req.PaymentProvider, req.ProviderTxnID), nil
	})
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), dbCallTimeout)
	defer cancel()

	var (
		id        int64
		createdAt time.Time
	)
	err = database.Pool.QueryRow(ctx, `
		INSERT INTO topup_ledger
			(idempotency_key, user_id, fiat_amount, fiat_currency, real_coins_minted, payment_provider, provider_txn_id)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		RETURNING id, created_at`,
		key, req.UserID, req.FiatAmount, req.FiatCurrency, req.RealCoinsMinted, req.PaymentProvider, req.ProviderTxnID,
	).Scan(&id, &createdAt)

	replayed := false
	if errors.Is(err, pgx.ErrNoRows) {
		// DB trigger skipped the insert: idempotency replay. Return the original record.
		replayed = true
		err = database.Pool.QueryRow(ctx,
			`SELECT id, created_at FROM topup_ledger WHERE idempotency_key = $1`, key,
		).Scan(&id, &createdAt)
	}
	if err != nil {
		handleDBError(w, "topup", err)
		return
	}

	status := http.StatusCreated
	if replayed {
		status = http.StatusOK
	}
	writeJSON(w, status, map[string]any{
		"success":         true,
		"replayed":        replayed,
		"ledger_id":       id,
		"idempotency_key": key,
		"user_id":         req.UserID,
		"real_coins":      req.RealCoinsMinted,
		"created_at":      createdAt,
	})
}

// ---------------------------------------------------------------------------
// POST /api/grant
// ---------------------------------------------------------------------------

type grantRequest struct {
	UserID           string  `json:"user_id"`
	PromoCoinsMinted int64   `json:"promo_coins_minted"`
	Reason           string  `json:"reason"`
	GrantedByAdminID *string `json:"granted_by_admin_id"` // optional / nullable
}

func grantHandler(w http.ResponseWriter, r *http.Request) {
	var req grantRequest
	if !decodeBody(w, r, &req) {
		return
	}

	req.Reason = strings.TrimSpace(req.Reason)

	if req.GrantedByAdminID != nil {
		v := strings.TrimSpace(*req.GrantedByAdminID)
		if v == "" {
			req.GrantedByAdminID = nil
		} else {
			req.GrantedByAdminID = &v
		}
	}

	switch {
	case requireUUID("user_id", req.UserID) != nil:
		writeError(w, http.StatusBadRequest, "user_id must be a valid UUID")
		return
	case req.PromoCoinsMinted <= 0 || req.PromoCoinsMinted > 100_000:
		writeError(w, http.StatusBadRequest, "promo_coins_minted must be between 1 and 100000")
		return
	case !allowedGrantReasons[req.Reason]:
		writeError(w, http.StatusBadRequest, "reason must be one of: welcome_pack, admin_gift, event_reward, compensation")
		return
	case req.GrantedByAdminID != nil && requireUUID("granted_by_admin_id", *req.GrantedByAdminID) != nil:
		writeError(w, http.StatusBadRequest, "granted_by_admin_id must be a valid UUID")
		return
	}

	// Grants have no natural unique key: callers should send an Idempotency-Key
	// header to make retries safe; otherwise a fresh random key is used.
	key, err := resolveKey(r, randomKey)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), dbCallTimeout)
	defer cancel()

	var (
		id        int64
		createdAt time.Time
	)
	err = database.Pool.QueryRow(ctx, `
		INSERT INTO grant_ledger
			(idempotency_key, user_id, promo_coins_minted, reason, granted_by_admin_id)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING id, created_at`,
		key, req.UserID, req.PromoCoinsMinted, req.Reason, req.GrantedByAdminID,
	).Scan(&id, &createdAt)

	replayed := false
	if errors.Is(err, pgx.ErrNoRows) {
		replayed = true
		err = database.Pool.QueryRow(ctx,
			`SELECT id, created_at FROM grant_ledger WHERE idempotency_key = $1`, key,
		).Scan(&id, &createdAt)
	}
	if err != nil {
		handleDBError(w, "grant", err)
		return
	}

	status := http.StatusCreated
	if replayed {
		status = http.StatusOK
	}
	writeJSON(w, status, map[string]any{
		"success":         true,
		"replayed":        replayed,
		"ledger_id":       id,
		"idempotency_key": key,
		"user_id":         req.UserID,
		"promo_coins":     req.PromoCoinsMinted,
		"reason":          req.Reason,
		"created_at":      createdAt,
	})
}

// ---------------------------------------------------------------------------
// POST /api/chargeback
// ---------------------------------------------------------------------------

type chargebackRequest struct {
	UserID         string `json:"user_id"`
	AmountDeducted int64  `json:"amount_deducted"`
	Reason         string `json:"reason"`
	ProviderTxnID  string `json:"provider_txn_id"`
}

func chargebackHandler(w http.ResponseWriter, r *http.Request) {
	var req chargebackRequest
	if !decodeBody(w, r, &req) {
		return
	}

	req.Reason = strings.TrimSpace(req.Reason)
	req.ProviderTxnID = strings.TrimSpace(req.ProviderTxnID)

	switch {
	case requireUUID("user_id", req.UserID) != nil:
		writeError(w, http.StatusBadRequest, "user_id must be a valid UUID")
		return
	case req.AmountDeducted <= 0:
		writeError(w, http.StatusBadRequest, "amount_deducted must be > 0 (positive magnitude)")
		return
	case req.Reason == "":
		writeError(w, http.StatusBadRequest, "reason is required")
		return
	case req.ProviderTxnID == "":
		writeError(w, http.StatusBadRequest, "provider_txn_id is required")
		return
	}

	// One chargeback per (user, provider transaction) unless the caller overrides the key.
	key, err := resolveKey(r, func() (string, error) {
		return deterministicKey("chargeback", strings.ToLower(req.UserID), req.ProviderTxnID), nil
	})
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), dbCallTimeout)
	defer cancel()

	var (
		id        int64
		createdAt time.Time
	)
	err = database.Pool.QueryRow(ctx, `
		INSERT INTO chargeback_ledger
			(idempotency_key, user_id, amount_deducted, reason, provider_txn_id)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING id, created_at`,
		key, req.UserID, req.AmountDeducted, req.Reason, req.ProviderTxnID,
	).Scan(&id, &createdAt)

	replayed := false
	if errors.Is(err, pgx.ErrNoRows) {
		replayed = true
		err = database.Pool.QueryRow(ctx,
			`SELECT id, created_at FROM chargeback_ledger WHERE idempotency_key = $1`, key,
		).Scan(&id, &createdAt)
	}
	if err != nil {
		handleDBError(w, "chargeback", err)
		return
	}

	status := http.StatusCreated
	if replayed {
		status = http.StatusOK
	}
	writeJSON(w, status, map[string]any{
		"success":         true,
		"replayed":        replayed,
		"ledger_id":       id,
		"idempotency_key": key,
		"user_id":         req.UserID,
		"amount_deducted": req.AmountDeducted,
		"created_at":      createdAt,
	})
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

// registerPublicRoutes mounts endpoints that do NOT require a JWT.
func registerPublicRoutes(mux *http.ServeMux, am *auth.Manager, mockLogin bool) {
	// 2. مسار فحص صحة الخادم
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{
			"status":  "HAJR LIVE V12 Engine Active",
			"version": "1.0.0",
		})
	})

	// 3. مسار إنشاء مستخدم جديد (متوافق مع الأعمدة الحقيقية)
	mux.HandleFunc("/api/users/create", func(w http.ResponseWriter, r *http.Request) {
		// إدخال مستخدم تجريبي برقم جوال
		query := `
			INSERT INTO users (phone_number, is_god_mode, kyc_status) 
			VALUES ('+966500000000', false, 'verified') 
			RETURNING id;
		`
		var userID string
		err := database.Pool.QueryRow(r.Context(), query).Scan(&userID)
		if err != nil {
			http.Error(w, "Database Error: "+err.Error(), http.StatusInternalServerError)
			return
		}

		// سيتم إنشاء المحفظة تلقائياً بفضل المحفزات (Triggers)
		writeJSON(w, http.StatusOK, map[string]string{
			"message": "User and Wallet created successfully!",
			"user_id": userID,
		})
	})

	// 4. تسجيل الدخول (تجريبي) - يُرجع JWT
	mux.HandleFunc("POST /api/login", loginHandler(am, mockLogin))
}

// registerAdminRoutes mounts financial endpoints: valid JWT with is_admin=true
// (401 without a valid token, 403 for non-admin users).
func registerAdminRoutes(mux *http.ServeMux, am *auth.Manager) {
	admin := func(h http.HandlerFunc) http.Handler { return am.AdminMiddleware(h) }

	// 5. مسارات الدفاتر (Ledgers) - المحفزات في قاعدة البيانات تحدّث المحافظ
	mux.Handle("POST /api/topup", admin(topupHandler))
	mux.Handle("POST /api/grant", admin(grantHandler))
	mux.Handle("POST /api/chargeback", admin(chargebackHandler))
}

// registerProtectedRoutes mounts endpoints open to any logged-in user ("Authorization: Bearer <jwt>").
func registerProtectedRoutes(mux *http.ServeMux, am *auth.Manager, hub *ws.Hub) {
	protect := func(h http.HandlerFunc) http.Handler { return am.Middleware(h) }

	// 6. محرك البث المباشر (WebSocket)
	mux.Handle("GET /ws", protect(func(w http.ResponseWriter, r *http.Request) {
		claims, ok := auth.ClaimsFromContext(r.Context())
		if !ok {
			writeError(w, http.StatusUnauthorized, "unauthenticated")
			return
		}
		hub.ServeWS(w, r, claims.UserID)
	}))
}

// ---------------------------------------------------------------------------
// POST /api/login  (MOCK - testing only)
// ---------------------------------------------------------------------------

type loginRequest struct {
	PhoneNumber string `json:"phone_number"`
}

var phoneRe = regexp.MustCompile(`^\+[1-9][0-9]{6,14}$`)

// loginHandler issues a JWT for an EXISTING user identified only by phone number.
// There is no OTP/password check, so anyone who knows a phone number can
// impersonate that user. It is gated by MOCK_LOGIN_ENABLED and must be replaced
// with real OTP verification before production.
func loginHandler(am *auth.Manager, enabled bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !enabled {
			writeError(w, http.StatusNotImplemented, "login is disabled (MOCK_LOGIN_ENABLED=false)")
			return
		}

		var req loginRequest
		if !decodeBody(w, r, &req) {
			return
		}
		req.PhoneNumber = strings.TrimSpace(req.PhoneNumber)
		if !phoneRe.MatchString(req.PhoneNumber) {
			writeError(w, http.StatusBadRequest, "phone_number must be in E.164 format, e.g. +966500000000")
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), dbCallTimeout)
		defer cancel()

		var (
			userID  string
			isAdmin bool
		)
		err := database.Pool.QueryRow(ctx,
			`SELECT id::text, is_god_mode FROM users WHERE phone_number = $1`, req.PhoneNumber,
		).Scan(&userID, &isAdmin)
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusNotFound, "user not found")
			return
		}
		if err != nil {
			handleDBError(w, "login", err)
			return
		}

		token, exp, err := am.GenerateToken(userID, req.PhoneNumber, isAdmin)
		if err != nil {
			log.Printf("[login] token generation failed: %v", err)
			writeError(w, http.StatusInternalServerError, "internal server error")
			return
		}

		writeJSON(w, http.StatusOK, map[string]any{
			"success":    true,
			"token":      token,
			"token_type": "Bearer",
			"expires_at": exp,
			"user_id":    userID,
			"is_admin":   isAdmin,
		})
	}
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

func envStatus(key string) string {
	if os.Getenv(key) == "" {
		return "MISSING"
	}
	return "set"
}

func main() {
	// 1. تحميل المتغيرات البيئية (لا نطبع القيم السرية أبدًا)
	if database.LoadEnv() {
		log.Println("[env] .env file loaded")
	} else {
		log.Println("[env] no .env file found, using process environment")
	}
	log.Printf("[env] DATABASE_URL=%s JWT_SECRET=%s PORT=%s", envStatus("DATABASE_URL"), envStatus("JWT_SECRET"), envOr("PORT", "8080"))

	// 2. الاتصال بقاعدة البيانات
	database.Connect()
	defer database.Pool.Close()

	// 3. نظام المصادقة JWT
	am, err := auth.NewManager(os.Getenv("JWT_SECRET"), tokenTTL)
	if err != nil {
		log.Fatalf("Fatal Error: %v", err)
	}
	log.Printf("[auth] JWT manager initialised (HS256, ttl=%s)", tokenTTL)

	mockLogin := strings.EqualFold(os.Getenv("MOCK_LOGIN_ENABLED"), "true")
	if mockLogin {
		log.Println("[auth] WARNING: MOCK_LOGIN_ENABLED=true - /api/login issues tokens without OTP. Do NOT use in production.")
	}

	// 4. محرك WebSocket
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	hub := ws.NewHub(strings.Split(os.Getenv("WS_ALLOWED_ORIGINS"), ","))
	hubDone := make(chan struct{})
	go func() {
		defer close(hubDone)
		hub.Run(ctx)
	}()
	log.Println("[ws] Hub initialised and running")

	// 5. المسارات: عامة + محمية
	mux := http.NewServeMux()
	registerPublicRoutes(mux, am, mockLogin)
	registerAdminRoutes(mux, am)
	registerProtectedRoutes(mux, am, hub)

	addr := ":" + envOr("PORT", "8080")
	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	serverErr := make(chan error, 1)
	go func() {
		log.Printf("Server is running on port %s...", strings.TrimPrefix(addr, ":"))
		serverErr <- srv.ListenAndServe()
	}()

	select {
	case err := <-serverErr:
		if !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("server error: %v", err)
		}
	case <-ctx.Done():
		log.Println("shutting down...")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil {
			log.Printf("graceful shutdown failed: %v", err)
		}
		<-hubDone
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
