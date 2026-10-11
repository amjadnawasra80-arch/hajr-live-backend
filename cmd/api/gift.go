package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/hajr-live/backend/internal/auth"
	"github.com/hajr-live/backend/internal/database"
	"github.com/jackc/pgx/v5"
)

// ---------------------------------------------------------------------------
// POST /api/gift  (any authenticated user)
//
// The SENDER is always the user in the JWT; it can never be supplied in the
// body. The transactions_apply() trigger locks both wallets, checks funds for
// the chosen coin type, applies the 25% platform fee and handles replays. On a
// first insert the gift is broadcast to every WebSocket client.
// ---------------------------------------------------------------------------

// eventBroadcaster is implemented by *websocket.Hub.
type eventBroadcaster interface {
	BroadcastEvent(typ, from string, data any) error
}

type giftRequest struct {
	ReceiverID string `json:"receiver_id"`
	CoinType   string `json:"coin_type"`
	Amount     int64  `json:"amount"`
}

const maxGiftAmount = 1_000_000_000

var allowedCoinTypes = map[string]bool{"real_coins": true, "promo_coins": true}

func giftHandler(hub eventBroadcaster) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		claims, ok := auth.ClaimsFromContext(r.Context())
		if !ok {
			writeError(w, http.StatusUnauthorized, "unauthenticated")
			return
		}
		senderID := strings.ToLower(claims.UserID)
		if requireUUID("sender", senderID) != nil {
			writeError(w, http.StatusUnauthorized, "invalid token subject")
			return
		}

		var req giftRequest
		if !decodeBody(w, r, &req) {
			return
		}
		req.ReceiverID = strings.ToLower(strings.TrimSpace(req.ReceiverID))
		req.CoinType = strings.TrimSpace(req.CoinType)

		switch {
		case requireUUID("receiver_id", req.ReceiverID) != nil:
			writeError(w, http.StatusBadRequest, "receiver_id must be a valid UUID")
			return
		case req.ReceiverID == senderID:
			writeError(w, http.StatusBadRequest, "you cannot gift yourself")
			return
		case !allowedCoinTypes[req.CoinType]:
			writeError(w, http.StatusBadRequest, "coin_type must be one of: real_coins, promo_coins")
			return
		case req.Amount < 1 || req.Amount > maxGiftAmount:
			writeError(w, http.StatusBadRequest, "amount must be between 1 and 1000000000 (minor units)")
			return
		}

		// Gifts have no natural unique key: callers should send an Idempotency-Key
		// header so a retried request can never double-charge; otherwise a random key is used.
		key, err := resolveKey(r, randomKey)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), dbCallTimeout)
		defer cancel()

		var (
			id        string
			fee, net  int64
			createdAt time.Time
		)
		err = database.Pool.QueryRow(ctx, `
			INSERT INTO transactions
				(idempotency_key, sender_id, receiver_id, coin_type, gross_amount)
			VALUES ($1, $2, $3, $4, $5)
			RETURNING id::text, platform_fee, net_amount, created_at`,
			key, senderID, req.ReceiverID, req.CoinType, req.Amount,
		).Scan(&id, &fee, &net, &createdAt)

		replayed := false
		if errors.Is(err, pgx.ErrNoRows) {
			// Trigger skipped the insert: idempotency replay. Return the original record,
			// but only to the original sender and only if the request is identical.
			replayed = true
			var (
				origSender, origReceiver, origCoin string
				origGross                          int64
			)
			err = database.Pool.QueryRow(ctx, `
				SELECT id::text, sender_id::text, receiver_id::text, coin_type, gross_amount,
				       platform_fee, net_amount, created_at
				FROM transactions WHERE idempotency_key = $1`, key,
			).Scan(&id, &origSender, &origReceiver, &origCoin, &origGross, &fee, &net, &createdAt)
			if err == nil && (origSender != senderID || origReceiver != req.ReceiverID ||
				origCoin != req.CoinType || origGross != req.Amount) {
				writeError(w, http.StatusConflict, "Idempotency-Key was already used for a different request")
				return
			}
		}
		if err != nil {
			handleDBError(w, "gift", err)
			return
		}

		status := http.StatusCreated
		if replayed {
			status = http.StatusOK
		} else if hub != nil {
			// Broadcast only after the ledger insert committed, and never on replays.
			if err := hub.BroadcastEvent("gift", senderID, map[string]any{
				"transaction_id": id,
				"receiver_id":    req.ReceiverID,
				"coin_type":      req.CoinType,
				"amount":         req.Amount,
				"net_amount":     net,
			}); err != nil {
				log.Printf("[gift] broadcast failed for transaction %s: %v", id, err)
			}
		}

		writeJSON(w, status, map[string]any{
			"success":         true,
			"replayed":        replayed,
			"transaction_id":  id,
			"idempotency_key": key,
			"sender_id":       senderID,
			"receiver_id":     req.ReceiverID,
			"coin_type":       req.CoinType,
			"gross_amount":    req.Amount,
			"platform_fee":    fee,
			"net_amount":      net,
			"created_at":      createdAt,
		})
	}
}
