CREATE TABLE IF NOT EXISTS wots_state (
    tree_id        TEXT     PRIMARY KEY,
    next_leaf      INTEGER  NOT NULL CHECK (next_leaf >= 0),
    max_leaf       INTEGER  NOT NULL CHECK (max_leaf > 0),
    last_updated   DATETIME NOT NULL,
    hmac           BLOB     NOT NULL,
    CHECK (next_leaf <= max_leaf)
);
CREATE TABLE IF NOT EXISTS wots_leaf_log (
    tree_id        TEXT     NOT NULL,
    leaf_index     INTEGER  NOT NULL,
    reserved_at    DATETIME NOT NULL,
    signature_hash BLOB,
    PRIMARY KEY (tree_id, leaf_index)
);
