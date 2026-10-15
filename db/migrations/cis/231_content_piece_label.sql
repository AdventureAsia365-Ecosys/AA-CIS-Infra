-- Migration 231: AA-791 — acp_shared.content_piece_label, a human verdict per T9 piece.
--
-- All ground truth for the T9 gates is AI-panel output today (S234 report 12 §1.5). AA-783 asks
-- Nghiệp (and optionally Ms. Thư) to label pieces with an explicit checklist; this table keeps
-- those labels next to the pieces so gates can be re-scored against them automatically. It is
-- written only by the admin Content Quality drawer (POST /admin/content-quality/pieces/{id}/label,
-- staff role `admin`), read only by admin routes. Tenants never see it.
--
-- Shape follows the AA-783 criteria pack (label-pack/HUONG-DAN-CHAM.md):
--   label           as_is | light (≤10 min, ≤3 sentences, no research) | heavy | reject
--   defects         {"fact"|"voice"|"format"|"ai_phrasing": "none"|"light"|"heavy"}, validated by the API
--   minutes_to_fix  the labeller's estimate, optional
--   reason          free text: the worst sentences / why
-- One row per (piece, labeller): two people labelling the same piece is how agreement (κ) is
-- measured, and a labeller changing their mind overwrites their own row (labelled_at moves).
-- content_sha256 is the hash of content_text when it was labelled: an admin sentence edit
-- (S234) after the label shows up as a mismatch instead of silently re-scoring a different text.
--
-- Admin-only data: no tenant_id column and no grant to aa_app_user (acp_shared has no default
-- privileges for it; the explicit REVOKE below keeps it that way if one is ever added). The
-- owner role (aa_cis_admin, the admin pool) reads and writes it.
--
-- Applied on Dev via the AA-CIS-Infra "DB Migrate" workflow (identical copy in
-- db/migrations/cis/). The app code tolerates the table being absent until then (the label
-- routes answer 503, the list shows no label column).

BEGIN;

CREATE TABLE IF NOT EXISTS acp_shared.content_piece_label (
    piece_id        UUID NOT NULL REFERENCES acp_shared.content_piece(piece_id) ON DELETE CASCADE,
    labelled_by     TEXT NOT NULL CHECK (length(btrim(labelled_by)) > 0),
    label           TEXT NOT NULL CHECK (label IN ('as_is', 'light', 'heavy', 'reject')),
    defects         JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(defects) = 'object'),
    minutes_to_fix  SMALLINT CHECK (minutes_to_fix IS NULL OR minutes_to_fix BETWEEN 0 AND 600),
    reason          TEXT CHECK (reason IS NULL OR length(reason) <= 4000),
    content_sha256  TEXT,
    labelled_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (piece_id, labelled_by)
);

CREATE INDEX IF NOT EXISTS idx_content_piece_label_label
    ON acp_shared.content_piece_label(label, labelled_at DESC);

COMMENT ON TABLE acp_shared.content_piece_label IS
    'AA-791 — human verdict on one T9 piece per labeller (AA-783 criteria): label as_is/light/heavy/'
    'reject, per-class defects, minutes to fix, reason, and the sha256 of the text labelled. '
    'Admin-only (Content Quality drawer); never in a tenant projection.';
COMMENT ON COLUMN acp_shared.content_piece_label.defects IS
    'AA-791 — {"fact"|"voice"|"format"|"ai_phrasing": "none"|"light"|"heavy"}; keys optional.';
COMMENT ON COLUMN acp_shared.content_piece_label.content_sha256 IS
    'AA-791 — sha256 of content_piece.content_text at label time; differs once an admin edits the piece.';

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aa_app_user') THEN
        REVOKE ALL ON acp_shared.content_piece_label FROM aa_app_user;
    END IF;
END $$;

INSERT INTO shared.schema_versions (version, applied_at, description)
VALUES ('231', now(), 'AA-791: acp_shared.content_piece_label — human label per T9 piece and labeller '
        '(as_is/light/heavy/reject, defects, minutes, reason, content sha256)')
ON CONFLICT (version) DO NOTHING;

COMMIT;
