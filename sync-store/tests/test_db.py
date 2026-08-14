"""Storage behaviour, exercised directly against an in-memory database.

No server, no HTTP. The invariants here — upsert not append, never clobber an
admin-set token, project tools down to strings — are the ones that break the whole
ecosystem quietly if they regress, so they get tested at the layer where a failure
names the cause.
"""

from __future__ import annotations

import re

from app.db import Store

TOOLS = [
    {"name": "get_balance", "description": "Balance.", "read_only": True,
     "requires_confirmation": False},
    {"name": "create_invoice", "description": "Invoice.", "read_only": False,
     "requires_confirmation": True},
]
RESOURCES = [{"uri": "finance://summary", "name": "summary", "templated": False}]


def _store() -> Store:
    return Store(":memory:")


def _register(store: Store, **over) -> dict:
    kwargs = {
        "name": "finance",
        "base_url": "https://finance.johnny.dev",
        "version": "0.1.0",
        "tools": TOOLS,
        "resources": RESOURCES,
    }
    kwargs.update(over)
    return store.register(**kwargs)


def test_the_schema_is_created_on_first_connect():
    store = _store()
    assert store.ping() is True
    assert store.list_servers() == []


def test_registering_a_new_server_stores_the_full_tool_objects():
    store = _store()
    result = _register(store)
    assert result["created"] is True

    record = store.get_server("finance")
    assert record["base_url"] == "https://finance.johnny.dev"
    assert record["mcp_path"] == "/mcp"
    assert record["tool_details"] == TOOLS
    assert record["resources"] == RESOURCES


def test_re_registering_the_same_name_updates_in_place_rather_than_appending():
    """The heartbeat re-POSTs an identical descriptor every 300 seconds, forever."""
    store = _store()
    _register(store)
    result = _register(store, version="0.2.0")

    assert result["created"] is False
    assert len(store.list_servers()) == 1
    assert store.get_server("finance")["version"] == "0.2.0"


def test_re_registering_bumps_the_register_count():
    store = _store()
    _register(store)
    _register(store)
    _register(store)
    assert store.get_server("finance")["register_count"] == 3


def test_re_registering_preserves_first_seen_and_moves_last_seen():
    store = _store()
    _register(store, now="2026-01-01T00:00:00+00:00")
    _register(store, now="2026-06-01T00:00:00+00:00")

    record = store.get_server("finance")
    assert record["first_seen"] == "2026-01-01T00:00:00+00:00"
    assert record["last_seen"] == "2026-06-01T00:00:00+00:00"


def test_re_registering_does_not_clear_an_admin_set_token():
    """The single most damaging regression available: the 300-second heartbeat
    silently wiping every peer credential in the ecosystem."""
    store = _store()
    _register(store)
    assert store.set_token("finance", "peer-cred") is True

    _register(store, version="0.3.0")

    assert store.get_server("finance")["token"] == "peer-cred"


def test_listing_projects_tools_down_to_bare_name_strings():
    """PeerRecord.tools is typed tuple[str, ...] and built with a bare tuple()."""
    store = _store()
    _register(store)
    record = store.list_servers()[0]
    assert record["tools"] == ["get_balance", "create_invoice"]
    assert all(isinstance(t, str) for t in record["tools"])


def test_listing_also_exposes_the_full_tool_objects_as_tool_details():
    store = _store()
    _register(store)
    assert store.list_servers()[0]["tool_details"] == TOOLS


def test_a_malformed_tool_entry_becomes_an_empty_name_rather_than_an_error():
    """One hand-curl'd registration must not break discovery for every other peer."""
    store = _store()
    _register(store, tools=["not-an-object", {"name": "ok"}])
    assert store.list_servers()[0]["tools"] == ["", "ok"]


def test_a_server_is_marked_stale_only_when_a_threshold_is_given():
    store = _store()
    _register(store, now="2020-01-01T00:00:00+00:00")

    assert store.list_servers(stale_after_s=60)[0]["stale"] is True
    assert store.list_servers(stale_after_s=0)[0]["stale"] is False


def test_stale_servers_are_listed_by_default_and_filtered_only_on_request():
    """Fail open: refresh() replaces its whole discovered layer, so hiding a
    live-but-slow server removes it from every agent at once."""
    store = _store()
    _register(store, now="2020-01-01T00:00:00+00:00")

    assert len(store.list_servers(stale_after_s=60)) == 1
    assert store.list_servers(stale_after_s=60, include_stale=False) == []


def test_setting_a_token_leaves_every_other_column_untouched():
    store = _store()
    _register(store)
    before = store.get_server("finance")
    store.set_token("finance", "peer-cred")
    after = store.get_server("finance")

    assert after["token"] == "peer-cred"
    assert {k: v for k, v in after.items() if k != "token"} == {
        k: v for k, v in before.items() if k != "token"
    }


def test_setting_a_token_on_an_unknown_server_reports_failure():
    assert _store().set_token("nope", "x") is False


def test_clearing_a_token_stores_an_empty_string():
    store = _store()
    _register(store)
    store.set_token("finance", "peer-cred")
    store.set_token("finance", "")
    assert store.get_server("finance")["token"] == ""


def test_deleting_a_server_removes_it_from_the_listing():
    store = _store()
    _register(store)
    assert store.delete_server("finance") is True
    assert store.list_servers() == []
    assert store.delete_server("finance") is False


def test_writing_a_config_blob_returns_a_monotonically_increasing_id():
    store = _store()
    first = store.put_config(device_id="macbook", blob={"a": 1})
    second = store.put_config(device_id="macbook", blob={"a": 2})
    assert second["id"] > first["id"]


def test_a_config_blob_round_trips_unchanged():
    """The store never interprets the blob — nesting, unicode and nulls survive."""
    store = _store()
    blob = {"nested": {"deep": [1, 2, {"x": None}]}, "unicode": "ambré ✨", "z": True}
    store.put_config(device_id="macbook", blob=blob)
    assert store.get_config()["blob"] == blob


def test_reading_config_without_a_device_id_returns_the_newest_across_devices():
    store = _store()
    store.put_config(device_id="macbook", blob={"from": "macbook"})
    store.put_config(device_id="phone", blob={"from": "phone"})
    assert store.get_config()["blob"] == {"from": "phone"}


def test_reading_config_with_a_device_id_returns_that_devices_newest():
    store = _store()
    store.put_config(device_id="macbook", blob={"n": 1})
    store.put_config(device_id="phone", blob={"n": 2})
    store.put_config(device_id="macbook", blob={"n": 3})
    assert store.get_config(device_id="macbook")["blob"] == {"n": 3}


def test_an_empty_store_returns_a_null_blob_rather_than_raising():
    assert _store().get_config() == {
        "id": None, "device_id": None, "blob": None, "created_at": None
    }


def test_config_history_is_pruned_to_the_configured_depth():
    store = _store()
    for n in range(10):
        store.put_config(device_id="macbook", blob={"n": n}, keep=3)
    history = store.config_history(device_id="macbook", limit=100)
    assert len(history) == 3
    assert store.get_config()["blob"] == {"n": 9}


def test_config_history_carries_metadata_but_no_blobs():
    store = _store()
    store.put_config(device_id="macbook", blob={"a": 1})
    row = store.config_history()[0]
    assert set(row) == {"id", "device_id", "byte_size", "created_at"}


def test_timestamps_are_iso_8601_utc_seconds():
    """Same format agent_mcp.usage_log writes, so the two join by eye."""
    store = _store()
    _register(store)
    assert re.fullmatch(
        r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+00:00", store.get_server("finance")["last_seen"]
    )
