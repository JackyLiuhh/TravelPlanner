"""Read-only whole-itinerary validation for Gehao Dong's standalone fixtures.

This is a local reference implementation, not the project's shared validator.
No database, provider, LLM, comparison score, booking or patch application.
"""
import from copy { deepcopy }
import from dataclasses { asdict }
import from datetime { date, datetime, timedelta, timezone }
import from hashlib { sha256 }
import json;
import from planning.profile_io { profile_from_data }
import from filter.models { PlaceFacts }
import from filter.evaluate { evaluate_place }
import from budget.ledger { build_ledger }
import from schema.common { to_plain }
import from zoneinfo { ZoneInfo, ZoneInfoNotFoundError }
import from backup.validation_models {
    Evidence,
    Moment,
    Replacement,
    RiskContext,
    TripContext
}
glob UTC = timezone.utc;
"""A missing/ambiguous fact is unresolved rather than a constraint failure."""
class MissingFact(ValueError) {}
"""Resolve an IANA local time; never guess DST folds or normalize a gap."""
def instant(moment: Moment) -> datetime {
    if (not moment.local or not moment.zone) {
        raise MissingFact("Time or time zone is missing");
    }
    try {
        local = datetime.fromisoformat(moment.local);
        zone = ZoneInfo(moment.zone);
    } except (ValueError, ZoneInfoNotFoundError, TypeError) as exc {
        raise ValueError("Time or time zone is invalid") from exc;
    }
    if (local.tzinfo is not None) {
        raise ValueError("Enter a local time and a time zone name, without a UTC offset");
    }
    if (
        (moment.fold is not None)
        and ((`type(moment.fold) is not int) or (moment.fold not in (0, 1)))
    ) {
        raise ValueError("DST fold must be 0 or 1");
    }
    possibilities = {};
    for fold in (0, 1) {
        value = local.replace(tzinfo=zone, fold=fold).astimezone(UTC);
        if (value.astimezone(zone).replace(tzinfo=None) == local) {
            possibilities[fold] = value;
        }
    }
    if not possibilities {
        raise ValueError("This time is skipped by a daylight-saving change");
    }
    if ((len(`set(possibilities.values())) > 1) and (moment.fold is None)) {
        raise MissingFact("This time happens twice because of a daylight-saving change; choose which one");
    }
    return possibilities[moment.fold if (moment.fold is not None) else 0];
}
def evidence_problem(evidence: (Evidence | None), now: datetime) -> str {
    if ((evidence is None) or not evidence.source.strip()) {
        return "No source is recorded";
    }
    try {
        checked = datetime.fromisoformat(evidence.checked_at);
        expires = datetime.fromisoformat(evidence.expires_at);
        if ((checked.utcoffset() is None) or (expires.utcoffset() is None)) {
            return "Source dates are missing a UTC offset";
        }
        if ((checked > now) or (expires <= now) or (expires <= checked)) {
            return "Source information has expired or has invalid dates";
        }
    } except (ValueError, TypeError) {
        return "Source dates are invalid";
    }
    return "";
}
def _amount(minor: int, currency: str) -> str {
    return f"{currency} {minor // 100:,}.{minor % 100:02d}";
}
def _minor(value: any) -> bool {
    return ((`type(value) is int) and (value >= 0));
}
def validate_replacement(
    trip: TripContext, risk: RiskContext, replacement: Replacement, now: datetime
) -> dict[str, any] {
    if (now.utcoffset() is None) {
        raise ValueError("Validation clock needs a UTC offset");
    }
    # Construct proposals from copies without mutating caller-owned inputs.
    (trip, risk, replacement) = deepcopy((trip, risk, replacement));
    fingerprint = sha256(json.dumps(asdict(trip), sort_keys=True).encode()).hexdigest();
    checks = [];
    ledger = None;
    def record(code: any, status: any, message: any, *ids: any) -> any {
        checks.append(
            {"code": code, "status": status, "message": message, "item_ids": `list(ids)}
        );
    }
    def resolve(moment: any, code: any, item_id: any) -> any {
        try {
            return instant(moment);
        } except MissingFact as exc {
            record(code, "unknown", str(exc), item_id);
        } except ValueError as exc {
            record(code, "fail", str(exc), item_id);
        }
        return None;
    }
    def evidence(e: any, code: any, *ids: any) -> any {
        problem = evidence_problem(e, now);
        record(
            code,
            "unknown" if problem else "pass",
            (problem or "Source information is current"),
            *ids
        );
        return not problem;
    }
    def finish(total: any = None, retained: any = None) -> any {
        statuses = {check["status"] for check in checks};
        status = "invalid"
            if ("fail" in statuses)
            else "needs_validation"
                if ("unknown" in statuses)
                else "passed_fixture_checks";
        return {
            "candidate_id": replacement.id,
            "title": replacement.item.title,
            "status": status,
            "scope": "standalone_fixture",
            "base_snapshot": fingerprint,
            "checked_at": now.isoformat(),
            "checks": checks,
            "cost": {
                "currency": trip.currency,
                "projected_total_minor": total,
                "retained_original_payment_minor": retained,
                "reserve_minor": trip.reserve_minor,
                "budget_minor": trip.budget_minor
            },
            "ledger": ledger,
            "proposed_items": [asdict(item) for item in nodes],
            "notice": "Demo data only. Nothing is booked. "
            "Amounts already paid are kept; no refund is assumed."
        };
    }
    nodes = `list(trip.items);
    ids = [item.id for item in nodes];
    if (
        not ids or `any(not key.strip() for key in ids) or (len(`set(ids)) != len(ids))
    ) {
        record("item_ids", "fail", "Every itinerary item needs its own ID");
        return finish();
    }
    if (
        (replacement.replaces_id not in ids)
        or (replacement.item.id != replacement.replaces_id)
    ) {
        record(
            "replacement_scope", "fail", "The replacement must keep the ID of the item it replaces"
        );
        return finish();
    }
    old = next(
        item
        for item in nodes
        if (item.id == replacement.replaces_id)
    );
    if (old.fixed or old.completed) {
        record(
            "protected_item", "fail", f"{old.title} is fixed or completed and can't be replaced", old.id
        );
        return finish();
    }
    record(
        "protected_item",
        "pass",
        "Fixed and completed items stay unchanged",
        old.id
    );
    if ((risk.trip_id != trip.id) or (risk.item_id != old.id)) {
        record(
            "risk_scope",
            "fail",
            "This risk belongs to a different trip or item",
            old.id
        );
    }
    evidence(risk.evidence, "risk_evidence", old.id);
    if (risk.status != "flagged") {
        record(
            "risk_status",
            "unknown",
            f"The risk to {old.title} isn't confirmed yet",
            old.id
        );
    }
    if (risk.trigger not in ("rain", "arrival_delay", "weather", "timing", "long_drive", "opening_hours",
        "booking_terms", "closure", "cancellation", "traveler_change", "budget_change", "inventory_change")) {
        record("risk_trigger", "unknown", "This type of disruption isn't supported yet", old.id);
    } elif (risk.trigger in ("rain", "arrival_delay") and old.category != ("activity" if risk.trigger == "rain" else "food")) {
        record(
            "risk_trigger",
            "fail",
            f"This disruption doesn't apply to {old.title}",
            old.id
        );
    }
    if (replacement.item.category != old.category) {
        record(
            "replacement_category",
            "fail",
            f"The replacement isn't the same kind of item as {old.title}",
            old.id
        );
    }
    if replacement.action not in ("replace", "reschedule") {
        record("replacement_action", "fail", "This type of change isn't supported", old.id);
    }
    if (replacement.action == "replace" and replacement.item.paid_minor != 0) {
        record(
            "replacement_payment",
            "fail",
            "A new purchase can't already be marked paid",
            old.id
        );
    }
    nodes = [replacement.item if (item.id == old.id) else item for item in nodes];
    profile = trip.profile;
    traveler = profile_from_data(trip.traveler_profile) if trip.traveler_profile is not None else None;
    party_size = (profile.adults if `type(profile.adults) is int else 0) + len(profile.child_ages);
    missing_adults = profile.adults is None and not profile.complete;
    if (
        (not missing_adults and ((`type(profile.adults) is not int) or (profile.adults < 1)))
        or `any(
            ((`type(age) is not int) or not (0 <= age <= 17))
            for age in profile.child_ages
        )
    ) {
        record(
            "profile", "fail", "Enter at least one adult, and child ages from 0 to 17"
        );
    }
    if missing_adults {
        record("profile", "unknown", "The number of travelers is missing");
    }
    if not profile.complete {
        record("profile", "unknown", "Traveler requirements are incomplete");
    }
    if `any(not code.strip() for code in profile.dietary) {
        record("profile", "unknown", "A dietary requirement isn't recognized");
    }
    try {
        (first, last) = (
            date.fromisoformat(trip.start_date),
            date.fromisoformat(trip.end_date)
        );
        if (last < first) {
            raise ValueError("The trip ends before it starts");
        }
        lower = instant(Moment((first.isoformat() + "T00:00"), trip.zone));
        upper = instant(
            Moment(((last + timedelta(days=1)).isoformat() + "T00:00"), trip.zone)
        );
    } except MissingFact as exc {
        record("trip_bounds", "unknown", str(exc));
        lower = upper=None;
    } except (ValueError, TypeError) as exc {
        record("trip_bounds", "fail", str(exc));
        lower = upper=None;
    }
    times = {};
    known_costs = trip.currency == "USD";
    if not known_costs {
        record("currency", "unknown", "Prices can only be checked in USD for now");
    }
    for item in nodes {
        if (item.category not in ("transport", "stay", "food", "activity")) {
            record(
                "category", "unknown", f"{item.title}: this type of item can't be checked", item.id
            );
        }
        if (not item.blocks_time and (item.category != "stay")) {
            record(
                "blocking_time",
                "fail",
                f"{item.title}: only hotel stays can overlap other plans",
                item.id
            );
        }
        fresh = evidence(item.evidence, "item_evidence", item.id);
        if (item.availability == "unavailable") {
            record("availability", "fail", f"{item.title} is unavailable", item.id);
        } elif (item.availability != "available") {
            record(
                "availability", "unknown", f"Availability of {item.title} is unknown", item.id
            );
        } else {
            record(
                "availability", "pass", f"{item.title} is available (demo data)", item.id
            );
        }
        if not item.venue.strip() {
            record("location", "unknown", f"No location for {item.title}", item.id);
        }
        begin = resolve(item.start, "schedule", item.id);
        end = resolve(item.end, "schedule", item.id);
        if ((begin is not None) and (end is not None)) {
            if (begin >= end) {
                record("schedule", "fail", f"{item.title} ends before it starts", item.id);
            } else {
                times[item.id] = (begin, end);
                if item.id in trip.latest_starts {
                    latest = resolve(trip.latest_starts[item.id], "latest_start", item.id);
                    if latest is not None and begin > latest { record("latest_start", "fail", f"{item.title} starts after your latest allowed start", item.id); }
                }
                if ((lower is not None) and ((begin < lower) or (end > upper))) {
                    record(
                        "trip_bounds",
                        "fail",
                        f"{item.title} falls outside the trip dates",
                        item.id
                    );
                } else {
                    record(
                        "schedule",
                        "pass",
                        f"{item.title} has a valid time",
                        item.id
                    );
                }
            }
            if (item.hours is None) {
                record(
                    "opening_hours",
                    "unknown",
                    f"Opening hours for {item.title} are unknown",
                    item.id
                );
            } else {
                (contained, unknown_window) = (False, False);
                for window in item.hours {
                    left = resolve(window.start, "opening_hours", item.id);
                    right = resolve(window.end, "opening_hours", item.id);
                    if ((left is None) or (right is None)) {
                        unknown_window = True;
                    } elif (right <= left) {
                        record(
                            "opening_hours",
                            "fail",
                            f"Opening hours for {item.title} are invalid",
                            item.id
                        );
                    } elif ((left <= begin) and (end <= right)) {
                        contained = True;
                    }
                }
                if not contained {
                    record(
                        "opening_hours",
                        "unknown" if unknown_window else "fail",
                        f"{item.title} doesn't fit within its known opening hours",
                        item.id
                    );
                } elif fresh {
                    record(
                        "opening_hours",
                        "pass",
                        f"{item.title} fits within its opening hours",
                        item.id
                    );
                }
            }
        }
        if traveler is not None {
            source = item.evidence;
            place = PlaceFacts(id=item.id, category=item.category, eligibility=item.eligibility,
                child_min_age=item.child_min_age, child_max_age=item.child_max_age,
                source_ref=source.source if source else "", checked_at=source.checked_at if source else "",
                expires_at=source.expires_at if source else "");
            filtered = evaluate_place(traveler, place, now);
            for check in filtered.checks {
                if check.status != "not_applicable" {
                    record("child_age" if check.evidence_key == "child:admission_ages" else "eligibility",
                        check.status, check.evidence_key + ": " + check.reason, item.id);
                }
            }
        }
        needs = [("dietary:" + code) for code in profile.dietary]
            if (item.category == "food")
            else [];
        if traveler is not None { needs = []; }
        if profile.pet and traveler is None {
            needs.append(("pet:" + profile.pet));
        }
        if profile.wheelchair and traveler is None {
            needs.append("accessibility:wheelchair");
        }
        if ((item.id == old.id) and (risk.trigger in ("rain", "weather"))) {
            needs.append("indoor");
        }
        for need in needs {
            value = item.eligibility.get(need);
            status = "unknown"
                if (not fresh or (`type(value) is not bool))
                else "pass" if value else "fail";
            record(
                "eligibility",
                status,
                need + (f": not confirmed for {item.title}" if status == "unknown" else f": supported by {item.title}" if value else f": not supported by {item.title}"),
                item.id
            );
        }
        if profile.child_ages and traveler is None {
            (lo, hi) = (item.child_min_age, item.child_max_age);
            if ((lo is None) or (hi is None) or not fresh) {
                record(
                    "child_age",
                    "unknown",
                    f"Child age limits for {item.title} are unknown",
                    item.id
                );
            } elif (not _minor(lo) or not _minor(hi) or (hi < lo)) {
                record(
                    "child_age", "fail", f"Child age limits for {item.title} are invalid", item.id
                );
            } else {
                allowed = all((lo <= age <= hi) for age in profile.child_ages);
                record(
                    "child_age",
                    "pass" if allowed else "fail",
                    f"All children meet the age limits for {item.title}"
                        if allowed
                        else f"A child is outside the age limits for {item.title}",
                    item.id
                );
            }
        }
        if (item.currency != trip.currency) {
            record(
                "currency",
                "unknown",
                f"{item.title} is priced in another currency and can't be converted",
                item.id
            );
            known_costs = False;
        }
        if ((item.cost_minor is None) or not fresh) {
            record("price", "unknown", f"No current price for {item.title}", item.id);
            known_costs = False;
        } elif not _minor(item.cost_minor) {
            record(
                "price",
                "fail",
                f"The price for {item.title} is invalid",
                item.id
            );
            known_costs = False;
        }
        if ((item.party_size != party_size) or (item.fees_included is not True)) {
            record(
                "party_quote",
                "unknown",
                f"Need a price for {item.title} that covers your whole group, with taxes and fees",
                item.id
            );
            known_costs = False;
        }
        if (item.paid_minor is None) {
            record("payment", "unknown", f"The amount paid for {item.title} is unknown", item.id);
            known_costs = False;
        } elif (
            not _minor(item.paid_minor)
            or (_minor(item.cost_minor) and (item.paid_minor > item.cost_minor))
        ) {
            record(
                "payment",
                "fail",
                f"The amount paid for {item.title} is more than its price",
                item.id
            );
            known_costs = False;
        }
    }
    if (risk.trigger == "arrival_delay" or risk.not_before is not None) {
        if (risk.not_before is None) {
            record(
                "arrival_delay",
                "unknown",
                "The new earliest dinner time is missing",
                old.id
            );
        } else {
            earliest = resolve(risk.not_before, "arrival_delay", old.id);
            if ((earliest is not None) and (old.id in times)) {
                ok = times[old.id][0] >= earliest;
                record(
                    "arrival_delay",
                    "pass" if ok else "fail",
                    "Dinner starts after the new arrival time"
                        if ok
                        else "Dinner starts before the new arrival time",
                    old.id
                );
            }
        }
    }
    if risk.trigger == "long_drive" {
        original_start = resolve(old.start, "original_duration", old.id);
        original_end = resolve(old.end, "original_duration", old.id);
        if original_start is None or original_end is None or original_end <= original_start {
            record("long_drive", "unknown", f"The original travel time for {old.title} is unknown", old.id);
        } elif old.id in times {
            shorter = times[old.id][1] - times[old.id][0] < original_end - original_start;
            record("long_drive", "pass" if shorter else "fail", "The alternative shortens the travel time" if shorter else "The alternative doesn't shorten the travel time", old.id);
        }
    }
    scheduled = sorted(
        (
            (times[item.id][0], times[item.id][1], item)
            for item in nodes
            if (item.blocks_time and (item.id in times))
        ),
        key=lambda (value: any) { (value[0], value[1], value[2].id); }
    );
    transfers = (
        [
            `edge
            for `edge in trip.transfers
            if (old.id not in (`edge.from_id, `edge.to_id))
        ]
        + `list(replacement.transfers)
    );
    pairs = [(e.from_id, e.to_id) for e in transfers];
    if (len(`set(pairs)) != len(pairs)) {
        record("transfer", "fail", "A travel time is entered twice for the same pair of items");
    }
    for `edge in transfers {
        if (
            (`edge.from_id not in ids)
            or (`edge.to_id not in ids)
            or (`edge.from_id == `edge.to_id)
        ) {
            record("transfer", "fail", "A travel time refers to an item that isn't in this trip");
        }
    }
    for (previous, following) in zip(scheduled, scheduled[1:]) {
        (left, right) = (previous[2], following[2]);
        gap = (following[0] - previous[1]).total_seconds() / 60;
        record(
            "overlap",
            "fail" if (gap < 0) else "pass",
            f"{left.title} and {right.title} overlap"
                if (gap < 0)
                else f"{left.title} and {right.title} don't overlap",
            left.id,
            right.id
        );
        matches = [
            e
            for e in transfers
            if ((e.from_id == left.id) and (e.to_id == right.id))
        ];
        if not matches {
            record(
                "transfer",
                "unknown",
                f"Travel time from {left.title} to {right.title} is unknown",
                left.id,
                right.id
            );
            continue;
        }
        `edge = matches[0];
        if ((`edge.from_venue != left.venue) or (`edge.to_venue != right.venue)) {
            record(
                "transfer",
                "unknown",
                f"The saved travel time from {left.title} to {right.title} is for different places",
                left.id,
                right.id
            );
        } elif evidence(`edge.evidence, "transfer_evidence", left.id, right.id) {
            if (`edge.minutes is None) {
                record(
                    "transfer",
                    "unknown",
                    f"Travel time from {left.title} to {right.title} is unknown",
                    left.id,
                    right.id
                );
            } elif not _minor(`edge.minutes) {
                record(
                    "transfer",
                    "fail",
                    "Travel time must be zero or more whole minutes",
                    left.id,
                    right.id
                );
            } else {
                record(
                    "transfer",
                    "pass" if (gap >= `edge.minutes) else "fail",
                    f"Enough time to get from {left.title} to {right.title}"
                        if (gap >= `edge.minutes)
                        else f"Not enough time to get from {left.title} to {right.title}",
                    left.id,
                    right.id
                );
            }
        }
    }
    remaining = {key: `set() for key in ids};
    titles = {item.id: item.title for item in nodes};
    for `edge in trip.dependencies {
        if (
            (`edge.from_id not in ids)
            or (`edge.to_id not in ids)
            or not _minor(`edge.buffer_minutes)
        ) {
            record("dependency", "fail", "A linked item or its buffer is invalid");
            continue;
        }
        remaining[`edge.to_id].add(`edge.from_id);
        if ((`edge.from_id in times) and (`edge.to_id in times)) {
            fits = (
                (times[`edge.from_id][1] + timedelta(minutes=`edge.buffer_minutes))
                <= times[`edge.to_id][0]
            );
            record(
                "dependency",
                "pass" if fits else "fail",
                (f"{titles.get(`edge.from_id)} ends in time for {titles.get(`edge.to_id)}" if fits
                    else f"{titles.get(`edge.from_id)} doesn't end in time for {titles.get(`edge.to_id)}"),
                `edge.from_id,
                `edge.to_id
            );
        }
    }
    while remaining {
        ready = {
            key
            for (key, deps) in remaining.items()
            if not deps
        };
        if not ready {
            record("dependency_cycle", "fail", "Linked items form a loop");
            break;
        }
        remaining = {
            key: (deps - ready)
            for (key, deps) in remaining.items()
            if (key not in ready)
        };
    }
    retained = old.paid_minor if replacement.action == "replace" else 0;
    if replacement.action == "replace" and old.committed and (old.cost_minor is None or old.paid_minor is None or old.paid_minor < old.cost_minor) {
        record("unpaid_commitment", "unknown", f"{old.title} is booked but not fully paid; its cancellation terms are needed to know the cost", old.id);
        known_costs = False;
    }
    if (retained is None) {
        record("original_payment", "unknown", f"The amount already paid for {old.title} is unknown");
        known_costs = False;
    } elif (
        not _minor(retained)
        or (
            (old.cost_minor is not None)
            and _minor(old.cost_minor)
            and (retained > old.cost_minor)
        )
    ) {
        record("original_payment", "fail", f"The amount paid for {old.title} is invalid");
        known_costs = False;
    }
    if ((old.currency != trip.currency) and (retained != 0)) {
        record("original_payment", "unknown", f"{old.title} was paid in a different currency");
        known_costs = False;
    }
    if not _minor(trip.reserve_minor) {
        record("reserve", "fail", "The budget reserve must be zero or more");
        known_costs = False;
    }
    if not _minor(trip.extra_cost_minor) {
        record("other_costs", "fail", "Other trip costs must be zero or more");
        known_costs = False;
    }
    total = None;
    if known_costs {
        lines = [{"id": item.id, "trip_id": trip.id, "title": item.title, "category": item.category,
            "cost_cents": item.cost_minor, "paid": bool(item.paid_minor), "done": item.completed} for item in nodes];
        extra_id = "retained:" + old.id;
        while any(line["id"] == extra_id for line in lines) { extra_id = "_" + extra_id; }
        lines.append({"id": extra_id, "trip_id": trip.id, "title": "Retained original payment",
            "category": "expense", "cost_cents": retained, "paid": True, "done": False});
        extra_id = "other:" + extra_id;
        while any(line["id"] == extra_id for line in lines) { extra_id = "_" + extra_id; }
        if trip.extra_items and sum(item["cost_cents"] for item in trip.extra_items) == trip.extra_cost_minor {
            lines.extend(dict(item) for item in trip.extra_items);
        } else {
            lines.append({"id": extra_id, "trip_id": trip.id, "title": "Other trip costs",
                "category": "expense", "cost_cents": trip.extra_cost_minor, "paid": False, "done": False});
        }
        ledger_budget = trip.budget_minor if _minor(trip.budget_minor) else 0;
        ledger = to_plain(build_ledger({"id": trip.id, "currency": trip.currency, "budget_cents": ledger_budget}, lines, trip.reserve_minor));
        total = ledger["planned_cents"] + ledger["contingency_cents"];
    }
    if (trip.budget_minor is None) {
        record("budget", "unknown", "No trip budget is set");
    } elif not _minor(trip.budget_minor) {
        record("budget", "fail", "The trip budget must be zero or more");
    } elif (total is None) {
        record("budget", "unknown", "The full trip cost can't be calculated yet");
    } else {
        record(
            "budget",
            "pass" if (total <= trip.budget_minor) else "fail",
            f"Trip total {_amount(total, trip.currency)} (with reserve and amounts already paid) is "
            + ("within" if total <= trip.budget_minor else "over") + f" the {_amount(trip.budget_minor, trip.currency)} budget"
        );
    }
    return finish(total, retained);
}
