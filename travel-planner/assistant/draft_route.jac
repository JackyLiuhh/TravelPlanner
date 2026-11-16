"""Put estimated transport legs in route order without rejecting an AI draft."""
import from copy { deepcopy }

def endpoint_matches(value: any, key: str, point: dict[str, any]) -> bool {
    if not isinstance(value, str) { return False; }
    if value.strip().casefold() == key.casefold() { return True; }
    city = point.get("city");
    return isinstance(city, str) and value.strip().casefold() == city.strip().casefold();
}

def repair(raw: any, trip: dict[str, any], saved: any = None) -> any {
    result = deepcopy(raw if raw is not None else saved);
    if not isinstance(result, dict) or not isinstance(result.get("stops"), list) or not result["stops"] { return result; }
    previous = saved if isinstance(saved, dict) else {};
    stops = result["stops"]; ids = {"origin", "return"};
    for stop in stops {
        if not isinstance(stop, dict) or not isinstance(stop.get("id"), str) or not stop["id"] or stop["id"] in ids { return result; }
        ids.add(stop["id"]);
    }
    if not isinstance(result.get("origin"), dict) and isinstance(previous.get("origin"), dict) { result["origin"] = deepcopy(previous["origin"]); }
    if not isinstance(result.get("origin"), dict) { return result; }
    if trip.get("departure_location") { result["origin"]["city"] = trip["departure_location"]; }
    returning = trip.get("return_location", "");
    if not returning { result["return_to"] = None; }
    elif not isinstance(result.get("return_to"), dict) {
        if isinstance(previous.get("return_to"), dict) and previous["return_to"].get("city") == returning {
            result["return_to"] = deepcopy(previous["return_to"]);
        } elif returning == trip.get("departure_location") {
            result["return_to"] = deepcopy(result["origin"]);
        } else { return result; }
    }
    if isinstance(result.get("return_to"), dict) { result["return_to"]["city"] = returning; }
    points: dict[str, any] = {stop["id"]: stop for stop in stops};
    points["origin"] = result["origin"];
    order = ["origin"] + [stop["id"] for stop in stops];
    if result.get("return_to") is not None { points["return"] = result["return_to"]; order.append("return"); }
    supplied: any = result.get("legs") if isinstance(result.get("legs"), list) else [];
    prior: any = previous.get("legs") if isinstance(previous.get("legs"), list) else [];
    legs: list[dict[str, any]] = [];
    for (left, right) in zip(order, order[1:]) {
        matches = [leg for leg in supplied + prior if isinstance(leg, dict)
            and endpoint_matches(leg.get("from_id"), left, points[left])
            and endpoint_matches(leg.get("to_id"), right, points[right])];
        source: dict[str, any] = matches[0] if matches else {};
        mode = source.get("mode");
        if mode not in ["flight", "train", "drive", "bus", "ferry"] { mode = "flight" if left == "origin" or right == "return" else "train"; }
        if not previous and (left == "origin" or right == "return") { mode = "flight"; }
        leg: dict[str, any] = {"from_id": left, "to_id": right, "mode": mode};
        for key in ["before_minutes", "after_minutes"] {
            value: any = source.get(key);
            leg[key] = value if type(value) is int and 0 <= value <= 1440 else 60 if mode == "flight" else 30;
        }
        legs.append(leg);
    }
    result["legs"] = legs;
    return result;
}
