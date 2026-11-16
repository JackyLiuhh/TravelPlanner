"""Local, explicitly estimated itinerary when an AI draft cannot be used."""
import from copy { deepcopy }
import from datetime { date, timedelta }
import from zoneinfo { ZoneInfo, ZoneInfoNotFoundError }
import journey.model as journey_model;

def timezone_name(value: any) -> str {
    if not isinstance(value, str) { return "UTC"; }
    try { ZoneInfo(value); return value; }
    except (ZoneInfoNotFoundError, ValueError) { return "UTC"; }
}

def row(title: str, category: str, day: str, time: str, duration: int, location: str,
    cost: int, notes: str, stop_id: str = "", leg_id: str = "", arrival_date: str = "", arrival_time: str = "") -> dict[str, any] {
    return {"item_id": "", "title": title[:160], "category": category, "date": day, "time": time,
        "duration_minutes": duration, "location": location[:300], "cost_cents": cost, "notes": notes[:2500],
        "stop_id": stop_id, "leg_id": leg_id, "arrival_date": arrival_date, "arrival_time": arrival_time, "flight": None};
}

def proposal(state: dict[str, any], facts: dict[str, any], mode: str) -> dict[str, any] {
    trip = state["trip"]; saved = state.get("items", []); route: any = deepcopy(state.get("journey"));
    assumed = route is None;
    if route is not None { route = journey_model.normalize(route, trip); }
    elif trip.get("departure_location") {
        zone = timezone_name(facts.get("zone"));
        origin: any = {"city": trip["departure_location"], "zone": zone, "lat": None, "lon": None};
        returning: any = {"city": trip["return_location"], "zone": zone, "lat": None, "lon": None} if trip.get("return_location") else None;
        stop: any = {"id": "destination", "city": trip["destination"], "zone": zone, "lat": None, "lon": None,
            "arrival_date": trip["start_date"], "departure_date": trip["end_date"]};
        legs: list[dict[str, any]] = [{"from_id": "origin", "to_id": "destination", "mode": "flight", "before_minutes": 60, "after_minutes": 30}];
        if returning is not None { legs.append({"from_id": "destination", "to_id": "return", "mode": "flight", "before_minutes": 60, "after_minutes": 30}); }
        route = journey_model.normalize({"version": 1, "origin": origin, "return_to": returning, "stops": [stop], "legs": legs}, trip);
    }
    note = "Basic planning estimate generated locally, not a researched listing or booking. Confirm all times and costs.";
    if assumed and route is not None { note += " Route time zones are provisional: " + route["origin"]["zone"] + " is used until confirmed."; }
    changes: list[dict[str, any]] = [];
    if route is not None {
        places = journey_model.places(route);
        covered = {item.get("journey", {}).get("leg_id") for item in saved if item.get("category") == "transport"};
        for leg in route["legs"] {
            if leg["id"] in covered { continue; }
            origin = places[leg["from_id"]]; destination = places[leg["to_id"]]; returning = leg["to_id"] == "return";
            duration = 180 if leg["mode"] == "flight" else 120;
            day = trip["end_date"] if returning else trip["start_date"] if leg["from_id"] == "origin" else origin["departure_date"];
            time = "18:00" if returning else "09:00";
            first = journey_model.instant(day + "T" + time, origin["zone"]);
            arrival = journey_model.local_time(first + timedelta(minutes=duration), destination["zone"]);
            label = "Estimated return " if returning else "Estimated outbound " if leg["from_id"] == "origin" else "Estimated connecting ";
            changes.append(row(label + leg["mode"], "transport", day, time, duration, origin["city"] + " → " + destination["city"],
                30000 if leg["mode"] == "flight" else 6000, note + " Duration and fare are placeholder allowances; no airline or service is selected.",
                leg_id=leg["id"], arrival_date=arrival.date().isoformat(), arrival_time=arrival.strftime("%H:%M")));
        }
    }
    first_day = date.fromisoformat(trip["start_date"]); last_day = date.fromisoformat(trip["end_date"]);
    day_count = (last_day - first_day).days + 1;
    batches = max(1, (40 - len(changes)) // 3); step = max(1, (day_count + batches - 1) // batches);
    for offset in range(0, day_count, step) {
        day = (first_day + timedelta(days=offset)).isoformat(); end = min(last_day, first_day + timedelta(days=offset + step - 1)).isoformat();
        count = (date.fromisoformat(end) - date.fromisoformat(day)).days + 1;
        stop: any = None;
        if route is not None {
            candidates = [stop for stop in route["stops"] if stop["arrival_date"] <= day <= stop["departure_date"]];
            stop = candidates[-1] if candidates else route["stops"][0] if day < route["stops"][0]["arrival_date"] else route["stops"][-1];
        }
        city = stop["city"] if stop else trip["destination"]; stop_id = stop["id"] if stop else "";
        block_note = note + (" Flexible daily allowance covering " + day + " through " + end + "; adjust each day around saved arrangements." if count > 1 else " Flexible time; adjust around saved arrangements.");
        existing = [item for item in saved if day <= item.get("date", "") <= end];
        if not any(item["category"] == "activity" for item in existing) {
            changes.append(row("Explore " + city + " at your own pace", "activity", day, "14:00", 90, city, 0, block_note + " Free self-guided sightseeing and rest; admission activities are not included.", stop_id));
        }
        if not any(item["category"] == "food" for item in existing) {
            changes.append(row("Meals and local travel allowance", "food", day, "12:30", 45, city, 4000 * count, block_note + " Includes approximate meals and local transport costs, not a venue reservation.", stop_id));
        }
        nights = min(count, (last_day - date.fromisoformat(day)).days);
        if nights > 0 and not any(item["category"] == "stay" for item in existing) {
            changes.append(row("Lodging allowance in " + city, "stay", day, "20:00", 30, city, 12000 * nights, block_note + " Covers " + str(nights) + " night(s); choose and confirm accommodation separately.", stop_id));
        }
    }
    if not changes {
        stop = route["stops"][-1] if route else None; city = stop["city"] if stop else trip["destination"];
        changes.append(row("Flexible time before returning", "activity", trip["end_date"], "15:00", 30, city, 0, note + " Keep all saved arrangements; use only if time permits.", stop["id"] if stop else ""));
    }
    remaining = max(0, trip["budget_cents"] - sum(item["cost_cents"] for item in saved) - facts.get("reserve_minor", 0));
    total = sum(item["cost_cents"] for item in changes);
    if trip["budget_cents"] and remaining > 0 and total > remaining {
        for item in changes {
            if item["cost_cents"] > 0 { item["cost_cents"] = max(1, item["cost_cents"] * remaining // total); }
            item["notes"] += " Cost is a budget allocation, not a market quote.";
        }
    }
    return {"title": ("Basic " + ("backup" if mode == "backup" else "replan" if mode == "replan" else "trip") + " for " + trip["destination"])[:160],
        "summary": "A basic estimated itinerary using your saved dates and locations. Existing arrangements stay unchanged; adjust the flexible suggestions before travel.",
        "trip_changes": {}, "journey": route, "changes": changes[:40], "basic_fallback": True};
}
