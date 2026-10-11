package auth

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	issuer    = "hajr-live"
	minSecret = 16
)

var ErrInvalidToken = errors.New("invalid or expired token")

// Claims are the custom JWT claims carried by every HAJR LIVE access token.
type Claims struct {
	UserID  string `json:"user_id"`
	Phone   string `json:"phone_number"`
	IsAdmin bool   `json:"is_admin"`
	jwt.RegisteredClaims
}

// Manager signs and validates HS256 tokens.
type Manager struct {
	secret []byte
	ttl    time.Duration
}

// NewManager builds a Manager. The secret must be at least 16 bytes.
func NewManager(secret string, ttl time.Duration) (*Manager, error) {
	if len(secret) < minSecret {
		return nil, fmt.Errorf("JWT_SECRET must be at least %d characters", minSecret)
	}
	if ttl <= 0 {
		return nil, errors.New("token ttl must be positive")
	}
	return &Manager{secret: []byte(secret), ttl: ttl}, nil
}

// GenerateToken issues a signed access token for the given user.
func (m *Manager) GenerateToken(userID, phone string, isAdmin bool) (string, time.Time, error) {
	now := time.Now()
	exp := now.Add(m.ttl)
	claims := Claims{
		UserID:  userID,
		Phone:   phone,
		IsAdmin: isAdmin,
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    issuer,
			Subject:   userID,
			IssuedAt:  jwt.NewNumericDate(now),
			NotBefore: jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(exp),
		},
	}
	signed, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(m.secret)
	if err != nil {
		return "", time.Time{}, err
	}
	return signed, exp, nil
}

// ValidateToken verifies signature (HS256 only), expiry and issuer.
func (m *Manager) ValidateToken(tokenStr string) (*Claims, error) {
	claims := &Claims{}
	token, err := jwt.ParseWithClaims(tokenStr, claims,
		func(*jwt.Token) (any, error) { return m.secret, nil },
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
		jwt.WithIssuer(issuer),
		jwt.WithExpirationRequired(),
	)
	if err != nil || !token.Valid || claims.UserID == "" {
		return nil, ErrInvalidToken
	}
	return claims, nil
}

type ctxKey struct{}

// ContextWithClaims stores validated claims in a context.
func ContextWithClaims(ctx context.Context, c *Claims) context.Context {
	return context.WithValue(ctx, ctxKey{}, c)
}

// ClaimsFromContext returns the claims set by the auth middleware.
func ClaimsFromContext(ctx context.Context) (*Claims, bool) {
	c, ok := ctx.Value(ctxKey{}).(*Claims)
	return c, ok
}
