-- Horizon v1.5 additive migration.
-- Run only against a separately backed-up, explicitly selected database.
-- This file does not execute itself and does not alter Genesis/history.

BEGIN;

ALTER TABLE public.chain_blocks
    ADD COLUMN IF NOT EXISTS organization_id TEXT,
    ADD COLUMN IF NOT EXISTS license_count BIGINT NOT NULL DEFAULT 0;

ALTER TABLE public.licenses
    ADD COLUMN IF NOT EXISTS organization_id TEXT,
    ADD COLUMN IF NOT EXISTS block_num BIGINT;

CREATE INDEX IF NOT EXISTS idx_chain_blocks_organization_id
    ON public.chain_blocks (organization_id);
CREATE INDEX IF NOT EXISTS idx_licenses_organization_block
    ON public.licenses (organization_id, block_num);

-- No historical backfill is performed. Existing rows remain NULL/0 until
-- independently reconciled; do not assign them to organizations by guess.
COMMIT;
