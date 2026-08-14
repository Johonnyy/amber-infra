"""The HTTP surface: a server registry, a config blob store, and a health check.

Two conceptually separate things in one tiny service, because running two processes
for this would be silly:

* **``/servers``** — what every ``agent-mcp-py`` app POSTs on startup and every 300
  seconds thereafter, and what Amber, the spawner and Aperture GET to discover
  peers. The shapes are not ours to choose; see ``app/models.py``.
* **``/config``** — Aperture's cross-device storage for one opaque JSON blob. The
  store never interprets it.

Three conventions carried from the ecosystem:

* **The error envelope is ``{"error", "message"}``**, not FastAPI's ``{"detail"}``.
  Every other service in the ecosystem speaks the former (``agent_mcp.middleware``),
  and two envelopes would mean every client needs two parsers. The exception
  handlers below are the only reason this file imports from ``fastapi.exceptions``.
* **A 401 carries ``WWW-Authenticate``.** Same as the MCP servers.
* **Every SQLite call goes through ``asyncio.to_thread``.** The store is synchronous
  by design; the event loop must not block on a write.

This service is *not* an MCP server. It accepts and logs ``X-Conversation-Id`` so a
registration can be tied to the exchange that caused it, and ignores
``X-Agent-Depth`` and ``X-Confirmed`` — registration sends neither, and there is no
onward hop to guard.
"""

from __future__ import annotations

import asyncio
import json
import logging
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.auth import REALM, AuthResult, parse_keys, verify_bearer
from app.config import Settings, get_settings
from app.db import Store, now_iso
from app.models import (
    ConfigRead,
    ConfigWrite,
    HealthResponse,
    RegisterResponse,
    ServerDescriptor,
    TokenUpdate,
)

logger = logging.getLogger(__name__)

HEADER_CONVERSATION_ID = "X-Conversation-Id"


class _Unauthorized(Exception):
    """Raised by the auth dependency; rendered by the handler below.

    A bare ``HTTPException(401)`` would work, but this keeps the
    ``WWW-Authenticate`` header in exactly one place.
    """

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


def _error(status: int, code: str, message: str, **headers: str) -> JSONResponse:
    return JSONResponse(
        status_code=status, content={"error": code, "message": message}, headers=headers or None
    )


def build_app(settings: Settings | None = None, *, store: Store | None = None) -> FastAPI:
    """Construct the app.

    A factory rather than a module-level ``app`` reading the environment, so a test
    can inject settings and an in-memory store without touching ``os.environ`` or a
    real ``.env``. The module-level ``app`` at the bottom is what uvicorn imports.
    """
    settings = settings or get_settings()
    keys = parse_keys(settings.keys)

    if not keys and not settings.allow_anonymous:
        # Fails closed rather than refusing to boot: an unreachable store is a
        # degraded ecosystem, but a store that 401s everything is at least a store
        # whose /health says so and whose logs name the missing variable.
        logger.warning(
            "No SYNC_STORE_KEYS configured — every authenticated request will be "
            "rejected. Set SYNC_STORE_KEYS, or SYNC_STORE_ALLOW_ANONYMOUS=true for "
            "local development."
        )

    owns_store = store is None

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        app.state.store = store or Store(
            settings.db_path, busy_timeout_ms=settings.busy_timeout_ms
        )
        app.state.settings = settings
        logger.info(
            "sync-store %s ready (db=%s, keys=%d)", settings.version, settings.db_path, len(keys)
        )
        try:
            yield
        finally:
            if owns_store:
                app.state.store.close()

    app = FastAPI(title="sync-store", version=settings.version, lifespan=lifespan)

    # --- error envelope ---

    @app.exception_handler(_Unauthorized)
    async def _on_unauthorized(request: Request, exc: _Unauthorized) -> JSONResponse:
        return _error(
            401,
            "unauthorized",
            exc.reason,
            **{"WWW-Authenticate": f'Bearer realm="{REALM}"'},
        )

    @app.exception_handler(RequestValidationError)
    async def _on_validation_error(request: Request, exc: RequestValidationError) -> JSONResponse:
        # 400, not FastAPI's 422. A malformed descriptor is a bad request in the
        # ecosystem's vocabulary, and agent_mcp's gate already speaks that word.
        detail = "; ".join(
            f"{'.'.join(str(p) for p in err.get('loc', ())[1:])}: {err.get('msg', '')}".strip(": ")
            for err in exc.errors()
        )
        return _error(400, "bad_request", detail or "invalid request body")

    @app.exception_handler(StarletteHTTPException)
    async def _on_http_error(request: Request, exc: StarletteHTTPException) -> JSONResponse:
        codes = {400: "bad_request", 404: "not_found", 413: "payload_too_large"}
        return _error(
            exc.status_code, codes.get(exc.status_code, "error"), str(exc.detail)
        )

    # --- auth ---

    async def authenticate(request: Request) -> AuthResult:
        result = verify_bearer(
            request.headers.get("authorization"),
            keys,
            allow_anonymous=settings.allow_anonymous,
        )
        if not result.ok:
            # Log the reason and the path, never the presented token.
            logger.warning("Rejected %s %s: %s", request.method, request.url.path, result.reason)
            raise _Unauthorized(result.reason)
        return result

    Caller = Depends(authenticate)

    def _store(request: Request) -> Store:
        return request.app.state.store

    def _conversation(request: Request) -> str:
        return request.headers.get(HEADER_CONVERSATION_ID.lower(), "")

    # --- health ---

    @app.get("/health", response_model=HealthResponse)
    async def health(request: Request) -> HealthResponse:
        """Unauthenticated, and public through Caddy — so it leaks no counts.

        Touches the database so an unlinked or corrupt file surfaces as an unhealthy
        container rather than a 200 that lies.
        """
        await asyncio.to_thread(_store(request).ping)
        return HealthResponse(
            status="ok", service=settings.service_name, version=settings.version
        )

    # --- server registry ---

    @app.post("/servers", response_model=RegisterResponse)
    @app.post("/servers/register", response_model=RegisterResponse)
    async def register_server(
        request: Request, descriptor: ServerDescriptor, caller: AuthResult = Caller
    ) -> RegisterResponse:
        """Upsert one server descriptor.

        ``/servers`` is the path the real client uses; ``/servers/register`` is an
        alias for the shape the spec described. It is a second decorator rather than
        a redirect because a 307 on a POST is a well-known way to lose a body.
        """
        extras = getattr(descriptor, "model_extra", None) or {}
        if "token" in extras:
            # A registering app must not be able to grant itself the credential
            # other agents will present to it. Ignored loudly.
            logger.warning(
                "[%s] Ignoring 'token' in a registration body from %s — peer "
                "credentials are set only via PUT /servers/{name}/token",
                descriptor.name,
                caller.caller,
            )

        result = await asyncio.to_thread(
            _store(request).register,
            name=descriptor.name,
            base_url=descriptor.base_url,
            mcp_path=descriptor.mcp_path,
            version=descriptor.version,
            tools=descriptor.tools,
            resources=descriptor.resources,
        )
        conversation = _conversation(request)
        logger.info(
            "[%s] Registered by %s: %d tool(s), %d resource(s)%s",
            descriptor.name,
            caller.caller,
            len(descriptor.tools),
            len(descriptor.resources),
            f" (conversation {conversation})" if conversation else "",
        )
        return RegisterResponse(
            name=descriptor.name, created=result["created"], last_seen=result["last_seen"]
        )

    @app.get("/servers")
    async def list_servers(
        request: Request,
        stale_after_s: int | None = None,
        include_stale: bool = True,
        caller: AuthResult = Caller,
    ) -> dict:
        """Discovery. ``PeerRegistry.refresh`` accepts this envelope or a bare array;
        the envelope leaves room for ``count``/``generated_at`` without a break."""
        threshold = settings.default_stale_after_s if stale_after_s is None else stale_after_s
        records = await asyncio.to_thread(
            _store(request).list_servers, stale_after_s=threshold, include_stale=include_stale
        )
        return {"servers": records, "count": len(records), "generated_at": now_iso()}

    @app.get("/servers/{name}")
    async def get_server(
        request: Request, name: str, stale_after_s: int | None = None, caller: AuthResult = Caller
    ) -> dict:
        threshold = settings.default_stale_after_s if stale_after_s is None else stale_after_s
        record = await asyncio.to_thread(
            _store(request).get_server, name, stale_after_s=threshold
        )
        if record is None:
            raise StarletteHTTPException(404, f"no server registered as {name!r}")
        return record

    @app.put("/servers/{name}/token")
    async def set_server_token(
        request: Request, name: str, update: TokenUpdate, caller: AuthResult = Caller
    ) -> dict:
        """Set the credential other agents present to this server.

        The gap this fills: ``sync_client.register()`` never sends a token, but
        ``PeerRegistry.refresh`` reads one and ``agent_runtime``'s MCP client sends
        it as the outbound ``Authorization``. So this store is the only place where
        "what does Amber show finance-agent" is set once and picked up everywhere.
        Empty by default, which means unauthenticated peer calls — and the far end
        fails closed, which is a loud, correct failure rather than a silent one.

        The response never echoes the token back.
        """
        found = await asyncio.to_thread(_store(request).set_token, name, update.token.strip())
        if not found:
            raise StarletteHTTPException(404, f"no server registered as {name!r}")
        logger.info(
            "[%s] Peer token %s by %s", name, "set" if update.token.strip() else "cleared",
            caller.caller,
        )
        return {"status": "ok", "name": name, "token_set": bool(update.token.strip())}

    @app.delete("/servers/{name}")
    async def delete_server(request: Request, name: str, caller: AuthResult = Caller) -> dict:
        """The only removal path. Nothing here ever expires on its own — see
        ``db.list_servers`` on why staleness flags rather than deletes."""
        found = await asyncio.to_thread(_store(request).delete_server, name)
        if not found:
            raise StarletteHTTPException(404, f"no server registered as {name!r}")
        logger.info("[%s] Deleted by %s", name, caller.caller)
        return {"status": "ok", "deleted": True}

    # --- config sync ---

    @app.post("/config")
    async def put_config(
        request: Request, payload: ConfigWrite, caller: AuthResult = Caller
    ) -> dict:
        """Store one opaque blob. Aperture owns its shape; we never look inside."""
        size = len(json.dumps(payload.blob, separators=(",", ":"), sort_keys=True).encode())
        if size > settings.max_blob_bytes:
            raise StarletteHTTPException(
                413, f"blob is {size} bytes; the limit is {settings.max_blob_bytes}"
            )
        result = await asyncio.to_thread(
            _store(request).put_config,
            device_id=payload.device_id,
            blob=payload.blob,
            keep=settings.config_history,
        )
        logger.info(
            "[config] %s wrote %d bytes for device %s",
            caller.caller,
            result["byte_size"],
            payload.device_id,
        )
        return {"status": "ok", **result}

    @app.get("/config", response_model=ConfigRead)
    async def get_config(
        request: Request, device_id: str | None = None, caller: AuthResult = Caller
    ) -> ConfigRead:
        """The newest blob, optionally scoped to one device.

        An empty store returns nulls with a 200 rather than a 404, so a first-run
        client has no special case to write.
        """
        record = await asyncio.to_thread(_store(request).get_config, device_id=device_id)
        return ConfigRead(**record)

    @app.get("/config/history")
    async def get_config_history(
        request: Request,
        device_id: str | None = None,
        limit: int = 20,
        caller: AuthResult = Caller,
    ) -> dict:
        """Metadata only — no blobs, so this stays cheap however large they get."""
        rows = await asyncio.to_thread(
            _store(request).config_history, device_id=device_id, limit=limit
        )
        return {"history": rows, "count": len(rows)}

    return app


#: What uvicorn imports. Reads the environment; tests use ``build_app`` instead.
app = build_app()

__all__ = ["app", "build_app"]
