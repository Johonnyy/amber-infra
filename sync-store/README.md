# sync-store

The ecosystem's discovery registry and Lucidity's cross-device config store. One
FastAPI process, one SQLite file, four runtime dependencies.

It exists because `agent-mcp-py` already implements both halves of a contract with
nothing on the other end: every MCP server calls `sync_client.register()` on startup
and re-registers on a heartbeat, and every agent calls `PeerRegistry.refresh()` to
discover peers. This is the service they were written against.

## The contract (not ours to change)

| | |
|---|---|
| `POST /servers` | What `sync_client.register()` sends — the descriptor, no envelope. Re-sent every `AGENT_MCP_HEARTBEAT_INTERVAL_S` (default 300s) forever, with no retry and a 5s timeout. **Upserts on `name`.** The client never parses the response body; it only calls `raise_for_status()`. |
| `POST /servers/register` | Alias for the above, for the shape the original spec described. A second decorator, not a redirect — a 307 on a POST loses the body. |
| `GET /servers` | What `PeerRegistry.refresh()` reads. Returns `{"servers": [...]}`; the reader accepts that or a bare array. |

Two asymmetries in that contract are the reason this service is not a thin CRUD app:

**Tools go in as objects and come out as strings.** `build_descriptor` writes
`[{name, description, read_only, requires_confirmation}]`, but `PeerRecord.tools` is
typed `tuple[str, ...]` and built with a bare `tuple(raw.get("tools") or ())`. Echo
the objects back under `tools` and every downstream agent holds dicts where it
expects strings. The store keeps the objects and serves both: `tools` (bare names,
the contract) and `tool_details` (the objects, for Lucidity).

**Nothing writes the `token` field that everything reads.** `PeerRegistry` reads a
per-server `token`, and `agent_runtime`'s MCP client presents it as the outbound
`Authorization` when calling that peer — but `register()` never sends one. So the
store is the credential authority: `PUT /servers/{name}/token`, admin-only, and
deliberately absent from the registration upsert so an app cannot grant itself the
credential others will present to it.

## Endpoints

Everything except `/health` needs `Authorization: Bearer <token>`. Errors use the
ecosystem envelope `{"error", "message"}`, not FastAPI's `{"detail"}`.

```
GET    /health                     no auth; touches the DB, leaks no counts
POST   /servers                    register/upsert  (alias: /servers/register)
GET    /servers                    discovery; ?stale_after_s= &include_stale=
GET    /servers/{name}             one record
PUT    /servers/{name}/token       set/clear the peer credential; never echoes it
DELETE /servers/{name}             the only removal path

POST   /config                     {device_id, blob} — blob must be a JSON object
GET    /config                     ?device_id= optional; newest wins; nulls if empty
GET    /config/history             metadata only, no blobs
```

The config half is Lucidity's storage and nothing else. The store never interprets
the blob; it stores bytes and hands them back.

## Staleness fails open

`GET /servers` lists dead servers by default. `PeerRegistry.refresh()` replaces its
discovered layer wholesale, so filtering a live-but-slow server removes it from every
agent at once and keeps it gone until its next heartbeat *and* their next refresh —
and `register()` has no retry, so one dropped POST is enough to trigger that. Leaving
a dead server listed costs one failed peer call, logged. Every record carries
`last_seen` and a `stale` flag so a UI can grey one out without breaking discovery.

## Running it

```bash
python -m venv .venv && .venv/Scripts/activate     # .venv/bin/activate on Linux
pip install -e ".[dev]"
cp .env.example .env                                # then set SYNC_STORE_KEYS
uvicorn app.main:app --reload --port 8081
pytest -q
```

`pytest tests/test_contract_agent_mcp.py` is the gate: it drives the real
`agent_mcp` client against a live instance of this service, so it proves the store
satisfies the library rather than proving it satisfies our idea of the library.

In production it runs from `docker-compose.prod.yml` on Server A, behind Caddy at
`sync.<domain>`, with `/data` on a named volume. See the repo README for the
deploy runbook.

## Known ecosystem wart

`mcp_path` is stored and served, but nothing reads it — `agent_mcp.registry`
hardcodes `MCP_MOUNT_PATH = "/mcp"`. Left as-is: making it meaningful is a change to
the library, not to this store.
