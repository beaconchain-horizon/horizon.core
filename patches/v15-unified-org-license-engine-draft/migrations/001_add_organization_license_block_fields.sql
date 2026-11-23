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

-- Database-level invariants. Existing legacy rows remain unassigned (NULL,
-- NULL) and are not backfilled. The composite FK prevents cross-organization
-- license linkage and is deferred so block + license rows commit atomically.
CREATE UNIQUE INDEX IF NOT EXISTS ux_chain_blocks_block_organization
    ON public.chain_blocks (block_num, organization_id);

DO $
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'ck_chain_blocks_org_cardinality'
          AND conrelid = 'public.chain_blocks'::regclass
    ) THEN
        ALTER TABLE public.chain_blocks
            ADD CONSTRAINT ck_chain_blocks_org_cardinality
            CHECK (organization_id IS NULL OR (license_count > 0 AND tx_count = 1));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'ck_licenses_org_block_pair'
          AND conrelid = 'public.licenses'::regclass
    ) THEN
        ALTER TABLE public.licenses
            ADD CONSTRAINT ck_licenses_org_block_pair
            CHECK (
                (organization_id IS NULL AND block_num IS NULL)
                OR
                (organization_id IS NOT NULL AND block_num IS NOT NULL AND block_num > 0)
            );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'fk_licenses_organization_block'
          AND conrelid = 'public.licenses'::regclass
    ) THEN
        ALTER TABLE public.licenses
            ADD CONSTRAINT fk_licenses_organization_block
            FOREIGN KEY (block_num, organization_id)
            REFERENCES public.chain_blocks (block_num, organization_id)
            ON UPDATE RESTRICT ON DELETE RESTRICT
            DEFERRABLE INITIALLY DEFERRED;
    END IF;
END $;

-- No historical backfill is performed. Existing rows remain NULL/0 until
-- independently reconciled; do not assign them to organizations by guess.
COMMIT;
