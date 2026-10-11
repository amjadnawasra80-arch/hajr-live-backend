-- =============================================================================
-- HAJR LIVE V12 - 002_topup_grant_ledgers.sql
-- Requires 001_core_schema.sql
--
--   * topup_ledger       real money  -> credits wallets.real_coins
--   * grant_ledger       free coins  -> credits wallets.promo_coins
--   * chargeback_ledger  fraud shield -> deducts wallets.real_coins (may go negative = debt)
--   * wallets_guard      REPLACED: negative real_coins allowed ONLY when the
--                        mutation originates from apply_chargeback()
--   * ledger_immutable() attached to all 3 ledgers (append-only)
-- =============================================================================

BEGIN;

-- 1. Generic append-only guard (re-declared so this file is self-contained).
CREATE OR REPLACE FUNCTION ledger_immutable() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'Ledger % is APPEND-ONLY: No modifications allowed', TG_TABLE_NAME
        USING ERRCODE = 'restrict_violation';
    RETURN NULL; -- unreachable
END;
$$ LANGUAGE plpgsql;

-- 2. Top-up ledger (real money)
CREATE TABLE topup_ledger (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    idempotency_key   uuid        NOT NULL UNIQUE,
    user_id           uuid        NOT NULL REFERENCES users(id),
    fiat_amount       bigint      NOT NULL CHECK (fiat_amount > 0),          -- minor units
    fiat_currency     text        NOT NULL CHECK (fiat_currency ~ '^[A-Z]{3}$'),
    real_coins_minted bigint      NOT NULL CHECK (real_coins_minted > 0 AND real_coins_minted <= 1000000000),
    payment_provider  text        NOT NULL CHECK (length(payment_provider) > 0),
    provider_txn_id   text        NOT NULL CHECK (length(provider_txn_id) > 0),
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (payment_provider, provider_txn_id)
);

CREATE TRIGGER topup_immutable_trg BEFORE UPDATE OR DELETE ON topup_ledger
    FOR EACH ROW EXECUTE FUNCTION ledger_immutable();
CREATE TRIGGER topup_trunc_trg BEFORE TRUNCATE ON topup_ledger
    FOR EACH STATEMENT EXECUTE FUNCTION ledger_immutable();

-- NOTE: wallets_guard() identifies this function by name. Do not rename.
CREATE FUNCTION apply_topup() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    -- Lock first (serialization point), then idempotency check.
    PERFORM 1 FROM wallets WHERE user_id = NEW.user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Wallet not found (user %)', NEW.user_id USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- Replay (also covers INSERT ... ON CONFLICT DO NOTHING): skip, never credit twice.
    IF EXISTS (SELECT 1 FROM topup_ledger WHERE idempotency_key = NEW.idempotency_key) THEN
        RETURN NULL;
    END IF;

    UPDATE wallets SET real_coins = real_coins + NEW.real_coins_minted WHERE user_id = NEW.user_id;
    RETURN NEW;
END;
$$;
CREATE TRIGGER topup_apply_trg BEFORE INSERT ON topup_ledger
    FOR EACH ROW EXECUTE FUNCTION apply_topup();

-- 3. Grant ledger (free promo coins)
CREATE TABLE grant_ledger (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    idempotency_key     uuid        NOT NULL UNIQUE,
    user_id             uuid        NOT NULL REFERENCES users(id),
    promo_coins_minted  bigint      NOT NULL CHECK (promo_coins_minted > 0 AND promo_coins_minted <= 100000),
    reason              text        NOT NULL CHECK (reason IN ('welcome_pack', 'admin_gift', 'event_reward', 'compensation')),
    granted_by_admin_id uuid        REFERENCES users(id),                    -- NULL allowed
    created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER grant_immutable_trg BEFORE UPDATE OR DELETE ON grant_ledger
    FOR EACH ROW EXECUTE FUNCTION ledger_immutable();
CREATE TRIGGER grant_trunc_trg BEFORE TRUNCATE ON grant_ledger
    FOR EACH STATEMENT EXECUTE FUNCTION ledger_immutable();

CREATE FUNCTION apply_grant() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM 1 FROM wallets WHERE user_id = NEW.user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Wallet not found (user %)', NEW.user_id USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM grant_ledger WHERE idempotency_key = NEW.idempotency_key) THEN
        RETURN NULL;
    END IF;

    -- If an admin is named, they must really be one.
    IF NEW.granted_by_admin_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.granted_by_admin_id AND is_god_mode) THEN
        RAISE EXCEPTION 'granted_by_admin_id % is not an admin', NEW.granted_by_admin_id
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    UPDATE wallets SET promo_coins = promo_coins + NEW.promo_coins_minted WHERE user_id = NEW.user_id;
    RETURN NEW;
END;
$$;
CREATE TRIGGER grant_apply_trg BEFORE INSERT ON grant_ledger
    FOR EACH ROW EXECUTE FUNCTION apply_grant();

-- 4. Chargeback ledger (Fraud Shield)
CREATE TABLE chargeback_ledger (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    idempotency_key uuid        NOT NULL UNIQUE,
    user_id         uuid        NOT NULL REFERENCES users(id),
    amount_deducted bigint      NOT NULL CHECK (amount_deducted > 0),        -- positive magnitude
    reason          text        NOT NULL CHECK (length(reason) > 0),
    provider_txn_id text        NOT NULL CHECK (length(provider_txn_id) > 0),
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER chargeback_immutable_trg BEFORE UPDATE OR DELETE ON chargeback_ledger
    FOR EACH ROW EXECUTE FUNCTION ledger_immutable();
CREATE TRIGGER chargeback_trunc_trg BEFORE TRUNCATE ON chargeback_ledger
    FOR EACH STATEMENT EXECUTE FUNCTION ledger_immutable();

-- NOTE: wallets_guard() identifies this function by name. Do not rename.
CREATE FUNCTION apply_chargeback() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM 1 FROM wallets WHERE user_id = NEW.user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Wallet not found (user %)', NEW.user_id USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM chargeback_ledger WHERE idempotency_key = NEW.idempotency_key) THEN
        RETURN NULL;
    END IF;

    -- Strictly real_coins; promo_coins untouched. May go negative (fraud debt).
    UPDATE wallets SET real_coins = real_coins - NEW.amount_deducted WHERE user_id = NEW.user_id;
    RETURN NEW;
END;
$$;
CREATE TRIGGER chargeback_apply_trg BEFORE INSERT ON chargeback_ledger
    FOR EACH ROW EXECUTE FUNCTION apply_chargeback();

-- 5. Replace wallets_guard: negative real_coins ONLY via apply_chargeback().
--    (b) Debt repayment via apply_topup() on an already-negative wallet is also
--        permitted, otherwise a user in debt could never top up. Delete the
--        "topup" branch below if you want top-ups into debt rejected instead.
CREATE OR REPLACE FUNCTION wallets_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_ctx text;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Wallets cannot be deleted' USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    -- OLD only exists on UPDATE/DELETE; never touch it on INSERT.
    IF TG_OP = 'UPDATE' THEN
        IF NEW.user_id IS DISTINCT FROM OLD.user_id THEN
            RAISE EXCEPTION 'wallets.user_id is immutable' USING ERRCODE = 'integrity_constraint_violation';
        END IF;
    END IF;

    IF NEW.promo_coins < 0 THEN
        RAISE EXCEPTION 'Insufficient funds: promo_coins cannot go negative' USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.real_coins < 0 THEN
        IF TG_OP = 'UPDATE' AND pg_trigger_depth() >= 2 THEN
            GET DIAGNOSTICS v_ctx = PG_CONTEXT;

            -- Chargeback: strict real_coins deduction only.
            IF v_ctx ~ E'(^|\\n)PL/pgSQL function apply_chargeback\\(\\) line [0-9]+'
               AND NEW.real_coins  < OLD.real_coins
               AND NEW.promo_coins = OLD.promo_coins THEN
                NEW.updated_at := now();
                RETURN NEW;
            END IF;

            -- Top-up repaying existing debt (wallet already negative, only moves upward).
            IF v_ctx ~ E'(^|\\n)PL/pgSQL function apply_topup\\(\\) line [0-9]+'
               AND OLD.real_coins < 0
               AND NEW.real_coins > OLD.real_coins
               AND NEW.promo_coins = OLD.promo_coins THEN
                NEW.updated_at := now();
                RETURN NEW;
            END IF;
        END IF;

        RAISE EXCEPTION 'Insufficient funds: real_coins cannot go negative except via chargeback ledger'
            USING ERRCODE = 'check_violation';
    END IF;

    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

-- 001 only attached INSERT/UPDATE; add DELETE so the delete block actually fires.
DROP TRIGGER IF EXISTS wallets_guard ON wallets;
CREATE TRIGGER wallets_guard
BEFORE INSERT OR UPDATE OR DELETE ON wallets
FOR EACH ROW EXECUTE FUNCTION wallets_guard();

-- Privileges: ledgers append-only at the privilege level too.
REVOKE UPDATE, DELETE, TRUNCATE ON topup_ledger      FROM PUBLIC;
REVOKE UPDATE, DELETE, TRUNCATE ON grant_ledger      FROM PUBLIC;
REVOKE UPDATE, DELETE, TRUNCATE ON chargeback_ledger FROM PUBLIC;

COMMIT;
