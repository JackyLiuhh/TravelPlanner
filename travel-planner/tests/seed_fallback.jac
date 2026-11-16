"""Seed an isolated pending fallback draft with the AI explicitly unavailable.
Run: jac run tests/seed_fallback.jac. No live model calls are made.
The temporary DB and trip ID are written to /tmp/roam-fallback-smoke-state.json.
"""
import os;
import json;
import tempfile;
import from pathlib { Path }
import from uuid { uuid4 }
import from unittest.mock { patch }
import server.main as api;
import assistant.provider as provider;

with entry {
    directory = tempfile.mkdtemp(prefix="roam-fallback-browser-");
    os.environ["TRAVEL_DB_PATH"] = directory + "/trip.db";
    id = api.save_trip("Fallback browser regression", "New York", "2027-01-01", "2027-01-03", "USD", "5000",
        departure_location="Detroit", return_location="Detroit").id;
    with patch.object(provider, "generate", side_effect=ValueError("Could not reach OpenAI or read its response. Please retry.")),
        patch.object(provider, "request", side_effect=RuntimeError("Network disabled in synthetic test")) {
        state = api.assistant_chat(id, "Prepare a complete trip", "plan", False, str(uuid4()), automatic=True, draft_only=True);
    }
    assert len(state["drafts"]) == 1 and state["drafts"][0]["can_apply"];
    assert api.list_items(id) == [];
    Path("/tmp/roam-fallback-smoke-state.json").write_text(json.dumps({"trip_id": id, "db": os.environ["TRAVEL_DB_PATH"]}));
    print(json.dumps({"trip_id": id, "pending_changes": len(state["drafts"][0]["changes"])}));
}
