"""Lucidity's config sync over a real socket.

The one thing every test here is really asserting: the store does not interpret the
blob. It stores bytes and hands them back.

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
    settings = Settings(
        _env_file=None,
        keys=f"lucidity:{TOKEN}",
        allow_anonymous=False,
        max_blob_bytes=2048,
        config_history=3,
    )
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


@pytest.fixture
def client(live):
    return lambda: httpx2.AsyncClient(base_url=live, timeout=5.0)


async def test_an_empty_store_returns_a_null_blob_rather_than_404(client):
    """A first-run Lucidity should not need a special case."""
    async with client() as http:
        response = await http.get("/config", params={"device_id": "never-written"}, headers=AUTH)
    assert response.status_code == 200
    assert response.json()["blob"] is None


async def test_a_blob_round_trips_unchanged(client):
    blob = {"nested": {"deep": [1, 2, {"x": None}]}, "unicode": "ambré ✨", "flag": True}
    async with client() as http:
        write = await http.post("/config", json={"device_id": "macbook", "blob": blob}, headers=AUTH)
        read = await http.get("/config", params={"device_id": "macbook"}, headers=AUTH)

    assert write.status_code == 200
    assert read.json()["blob"] == blob


async def test_the_newest_blob_wins_across_devices(client):
    async with client() as http:
        await http.post("/config", json={"device_id": "a", "blob": {"n": 1}}, headers=AUTH)
        await http.post("/config", json={"device_id": "b", "blob": {"n": 2}}, headers=AUTH)
        latest = await http.get("/config", headers=AUTH)
    assert latest.json()["blob"] == {"n": 2}


async def test_a_device_scoped_read_ignores_other_devices(client):
    async with client() as http:
        await http.post("/config", json={"device_id": "phone", "blob": {"m": 1}}, headers=AUTH)
        await http.post("/config", json={"device_id": "other", "blob": {"m": 2}}, headers=AUTH)
        scoped = await http.get("/config", params={"device_id": "phone"}, headers=AUTH)
    assert scoped.json()["blob"] == {"m": 1}


async def test_an_oversized_blob_is_a_413(client):
    async with client() as http:
        response = await http.post(
            "/config", json={"device_id": "fat", "blob": {"pad": "x" * 4096}}, headers=AUTH
        )
    assert response.status_code == 413
    assert response.json()["error"] == "payload_too_large"


async def test_a_non_object_blob_is_a_400(client):
    async with client() as http:
        response = await http.post(
            "/config", json={"device_id": "wrong", "blob": [1, 2, 3]}, headers=AUTH
        )
    assert response.status_code == 400


async def test_a_missing_device_id_is_a_400(client):
    async with client() as http:
        response = await http.post("/config", json={"blob": {}}, headers=AUTH)
    assert response.status_code == 400


async def test_history_is_pruned_and_carries_no_blobs(client):
    async with client() as http:
        for n in range(6):
            await http.post(
                "/config", json={"device_id": "pruned", "blob": {"n": n}}, headers=AUTH
            )
        history = await http.get("/config/history", params={"device_id": "pruned"}, headers=AUTH)

    rows = history.json()["history"]
    assert len(rows) == 3  # config_history=3 in the fixture
    assert "blob" not in rows[0]


async def test_config_endpoints_require_auth(client):
    async with client() as http:
        assert (await http.get("/config")).status_code == 401
        assert (await http.post("/config", json={"device_id": "x", "blob": {}})).status_code == 401
