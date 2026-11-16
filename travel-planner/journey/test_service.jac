"""End-to-end service checks with isolated stores and mocked model responses."""
import os;
import tempfile;
import unittest;
import from copy { deepcopy }
import from unittest.mock { patch }
import from uuid { uuid4 }
import server.main as api;
import assistant.provider as provider;
import journey.model as journey;
import from journey.fixtures { route, plan }
import from assistant.workflow { check_plan }
import from replan.engine { build_combination }

def create -> str {
    return api.save_trip("Japan", "Tokyo", "2027-01-01", "2027-01-07", "USD", "8000", "", "", "Detroit", "Detroit").id;
}
def send(trip_id: str, proposal: any) -> any {
    response = {"answer": "Review your route.", "sources": [], "plans": [proposal]};
    with patch.object(provider, "generate", return_value=response), patch.object(provider, "repair", return_value=response) {
        return api.assistant_chat(trip_id, "Plan the whole journey", "plan", False, str(uuid4()));
    }
}

test "journey complete cross-zone plan saves route and all transport only on acceptance" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); response = send(id, plan()); draft = response["drafts"][0];
        assert draft["can_apply"] and draft["total_cents"] == 259500;
        assert api.journey_state(id)["journey"] is None and api.list_items(id) == [];
        api.assistant_review(id, draft["id"], True, True);
        items = api.list_items(id); saved = api.journey_state(id);
        assert len(items) == 8 and len(saved["journey"]["stops"]) == 3 and not saved["issues"];
        returning = next(item for item in items if item.title == "Return");
        assert returning.time == "16:00" and returning.journey["arrival_time"] == "14:00" and returning.duration_minutes == 720;
        assert len(api.load_trip_map(id)["journey"]["legs"]) == 4;
        api.assistant_review(id, draft["id"], True, True); assert len(api.list_items(id)) == 8;
    }
}

test "journey rejects missing legs and impossible arrival or city activity" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); state = api.replan_state(id); check = unittest.TestCase();
        for kind in ["missing", "early", "wrong_city", "duration", "duplicate", "outside"] {
            bad = plan();
            if kind == "missing" { bad["changes"].pop(); }
            elif kind == "early" { bad["changes"][4]["time"] = "13:00"; }
            elif kind == "wrong_city" { bad["changes"][4]["stop_id"] = "foreign"; }
            elif kind == "duration" { bad["changes"][0]["duration_minutes"] = 60; }
            elif kind == "duplicate" { bad["changes"].append(deepcopy(bad["changes"][0])); }
            else { bad["journey"]["stops"][0]["arrival_date"] = "2026-12-31"; }
            with check.assertRaises(ValueError) { check_plan(state, {}, bad); }
        }
        assert api.list_items(id) == [];
    }
}

test "journey route changes invalidate drafts and stale editors without partial writes" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); before = api.journey_state(id); draft = send(id, plan())["drafts"][0];
        saved = api.save_journey(id, route(), before["version"]);
        assert len(saved["issues"]) == 4;
        check = unittest.TestCase();
        with check.assertRaises(ValueError) { api.assistant_review(id, draft["id"], True, True); }
        with check.assertRaises(ValueError) { api.save_journey(id, route(), before["version"]); }
        assert api.list_items(id) == [];
        fresh = send(id, plan())["drafts"][0]; api.assistant_review(id, fresh["id"], False, False);
        assert api.list_items(id) == [] and api.journey_state(id)["journey"] == saved["journey"];
    }
}

test "journey manual edits preserve zones and reject impossible transfers transactionally" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); draft = send(id, plan())["drafts"][0]; api.assistant_review(id, draft["id"], True, True);
        item = next(i for i in api.list_items(id) if i.title == "Kyoto walk"); check = unittest.TestCase();
        with check.assertRaises(ValueError) { api.save_item(id, item.title, item.category, item.date, "12:45", item.location, "", item.notes, "0", item.id); }
        assert next(i for i in api.list_items(id) if i.id == item.id).time == "14:00";
        updated = api.save_item(id, item.title, item.category, item.date, "14:30", item.location, "", item.notes, "0", item.id);
        assert updated.journey["arrival_time"] == "16:30";
        with check.assertRaises(ValueError) { api.save_trip("Japan", "Tokyo", "2027-01-01", "2027-01-05", "USD", "8000", "", id); }
        with check.assertRaises(ValueError) { api.save_trip("Japan", "Tokyo", "2026-12-31", "2027-01-07", "USD", "8000", "", id); }
    }
}

test "journey schema rejects invalid zones duplicate stops order and DST ambiguity" {
    trip = {"start_date": "2027-01-01", "end_date": "2027-01-07"}; check = unittest.TestCase();
    for kind in ["zone", "duplicate", "order", "coordinates"] {
        bad = route();
        if kind == "zone" { bad["origin"]["zone"] = "Mars/Olympus"; }
        elif kind == "duplicate" { bad["stops"][1]["id"] = "tokyo"; }
        elif kind == "order" { bad["legs"][1]["to_id"] = "osaka"; }
        else { bad["origin"]["lat"] = 500; bad["origin"]["lon"] = 0; }
        with check.assertRaises(ValueError) { journey.normalize(bad, trip); }
    }
    with check.assertRaises(ValueError) { journey.instant("2027-03-14T02:30", "America/Detroit"); }
    with check.assertRaises(ValueError) { journey.instant("2027-11-07T01:30", "America/Detroit"); }
    assert journey.instant("2027-01-07T16:00", "Asia/Tokyo") < journey.instant("2027-01-07T14:00", "America/Detroit");
}

test "journey one-way routes need outbound and intercity transport but no invented return" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); api.save_trip("Japan", "Tokyo", "2027-01-01", "2027-01-07", "USD", "8000", trip_id=id, departure_location="Detroit", return_location=""); proposal = plan(); proposal["journey"]["return_to"] = None; proposal["journey"]["legs"].pop(); proposal["changes"].pop();
        proposal["trip_changes"] = {key: None for key in provider.trip_schema()["properties"]};
        draft = send(id, proposal)["drafts"][0]; api.assistant_review(id, draft["id"], True, True);
        assert api.list_trips()[0].return_location == "" and len(api.journey_state(id)["journey"]["legs"]) == 3;
    }
}

test "journey rejects conflicting city edits and overlapping manual activities" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); draft = send(id, plan())["drafts"][0]; api.assistant_review(id, draft["id"], True, True);
        check = unittest.TestCase(); state = api.replan_state(id);
        with check.assertRaises(ValueError) { check_plan(state, {}, {"title": "Different origin", "summary": "", "changes": [], "trip_changes": {"departure_location": "Boston"}}); }
        with check.assertRaises(ValueError) { api.save_item(id, "Overlapping lunch", "food", "2027-01-04", "15:00", "Kyoto", "", "", "0", "", {"stop_id": "kyoto"}, 60); }
        assert len(api.list_items(id)) == 8;
        changed = route(); changed["stops"][1]["city"] = "Nagoya";
        with check.assertRaises(ValueError) { api.save_journey(id, changed, api.journey_state(id)["version"]); }
        assert api.journey_state(id)["journey"]["stops"][1]["city"] == "Kyoto";
        outbound = next(i for i in api.list_items(id) if i.title == "Outbound");
        api.replan_save_rules(id, outbound.id, 840, "2027-01-01T12:30", False);
        with check.assertRaises(ValueError) { api.replan_save_rules(id, outbound.id, 60, "", False); }
        assert next(i for i in api.list_items(id) if i.id == outbound.id).duration_minutes == 840;
    }
}

test "journey backup reschedules preserve city timing and reject cross-city sample replacements" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); draft = send(id, plan())["drafts"][0]; api.assistant_review(id, draft["id"], True, True);
        state = api.replan_state(id); item = next(i for i in state["items"] if i["title"] == "Kyoto walk");
        candidate = {"action": "reschedule", "replaces_id": item["id"], "item": {"start": {"local": "2027-01-04T14:30", "zone": "Asia/Tokyo"}, "end": {"local": "2027-01-04T16:30", "zone": "Asia/Tokyo"}}};
        result = journey.replacement_items(state, [candidate]);
        assert result[item["id"]]["journey"]["arrival_time"] == "16:30";
        check = unittest.TestCase(); candidate["item"]["start"]["local"] = "2027-01-04T12:00";
        with check.assertRaises(ValueError) { journey.replacement_items(state, [candidate]); }
        candidate["action"] = "replace";
        with check.assertRaises(ValueError) { journey.replacement_items(state, [candidate]); }
        with check.assertRaises(ValueError) { build_combination(state, {"item_id": item["id"], "type": "interrupted"}, [item["id"]], {}); }
    }
}


test "AI derives cross-zone transport durations without another model request" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); proposal = plan();
        proposal["changes"][0]["duration_minutes"] = 120;
        response = {"answer": "The outbound flight is 120 minutes.", "plans": [proposal]};
        with patch.object(provider, "generate", return_value=response), patch.object(provider, "repair") as repair {
            state = api.assistant_chat(id, "Plan the whole journey", "plan", False, str(uuid4()), automatic=True);
            assert repair.call_count == 0;
        }
        draft = state["drafts"][0];
        assert draft["changes"][0]["after"]["duration_minutes"] == 840;
        assert "840 minutes" in draft["timing_adjustments"][0];
        assert "calculated" in state["messages"][-1]["text"] and "120 minutes" not in state["messages"][-1]["text"];
        assert api.list_items(id) == [];
        api.assistant_review(id, draft["id"], True, True);
        assert next(item for item in api.list_items(id) if item.title == "Outbound").duration_minutes == 840;
    }
}

test "impossible flight instants remain blocked and do not claim successful repairs" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); proposal = plan();
        proposal["changes"][0]["arrival_date"] = "2027-01-01";
        response = {"answer": "Repaired the outbound flight estimate successfully.", "plans": [proposal]};
        with patch.object(provider, "generate", return_value=response), patch.object(provider, "repair", return_value=response) as repair {
            state = api.assistant_chat(id, "Plan my trip", "plan", False, str(uuid4()), automatic=True);
            assert repair.call_count == 1;
        }
        assert state["drafts"] == [] and api.list_items(id) == [];
        message = state["messages"][-1];
        assert "could not prepare a valid draft" in message["text"];
        assert "arrival must be after departure" in message["issues"][0];
    }
}


def optional_item(title: str, day: str, time: str, duration: int, cost: int = 1000) -> dict[str, any] {
    return {"item_id": "", "title": title, "category": "food", "date": day, "time": time,
        "duration_minutes": duration, "location": "Tokyo", "cost_cents": cost, "notes": "Estimated meal.",
        "stop_id": "tokyo", "leg_id": "", "arrival_date": "", "arrival_time": ""};
}

test "breakfast is moved before departure buffer without asking AI to repair again" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); proposal = plan();
        proposal["changes"].append(optional_item("Breakfast", "2027-01-04", "09:30", 60));
        with patch.object(provider, "generate", return_value={"answer": "Trip draft", "plans": [proposal]}), patch.object(provider, "repair") as repair {
            state = api.assistant_chat(id, "Plan my trip", "plan", False, str(uuid4()), automatic=True);
            assert repair.call_count == 0;
        }
        draft = state["drafts"][0]; breakfast = next(row["after"] for row in draft["changes"] if row["after"]["title"] == "Breakfast");
        assert breakfast["time"] == "08:00" and breakfast["duration_minutes"] == 60;
        assert len(draft["changes"]) == 9 and draft["omitted_items"] == [];
        assert any("Breakfast" in note for note in draft["timing_adjustments"]);
        api.assistant_review(id, draft["id"], True, True);
        assert len(api.list_items(id)) == 9;
    }
}

test "optional meal is omitted when it cannot fit while required route remains reviewable" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); proposal = plan();
        proposal["changes"].append(optional_item("Optional extended breakfast", "2027-01-04", "09:30", 1380));
        with patch.object(provider, "generate", return_value={"answer": "Full trip ready", "plans": [proposal]}), patch.object(provider, "repair") as repair {
            state = api.assistant_chat(id, "Give me a usable trip", "plan", False, str(uuid4()), automatic=True);
            assert repair.call_count == 0;
        }
        draft = state["drafts"][0];
        assert len(draft["changes"]) == 8 and len(draft["omitted_items"]) == 1 and draft["can_apply"];
        assert "simplified trip draft" in state["messages"][-1]["text"] and state["messages"][-1]["issues"] == [];
        assert api.list_items(id) == [];
        api.assistant_review(id, draft["id"], True, True);
        assert len(api.list_items(id)) == 8 and api.journey_state(id)["issues"] == [];
    }
}

test "optional extras are dropped for budget while all required transport is retained" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); proposal = plan();
        proposal["changes"].append(optional_item("Optional luxury meal", "2027-01-03", "18:00", 60, 700000));
        with patch.object(provider, "generate", return_value={"answer": "Draft", "plans": [proposal]}), patch.object(provider, "repair") as repair {
            state = api.assistant_chat(id, "Plan my trip", "plan", False, str(uuid4()), automatic=True);
            assert repair.call_count == 0;
        }
        draft = state["drafts"][0];
        assert draft["total_cents"] <= 800000 and len(draft["omitted_items"]) == 1;
        assert len([row for row in draft["changes"] if row["after"]["category"] == "transport"]) == 4;
    }
}

test "activities after arrival are shifted behind the arrival buffer" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); proposal = plan();
        proposal["changes"].append(optional_item("Arrival meal", "2027-01-02", "16:30", 60));
        state = send(id, proposal); draft = state["drafts"][0];
        meal = next(row["after"] for row in draft["changes"] if row["after"]["title"] == "Arrival meal");
        assert meal["time"] == "17:00" and meal["journey"]["arrival_time"] == "18:00";
    }
}


test "optional meals fit around saved fixed arrangements without moving those bookings" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); initial = send(id, plan())["drafts"][0]; api.assistant_review(id, initial["id"], True, True);
        saved = api.save_item(trip_id=id, title="Fixed breakfast booking", category="food", date="2027-01-04", time="08:00", cost="20", journey={"stop_id": "tokyo"}, duration_minutes=60);
        api.replan_save_rules(id, saved.id, 60, "", True);
        proposal = {"title": "Add breakfast", "summary": "Estimated optional meal.", "changes": [optional_item("Optional breakfast", "2027-01-04", "08:30", 60)]};
        state = send(id, proposal); draft = state["drafts"][0];
        assert draft["changes"][0]["after"]["time"] == "07:00";
        api.assistant_review(id, draft["id"], True, True);
        unchanged = next(item for item in api.list_items(id) if item.id == saved.id);
        assert unchanged.time == "08:00" and unchanged.duration_minutes == 60 and unchanged.cost_cents == 2000;
    }
}


test "omitting optional meals cannot make missing required transport pass validation" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); proposal = plan();
        proposal["changes"] = [optional_item("Optional all-day meal", "2027-01-03", "09:00", 1380, 900000)];
        state = send(id, proposal);
        assert state["drafts"] == [] and api.list_items(id) == [];
        assert any("Complete the journey" in issue for issue in state["messages"][-1]["issues"]);
    }
}


test "backup and replan retime proposed flexible saved activities around transport" {
    for mode in ["backup", "replan"] {
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
            id = create(); base = plan(); base["changes"].append(optional_item("Breakfast", "2027-01-04", "08:00", 60));
            initial = send(id, base)["drafts"][0]; api.assistant_review(id, initial["id"], True, True);
            breakfast = next(item for item in api.list_items(id) if item.title == "Breakfast");
            edit = {**optional_item("Breakfast", "2027-01-04", "09:30", 60), "item_id": breakfast.id};
            proposal = {"title": "Flexible meal option", "summary": "Estimated schedule adjustment.", "changes": [edit]};
            with patch.object(provider, "generate", return_value={"answer": "Review this option", "plans": [proposal]}), patch.object(provider, "repair") as repair {
                state = api.assistant_chat(id, "Use my saved trip", mode, False, str(uuid4()), automatic=True);
                assert repair.call_count == 0;
            }
            draft = state["drafts"][0]; assert draft["can_apply"] and draft["mode"] == mode;
            assert draft["changes"][0]["item_id"] == breakfast.id and draft["changes"][0]["after"]["time"] == "08:00";
            assert len(api.list_items(id)) == 9;
            api.assistant_review(id, draft["id"], True, True);
            assert len(api.list_items(id)) == 9;
        }
    }
}

test "both AI backup alternatives survive optional omissions and timing adjustments" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); first = plan(); second = plan();
        first["title"] = "Simple backup"; second["title"] = "Earlier breakfast backup";
        first["changes"].append(optional_item("Optional all-day meal", "2027-01-04", "09:30", 1380));
        second["changes"].append(optional_item("Breakfast", "2027-01-04", "09:30", 60));
        with patch.object(provider, "generate", return_value={"answer": "Two backups", "plans": [first, second]}), patch.object(provider, "repair") as repair {
            state = api.assistant_chat(id, "Prepare backups", "backup", False, str(uuid4()), automatic=True);
            assert repair.call_count == 0;
        }
        assert len(state["drafts"]) == 2 and all(draft["can_apply"] for draft in state["drafts"]);
        assert sum(len(draft["omitted_items"]) for draft in state["drafts"]) == 1;
        assert state["messages"][-1]["issues"] == [] and api.list_items(id) == [];
    }
}

test "a valid backup remains available when another alternative still fails or repair errors" {
    for failed_transport in [False, True] {
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
            id = create(); good = plan(); bad = plan(); good["title"] = "Feasible backup";
            bad["changes"][0]["arrival_date"] = "2027-01-01";
            repaired = {"answer": "An option still failed", "plans": [bad]};
            with patch.object(provider, "generate", return_value={"answer": "Two options", "plans": [good, bad]}), patch.object(provider, "repair", return_value=repaired, side_effect=RuntimeError("AI unavailable") if failed_transport else None) as repair {
                state = api.assistant_chat(id, "Find backups", "backup", False, str(uuid4()), automatic=True);
                assert repair.call_count == 1 and len(repair.call_args.args[1]["plans"]) == 1;
            }
            assert len(state["drafts"]) == 1 and state["drafts"][0]["title"] == "Feasible backup";
            assert state["messages"][-1]["issues"] == [] and "1 valid trip option" in state["messages"][-1]["text"];
            assert any("Another option was left out" in warning for warning in state["drafts"][0]["warnings"]);
            api.assistant_review(id, state["drafts"][0]["id"], True, True);
            assert len(api.list_items(id)) == 8;
        }
    }
}


test "initial AI plans must include outbound and return flights to the saved locations" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = create(); api.save_trip("Japan", "Tokyo", "2027-01-01", "2027-01-07", "USD", "8000", trip_id=id, departure_location="Detroit", return_location="Chicago");
        full = plan(); full["journey"]["return_to"].update({"city": "Chicago", "zone": "America/Chicago"});
        missing = deepcopy(full); missing.pop("journey");
        with patch.object(provider, "generate", return_value={"answer": "Activities only", "plans": [missing]}), patch.object(provider, "repair", return_value={"answer": "Complete route", "plans": [full]}) as repair {
            state = api.assistant_chat(id, "Plan with flights", "plan", False, str(uuid4()), automatic=True);
            assert repair.call_count == 1 and "outbound flight" in repair.call_args.args[2][0];
        }
        draft = state["drafts"][0]; flights = [row["after"] for row in draft["changes"] if row["after"].get("journey", {}).get("mode") == "flight"];
        assert len(flights) == 2 and draft["require_travel"];
        outbound = next(item for item in flights if item["journey"]["from_city"] == "Detroit");
        returning = next(item for item in flights if item["journey"]["to_city"] == "Chicago");
        assert outbound["date"] == "2027-01-01" and returning["journey"]["arrival_date"] == "2027-01-07";
        assert returning["duration_minutes"] == 780 and draft["total_cents"] == 259500;
        assert api.list_items(id) == [];
        api.assistant_review(id, draft["id"], True, True);
        assert len([item for item in api.list_items(id) if item.journey.get("mode") == "flight"]) == 2;
        assert api.list_trips()[0].return_location == "Chicago";
    }
}

test "planning backup and replan cannot omit the required return flight" {
    for mode in ["plan", "backup", "replan"] {
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
            id = create(); missing = plan(); missing["changes"].pop();
            with patch.object(provider, "generate", return_value={"answer": "Draft", "plans": [missing]}), patch.object(provider, "repair", return_value={"answer": "Full route", "plans": [plan()]}) as repair {
                state = api.assistant_chat(id, "Keep outbound and return flights", mode, False, str(uuid4()), automatic=True);
                assert repair.call_count == 1;
            }
            draft = state["drafts"][0]; assert draft["can_apply"];
            assert len([row for row in draft["changes"] if row["after"].get("journey", {}).get("mode") == "flight"]) == 2;
        }
    }
}

test "AI cannot silently remove return locations or replace required flights with ground travel" {
    for kind in ["return_location", "mode", "route_only"] {
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
            id = create(); bad = plan();
            if kind == "return_location" {
                bad["journey"]["return_to"] = None; bad["journey"]["legs"].pop(); bad["changes"].pop();
                bad["trip_changes"] = {"return_location": ""};
            } elif kind == "mode" { bad["journey"]["legs"][0]["mode"] = "train"; }
            else { bad["changes"] = []; }
            response = {"answer": "Complete trip", "plans": [bad]};
            with patch.object(provider, "generate", return_value=response), patch.object(provider, "repair", return_value=response) {
                state = api.assistant_chat(id, "Plan with flights", "plan", False, str(uuid4()), automatic=True);
            }
            assert state["drafts"] == [] and api.list_items(id) == [];
            assert len(state["messages"][-1]["issues"]) > 0;
        }
    }
}
