package main

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/hajr-live/backend/internal/auth"
	"github.com/hajr-live/backend/internal/database"
	"github.com/jackc/pgx/v5"
)

// ---------------------------------------------------------------------------
// GET /api/wallet  (any authenticated user)
// Read-only: returns the caller's own balances (user comes from the JWT).
// ---------------------------------------------------------------------------

func walletHandler(w http.ResponseWriter, r *http.Request) {
	claims, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	userID := strings.ToLower(claims.UserID)
	if requireUUID("user", userID) != nil {
		writeError(w, http.StatusUnauthorized, "invalid token subject")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), dbCallTimeout)
	defer cancel()

	var (
		realCoins, promoCoins int64
		updatedAt             time.Time
	)
	err := database.Pool.QueryRow(ctx,
		`SELECT real_coins, promo_coins, updated_at FROM wallets WHERE user_id = $1`, userID,
	).Scan(&realCoins, &promoCoins, &updatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "wallet not found")
		return
	}
	if err != nil {
		handleDBError(w, "wallet", err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"success":     true,
		"user_id":     userID,
		"is_admin":    claims.IsAdmin,
		"real_coins":  realCoins,
		"promo_coins": promoCoins,
		"updated_at":  updatedAt,
	})
}
