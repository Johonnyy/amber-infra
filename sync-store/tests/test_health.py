"""``/health`` — the one unauthenticated route, and therefore the careful one.

It is public through Caddy, so it must say enough for a healthcheck to be meaningful
and nothing an unauthenticated stranger shouldn't know.

Live fixture duplicated deliberately — see the note in ``test_servers_api.py``.
"""

from __future__ import annotations

import socket
import threading
import time

import httpx2
import pytest
import uvicorn

from app.config import Settings
from app.db import Store
from app.main import build_app

TOKEN = "s3cret"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="module")
def live():
    settings = Settings(_env_file=None, keys=f"amber:{TOKEN}", version="9.9.9")
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

    yield f"http://127.0.0.1:{port}"

    server.should_exit = True
    thread.join(timeout=10)


async def test_health_needs_no_token(live):
    async with httpx2.AsyncClient(base_url=live, timeout=5.0) as http:
        response = await http.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


async def test_health_reports_the_service_name_and_version(live):
    async with httpx2.AsyncClient(base_url=live, timeout=5.0) as http:
        body = (await http.get("/health")).json()
    assert body["service"] == "sync-store"
    assert body["version"] == "9.9.9"


async def test_health_leaks_no_server_count(live):
    """Public URL. It proves liveness, not inventory."""
    async with httpx2.AsyncClient(base_url=live, timeout=5.0) as http:
        await http.post(
            "/servers",
            json={"name": "secret_app", "base_url": "https://x.test"},
            headers=AUTH,
        )
        body = (await http.get("/health")).json()

    assert set(body) == {"status", "service", "version"}
    assert "secret_app" not in str(body)
