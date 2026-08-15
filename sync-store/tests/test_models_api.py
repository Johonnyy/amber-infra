"""The shared model keyword table over a real socket.

What every test here is really asserting: this table is a **patch layer**, not a
picture of any one app's configuration. An app pushes what it changed, reads what
everyone else changed, and falls back to its own built-in defaults for the rest.
Replacement semantics anywhere in here would let one app's view quietly delete
keywords it had never heard of.

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
    """The store is module-scoped; a test's keywords must not become another's."""
    yield
    async with client() as http:
        existing = (await http.get("/models", headers=AUTH)).json()["keywords"]
        for keyword in existing:
            await http.delete(f"/models/{keyword}", headers=AUTH)


async def test_an_empty_table_is_a_200_not_a_404(client):
    """Absent means "nobody re-pointed anything", which is the normal first-run state
    and needs no special case at the reading app."""
    async with client() as http:
        response = await http.get("/models", headers=AUTH)
    assert response.status_code == 200
    assert response.json() == {
        "keywords": {},
        "count": 0,
        "generated_at": response.json()["generated_at"],
    }


async def test_a_keyword_round_trips_with_its_description(client):
    """The description travels because a keyword invented on one device is a bare
    word everywhere else without it."""
    async with client() as http:
        await http.put(
            "/models/sql",
            json={"model": "vendor/db-tuned", "description": "Schema and query work."},
            headers=AUTH,
        )
        table = (await http.get("/models", headers=AUTH)).json()

    assert table["keywords"]["sql"]["model"] == "vendor/db-tuned"
    assert table["keywords"]["sql"]["description"] == "Schema and query work."
    assert table["keywords"]["sql"]["updated_by"] == "amber"
    assert table["count"] == 1


async def test_re_pointing_keeps_the_description(client):
    """The common write is one app changing a model on a keyword another app named.
    Blanking the explanation each time would empty the table of meaning in a week."""
    async with client() as http:
        await http.put(
            "/models/coding",
            json={"model": "vendor/coder-1", "description": "Writing and fixing code."},
            headers=AUTH,
        )
        await http.put("/models/coding", json={"model": "vendor/coder-2"}, headers=AUTH)
        table = (await http.get("/models", headers=AUTH)).json()

    assert table["keywords"]["coding"]["model"] == "vendor/coder-2"
    assert table["keywords"]["coding"]["description"] == "Writing and fixing code."


async def test_a_map_patch_sets_and_removes(client):
    async with client() as http:
        await http.put("/models/writing", json={"model": "vendor/prose-1"}, headers=AUTH)
        response = await http.put(
            "/models",
            json={"keywords": {"coding": "vendor/coder-9", "writing": None}},
            headers=AUTH,
        )
        table = (await http.get("/models", headers=AUTH)).json()

    assert response.json()["set"] == ["coding"]
    assert response.json()["removed"] == ["writing"]
    assert set(table["keywords"]) == {"coding"}


async def test_a_map_patch_leaves_unmentioned_keywords_alone(client):
    """The whole reason this is a patch: an app must not delete what it never knew."""
    async with client() as http:
        await http.put("/models/vision", json={"model": "vendor/eyes-1"}, headers=AUTH)
        await http.put("/models", json={"keywords": {"fast": "vendor/quick"}}, headers=AUTH)
        table = (await http.get("/models", headers=AUTH)).json()

    assert set(table["keywords"]) == {"vision", "fast"}


async def test_a_map_patch_is_all_or_nothing(client):
    """A typo in the fourth entry must not leave the shared table half-applied."""
    async with client() as http:
        response = await http.put(
            "/models",
            json={"keywords": {"coding": "vendor/coder-9", "writing": "not-a-model-id"}},
            headers=AUTH,
        )
        table = (await http.get("/models", headers=AUTH)).json()

    assert response.status_code == 400
    assert response.json()["error"] == "bad_request"
    assert table["keywords"] == {}


@pytest.mark.parametrize("model", ["balanced", "no-slash", "vendor/with space", ""])
async def test_a_bare_keyword_in_the_model_field_is_a_400(client, model):
    """Caught here rather than as a 400 from OpenRouter, mid-turn, in every app."""
    async with client() as http:
        response = await http.put("/models/coding", json={"model": model}, headers=AUTH)
    assert response.status_code == 400


@pytest.mark.parametrize("keyword", ["With Caps", "9lives", "x" * 33])
async def test_a_malformed_keyword_is_a_400(client, keyword):
    async with client() as http:
        response = await http.put(
            f"/models/{keyword}", json={"model": "vendor/model"}, headers=AUTH
        )
    assert response.status_code == 400


async def test_a_keyword_containing_a_slash_cannot_be_created(client):
    """A slash is the one character that would make a keyword and a model id
    indistinguishable. In the path it cannot even reach the handler — the router
    answers first — so the map endpoint is where the rule has to be enforced."""
    async with client() as http:
        path = await http.put(
            "/models/has/slash", json={"model": "vendor/model"}, headers=AUTH
        )
        patch = await http.put(
            "/models", json={"keywords": {"has/slash": "vendor/model"}}, headers=AUTH
        )
    assert path.status_code == 404  # no such route, which is its own kind of refusal
    assert patch.status_code == 400


async def test_a_keyword_is_normalised_rather_than_rejected(client):
    """Case is a client's formatting, not a different keyword."""
    async with client() as http:
        await http.put("/models/CODING", json={"model": "vendor/coder-9"}, headers=AUTH)
        table = (await http.get("/models", headers=AUTH)).json()
    assert set(table["keywords"]) == {"coding"}


async def test_deleting_an_unknown_keyword_is_a_404(client):
    async with client() as http:
        response = await http.delete("/models/never-set", headers=AUTH)
    assert response.status_code == 404
    assert response.json()["error"] == "not_found"


async def test_the_table_needs_a_token(client):
    async with client() as http:
        read = await http.get("/models")
        write = await http.put("/models/coding", json={"model": "vendor/x"})
    assert read.status_code == 401
    assert write.status_code == 401
    assert "WWW-Authenticate" in read.headers
