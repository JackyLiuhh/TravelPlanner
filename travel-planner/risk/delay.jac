"""Delay impact: what a late-running item does to the items scheduled after it.

The delay is carried forward along the itinerary's links. Each linked item gets
the same time it needs after the previous one as the tight-connection rule uses
(a stated minimum, a travel estimate, or the standard buffer). An item is pushed
only when it can't start on time; a stay keeps its checkout and only checks in
later. Missing times leave an item unresolved, and later items on the same day
that aren't linked are listed as unchecked, never as fine.
"""
import from datetime { datetime, timedelta }
import from schema.common { local_to_instant, minutes_between, to_local_text }
import from schema.itinerary { ItineraryNode, ItineraryEdge, NodeKind, BookingStatus, EdgeRelation }
import from schema.bundle { TripBundle }
import from risk.config { RiskConfig }

"""How one later item is affected. status is pushed, on_time, unresolved or not_linked."""
obj DelayEffect {
    has node_id: str;
    has title: str;
    has status: str;
    has minutes_late: int | None = None;
    has spare_minutes: int | None = None;
    has new_start_local: str = "";
    has after_id: str = "";
    has reason: str = "";
    has evidence_ids: list[str] = [];
}

obj DelayImpact {
    has node_id: str;
    has delay_minutes: int;
    has new_end_local: str;
    has effects: list[DelayEffect] = [];
}

def _active(n: ItineraryNode) -> bool {
    return n.booking_status not in [BookingStatus.CANCELLED, BookingStatus.COMPLETED];
}

def _local(instant: datetime, tz: str) -> str { return to_local_text(instant, tz)[:16]; }

"""Minutes needed between src ending and dst starting, and the evidence behind them."""
def _needed(bundle: TripBundle, link: ItineraryEdge, src: ItineraryNode, config: RiskConfig) -> tuple[int, list[str]] {
    needs: list[int] = [];
    evidence: list[str] = [];
    if link.min_transition_minutes is not None { needs.append(link.min_transition_minutes); }
    for est in bundle.travel_estimates {
        if est.from_node_id == src.id and est.to_node_id == link.target_id {
            needs.append(est.minutes);
            evidence.append(est.evidence_id);
        }
    }
    if not needs {
        needs.append(config.flight_arrival_buffer_minutes if src.kind == NodeKind.FLIGHT else config.min_transfer_minutes);
    }
    return (max(needs), evidence);
}

"""Carry a delay of `delay_minutes` on `node_id` forward through the items after it."""
def delay_impact(bundle: TripBundle, node_id: str, delay_minutes: int, config: RiskConfig | None = None) -> DelayImpact {
    cfg = config or RiskConfig();
    delayed = bundle.itinerary.find_node(node_id);
    if delayed is None { raise ValueError(f"unknown item '{node_id}'"); }
    if delay_minutes < 0 { raise ValueError("delay must be zero or more minutes"); }
    scheduled_end = local_to_instant(delayed.end_local, delayed.end_zone());
    late_end = scheduled_end + timedelta(minutes=delay_minutes) if scheduled_end is not None else None;
    impact = DelayImpact(node_id=delayed.id, delay_minutes=delay_minutes,
        new_end_local=_local(late_end, delayed.end_zone()) if late_end is not None else "");
    ends: dict[str, datetime | None] = {delayed.id: late_end};
    queue: list[str] = [delayed.id];
    while queue {
        src = bundle.itinerary.find_node(queue.pop(0));
        if src is None { continue; }
        for link in bundle.itinerary.edges {
            if link.source_id != src.id or link.relation == EdgeRelation.ALTERNATIVE or link.target_id in ends { continue; }
            dst = bundle.itinerary.find_node(link.target_id);
            if dst is None or not _active(dst) { continue; }
            effect = DelayEffect(node_id=dst.id, title=dst.title, status="unresolved", after_id=src.id);
            start = local_to_instant(dst.start_local, dst.tz);
            src_end = ends[src.id];
            ends[dst.id] = None;
            queue.append(dst.id);
            if src_end is None {
                effect.reason = f"{src.title} has no known end time, so the effect on {dst.title} can't be checked.";
            } elif start is None {
                effect.reason = f"{dst.title} has no start time, so the effect of the delay can't be checked.";
            } else {
                (need, evidence) = _needed(bundle, link, src, cfg);
                earliest = src_end + timedelta(minutes=need);
                late = minutes_between(start, earliest);
                end = local_to_instant(dst.end_local, dst.end_zone());
                effect.evidence_ids = sorted(set(evidence));
                if late > 0 {
                    effect.status = "pushed";
                    effect.minutes_late = late;
                    effect.new_start_local = _local(earliest, dst.tz);
                    effect.reason = (f"{dst.title} can't start until {effect.new_start_local[11:]}, "
                        + f"{late} min late ({need} min needed after {src.title}).");
                    # A stay checks in later but keeps its checkout; anything else keeps its length.
                    ends[dst.id] = end if dst.kind == NodeKind.STAY or end is None else end + timedelta(minutes=late);
                } else {
                    effect.status = "on_time";
                    effect.minutes_late = 0;
                    effect.spare_minutes = -late;
                    effect.reason = f"{dst.title} still starts on time with {-late} min to spare.";
                    ends[dst.id] = end;
                }
            }
            impact.effects.append(effect);
        }
    }
    if scheduled_end is not None {
        day = _local(scheduled_end, delayed.end_zone())[:10];
        for n in bundle.itinerary.nodes {
            if n.id in ends or not _active(n) { continue; }
            start = local_to_instant(n.start_local, n.tz);
            if start is None or start < scheduled_end or _local(start, delayed.end_zone())[:10] != day { continue; }
            impact.effects.append(DelayEffect(node_id=n.id, title=n.title, status="not_linked",
                reason=f"{n.title} isn't linked to {delayed.title}, so this delay's effect on it isn't checked."));
        }
    }
    return impact;
}
