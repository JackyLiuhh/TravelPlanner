"""Prototype draft regressions with synthetic routes and no model network calls."""
import os;
import json;
import tempfile;
import unittest;
import from unittest.mock { patch }
import from uuid { uuid4 }
import server.main as api;
import assistant.provider as provider;
import from assistant.workflow { check_plan }
import from journey.fixtures { plan }

def create(budget: str = "8000") -> str {
    return api.save_trip("Japan", "Tokyo", "2027-01-01", "2027-01-07", "USD", budget, "", "", "Detroit", "Detroit").id;
}

def draft(trip_id: str, proposal: dict[str, any], mode: str = "plan") -> dict[str, any] {
    response = {"answer": "Review this estimated itinerary.", "sources": [], "plans": [proposal]};
    with patch.object(provider, "generate", return_value=response), patch.object(provider, "repair") as repair {
        state = api.assistant_chat(trip_id, "Prepare my trip", mode, False, str(uuid4()), automatic=True, draft_only=True);
        assert repair.call_count == 0;
        assert len(state["drafts"]) == 1;
        return state["drafts"][0];
    }
}

test "draft mode accepts airport aliases while preserving saved endpoint cities" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); proposal = plan();
        proposal["journey"]["origin"]["city"] = "Detroit Wayne County (DTW)";
        proposal["journey"]["return_to"]["city"] = "DTW";
        result = draft(id, proposal);
        assert result["relaxed"] and result["can_apply"];
        assert result["journey"]["origin"]["city"] == "Detroit";
        assert result["journey"]["return_to"]["city"] == "Detroit";
        assert api.list_items(id) == [];
        api.assistant_review(id, result["id"], True, True);
        assert len(api.list_items(id)) == 8;
        assert api.list_trips()[0].departure_location == "Detroit" and api.list_trips()[0].return_location == "Detroit";
    }
}

test "draft mode completes missing return flight with a clearly labeled estimate" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); proposal = plan(); proposal["changes"].pop();
        result = draft(id, proposal);
        returning = next(row["after"] for row in result["changes"] if row["after"]["journey"].get("leg_id") == "osaka:return");
        assert result["can_apply"] and len(result["changes"]) == 8;
        assert returning["title"] == "Estimated return flight" and returning["flight"] == {};
        assert "not a searched flight or booking" in returning["notes"];
        assert returning["journey"]["arrival_date"] == "2027-01-07";
        assert returning["duration_minutes"] > 0 and returning["cost_cents"] > 0;
        api.assistant_review(id, result["id"], True, True);
        assert len(api.list_items(id)) == 8;
        assert any(item.title == "Estimated return flight" for item in api.list_items(id));
    }
}

test "draft mode fills both flight gaps without moving return to the departure day or dropping activities" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); proposal = plan();
        proposal["changes"] = [row for row in proposal["changes"] if row["leg_id"] not in ["origin:tokyo", "osaka:return"]];
        result = draft(id, proposal);
        outbound = next(row["after"] for row in result["changes"] if row["after"]["journey"].get("leg_id") == "origin:tokyo");
        returning = next(row["after"] for row in result["changes"] if row["after"]["journey"].get("leg_id") == "osaka:return");
        assert outbound["date"] == "2027-01-01" and returning["date"] == "2027-01-07";
        assert returning["journey"]["arrival_date"] == "2027-01-07";
        assert outbound["flight"] == {} and returning["flight"] == {};
        assert len([row for row in result["changes"] if row["after"]["category"] in ["activity", "food"]]) == 3;
        api.assistant_review(id, result["id"], True, True);
        assert len(api.list_items(id)) == 8;
    }
}

test "draft mode derives a usable arrival when the model reverses flight instants" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); proposal = plan(); proposal["changes"][-1]["arrival_date"] = "2027-01-01";
        result = draft(id, proposal);
        returning = next(row["after"] for row in result["changes"] if row["after"]["title"] == "Return");
        assert returning["journey"]["arrival_date"] == "2027-01-07";
        assert returning["journey"]["arrival_time"] == "14:00";
        assert returning["duration_minutes"] == 720;
        assert result["timing_adjustments"];
        api.assistant_review(id, result["id"], True, True);
        assert len(api.list_items(id)) == 8;
    }
}

test "draft mode returns an unknown-price draft without spending another model request" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); proposal = plan(); proposal["changes"][0]["cost_cents"] = None;
        result = draft(id, proposal);
        assert result["total_cents"] is None;
        assert any(row["price_unknown"] for row in result["changes"]);
        assert api.list_items(id) == [];
    }
}

test "draft mode keeps required travel above budget as a reviewable estimate in every planning mode" {
    for mode in ["plan", "backup", "replan"] {
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
            id = create("2000"); result = draft(id, plan(), mode);
            assert result["can_apply"] and result["total_cents"] > 200000;
            assert any("budget" in warning.lower() for warning in result["warnings"]);
            assert len([row for row in result["changes"] if row["after"]["category"] == "transport"]) == 4;
            assert api.list_items(id) == [];
            api.assistant_review(id, result["id"], True, True);
            assert len([item for item in api.list_items(id) if item.category == "transport"]) == 4;
            assert api.list_trips()[0].budget_cents == 200000;
        }
    }
}

test "strict default still rejects missing travel and alias mismatches" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); state = api.replan_state(id); check = unittest.TestCase();
        missing = plan(); missing["changes"].pop();
        alias = plan(); alias["journey"]["origin"]["city"] = "DTW";
        for proposal in [missing, alias] {
            with check.assertRaises(ValueError) { check_plan(state, {}, proposal, True, True, True); }
        }
        assert api.list_items(id) == [];
    }
}

test "draft mode still protects paid bookings from model edits" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); result = draft(id, plan()); api.assistant_review(id, result["id"], True, True);
        outbound = next(item for item in api.list_items(id) if item.title == "Outbound");
        api.set_item_state(id, outbound.id, False, True);
        proposal = plan(); proposal["journey"] = None; proposal["changes"] = [proposal["changes"][0]];
        proposal["changes"][0]["item_id"] = outbound.id; proposal["changes"][0]["time"] = "13:00";
        check = unittest.TestCase();
        with check.assertRaises(ValueError) { check_plan(api.replan_state(id), {}, proposal, True, True, True, [], True); }
        assert next(item for item in api.list_items(id) if item.id == outbound.id).time == "12:00";
    }
}

test "automatic schema pins independent departure and return city labels" {
    schema = provider.plan_schema("plan", True, True, True, {"departure_location": "Detroit", "return_location": "Boston"});
    fields = schema["properties"]["plans"]["items"]["properties"];
    route = fields["journey"]["properties"];
    assert route["origin"]["properties"]["city"]["enum"] == ["Detroit"];
    assert route["return_to"]["properties"]["city"]["enum"] == ["Boston"];
    assert route["return_to"]["type"] == "object";
    assert fields["trip_changes"]["properties"]["departure_location"] == {"type": "null"};
    assert fields["trip_changes"]["properties"]["return_location"] == {"type": "null"};
    one_way = provider.journey_schema({"departure_location": "Detroit", "return_location": ""});
    assert one_way["anyOf"][0]["properties"]["return_to"] == {"type": "null"};
}

test "new trip keeps estimated flight legs when no dated listings or transport rows are returned" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); proposal = plan();
        proposal["journey"]["legs"][0]["mode"] = "bus";
        proposal["journey"]["legs"][-1]["mode"] = "bus";
        proposal["changes"] = [row for row in proposal["changes"] if row["leg_id"] not in ["origin:tokyo", "osaka:return"]];
        result = draft(id, proposal);
        assert result["journey"]["legs"][0]["mode"] == "flight" and result["journey"]["legs"][-1]["mode"] == "flight";
        flights = [row["after"] for row in result["changes"] if row["after"]["journey"].get("mode") == "flight"];
        assert len(flights) == 2 and all(item["flight"] == {} for item in flights);
        assert all("Estimated" in item["title"] for item in flights);
        api.assistant_review(id, result["id"], True, True);
        assert len([item for item in api.list_items(id) if item.journey.get("mode") == "flight"]) == 2;
    }
}

test "draft mode instructions reach generation and repair without asking for clarification or withholding plans" {
    response = {"answer": "Review this estimate.", "plans": [plan()]};
    structured = {"status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": json.dumps(response)}]}]};
    context = {"draft_only": True, "automatic_action": True};
    with patch.object(provider, "request", return_value=structured) as transport {
        for mode in ["plan", "backup", "replan"] { provider.generate(context, [], "Prepare my trip", mode, False); }
        provider.repair(context, response, ["Timing or budget uncertainty"]);
        assert transport.call_count == 4;
        for call in transport.call_args_list {
            body = call[0][0];
            assert "complete draft without follow-up questions" in body["instructions"];
            assert "short note, not a reason to return no plan" in body["instructions"];
            assert "never invent airline names, flight numbers or sourced fares" in body["instructions"];
            assert "return no drafts" not in body["input"];
            assert body["text"]["format"]["schema"]["properties"]["plans"]["minItems"] == 1;
            assert body["text"]["format"]["schema"]["properties"]["plans"]["maxItems"] == 1;
        }
        assert "Keep a useful draft with brief uncertainty notes" in transport.call_args[0][0]["input"];
    }
    assert provider.draft_instructions({}) == "";
}
