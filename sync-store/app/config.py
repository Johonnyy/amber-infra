"""Every knob this service has, behind one env prefix.

Follows the ecosystem convention: a pydantic-settings ``BaseSettings`` with a single
prefix, and an ``lru_cache``d accessor that runtime code calls **inside** functions
rather than binding at import time, so a test can ``get_settings.cache_clear()``
without reimporting the module.

The service reads ``SYNC_STORE_*`` and nothing else. It does not embed
``agent_mcp``, so there is no second prefix to keep in sync — unlike Amber, which
owns three consumers behind one ``AMBER_`` prefix.
"""

from __future__ import annotations

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="SYNC_STORE_",
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # --- Identity ---
    service_name: str = "sync-store"
    version: str = "0.1.0"

    # --- Storage ---
    #: In the container this is /data/sync-store.db, on a named volume. ":memory:"
    #: is honoured (and skips the WAL pragma) so tests need no temp files.
    db_path: str = "sync-store.db"
    #: WAL removes reader/writer blocking but not writer/writer. Without a timeout,
    #: two concurrent registrations surface as "database is locked".
    busy_timeout_ms: int = 5000

    # --- Auth ---
    #: Comma-separated bearer tokens, each optionally "name:token" so a registration
    #: is attributable in the log. EMPTY MEANS REJECT EVERYTHING — see app/auth.py
    #: on failing closed.
    keys: str = ""
    #: The explicit escape hatch for local development. Never set this in production.
    allow_anonymous: bool = False

    # --- Registry ---
    #: Seconds after which a server is *flagged* stale. 0 disables the flag and the
    #: default filtering entirely. Fail open: see db.list_servers.
    default_stale_after_s: int = 0

    # --- Config sync ---
    #: 1 MiB. Lucidity's blob is device config, not a data store.
    max_blob_bytes: int = 1_048_576
    #: Rows retained per device_id. Free undo, bounded growth.
    config_history: int = 50


@lru_cache
def get_settings() -> Settings:
    return Settings()
