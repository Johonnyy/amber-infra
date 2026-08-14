"""The registry over a real socket.

**Not** ``starlette.testclient``: it pulls in ``httpx``, while every client in this
ecosystem imports ``httpx2`` (mcp v2 ships it as a separate distribution with its
own top-level module). Testing one service through two HTTP stacks is a good way to
prove something that is not true on the wire. So these tests drive a live uvicorn on
an ephemeral port with the same client the real callers use, which also means they
exercise the exact path ``test_contract_agent_mcp.py`` does.

The live fixture is duplicated across the API test files on purpose — this suite has
no ``conftest.py``, following the ecosystem convention that a fixture is easier to
read next to the tests that use it than one import away.
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

DESCRIPTOR = {
    "name": "finance",
    "version": "0.1.0",
    "base_url": "https://finance.johnny.dev",
    "mcp_path": "/mcp",
    "tools": [
        {"name": "get_balance", "description": "Balance.", "read_only": True,
         "requires_confirmation": False},
        {"name": "create_invoice", "description": "Invoice.", "read_only": False,
         "requires_confirmation": True},
    ],
    "resources": [{"uri": "finance://summary", "name": "summary", "templated": False}],
}


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="module")
def live():
    """A real server on a real port, torn down at the end of the module."""
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


async def _register(client, **over) -> httpx2.Response:
    body = {**DESCRIPTOR, **over}
    async with client() as http:
        return await http.post("/servers", json=body, headers=AUTH)


# --- registration ---


async def test_registering_a_descriptor_returns_ok_and_makes_it_discoverable(client):
    response = await _register(client, name="discoverable")
    assert response.status_code == 200
    assert response.json()["name"] == "discoverable"

    async with client() as http:
        listing = await http.get("/servers", headers=AUTH)
    names = [s["name"] for s in listing.json()["servers"]]
    assert "discoverable" in names


async def test_the_register_alias_path_accepts_the_same_body(client):
    """The spec described /servers/register; the real client POSTs /servers. Both
    work, as two decorators rather than a redirect — a 307 loses a POST body."""
    async with client() as http:
        response = await http.post(
            "/servers/register", json={**DESCRIPTOR, "name": "aliased"}, headers=AUTH
        )
    assert response.status_code == 200


async def test_a_second_registration_updates_rather_than_duplicating(client):
    await _register(client, name="updated", version="0.1.0")
    response = await _register(client, name="updated", version="0.9.0")

    assert response.json()["created"] is False
    async with client() as http:
        record = await http.get("/servers/updated", headers=AUTH)
    assert record.json()["version"] == "0.9.0"


async def test_tools_are_served_as_bare_strings_and_objects_side_by_side(client):
    await _register(client, name="projected")
    async with client() as http:
        record = (await http.get("/servers/projected", headers=AUTH)).json()

    assert record["tools"] == ["get_balance", "create_invoice"]
    assert record["tool_details"][0]["read_only"] is True


async def test_an_unknown_descriptor_field_does_not_break_registration(client):
    """A new library field must not 422 a fleet halfway through a rollout."""
    response = await _register(client, name="futuristic", capabilities=["something_new"])
    assert response.status_code == 200


async def test_a_token_in_the_registration_body_is_ignored(client):
    """A registering app must not be able to grant itself a peer credential."""
    await _register(client, name="sneaky", token="i-granted-myself-this")
    async with client() as http:
        record = (await http.get("/servers/sneaky", headers=AUTH)).json()
    assert record["token"] == ""


# --- validation ---


async def test_a_descriptor_missing_base_url_is_a_400_with_the_bad_request_shape(client):
    async with client() as http:
        response = await http.post(
            "/servers", json={"name": "broken", "base_url": ""}, headers=AUTH
        )
    assert response.status_code == 400
    assert response.json()["error"] == "bad_request"


async def test_a_name_containing_a_double_underscore_is_rejected(client):
    """'__' is agent_runtime's <server>__<tool> namespace separator."""
    response = await _register(client, name="two__names")
    assert response.status_code == 400


async def test_a_name_longer_than_twenty_two_characters_is_rejected(client):
    response = await _register(client, name="a" * 23)
    assert response.status_code == 400


async def test_a_name_with_uppercase_is_rejected(client):
    assert (await _register(client, name="Finance")).status_code == 400


async def test_an_unknown_server_is_a_404_with_the_not_found_shape(client):
    async with client() as http:
        response = await http.get("/servers/nope", headers=AUTH)
    assert response.status_code == 404
    assert response.json()["error"] == "not_found"


# --- auth ---


async def test_a_request_without_a_token_is_rejected_with_the_ecosystem_error_shape(client):
    async with client() as http:
        response = await http.get("/servers")
    assert response.status_code == 401
    assert response.json()["error"] == "unauthorized"
    assert response.headers["www-authenticate"].startswith("Bearer")


async def test_a_request_with_a_wrong_token_is_rejected(client):
    async with client() as http:
        response = await http.get("/servers", headers={"Authorization": "Bearer wrong"})
    assert response.status_code == 401
    assert response.json()["message"] == "unrecognised bearer token"


async def test_a_bare_token_without_the_bearer_scheme_is_rejected(client):
    async with client() as http:
        response = await http.get("/servers", headers={"Authorization": TOKEN})
    assert response.status_code == 401


async def test_registration_requires_auth(client):
    async with client() as http:
        response = await http.post("/servers", json=DESCRIPTOR)
    assert response.status_code == 401


# --- peer credentials ---


async def test_setting_a_peer_token_makes_it_appear_in_the_listing(client):
    await _register(client, name="credentialed")
    async with client() as http:
        await http.put("/servers/credentialed/token", json={"token": "peer-cred"}, headers=AUTH)
        record = (await http.get("/servers/credentialed", headers=AUTH)).json()
    assert record["token"] == "peer-cred"


async def test_the_token_endpoint_never_echoes_the_token_back(client):
    await _register(client, name="quiet")
    async with client() as http:
        response = await http.put(
            "/servers/quiet/token", json={"token": "peer-cred"}, headers=AUTH
        )
    assert "peer-cred" not in response.text
    assert response.json()["token_set"] is True


async def test_setting_a_token_on_an_unknown_server_is_a_404(client):
    async with client() as http:
        response = await http.put("/servers/nope/token", json={"token": "x"}, headers=AUTH)
    assert response.status_code == 404


# --- removal ---


async def test_deleting_a_server_removes_it(client):
    await _register(client, name="doomed")
    async with client() as http:
        assert (await http.delete("/servers/doomed", headers=AUTH)).status_code == 200
        assert (await http.get("/servers/doomed", headers=AUTH)).status_code == 404


# --- headers ---


async def test_the_conversation_id_header_is_accepted_and_not_required(client):
    async with client() as http:
        response = await http.post(
            "/servers",
            json={**DESCRIPTOR, "name": "traced"},
            headers={**AUTH, "X-Conversation-Id": "abc123"},
        )
    assert response.status_code == 200


async def test_a_depth_header_is_ignored_because_this_is_not_an_mcp_server(client):
    """agent_mcp's gate refuses depth >= 5. Registration sends no depth at all and
    there is no onward hop here, so a depth header is data, not a gate."""
    async with client() as http:
        response = await http.post(
            "/servers",
            json={**DESCRIPTOR, "name": "deep"},
            headers={**AUTH, "X-Agent-Depth": "99"},
        )
    assert response.status_code == 200
