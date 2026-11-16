"""Fit proposed flexible AI activities; preserve unedited and protected arrangements."""
import from datetime { datetime, timedelta }
import from copy { deepcopy }
import journey.model as journey_model;

def start(item: dict[str, any]) -> datetime {
    zone = item.get("journey", {}).get("zone");
    value = item["date"] + "T" + item["time"];
    return journey_model.instant(value, zone) if zone else datetime.fromisoformat(value);
}

def fit_optional(nodes: dict[str, any], new_ids: list[str], journey: any, budget: int = 0, reserve: int = 0, edit_ids: list[str] | None = None, originals: dict[str, any] | None = None) -> dict[str, any] {
    adjustments: list[str] = []; omitted: list[str] = []; reverted: list[str] = [];
    original = originals or {}; mutable = new_ids + (edit_ids or []); pending = set(mutable);
    for key in mutable {
        pending.discard(key);
        item = nodes[key]; detail = item.get("journey", {});
        if item["category"] not in ["food", "activity"] or (journey and not detail.get("stop_id")) { continue; }
        day = item["date"]; zone = detail.get("zone", ""); stop = detail.get("stop_id", "");
        low = journey_model.instant(day + "T00:00", zone) if zone else datetime.fromisoformat(day + "T00:00");
        high = journey_model.instant(day + "T23:59", zone) if zone else datetime.fromisoformat(day + "T23:59");
        for leg in (journey["legs"] if journey else []) {
            transfers = [other for other in nodes.values() if other.get("journey", {}).get("leg_id") == leg["id"]];
            if not transfers { continue; }
            transfer = transfers[0]; departure = start(transfer);
            arrival = departure + timedelta(minutes=transfer["duration_minutes"]);
            if leg["to_id"] == stop { low = max(low, arrival + timedelta(minutes=leg["after_minutes"])); }
            if leg["from_id"] == stop { high = min(high, departure - timedelta(minutes=leg["before_minutes"])); }
        }
        duration = timedelta(minutes=item["duration_minutes"]); wanted = start(item);
        blocks = [];
        for (other_id, other) in nodes.items() {
            if other_id in pending and other["category"] in ["food", "activity"] { continue; }
            if other_id == key or other["category"] in ["packing", "expense"] or not other["date"] or not other["time"] { continue; }
            first = start(other); last = first + timedelta(minutes=other["duration_minutes"]);
            if last > low and first < high { blocks.append((first, last)); }
        }
        candidates = [wanted, low, high - duration];
        for (first, last) in blocks { candidates.extend([last, first - duration]); }
        valid = [candidate for candidate in candidates if candidate >= low and candidate + duration <= high
            and not any(candidate < last and candidate + duration > first for (first, last) in blocks)];
        if not valid {
            if key in original {
                nodes[key] = deepcopy(original[key]); reverted.append(key);
                omitted.append("Proposed change to " + item["title"] + " (" + day + "): left out because it could not fit; the saved arrangement was kept.");
            } else {
                omitted.append(item["title"] + " (" + day + "): left out because it could not fit around travel and saved arrangements.");
                nodes.pop(key);
            }
            continue;
        }
        chosen = min(valid, key=lambda (candidate: any) -> any { abs((candidate - wanted).total_seconds()); });
        if chosen != wanted {
            local = journey_model.local_time(chosen, zone) if zone else chosen;
            before = journey_model.local_time(wanted, zone) if zone else wanted;
            item["time"] = local.strftime("%H:%M");
            if journey { item["journey"] = journey_model.bind(item, detail, journey); }
            adjustments.append(item["title"] + " (" + day + "): moved from " + before.strftime("%H:%M") + " to " + item["time"] + " to preserve travel buffers and saved arrangements.");
        }
    }
    if budget {
        optional = [key for key in mutable if key in nodes and key not in reverted and nodes[key]["category"] in ["food", "activity"]];
        optional.sort(key=lambda (key: str) -> int { nodes[key]["cost_cents"] - original.get(key, {}).get("cost_cents", 0); }, reverse=True);
        total = sum(item["cost_cents"] for item in nodes.values()) + reserve;
        for key in optional {
            if total <= budget { break; }
            item = nodes[key]; saving = item["cost_cents"] - original.get(key, {}).get("cost_cents", 0);
            if saving <= 0 { continue; }
            total -= saving;
            if key in original {
                nodes[key] = deepcopy(original[key]); reverted.append(key);
                omitted.append("Proposed change to " + item["title"] + ": left out to fit the saved budget; the saved arrangement was kept.");
            } else {
                nodes.pop(key);
                omitted.append(item["title"] + " (" + item["date"] + "): left out to keep required travel, saved arrangements and contingency within the saved budget.");
            }
        }
    }
    return {"adjustments": adjustments, "omitted": omitted, "reverted": reverted};
}


def estimated_arrival(item: dict[str, any], detail: dict[str, any], journey: dict[str, any]) -> dict[str, any] {
    matches = [leg for leg in journey["legs"] if leg["id"] == detail.get("leg_id")];
    if item["category"] != "transport" or not matches { raise ValueError("Only transport items can cover a saved intercity leg."); }
    duration = item["duration_minutes"];
    if type(duration) is not int or not 1 <= duration <= 1440 { raise ValueError("Item durations must be between 1 and 1440 minutes."); }
    leg = matches[0]; places = journey_model.places(journey);
    first = journey_model.instant(item["date"] + "T" + item["time"], places[leg["from_id"]]["zone"]);
    arrival = journey_model.local_time(first + timedelta(minutes=duration), places[leg["to_id"]]["zone"]);
    result = deepcopy(detail);
    result.update({"arrival_date": arrival.date().isoformat(), "arrival_time": arrival.strftime("%H:%M")});
    return result;
}

def estimated_flights(nodes: dict[str, any], journey: dict[str, any], trip: dict[str, any]) -> list[dict[str, any]] {
    additions: list[dict[str, any]] = []; places = journey_model.places(journey);
    known = [item for item in nodes.values() if item.get("journey", {}).get("mode") == "flight"];
    duration = known[0]["duration_minutes"] if known else 180;
    prices = [item["cost_cents"] for item in known if item["cost_cents"] > 0];
    allowance = prices[0] if prices else trip["budget_cents"] // 10 if trip["budget_cents"] else 0;
    for leg in journey["legs"] {
        if leg["mode"] != "flight" or any(item.get("journey", {}).get("leg_id") == leg["id"] for item in nodes.values()) { continue; }
        origin = places[leg["from_id"]]; destination = places[leg["to_id"]]; returning = leg["to_id"] == "return";
        if returning {
            last = journey_model.instant(trip["end_date"] + "T18:00", destination["zone"]);
            first = last - timedelta(minutes=duration);
        } else {
            day = trip["start_date"] if leg["from_id"] == "origin" else origin["departure_date"];
            first = journey_model.instant(day + "T10:00", origin["zone"]); last = first + timedelta(minutes=duration);
        }
        departure = journey_model.local_time(first, origin["zone"]); arrival = journey_model.local_time(last, destination["zone"]);
        if not trip["start_date"] <= departure.date().isoformat() <= trip["end_date"] {
            fallback_day = trip["end_date"] if returning else trip["start_date"];
            first = journey_model.instant(fallback_day + ("T18:00" if returning else "T10:00"), origin["zone"]); last = first + timedelta(minutes=duration);
            departure = journey_model.local_time(first, origin["zone"]); arrival = journey_model.local_time(last, destination["zone"]);
        }
        key = "estimated-flight-" + leg["id"];
        item = {"id": key, "trip_id": trip["id"], "title": "Estimated return flight" if returning else "Estimated outbound flight" if leg["from_id"] == "origin" else "Estimated connecting flight",
            "category": "transport", "date": departure.date().isoformat(), "time": departure.strftime("%H:%M"), "duration_minutes": duration,
            "location": origin["city"] + " → " + destination["city"], "cost_cents": allowance,
            "notes": "Provisional travel-time and fare allowance, not a searched flight or booking. Confirm the schedule and price before travel.",
            "reference": "", "paid": False, "done": False, "fixed": False, "protected": False, "latest_start": "", "flight": {}};
        item["journey"] = journey_model.bind(item, {"stop_id": "", "leg_id": leg["id"], "arrival_date": arrival.date().isoformat(), "arrival_time": arrival.strftime("%H:%M")}, journey);
        nodes[key] = item; additions.append(item);
    }
    return additions;
}
