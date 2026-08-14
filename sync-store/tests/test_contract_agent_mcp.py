"""The contract, exercised with agent-mcp-py's own client rather than a fake.

Every other test in this suite asserts what *we* think the wire looks like. This one
asserts what the caller actually sends and actually parses, by importing
``agent_mcp.sync_client`` and ``agent_mcp.registry`` and pointing them at a live
store. That is the entire reason ``agent-mcp-py`` is a dev-only dependency — see
``app/auth.py`` on why it is deliberately not a runtime one.

Note ``httpx2``, not ``httpx``: mcp v2 ships httpx2 as a separate distribution and
the client imports it directly. It arrives transitively with the agent-mcp-py pin.

Live fixture duplicated deliberately — see the note in ``test_servers_api.py``.
"""

from __future__ import annotations

import socket
import threading
import time

import pytest
import uvicorn
from agent_mcp import sync_client
from agent_mcp.decorators import ResourcePolicy, ToolPolicy
from agent_mcp.registry import PeerRegistry, PeerRecord, mcp_url

from app.config import Settings
from app.db import Store
from app.main import build_app

TOKEN = "s3cret"
BASE_URL = "https://finance.johnny.dev"

TOOLS = (
    ToolPolicy(name="get_balance", read_only=True),
    ToolPolicy(name="create_invoice", read_only=False, requires_confirmation=True),
)
RESOURCES = (ResourcePolicy(uri="finance://summary", name="summary", templated=False),)


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _serve(settings: Settings):
    """Start a live store; returns (base_url, shutdown)."""
    app = build_app(settings, store=Store(":memory:"))
    port = _free_port()
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="error"))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    for _ in range(200):
        if server.started:
            break
        time.sleep(0.05)
    assert server.started, "uvicorn did not start"

    def shutdown() -> None:
        server.should_exit = True
        thread.join(timeout=10)

    return f"http://127.0.0.1:{port}", shutdown


@pytest.fixture
def live():
    """Function-scoped: several cases need a store with a known, isolated history."""
    url, shutdown = _serve(Settings(_env_file=None, keys=f"amber:{TOKEN}"))
    yield url
    shutdown()


def _descriptor(**over) -> dict:
    """Built by the real builder, so the payload is theirs and not ours."""
    kwargs = {
        "app_name": "finance",
        "version": "0.1.0",
        "base_url": BASE_URL,
        "tools": TOOLS,
        "resources": RESOURCES,
        "descriptions": {"get_balance": "Balance for an account."},
    }
    kwargs.update(over)
    return sync_client.build_descriptor(**kwargs)


async def _register(live, **over) -> bool:
    return await sync_client.register(
        sync_store_url=live, descriptor=_descriptor(**over), token=TOKEN
    )


async def test_the_real_register_call_creates_a_discoverable_server(live):
    assert await _register(live) is True

    registry = PeerRegistry()
    assert await registry.refresh(live, token=TOKEN) == 1
    assert registry.known() == ["finance"]


async def test_the_real_peer_registry_parses_what_the_store_serves(live):
    """The projection this store exists to get right.

    ``build_descriptor`` writes tools as objects; ``PeerRecord.tools`` is typed
    ``tuple[str, ...]`` and built with a bare ``tuple(raw.get("tools") or ())``. Echo
    the objects back and every agent downstream holds dicts where it expects strings.
    """
    await _register(live)

    registry = PeerRegistry()
    await registry.refresh(live, token=TOKEN)
    record = registry.resolve("finance")

    assert record is not None
    assert record.base_url == BASE_URL
    assert record.version == "0.1.0"
    assert record.tools == ("get_balance", "create_invoice")
    assert all(isinstance(tool, str) for tool in record.tools)


async def test_the_resolved_mcp_url_is_the_canonical_trailing_slash_form(live):
    """Proves base_url is stored without the /mcp suffix the client appends."""
    await _register(live)
    registry = PeerRegistry()
    await registry.refresh(live, token=TOKEN)

    assert mcp_url(registry.resolve("finance")) == f"{BASE_URL}/mcp/"


async def test_an_admin_set_token_reaches_the_peer_record(live):
    """Closes the loop nothing else does: the store writes the credential, the
    registry reads it, and agent_runtime presents it as the outbound Authorization."""
    import httpx2

    await _register(live)
    async with httpx2.AsyncClient(base_url=live, timeout=5.0) as http:
        response = await http.put(
            "/servers/finance/token",
            json={"token": "peer-cred"},
            headers={"Authorization": f"Bearer {TOKEN}"},
        )
        response.raise_for_status()

    registry = PeerRegistry()
    await registry.refresh(live, token=TOKEN)
    assert registry.resolve("finance").token == "peer-cred"


async def test_a_second_registration_updates_rather_than_duplicating(live):
    await _register(live, version="0.1.0")
    await _register(live, version="0.2.0")

    registry = PeerRegistry()
    assert await registry.refresh(live, token=TOKEN) == 1
    assert registry.resolve("finance").version == "0.2.0"


async def test_a_heartbeat_re_registration_does_not_clear_the_admin_token(live):
    """The highest-value assertion in the repo.

    ``register()`` re-POSTs the same descriptor every heartbeat interval, forever. If
    the upsert touched the token column, every peer credential in the ecosystem would
    be wiped within five minutes of being set, silently, with the failure surfacing
    much later as an unauthorized peer call.
    """
    import httpx2

    await _register(live)
    async with httpx2.AsyncClient(base_url=live, timeout=5.0) as http:
        await http.put(
            "/servers/finance/token",
            json={"token": "peer-cred"},
            headers={"Authorization": f"Bearer {TOKEN}"},
        )

    await _register(live)  # the heartbeat

    registry = PeerRegistry()
    await registry.refresh(live, token=TOKEN)
    assert registry.resolve("finance").token == "peer-cred"


async def test_registering_with_a_wrong_token_fails_softly_and_does_not_raise(live):
    """register() swallows everything by contract — a rejected app keeps serving,
    it is just not discoverable."""
    assert (
        await sync_client.register(
            sync_store_url=live, descriptor=_descriptor(), token="wrong"
        )
        is False
    )


async def test_a_registry_refresh_against_a_dead_store_returns_zero_and_keeps_static_peers():
    """Discovery is a convenience; an unreachable store must not break serving."""
    dead = f"http://127.0.0.1:{_free_port()}"
    registry = PeerRegistry(
        static={"finance": PeerRecord(name="finance", base_url=BASE_URL)}
    )

    assert await registry.refresh(dead, token=TOKEN, timeout_s=1.0) == 0
    assert registry.resolve("finance").base_url == BASE_URL


async def test_the_real_client_omits_the_authorization_header_when_the_token_is_empty():
    """sync_client sends no Authorization at all with an empty token, so the store
    has to have a coherent answer for the no-header case."""
    url, shutdown = _serve(Settings(_env_file=None, keys="", allow_anonymous=True))
    try:
        assert (
            await sync_client.register(sync_store_url=url, descriptor=_descriptor(), token="")
            is True
        )
        registry = PeerRegistry()
        assert await registry.refresh(url) == 1
    finally:
        shutdown()


async def test_registration_is_refused_without_a_public_url_before_any_http_happens():
    """register() checks base_url itself and never reaches the network — worth
    pinning, because it is the most common 'why isn't my app discoverable' cause."""
    descriptor = _descriptor(base_url="")
    assert await sync_client.register(
        sync_store_url="http://127.0.0.1:1", descriptor=descriptor, token=TOKEN
    ) is False
