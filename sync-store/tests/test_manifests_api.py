"""Shared provider manifests over a real socket.

What this table is for: a Bloom install teaches itself to reach a new service by
writing a provider manifest, and without somewhere to share it, the next install
repeats the same research and the same model spend to produce the same TOML.

What this store is *not*: a validator. The manifest format's rules live in Bloom,
are versioned with Bloom, and a store enforcing its own stale copy would reject
manifests a newer Bloom considers fine. So the document is opaque here — exactly
like a config blob — and the tests below assert that it is stored and returned
byte-for-byte rather than interpreted. The corollary is that anything read from
here is untrusted input, and every reader must validate; that half is asserted in
Bloom's own `tests/test_manifests_api.py`.

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

MANIFEST = """\
name = "analytics"
display_name = "Example Analytics"
api_base = "https://api.example.com/v1"
auth = "api_key"
"""


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="module")
def live():
    settings = Settings(_env_file=None, keys=f"amber:{TOKEN}", allow_anonymous=False)
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


@pytest.fixture(autouse=True)
async def clean(client):
    """The store is module-scoped; one test's manifests must not become another's."""
    yield
    async with client() as http:
        existing = (await http.get("/manifests", headers=AUTH)).json()["manifests"]
        for name in existing:
            await http.delete(f"/manifests/{name}", headers=AUTH)


async def test_a_manifest_round_trips_byte_for_byte(client):
    """Opaque means opaque: not reformatted, not re-serialised, not parsed."""
    async with client() as http:
        assert (
            await http.put("/manifests/analytics", headers=AUTH, json={"toml": MANIFEST})
        ).status_code == 200
        got = (await http.get("/manifests/analytics", headers=AUTH)).json()
    assert got["toml"] == MANIFEST
    assert got["name"] == "analytics"


async def test_the_store_does_not_validate_the_document(client):
    """Deliberate. The rules live in Bloom and are versioned with Bloom.

    A store that enforced its own copy would reject a manifest a newer Bloom
    considers valid, and the failure would look like a network problem. Readers
    validate — and they must, since everything here was written by somebody's model.
    """
    async with client() as http:
        stored = await http.put(
            "/manifests/analytics", headers=AUTH, json={"toml": "this is not toml {{{"}
        )
    assert stored.status_code == 200


async def test_the_name_is_validated_because_it_is_the_primary_key(client):
    """The one thing this store does check. Everything else about a manifest is Bloom's."""
    async with client() as http:
        for bad in ("Has Spaces", "1leading", "way_too_long_a_provider_name_here", "has-hyphen"):
            refused = await http.put(f"/manifests/{bad}", headers=AUTH, json={"toml": MANIFEST})
            assert refused.status_code == 400, bad


async def test_a_name_is_normalised_rather_than_refused_for_its_case(client):
    """Same rule as a keyword: case is not identity, so it is folded, not rejected."""
    async with client() as http:
        assert (
            await http.put("/manifests/ANALYTICS", headers=AUTH, json={"toml": MANIFEST})
        ).status_code == 200
        listed = (await http.get("/manifests", headers=AUTH)).json()
    assert list(listed["manifests"]) == ["analytics"]


async def test_publishing_the_same_name_replaces_rather_than_duplicating(client):
    async with client() as http:
        await http.put("/manifests/analytics", headers=AUTH, json={"toml": MANIFEST})
        second = await http.put(
            "/manifests/analytics", headers=AUTH, json={"toml": MANIFEST + "\ndocs_url = 'x'\n"}
        )
        assert second.json()["created"] is False
        listed = (await http.get("/manifests", headers=AUTH)).json()
    assert listed["count"] == 1
    assert "docs_url" in listed["manifests"]["analytics"]["toml"]


async def test_verified_is_sticky_upward(client):
    """It says "this has worked somewhere".

    Re-uploading the same document from a box that has not proved anything is not
    evidence that it stopped working, so a later unverified publish must not clear
    the flag.
    """
    async with client() as http:
        await http.put(
            "/manifests/analytics", headers=AUTH, json={"toml": MANIFEST, "verified": True}
        )
        await http.put(
            "/manifests/analytics", headers=AUTH, json={"toml": MANIFEST, "verified": False}
        )
        got = (await http.get("/manifests/analytics", headers=AUTH)).json()
    assert got["verified"] is True


async def test_the_index_can_omit_the_documents(client):
    """A client deciding *whether* to pull does not need the bulk of every row yet."""
    async with client() as http:
        await http.put("/manifests/analytics", headers=AUTH, json={"toml": MANIFEST})
        light = (await http.get("/manifests", headers=AUTH, params={"full": "false"})).json()
        full = (await http.get("/manifests", headers=AUTH)).json()
    assert light["manifests"]["analytics"]["toml"] is None
    assert light["manifests"]["analytics"]["updated_at"]
    assert full["manifests"]["analytics"]["toml"] == MANIFEST


async def test_an_empty_store_answers_200_with_an_empty_map(client):
    """A first-run install has no special case to write."""
    async with client() as http:
        body = (await http.get("/manifests", headers=AUTH)).json()
    assert body == {"manifests": {}, "count": 0, "generated_at": body["generated_at"]}


async def test_deleting_something_that_is_not_there_is_a_404(client):
    async with client() as http:
        assert (await http.delete("/manifests/ghost", headers=AUTH)).status_code == 404


async def test_the_manifest_table_requires_a_key(client):
    async with client() as http:
        assert (await http.get("/manifests")).status_code == 401
        assert (
            await http.put("/manifests/analytics", json={"toml": MANIFEST})
        ).status_code == 401
