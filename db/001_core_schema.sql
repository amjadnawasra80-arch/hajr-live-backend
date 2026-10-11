-- =============================================================================
-- HAJR LIVE V12 - 001_core_schema.sql
-- PostgreSQL 13+ | Strict ACID | BIGINT minor units only
--
-- Contents:
--   * ledger_immutable()      generic append-only guard (shared with 002)
--   * users                   (UUID, phone_number, is_god_mode, kyc_status)
--                             user #1 is ALWAYS the admin (god mode)
--   * wallets + wallets_guard dual balances, negative balances forbidden
--   * transactions            immutable gift ledger, 25% platform fee,
--                             enforced by a BEFORE INSERT trigger that locks
--                             the wallets rows FOR UPDATE
-- =============================================================================

BEGIN;

-- gen_random_uuid() is built into core PostgreSQL 13+, no extension required.

-- -----------------------------------------------------------------------------
-- Generic append-only guard. Attached to every ledger table
-- (row-level for UPDATE/DELETE, statement-level for TRUNCATE).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ledger_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Ledger "%" is APPEND-ONLY: % is forbidden',
        TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'restrict_violation';
    RETURN NULL; -- unreachable
END;
$$;

-- -----------------------------------------------------------------------------
-- users
-- -----------------------------------------------------------------------------
CREATE TABLE users (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Human-friendly, strictly sequential number. User #1 is the admin.
    user_number   BIGINT      GENERATED ALWAYS AS IDENTITY UNIQUE,
    phone_number  TEXT        NOT NULL UNIQUE
                  CONSTRAINT users_phone_e164_chk CHECK (phone_number ~ '^\+[1-9][0-9]{6,14}$'),
    is_god_mode   BOOLEAN     NOT NULL DEFAULT FALSE,
    kyc_status    TEXT        NOT NULL DEFAULT 'unverified'
                  CONSTRAINT users_kyc_status_chk
                  CHECK (kyc_status IN ('unverified', 'pending', 'verified', 'rejected')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- User #1 is admin: force god mode on the very first user, whatever the caller sent.
CREATE OR REPLACE FUNCTION users_bootstrap_admin()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.user_number = 1 THEN
        NEW.is_god_mode := TRUE;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER users_bootstrap_admin
BEFORE INSERT ON users
FOR EACH ROW EXECUTE FUNCTION users_bootstrap_admin();

-- -----------------------------------------------------------------------------
-- wallets (dual ledger balances)
--   real_coins  = purchased coins
--   promo_coins = free coins
-- Non-negativity is enforced by the wallets_guard TRIGGER (not a CHECK) so that
-- 002 can carve out the single chargeback exception.
-- -----------------------------------------------------------------------------
CREATE TABLE wallets (
    user_id      UUID        PRIMARY KEY REFERENCES users(id),
    real_coins   BIGINT      NOT NULL DEFAULT 0,
    promo_coins  BIGINT      NOT NULL DEFAULT 0,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION wallets_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.real_coins < 0 THEN
        RAISE EXCEPTION 'Negative real_coins balance is forbidden (user %, value %)',
            NEW.user_id, NEW.real_coins
            USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.promo_coins < 0 THEN
        RAISE EXCEPTION 'Negative promo_coins balance is forbidden (user %, value %)',
            NEW.user_id, NEW.promo_coins
            USING ERRCODE = 'check_violation';
    END IF;

    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER wallets_guard
BEFORE INSERT OR UPDATE ON wallets
FOR EACH ROW EXECUTE FUNCTION wallets_guard();

-- Every user gets exactly one wallet, atomically with the user row.
CREATE OR REPLACE FUNCTION users_create_wallet()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    INSERT INTO wallets (user_id) VALUES (NEW.id);
    RETURN NEW;
END;
$$;

CREATE TRIGGER users_create_wallet
AFTER INSERT ON users
FOR EACH ROW EXECUTE FUNCTION users_create_wallet();

-- -----------------------------------------------------------------------------
-- transactions: immutable gift ledger
--   sender pays gross_amount; receiver gets net_amount; platform keeps
--   platform_fee = floor(gross_amount * 25 / 100).
--   Coins keep their type end-to-end (promo stays promo, real stays real), so
--   free coins can never be converted into purchased coins via gifting.
--   platform_fee / net_amount are ALWAYS computed by the trigger; any values
--   supplied by the caller are overwritten.
-- -----------------------------------------------------------------------------
CREATE TABLE transactions (
    id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    idempotency_key  TEXT        NOT NULL UNIQUE
                     CONSTRAINT transactions_idem_chk CHECK (length(idempotency_key) > 0),
    sender_id        UUID        NOT NULL REFERENCES users(id),
    receiver_id      UUID        NOT NULL REFERENCES users(id),
    coin_type        TEXT        NOT NULL
                     CONSTRAINT transactions_coin_type_chk CHECK (coin_type IN ('real_coins', 'promo_coins')),
    gross_amount     BIGINT      NOT NULL
                     CONSTRAINT transactions_gross_chk CHECK (gross_amount BETWEEN 1 AND 1000000000),
    platform_fee     BIGINT      NOT NULL DEFAULT 0
                     CONSTRAINT transactions_fee_chk CHECK (platform_fee >= 0),
    net_amount       BIGINT      NOT NULL DEFAULT 0
                     CONSTRAINT transactions_net_chk CHECK (net_amount >= 0),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT transactions_no_self_gift_chk CHECK (sender_id <> receiver_id),
    CONSTRAINT transactions_split_chk CHECK (platform_fee + net_amount = gross_amount)
);

CREATE INDEX transactions_sender_idx   ON transactions (sender_id, created_at DESC);
CREATE INDEX transactions_receiver_idx ON transactions (receiver_id, created_at DESC);

CREATE OR REPLACE FUNCTION transactions_apply()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    c_fee_percent CONSTANT BIGINT := 25;
    v_sender_real   BIGINT;
    v_sender_promo  BIGINT;
    v_receiver_ok   BOOLEAN;
BEGIN
    -- 1) Lock BOTH wallet rows in deterministic order (user_id) -> no deadlocks
    --    between opposing gifts, and a serialization point for this sender.
    PERFORM 1
    FROM wallets
    WHERE user_id IN (NEW.sender_id, NEW.receiver_id)
    ORDER BY user_id
    FOR UPDATE;

    -- 2) Idempotent replay: same key => silently skip (0 rows inserted, no money moves).
    --    Done AFTER the lock so concurrent duplicates serialize correctly.
    IF EXISTS (SELECT 1 FROM transactions WHERE idempotency_key = NEW.idempotency_key) THEN
        RETURN NULL;
    END IF;

    SELECT real_coins, promo_coins
      INTO v_sender_real, v_sender_promo
      FROM wallets
     WHERE user_id = NEW.sender_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sender wallet not found (user %)', NEW.sender_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    SELECT TRUE INTO v_receiver_ok FROM wallets WHERE user_id = NEW.receiver_id;
    IF v_receiver_ok IS NOT TRUE THEN
        RAISE EXCEPTION 'Receiver wallet not found (user %)', NEW.receiver_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- 3) 25% platform fee (integer math, truncated); receiver gets the remainder.
    NEW.platform_fee := (NEW.gross_amount * c_fee_percent) / 100;
    NEW.net_amount   := NEW.gross_amount - NEW.platform_fee;

    -- 4) Funds check + movement (same coin type on both sides).
    IF NEW.coin_type = 'real_coins' THEN
        IF v_sender_real < NEW.gross_amount THEN
            RAISE EXCEPTION 'Insufficient real_coins: have %, need %', v_sender_real, NEW.gross_amount
                USING ERRCODE = 'check_violation';
        END IF;

        UPDATE wallets SET real_coins = real_coins - NEW.gross_amount WHERE user_id = NEW.sender_id;
        UPDATE wallets SET real_coins = real_coins + NEW.net_amount   WHERE user_id = NEW.receiver_id;
    ELSE
        IF v_sender_promo < NEW.gross_amount THEN
            RAISE EXCEPTION 'Insufficient promo_coins: have %, need %', v_sender_promo, NEW.gross_amount
                USING ERRCODE = 'check_violation';
        END IF;

        UPDATE wallets SET promo_coins = promo_coins - NEW.gross_amount WHERE user_id = NEW.sender_id;
        UPDATE wallets SET promo_coins = promo_coins + NEW.net_amount   WHERE user_id = NEW.receiver_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER transactions_apply
BEFORE INSERT ON transactions
FOR EACH ROW EXECUTE FUNCTION transactions_apply();

-- Immutability (append-only)
CREATE TRIGGER transactions_immutable_row
BEFORE UPDATE OR DELETE ON transactions
FOR EACH ROW EXECUTE FUNCTION ledger_immutable();

CREATE TRIGGER transactions_immutable_truncate
BEFORE TRUNCATE ON transactions
FOR EACH STATEMENT EXECUTE FUNCTION ledger_immutable();

-- -----------------------------------------------------------------------------
-- Privileges: balances may only move through the ledger triggers above
-- (SECURITY DEFINER functions run as the migration owner).
-- -----------------------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON wallets      FROM PUBLIC;
REVOKE UPDATE, DELETE, TRUNCATE         ON transactions FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- Seed: user #1 = platform admin (god mode). CHANGE THE PHONE NUMBER before
-- production. Only runs on an empty users table.
-- -----------------------------------------------------------------------------
INSERT INTO users (phone_number, kyc_status)
SELECT '+10000000000', 'verified'
WHERE NOT EXISTS (SELECT 1 FROM users);

COMMIT;
