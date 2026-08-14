"""SQLite storage for both halves of the store.

Two tables, one file, and no relationship between them. The **server registry** is
what ``agent_mcp.sync_client.register()`` writes and ``agent_mcp.registry
.PeerRegistry.refresh()`` reads. The **config blobs** are Lucidity's cross-device
storage, which this service never interprets. They share a process because running
two services for this would be silly, and share nothing else.

Follows the ecosystem's SQLite house pattern (``agent_mcp.usage_log``): a
module-level ``_SCHEMA`` of ``CREATE TABLE IF NOT EXISTS`` run through
``executescript``, one connection with ``check_same_thread=False`` serialized under
a ``threading.Lock``, rows out as plain dicts, and ISO-8601 UTC-seconds TEXT
timestamps — never epoch floats. Every method here is synchronous; ``main.py``
wraps each call in ``asyncio.to_thread`` so a write never blocks the event loop.

Two storage decisions worth the words:

* **``tools_json`` and ``resources_json`` are TEXT, not normalized child tables.**
  The store never queries inside them — it stores what was POSTed and projects on
  read. Normalizing would mean deleting and reinserting N rows every heartbeat
  interval, per server, forever, to arrive at the same bytes.
* **The upsert never writes ``token``.** A registering app must not be able to grant
  itself the credential other agents will present to it. That column is set only
  through :meth:`Store.set_token`, which is reachable only from the admin endpoint.
"""

from __future__ import annotations

import json
import logging
import sqlite3
import threading
from datetime import datetime, timedelta, timezone

logger = logging.getLogger(__name__)

_SCHEMA = """
CREATE TABLE IF NOT EXISTS servers (
    name            TEXT    PRIMARY KEY,          -- the upsert key; see models.validate_app_name
    base_url        TEXT    NOT NULL,             -- no trailing slash, no /mcp suffix
    mcp_path        TEXT    NOT NULL DEFAULT '/mcp',
    version         TEXT    NOT NULL DEFAULT '',
    token           TEXT    NOT NULL DEFAULT '',  -- peer credential. ADMIN-SET ONLY.
    tools_json      TEXT    NOT NULL DEFAULT '[]',      -- full objects, exactly as POSTed
    resources_json  TEXT    NOT NULL DEFAULT '[]',
    first_seen      TEXT    NOT NULL,             -- ISO-8601 UTC, seconds
    last_seen       TEXT    NOT NULL,
    register_count  INTEGER NOT NULL DEFAULT 1    -- heartbeats observed; cheap liveness
);
CREATE INDEX IF NOT EXISTS idx_servers_last_seen ON servers (last_seen);

CREATE TABLE IF NOT EXISTS config_blobs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,  -- the change cursor Lucidity polls
    device_id   TEXT    NOT NULL,
    blob_json   TEXT    NOT NULL,   -- opaque: Lucidity owns the shape, we never parse it
    byte_size   INTEGER NOT NULL,
    created_at  TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_config_device ON config_blobs (device_id, id DESC);
"""


def now_iso() -> str:
    """Current UTC time as ISO-8601 seconds.

    Lexically sortable, and the exact format ``agent_mcp.usage_log.now_iso`` writes,
    so a human can eyeball a ``last_seen`` here against a usage row over there.
    """
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _parse_iso(value: str) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(value)
    except (TypeError, ValueError):
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def _tool_names(raw: str) -> list[str]:
    """Project stored tool objects down to the bare names the readers expect.

    This is the load-bearing asymmetry of the whole contract.
    ``sync_client.build_descriptor`` **writes** tools as objects, but
    ``PeerRegistry.refresh`` **reads** them into ``PeerRecord.tools``, which is typed
    ``tuple[str, ...]`` and built with a bare ``tuple(raw.get("tools") or ())``. Echo
    the objects back under ``tools`` and every agent in the ecosystem ends up holding
    a tuple of dicts where it expects strings.

    A malformed entry (a hand-``curl``'d registration, say) becomes ``""`` rather
    than raising, because one bad row must not break discovery for every other peer.
    """
    try:
        loaded = json.loads(raw or "[]")
    except json.JSONDecodeError:
        return []
    if not isinstance(loaded, list):
        return []
    return [t.get("name", "") if isinstance(t, dict) else "" for t in loaded]


def _loads_list(raw: str) -> list:
    try:
        loaded = json.loads(raw or "[]")
    except json.JSONDecodeError:
        return []
    return loaded if isinstance(loaded, list) else []


class Store:
    """One SQLite file, one connection, one lock."""

    def __init__(self, path: str = "sync-store.db", *, busy_timeout_ms: int = 5000) -> None:
        self.path = path
        # check_same_thread=False: the connection is reused from asyncio.to_thread
        # worker threads. Safe because every access is serialized by _lock.
        self._conn = sqlite3.connect(path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._lock = threading.Lock()
        with self._lock:
            if path != ":memory:":
                self._conn.execute("PRAGMA journal_mode=WAL")
            self._conn.execute(f"PRAGMA busy_timeout={int(busy_timeout_ms)}")
            self._conn.executescript(_SCHEMA)
            self._conn.commit()

    # --- lifecycle ---

    def ping(self) -> bool:
        """Prove the handle is alive, not merely that the process is.

        ``/health`` calls this so a corrupted or unlinked database file surfaces as
        an unhealthy container rather than a 200 that lies.
        """
        with self._lock:
            self._conn.execute("SELECT 1").fetchone()
        return True

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    # --- server registry ---

    def register(
        self,
        *,
        name: str,
        base_url: str,
        mcp_path: str = "/mcp",
        version: str = "",
        tools: list | None = None,
        resources: list | None = None,
        now: str | None = None,
    ) -> dict:
        """Upsert one server descriptor. Returns ``{"created": bool, "last_seen": str}``.

        Idempotent by construction: the same descriptor arrives every heartbeat
        interval, forever, and must update in place rather than accumulate.
        """
        stamp = now or now_iso()
        tools_json = json.dumps(tools or [], separators=(",", ":"))
        resources_json = json.dumps(resources or [], separators=(",", ":"))
        with self._lock:
            existing = self._conn.execute(
                "SELECT 1 FROM servers WHERE name = ?", (name,)
            ).fetchone()
            self._conn.execute(
                """
                INSERT INTO servers (name, base_url, mcp_path, version, tools_json,
                                     resources_json, first_seen, last_seen, register_count)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
                ON CONFLICT(name) DO UPDATE SET
                    base_url       = excluded.base_url,
                    mcp_path       = excluded.mcp_path,
                    version        = excluded.version,
                    tools_json     = excluded.tools_json,
                    resources_json = excluded.resources_json,
                    last_seen      = excluded.last_seen,
                    register_count = servers.register_count + 1
                """,
                # token and first_seen are absent from the SET list on purpose: a
                # registering app must not be able to grant itself a peer credential,
                # and first_seen is history, not state.
                (name, base_url, mcp_path, version, tools_json, resources_json, stamp, stamp),
            )
            self._conn.commit()
        return {"created": existing is None, "last_seen": stamp}

    def _row_to_record(self, row: sqlite3.Row, *, stale_after_s: int, now: datetime) -> dict:
        last_seen = _parse_iso(row["last_seen"])
        stale = bool(
            stale_after_s > 0
            and last_seen is not None
            and now - last_seen > timedelta(seconds=stale_after_s)
        )
        return {
            "name": row["name"],
            "base_url": row["base_url"],
            "mcp_path": row["mcp_path"],
            "version": row["version"],
            "token": row["token"],
            # The two shapes of the same list. `tools` is the contract; `tool_details`
            # is for Lucidity's UI, and PeerRegistry ignores keys it does not know.
            "tools": _tool_names(row["tools_json"]),
            "tool_details": _loads_list(row["tools_json"]),
            "resources": _loads_list(row["resources_json"]),
            "first_seen": row["first_seen"],
            "last_seen": row["last_seen"],
            "register_count": row["register_count"],
            "stale": stale,
        }

    def list_servers(self, *, stale_after_s: int = 0, include_stale: bool = True) -> list[dict]:
        """Every registered server, newest registration first.

        **Filtering is off by default, and that is a decision.**
        ``PeerRegistry.refresh`` replaces its discovered layer wholesale, so dropping
        a live-but-slow server here removes it from every agent at once and keeps it
        gone until its next heartbeat *and* their next refresh. ``register()`` has no
        retry and a five-second timeout, so one dropped POST is enough to trigger
        that. Leaving a dead server listed costs one failed peer call, logged. The
        costs are asymmetric, so this fails open and merely *flags* staleness for a
        UI to grey out.
        """
        now = datetime.now(timezone.utc)
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM servers ORDER BY last_seen DESC, name ASC"
            ).fetchall()
        records = [self._row_to_record(r, stale_after_s=stale_after_s, now=now) for r in rows]
        if not include_stale:
            records = [r for r in records if not r["stale"]]
        return records

    def get_server(self, name: str, *, stale_after_s: int = 0) -> dict | None:
        now = datetime.now(timezone.utc)
        with self._lock:
            row = self._conn.execute("SELECT * FROM servers WHERE name = ?", (name,)).fetchone()
        if row is None:
            return None
        return self._row_to_record(row, stale_after_s=stale_after_s, now=now)

    def set_token(self, name: str, token: str) -> bool:
        """Set (or clear, with ``""``) the peer credential for one server.

        The only writer of this column. ``sync_client.register()`` never sends a
        token, but ``PeerRegistry.refresh`` reads one and ``agent_runtime``'s MCP
        client presents it as the outbound ``Authorization`` — so this store is the
        one place in the ecosystem where "what does Amber show finance-agent" is
        set once and picked up everywhere.
        """
        with self._lock:
            cursor = self._conn.execute(
                "UPDATE servers SET token = ? WHERE name = ?", (token, name)
            )
            self._conn.commit()
        return cursor.rowcount > 0

    def delete_server(self, name: str) -> bool:
        """Remove a server. The only removal path — nothing here expires on its own."""
        with self._lock:
            cursor = self._conn.execute("DELETE FROM servers WHERE name = ?", (name,))
            self._conn.commit()
        return cursor.rowcount > 0

    # --- config sync ---

    def put_config(self, *, device_id: str, blob: dict, keep: int = 50) -> dict:
        """Append one config blob and prune that device's history to ``keep`` rows.

        ``sort_keys`` so an unchanged blob serializes to identical bytes, which makes
        ``byte_size`` a usable change signal and keeps diffs readable.
        """
        payload = json.dumps(blob, separators=(",", ":"), sort_keys=True)
        stamp = now_iso()
        with self._lock:
            cursor = self._conn.execute(
                "INSERT INTO config_blobs (device_id, blob_json, byte_size, created_at) "
                "VALUES (?, ?, ?, ?)",
                (device_id, payload, len(payload.encode("utf-8")), stamp),
            )
            if keep > 0:
                self._conn.execute(
                    "DELETE FROM config_blobs WHERE device_id = ? AND id NOT IN "
                    "(SELECT id FROM config_blobs WHERE device_id = ? ORDER BY id DESC LIMIT ?)",
                    (device_id, device_id, int(keep)),
                )
            self._conn.commit()
            row_id = cursor.lastrowid
        return {
            "id": row_id,
            "device_id": device_id,
            "created_at": stamp,
            "byte_size": len(payload.encode("utf-8")),
        }

    def get_config(self, *, device_id: str | None = None) -> dict:
        """The newest blob, optionally scoped to one device.

        Without a ``device_id`` this returns the newest blob written by *any* device
        — that is the cross-device sync semantic ("give me the latest"). An empty
        store returns nulls rather than raising, so a first-run client needs no
        special case.
        """
        sql = "SELECT * FROM config_blobs"
        params: list[object] = []
        if device_id:
            sql += " WHERE device_id = ?"
            params.append(device_id)
        sql += " ORDER BY id DESC LIMIT 1"
        with self._lock:
            row = self._conn.execute(sql, params).fetchone()
        if row is None:
            return {"id": None, "device_id": None, "blob": None, "created_at": None}
        return {
            "id": row["id"],
            "device_id": row["device_id"],
            "blob": json.loads(row["blob_json"]),
            "created_at": row["created_at"],
        }

    def config_history(self, *, device_id: str | None = None, limit: int = 20) -> list[dict]:
        """Metadata only — no blobs, so this stays cheap however large they get."""
        sql = "SELECT id, device_id, byte_size, created_at FROM config_blobs"
        params: list[object] = []
        if device_id:
            sql += " WHERE device_id = ?"
            params.append(device_id)
        sql += " ORDER BY id DESC LIMIT ?"
        params.append(int(limit))
        with self._lock:
            rows = self._conn.execute(sql, params).fetchall()
        return [dict(r) for r in rows]
