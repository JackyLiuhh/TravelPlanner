"""Saved trip details reach AI tasks without model calls or automatic itinerary writes."""
import os;
import json;
import sqlite3;
import tempfile;
import from uuid { uuid4 }
import from unittest.mock { patch }
import server.main as api;
import assistant.provider as provider;
import assistant.fallback as fallback;
import from journey.fixtures { plan }

test "AI backups and replans receive current saved details and only pending trip changes" {
    for mode in ["backup", "replan"] {
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
            id = api.save_trip("Quiet New York trip", "New York", "2027-01-01", "2027-01-03", "USD", "5000",
                notes="Prefer quiet evenings and short walks.", departure_location="Detroit", return_location="Detroit").id;
            foreign = api.save_trip("Other trip", "Boston", "2027-01-01", "2027-01-03", "USD", "900").id;
            booking = api.save_item(id, "Reserved hotel", "stay", "2027-01-01", "16:00", "New York", "PRIVATE-BOOKING-123", "Near the park", "300");
            api.set_item_state(id, booking.id, False, True);
            api.assistant_save_preferences(id, True, "relax", api.assistant_state(id)["trip_version"]);
            facts = {"reserve_minor": 50000, "zone": "America/New_York"};
            pending = {"id": "pending-change", "item_id": booking.id, "type": "delayed", "delay_minutes": 120,
                "source": "simulator", "observed_at": "2026-11-16T12:00:00+00:00", "confirmation_code": "PRIVATE-EVENT-456"};
            with sqlite3.connect(directory + "/trip.db") as conn {
                conn.execute("INSERT INTO planning_contexts VALUES (?,?)", (id, json.dumps(facts)));
                for (event_id, trip_id, status) in [("pending-change", id, "pending"), ("applied-change", id, "applied"), ("foreign-change", foreign, "pending")] {
                    conn.execute("INSERT INTO disruption_events(id,trip_id,payload,status) VALUES (?,?,?,?)",
                        (event_id, trip_id, json.dumps({**pending, "id": event_id}), status));
                }
            }
            proposed = fallback.proposal(api.replan_state(id), facts, mode);
            response = {"answer": "Review this estimated option.", "plans": [proposed], "sources": []};
            with patch.object(provider, "generate", return_value=response) as generate,
                patch.object(provider, "repair") as repair, patch.object(provider, "request", side_effect=RuntimeError("Network disabled")) {
                result = api.assistant_chat(id, "Use my saved trip", mode, False, str(uuid4()), automatic=True, draft_only=True);
                assert generate.call_count == 1 and repair.call_count == 0;
                context = generate.call_args.args[0];
            }
            assert context["trip"]["notes"] == "Prefer quiet evenings and short walks.";
            assert context["trip"]["budget_cents"] == 500000;
            assert context["trip"]["departure_location"] == "Detroit" and context["trip"]["return_location"] == "Detroit";
            assert context["planning_preferences"] == {"pet_friendly": True, "pace": "relax"};
            assert context["traveler_facts"]["reserve_minor"] == 50000;
            assert len(context["items"]) == 1 and context["items"][0]["id"] == booking.id;
            assert context["items"][0]["locked"] and "reference" not in context["items"][0];
            assert context["reported_changes"] == [{key: pending[key] for key in ["id", "item_id", "type", "delay_minutes", "source", "observed_at"]}];
            assert "PRIVATE-BOOKING-123" not in json.dumps(context) and "PRIVATE-EVENT-456" not in json.dumps(context);
            assert context["flight_listings"] == {};
            assert len(result["drafts"]) == 1 and result["drafts"][0]["can_apply"];
            assert len(api.list_items(id)) == 1;
            api.assistant_review(id, result["drafts"][0]["id"], True, True);
            assert len(api.list_items(id)) > 1;
            retained = next(item for item in api.list_items(id) if item.id == booking.id);
            assert retained.reference == "PRIVATE-BOOKING-123" and retained.paid and retained.cost_cents == 30000;
        }
    }
}

test "saved sourced flight details are included in the next AI task" {
    with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"TRAVEL_DB_PATH": directory + "/trip.db"}) {
        id = api.save_trip("Japan", "Tokyo", "2027-01-01", "2027-01-07", "USD", "8000",
            departure_location="Detroit", return_location="Detroit").id;
        proposal = plan(); outbound = proposal["changes"][0];
        outbound["flight"] = {"airline": "Fixture Air", "flight_number": "QA101", "departure_airport": "DTW", "arrival_airport": "HND",
            "departure_date": outbound["date"], "departure_time": outbound["time"], "arrival_date": outbound["arrival_date"], "arrival_time": outbound["arrival_time"],
            "fare_cents": outbound["cost_cents"], "currency": "USD", "source_url": "https://example.com/outbound"};
        response = {"answer": "Synthetic sourced flight.", "plans": [proposal], "sources": [{"url": "https://example.com/outbound", "title": "Synthetic fixture source"}]};
        with patch.object(provider, "generate", return_value=response), patch.object(provider, "request", side_effect=RuntimeError("Network disabled")) {
            result = api.assistant_chat(id, "Plan", "plan", False, str(uuid4()), automatic=True, draft_only=True);
        }
        api.assistant_review(id, result["drafts"][0]["id"], True, True);
        saved = next(item for item in api.list_items(id) if item.title == "Outbound");
        basic = fallback.proposal(api.replan_state(id), {}, "backup"); before_count = len(api.list_items(id));
        with patch.object(provider, "generate", return_value={"answer": "Backup estimate.", "plans": [basic]}) as generate,
            patch.object(provider, "repair") as repair, patch.object(provider, "request", side_effect=RuntimeError("Network disabled")) {
            api.assistant_chat(id, "Suggest a backup", "backup", False, str(uuid4()), automatic=True, draft_only=True);
            context = generate.call_args.args[0];
            assert generate.call_count == 1 and repair.call_count == 0;
        }
        assert len(context["flight_listings"]) == 1;
        flight = context["flight_listings"][saved.id];
        assert flight["flight_number"] == "QA101" and flight["source_url"] == "https://example.com/outbound";
        assert flight["departure_airport"] == "DTW" and flight["arrival_airport"] == "HND";
        assert flight["status"] == "web_sourced" and flight["availability"] == "Confirm with airline";
        assert len(api.list_items(id)) == before_count;
    }
}
