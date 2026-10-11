# HAJR LIVE V12 — Engine Architecture & Documentation

## 1. Project Overview

**HAJR LIVE V12** is the backend engine of a live-streaming platform with a virtual-coin economy (gifting, top-ups, promotions and fraud-chargeback handling).

The guiding principle is **the database is the source of truth for money**. The Go API is intentionally thin: it authenticates callers, validates input, and *appends a row to a ledger*. PostgreSQL triggers then apply the business rules (balance updates, idempotency, non-negative balances) atomically inside the same transaction.

Core directives (also enforced in `.cursorrules`):

| Directive | Rule |
|---|---|
| Database | PostgreSQL 13+, strict ACID |
| Currency | `BIGINT` only, in minor units (no floats, no decimals) |
| Dual wallet | `real_coins` (purchased) and `promo_coins` (free) |
| Negative balances | Forbidden, **except** via the `chargeback_ledger` (fraud debt) |
| Immutability | All ledgers are **append-only** (no `UPDATE` / `DELETE` / `TRUNCATE`) |

---

## 2. Architecture

```
            ┌────────────────────────── Go API (net/http, :8080) ──────────────────────────┐
 Clients ──▶│  Public routes      Admin routes (JWT + is_admin)     Protected routes (JWT)  │
 (HTTP/WS)  │  /health            /api/topup                        /ws ──▶ WebSocket Hub   │
            │  /api/users/create  /api/grant                                                │
            │  /api/login         /api/chargeback                                           │
            └───────────────┬───────────────────────────────────────────────────────────────┘
                            │ pgxpool (INSERT into ledgers)
                            ▼
            ┌────────────────────────── PostgreSQL 13+ ─────────────────────────────────┐
            │ users ─▶ wallets (dual balance)   topup_ledger / grant_ledger /            │
            │ BEFORE INSERT triggers move       chargeback_ledger / transactions         │
            │ money; guard triggers reject      (append-only, idempotent)                │
            │ illegal states                                                             │
            └────────────────────────────────────────────────────────────────────────────┘
```

### Project layout

```
cmd/api/main.go                 Entry point: routing, handlers, middleware wiring, graceful shutdown
cmd/api/gift.go                 POST /api/gift handler (JWT sender, idempotent, WebSocket broadcast)
internal/database/postgres.go   .env loading (godotenv) + pgxpool connection (global `database.Pool`)
internal/auth/jwt.go            JWT generation / validation (HS256) and claims-in-context helpers
internal/auth/middleware.go     Middleware (any valid JWT) and AdminMiddleware (is_admin = true)
internal/websocket/hub.go       Hub: client registry + broadcast fan-out
internal/websocket/client.go    Per-connection read/write pumps, keep-alive, message validation
db/001_core_schema.sql          users, wallets, transactions (gift ledger), guards
db/002_topup_grant_ledgers.sql  topup / grant / chargeback ledgers + replaced wallets guard
```

### Technology

| Layer | Choice |
|---|---|
| Language | Go 1.25 (`net/http` with method-aware route patterns) |
| Database driver | `jackc/pgx/v5` (`pgxpool`) |
| Auth | `golang-jwt/jwt/v5` (HS256) |
| Realtime | `gorilla/websocket` |
| Config | `joho/godotenv` |

### Request flow (financial write)

1. Client calls an admin endpoint with a Bearer token.
2. Middleware validates the JWT and the `is_admin` claim.
3. The handler validates input, derives/accepts an **idempotency key**, and runs a single `INSERT … RETURNING` on the ledger.
4. A `BEFORE INSERT` trigger locks the wallet row (`FOR UPDATE`), checks for replays, and updates the balance.
5. The handler maps any PostgreSQL error to a clean HTTP status and returns JSON.

### WebSocket Hub

A single goroutine (`Hub.Run`) owns the client set, so no locks are required. Each connection has a read pump and a write pump, with ping/pong keep-alive, a 4 KB message limit and a bounded send buffer. A client that cannot keep up is disconnected rather than stalling everyone else. The hub shuts down with the server.

---

## 3. The Financial Database Engine

All balance changes flow through ledger tables. **The Go code never updates `wallets`.**

### Tables

| Table | Purpose | Effect (via trigger) |
|---|---|---|
| `users` | Identity (UUID, E.164 phone, `is_god_mode`, `kyc_status`) | Creates a wallet automatically; user **#1** is forced to `is_god_mode = true` |
| `wallets` | One row per user: `real_coins`, `promo_coins` | Modified **only** by ledger triggers (`SECURITY DEFINER`) |
| `topup_ledger` | Real-money purchases | `+ real_coins` |
| `grant_ledger` | Free promotional coins | `+ promo_coins` |
| `chargeback_ledger` | Fraud/chargeback deductions | `− real_coins` (may go negative = debt) |
| `transactions` | Gifts between users | 25 % platform fee (integer math), same coin type end-to-end |

> The `transactions` (gifting) ledger and its trigger live in `db/001_core_schema.sql` and are exposed through `POST /api/gift`, which also broadcasts a `gift` event to the WebSocket hub.

### Triggers

- **`ledger_immutable()`** — attached to every ledger for `UPDATE`/`DELETE` (row level) and `TRUNCATE` (statement level). Always raises `restrict_violation`. Privileges are also revoked from `PUBLIC`.
- **`apply_topup()` / `apply_grant()` / `apply_chargeback()`** — `BEFORE INSERT`. Each locks the user's wallet row, returns `NULL` on an idempotent replay (skipping the insert), then updates the balance. Missing wallet raises `foreign_key_violation`.
- **`apply_grant()`** additionally requires `granted_by_admin_id` (if provided) to be a `is_god_mode` user.
- **`wallets_guard()`** — rejects negative `promo_coins` always, and negative `real_coins` unless the update originates from `apply_chargeback()` (strict `real_coins` decrease only, promo untouched). A top-up that repays an already-negative balance is also allowed; otherwise a user in debt could never top up. It also blocks wallet deletion and `user_id` changes.
- **`users_create_wallet()`** — atomically creates the wallet with the user.
- **`transactions_apply()`** — locks both wallets in a deterministic order (deadlock-free), computes the 25 % fee, and moves coins of the same type.

### Check constraints (highlights)

| Ledger | Constraints |
|---|---|
| `topup_ledger` | `fiat_amount > 0`; `fiat_currency ~ '^[A-Z]{3}$'`; `0 < real_coins_minted ≤ 1,000,000,000`; non-empty `payment_provider` / `provider_txn_id`; `UNIQUE (payment_provider, provider_txn_id)` |
| `grant_ledger` | `0 < promo_coins_minted ≤ 100,000`; `reason ∈ {welcome_pack, admin_gift, event_reward, compensation}` |
| `chargeback_ledger` | `amount_deducted > 0` (positive magnitude); non-empty `reason` and `provider_txn_id` |
| `users` | E.164 phone regex; `kyc_status ∈ {unverified, pending, verified, rejected}` |
| `transactions` | `1 ≤ gross_amount ≤ 1,000,000,000`; no self-gifting; `platform_fee + net_amount = gross_amount` |

### Idempotency

Every ledger row carries an `idempotency_key` (`UNIQUE`). The trigger performs the replay check **after** taking the wallet lock, so concurrent duplicates serialize correctly: the first credits, the rest are silently skipped.

The API handles this for you:

| Endpoint | Key used |
|---|---|
| `/api/topup` | `Idempotency-Key` header, else derived from `payment_provider` + `provider_txn_id` |
| `/api/chargeback` | `Idempotency-Key` header, else derived from `user_id` + `provider_txn_id` |
| `/api/gift` | `Idempotency-Key` header, else a **random** key (send the header to make retries safe) |
| `/api/grant` | `Idempotency-Key` header, else a **random** key (grants have no natural unique key — send the header to make retries safe) |

A replay returns `200` with `"replayed": true` and the original record; a first insert returns `201`.

---

## 4. API Documentation

Base URL: `http://localhost:8080` (configurable via `PORT`).
All responses are JSON. Errors have the shape `{"success": false, "error": "<message>"}`.
Request bodies are limited to 1 MiB and **unknown JSON fields are rejected**.

| Method | Path | Auth |
|---|---|---|
| GET | `/health` | Public |
| POST | `/api/users/create` | Public *(development helper)* |
| POST | `/api/login` | Public *(mock — dev only)* |
| POST | `/api/topup` | Admin |
| POST | `/api/grant` | Admin |
| POST | `/api/chargeback` | Admin |
| POST | `/api/gift` | Any logged-in user |
| GET | `/api/wallet` | Any logged-in user |
| GET | `/ws` | Any logged-in user |

### `GET /health`

```json
{ "status": "HAJR LIVE V12 Engine Active", "version": "1.0.0" }
```

### `POST /api/users/create`

Development helper: inserts a fixed test user (`+966500000000`, `kyc_status = verified`). The wallet is created by a trigger. Calling it twice fails (unique phone number).

```json
{ "message": "User and Wallet created successfully!", "user_id": "<uuid>" }
```

### `POST /api/login` (mock)

Request:

```json
{ "phone_number": "+966500000000" }
```

Looks up an **existing** user by E.164 phone number and returns a JWT. There is **no OTP/password check**, so it is only enabled when `MOCK_LOGIN_ENABLED=true`; otherwise it returns `501`.

```json
{
  "success": true,
  "token": "<jwt>",
  "token_type": "Bearer",
  "expires_at": "2026-10-13T00:45:51+03:00",
  "user_id": "<uuid>",
  "is_admin": false
}
```

Status codes: `200`, `400` (bad phone format), `404` (unknown user), `501` (mock login disabled).

### `POST /api/topup` — Admin

Credits `real_coins` after a successful real-money payment.

```json
{
  "user_id": "<uuid>",
  "fiat_amount": 999,
  "fiat_currency": "USD",
  "real_coins_minted": 1000,
  "payment_provider": "stripe",
  "provider_txn_id": "pi_3Nxxxx"
}
```

`fiat_amount` is in minor units (999 = 9.99 USD).

### `POST /api/grant` — Admin

Credits free `promo_coins`.

```json
{
  "user_id": "<uuid>",
  "promo_coins_minted": 500,
  "reason": "welcome_pack",
  "granted_by_admin_id": "<admin-uuid or null>"
}
```

`reason` must be one of `welcome_pack`, `admin_gift`, `event_reward`, `compensation`.

### `POST /api/chargeback` — Admin

Deducts `real_coins` (the balance may become negative — fraud debt). Promo coins are never touched.

```json
{
  "user_id": "<uuid>",
  "amount_deducted": 1000,
  "reason": "card_dispute",
  "provider_txn_id": "pi_3Nxxxx"
}
```

### Ledger response (topup / grant / chargeback)

```json
{
  "success": true,
  "replayed": false,
  "ledger_id": 42,
  "idempotency_key": "<uuid>",
  "user_id": "<uuid>",
  "created_at": "2026-10-12T00:50:00Z"
}
```

Each endpoint also echoes its amount field(s): `real_coins`, `promo_coins` + `reason`, or `amount_deducted`.

### Error mapping (ledger endpoints)

| Condition | HTTP |
|---|---|
| Invalid JSON, field validation, or `Idempotency-Key` is not a UUID | 400 |
| Missing/invalid/expired token | 401 |
| Valid token but not an admin; or `granted_by_admin_id` is not an admin | 403 |
| Unknown user / wallet / admin (foreign key) | 404 |
| Duplicate `provider_txn_id` with a different idempotency key | 409 |
| Check-constraint or funds violation | 422 |
| Database timeout (5 s per call) | 504 |
| Anything else (details logged server-side only) | 500 |

### `POST /api/gift` — Any logged-in user

Sends coins from the authenticated user to another user. Requires `Authorization: Bearer <jwt>`. The **sender is always the user in the token**; a `sender_id` field in the body is rejected as an unknown field.

```json
{
  "receiver_id": "<uuid>",
  "coin_type": "real_coins",
  "amount": 100
}
```

- `coin_type` is `real_coins` or `promo_coins`. Coins keep their type end-to-end, so free coins can never become purchased coins.
- `amount` is in minor units, between 1 and 1,000,000,000. Self-gifting is rejected.
- The database trigger locks both wallets, verifies the sender's balance for that coin type, and applies the 25 % platform fee (integer math, truncated). The receiver gets `amount - platform_fee`.
- Send an `Idempotency-Key` header (UUID) so a retry can never charge twice. A replay returns `200` with `"replayed": true` and the original record, moves no money, and does **not** broadcast again. Reusing a key for a different request returns `409`.
- On a first successful insert (`201`), a `gift` event is broadcast to every WebSocket client.

```json
{
  "success": true,
  "replayed": false,
  "transaction_id": "<uuid>",
  "idempotency_key": "<uuid>",
  "sender_id": "<uuid>",
  "receiver_id": "<uuid>",
  "coin_type": "real_coins",
  "gross_amount": 100,
  "platform_fee": 25,
  "net_amount": 75,
  "created_at": "2026-10-12T00:50:00Z"
}
```

Status codes: `201`, `200` (replay), `400` (validation), `401`, `404` (unknown receiver), `409` (key reuse), `422` (insufficient funds), `504`.

WebSocket broadcast (`from` = sender user_id, set by the server):

```json
{ "type": "gift", "from": "<sender>", "data": { "transaction_id": "<uuid>", "receiver_id": "<uuid>", "coin_type": "real_coins", "amount": 100, "net_amount": 75 }, "ts": "2026-10-12T00:50:00Z" }
```

### `GET /ws` — WebSocket

Requires `Authorization: Bearer <jwt>` on the upgrade request.

```
GET /ws  HTTP/1.1
Authorization: Bearer <jwt>
Upgrade: websocket
```

**Client → server** (text frame). Currently only `chat` is accepted:

```json
{ "type": "chat", "data": { "text": "hello" } }
```

**Server → all clients:**

```json
{ "type": "chat", "from": "<sender user_id>", "data": { "text": "hello" }, "ts": "2026-10-12T00:50:00Z" }
```

`from` is set by the server from the JWT and cannot be spoofed. Unsupported or malformed frames get a private `{"type":"error", ...}` reply. Browsers cannot set the `Authorization` header on a WebSocket, so the JWT can alternatively be sent in the subprotocol list `["bearer", "<jwt>"]` (`Sec-WebSocket-Protocol: bearer, <jwt>`). The token is validated by the same middleware and never appears in the URL. The Flutter app uses this on every platform.

### `GET /api/wallet` — Any logged-in user

Read-only. Returns the caller's own balances (the user always comes from the JWT).

```json
{ "success": true, "user_id": "<uuid>", "is_admin": false, "real_coins": 1000, "promo_coins": 500, "updated_at": "2026-10-12T00:50:00Z" }
```

Status codes: `200`, `401`, `404` (no wallet).

---

## 5. Security

### JWT authentication

- Algorithm **HS256**, signed with `JWT_SECRET` (minimum 16 characters, enforced at startup). Tokens with any other algorithm are rejected.
- Validated on every protected request: signature, expiry (required), issuer (`hajr-live`).
- Token lifetime: **24 hours**.
- Claims: `user_id`, `phone_number`, `is_admin`, plus standard `iss`, `sub`, `iat`, `nbf`, `exp`.
- Header format: `Authorization: Bearer <token>`; failures return `401` with a `WWW-Authenticate` header.

### Route groups

| Group | Middleware | Routes | Failure |
|---|---|---|---|
| Public | none | `/health`, `/api/users/create`, `/api/login` | — |
| Protected | `Manager.Middleware` | `/api/gift`, `/api/wallet`, `/ws` | 401 |
| Admin | `Manager.AdminMiddleware` | `/api/topup`, `/api/grant`, `/api/chargeback` | 401 / **403** |

### God Mode admin

`users.is_god_mode` is copied into the token as `is_admin` at login. `AdminMiddleware` validates the token, then requires `is_admin == true`; regular users receive `403 Forbidden`. **User #1 is always an admin** (enforced by a database trigger and the seed row in `db/001_core_schema.sql`).

### Defense in depth

- Money can only move through ledger triggers; direct `INSERT/UPDATE/DELETE/TRUNCATE` on `wallets` and `UPDATE/DELETE/TRUNCATE` on ledgers are revoked from `PUBLIC`, and ledgers are additionally protected by immutability triggers.
- Strict JSON decoding, size limits, UUID/range validation, per-call DB timeouts, and server read/write timeouts.
- Internal database errors are logged, never returned to clients.
- Secrets live in `.env`, which is git-ignored (see `.gitignore`); `.env.example` is the committed template. Startup logs only whether variables are *set*, never their values.

### Known limitations / before production

1. **`/api/login` is a mock.** Anyone who knows a registered phone number (including the admin's) can obtain a token. Keep `MOCK_LOGIN_ENABLED=false` anywhere reachable and replace it with real OTP verification.
2. **Admin status is read from the token.** If `is_god_mode` is revoked, existing tokens stay valid until they expire (≤ 24 h). Shorten the TTL or re-check the database for admin requests if this matters.
3. **Use a strong, random `JWT_SECRET`** (e.g. `openssl rand -hex 32`); never reuse the development value.
4. **Change the seeded admin phone number** (`+10000000000`) in `db/001_core_schema.sql` before the first production run.
5. **`/api/users/create` is a development helper** and should be removed or protected.
6. Serve the API behind **TLS** (reverse proxy) and use `sslmode=require` (or stricter) in `DATABASE_URL`.
7. Run the API with a **dedicated, least-privilege database role**, not the `postgres` superuser. The `REVOKE ... FROM PUBLIC` statements are only meaningful for non-owner roles.

---

## 6. How to Run

### Prerequisites

- Go **1.25+**
- PostgreSQL **13+**

### 1. Create the database and apply the schema

```bash
createdb -U postgres hajr_live
psql -U postgres -d hajr_live -f db/001_core_schema.sql
psql -U postgres -d hajr_live -f db/002_topup_grant_ledgers.sql
```

Run the files in order, once each. They create tables without `IF NOT EXISTS`, so re-running them on an existing database will fail.

### 2. Configure the environment

```bash
cp .env.example .env        # Windows PowerShell: Copy-Item .env.example .env
```

| Variable | Required | Description |
|---|---|---|
| `DATABASE_URL` | yes | e.g. `postgres://postgres:<PASSWORD>@localhost:5432/hajr_live?sslmode=disable` |
| `JWT_SECRET` | yes | HMAC secret, at least 16 characters |
| `PORT` | no | HTTP port, default `8080` |
| `MOCK_LOGIN_ENABLED` | no | `true` enables the mock `/api/login` (**development only**) |
| `WS_ALLOWED_ORIGINS` | no | Comma-separated browser origins allowed to open `/ws` (empty = same-origin only; non-browser clients are unaffected) |
| `CORS_ALLOWED_ORIGINS` | no | Comma-separated browser origins allowed to call the REST API cross-origin (empty = CORS disabled) |

Real process environment variables take priority over `.env`. **Never commit `.env`.**

### 3. Run

```bash
go mod download
go run ./cmd/api
```

Expected startup log:

```
[env] .env file loaded
[env] DATABASE_URL=set JWT_SECRET=set PORT=8080
PostgreSQL V12 Engine successfully connected and pooled!
[auth] JWT manager initialised (HS256, ttl=24h0m0s)
[ws] Hub initialised and running
Server is running on port 8080...
```

Stop with `Ctrl+C` (graceful shutdown). Run the tests with `go test ./...`.

### 4. Try it (PowerShell)

```powershell
# Health
Invoke-RestMethod http://localhost:8080/health

# Log in as the admin (user #1 — use the phone number seeded in db/001_core_schema.sql)
$login = Invoke-RestMethod -Method Post http://localhost:8080/api/login `
  -ContentType 'application/json' -Body '{"phone_number":"+10000000000"}'
$h = @{ Authorization = "Bearer $($login.token)" }

# Top up a user (replace <USER_UUID>)
Invoke-RestMethod -Method Post http://localhost:8080/api/topup -Headers $h `
  -ContentType 'application/json' -Body (@{
    user_id = '<USER_UUID>'; fiat_amount = 999; fiat_currency = 'USD'
    real_coins_minted = 1000; payment_provider = 'stripe'; provider_txn_id = 'pi_test_001'
  } | ConvertTo-Json)
```

Repeating the same top-up returns `200` with `"replayed": true` and credits nothing.

The same flow with `curl`:

```bash
TOKEN=$(curl -s -X POST localhost:8080/api/login -d '{"phone_number":"+10000000000"}' | jq -r .token)
curl -X POST localhost:8080/api/topup -H "Authorization: Bearer $TOKEN" \
  -d '{"user_id":"<USER_UUID>","fiat_amount":999,"fiat_currency":"USD","real_coins_minted":1000,"payment_provider":"stripe","provider_txn_id":"pi_test_001"}'
```

---

## 7. Docker Deployment

The repository ships with two multi-stage Dockerfiles — `Dockerfile` (static Go binary, non-root Alpine runtime) and `frontend/Dockerfile` (Flutter web build served by nginx) — and a `docker-compose.yml` that runs the whole platform: **PostgreSQL 16 + Go API + Flutter web**.

### Quick start

```bash
cp .env.example .env        # Windows PowerShell: Copy-Item .env.example .env
# Edit .env: set POSTGRES_PASSWORD and JWT_SECRET (e.g. `openssl rand -hex 32`)
docker compose up -d --build
```

- **Web app:** `http://localhost:3000` (override with `WEB_PORT`). nginx serves the Flutter build and proxies `/api`, `/health` and `/ws` to the API, so the browser only ever talks to one origin (no CORS needed).
- The API is also available directly at `http://localhost:8080` (override with `PORT`); check it with `curl http://localhost:8080/health`.
- To sign in you need an existing user and `MOCK_LOGIN_ENABLED=true` (development only). The schema seeds admin user #1 with phone `+10000000000`.
- PostgreSQL is published on `127.0.0.1:5432` only.
- `db/*.sql` is mounted into `/docker-entrypoint-initdb.d`, so the schema is applied **once, in order, when the `pgdata` volume is first created**. To re-initialise from scratch: `docker compose down -v` (this deletes all data).
- `docker compose up` refuses to start if `POSTGRES_PASSWORD` or `JWT_SECRET` is missing. Use a URL-safe `POSTGRES_PASSWORD` (letters/digits), since it is embedded in `DATABASE_URL`.

### Compose environment

| Variable | Default | Description |
|---|---|---|
| `POSTGRES_USER` | `hajr` | Database role |
| `POSTGRES_PASSWORD` | *(required)* | Database password |
| `POSTGRES_DB` | `hajr_live` | Database name |
| `JWT_SECRET` | *(required)* | HMAC secret, at least 16 characters |
| `PORT` | `8080` | Host port for the API |
| `WEB_PORT` | `3000` | Host port for the web app |
| `CORS_ALLOWED_ORIGINS` | *(empty)* | Cross-origin allow-list for the REST API (not needed with the bundled nginx) |
| `MOCK_LOGIN_ENABLED` | `false` | Keep `false` outside development |
| `WS_ALLOWED_ORIGINS` | *(empty)* | Allowed browser origins for `/ws` |

### Useful commands

```bash
docker compose logs -f api      # follow API logs
docker compose ps               # service status and health
docker compose down             # stop (data is kept in the pgdata volume)
docker build -t hajr-live-backend .   # build the API image only
docker build -t hajr-live-web ./frontend   # build the web image only
```

> The seeded admin and the mock login are development conveniences; review the "Known limitations" in section 5 before exposing this stack publicly.

### CI

`.github/workflows/build.yml` runs `go vet`, `go build` and `go test` on every push and pull request to `main`, runs `flutter analyze`, `flutter test` and `flutter build web` for the frontend, then verifies that the API Docker image builds.

---

## 8. Frontend (Flutter: Android, iOS, Web)

The app lives in `frontend/` (package `hajr_live`) and talks to the Go API over REST and WebSocket.

```
frontend/lib/main.dart                       App entry, session-driven routing (login <-> app)
frontend/lib/config.dart                     API base URL (--dart-define=API_BASE_URL) and ws:// URL
frontend/lib/models.dart                     Session, Wallet, LiveEvent (chat / gift / system), helpers
frontend/lib/services/api_client.dart        Typed REST client: login, wallet, gift, top-up
frontend/lib/services/live_socket.dart       WebSocket with JWT subprotocol auth + auto-reconnect
frontend/lib/services/session_store.dart     JWT persistence (flutter_secure_storage), login/logout
frontend/lib/app_shell.dart                  Bottom navigation, owns the single WebSocket connection
frontend/lib/screens/login_screen.dart       Phone-number sign-in (saves the JWT)
frontend/lib/screens/live_room_screen.dart   Live chat, gift sheet, animated gift banners
frontend/lib/screens/wallet_screen.dart      Balances (real / promo) and admin top-up
```

### Screens

| Screen | What it does |
|---|---|
| Login | Validates an E.164 phone number, calls `POST /api/login`, stores the JWT securely, restores the session on restart and signs out automatically on a `401`. |
| Live room | Connects to `/ws`, shows real-time chat, and sends gifts through `POST /api/gift` (promo/real coins, preset or custom amount, idempotency key reused on retries). Every `gift` event from the hub plays an animated banner. |
| Wallet | Shows `GET /api/wallet` balances (pull to refresh, auto-refresh after gifts) and triggers `POST /api/topup`. Top-up is an **admin-only** endpoint on the backend, so the buttons are enabled for admin accounts only. |

### Run in development

Start the stack (or just the database and API), then:

```bash
cd frontend
flutter pub get

# Web (the API must allow this origin: set CORS_ALLOWED_ORIGINS=http://localhost:5555 on the API)
flutter run -d chrome --web-port 5555 --dart-define=API_BASE_URL=http://localhost:8080

# Android emulator (the host machine is 10.0.2.2); use your LAN IP for a real device
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080

# iOS simulator
flutter run --dart-define=API_BASE_URL=http://localhost:8080
```

Checks: `flutter analyze` and `flutter test`. Production web build: `flutter build web --dart-define=API_BASE_URL=origin`.

> Plain `http://`/`ws://` is fine for local development. In production serve everything over **HTTPS/WSS** (the app derives `wss://` from an `https://` base URL), because release builds block cleartext traffic (Android: only debug builds allow it; iOS: only local networking is exempt).
