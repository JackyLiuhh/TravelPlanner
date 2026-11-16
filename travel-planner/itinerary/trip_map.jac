"""The map workspace for saved itineraries, transport and disruptions."""
import from server.main { load_trip_map }
import from itinerary.actions { focusItineraryControl }
import from itinerary.map_land { landPolygons }
import from itinerary.map_geometry { mapViewport, screenPoint, screenRoute, drawTripMap }
import from itinerary.map_scene { mapScene }
import from itinerary.map_route_editor { MapRouteEditor }
import from itinerary.presentation { planTitle, moneyLabel, shiftLabel }
import from itinerary.review { itinerarySchedule }
import from itinerary.flight_card { FlightCard }
import from itinerary.map_overview { mapOverview, routePath }

def markerStyle(point: any) -> any {
    return {"left": str(point["x"]) + "px", "top": str(point["y"]) + "px"};
}

def inside(point: any, width: int, height: int) -> bool {
    return 18 < point["x"] < width - 18 and 63 < point["y"] < height - 55;
}

def toneLabel(tone: str) -> str {
    return "Disruption" if tone == "disruption" else "Needs confirmation" if tone == "check" else
        "Plan B preview" if tone == "preview" else "Planned";
}

def firstOrNone(matches: any) -> any {
    return matches[0] if len(matches) > 0 else None;
}

def endpointLabel(name: str, travel: any) -> str {
    city = name.split(",")[0].strip().lower();
    departing = any(leg["direction"] == "Departure" and leg["from"].split(",")[0].strip().lower() == city for leg in travel);
    returning = any(leg["direction"] == "Return" and leg["to"].split(",")[0].strip().lower() == city for leg in travel);
    return "Departure & return" if departing and returning else "Departure" if departing else "Return" if returning else "";
}

def routeDirection(id: str, travel: any) -> str {
    for leg in travel { if leg["id"] == id { return leg["direction"]; } }
    return "";
}

def routeEstimated(id: str, flights: any) -> bool {
    listing = flights.get(id);
    return not bool(listing and listing.get("source_url"));
}

def savedLocationApplies(item: any, preview: any) -> bool {
    if not preview or item.id not in preview["changes"] { return True; }
    return preview["changes"][item.id]["venue"] == item.location;
}

def:pub TripMap(trip: any, items: any, revision: int, preview: any, disabled: bool,
    onReview: any, onPlanB: any, onStop: any, onTimeline: any, onSample: any,
    journey: any = None, draft: any = None, working: bool = False, day: str = "", onDay: any = None, onDraft: any = None) -> JsxElement {
    has data: any = {}, loadError: str = "", width: int = 800, height: int = 530,
        zoom: float = 1.0, panX: float = 0.0, panY: float = 0.0, popup: any = None, hoverRoute: str = "",
        popupTab: str = "plan", editing: bool = False,
        land: Ref[any] = Ref(None), observer: Ref[any] = Ref(None), interval: Ref[int] = Ref(0),
        alive: Ref[bool] = Ref(False), sequence: Ref[int] = Ref(0), drag: Ref[any] = Ref(None),
        onWindowFocus: Ref[any] = Ref(None);
    browser: any = window;
    stageId = "trip-map-" + trip.id;
    closeId = stageId + "-close";
    async def reload -> None {
        sequence.current += 1; token = sequence.current;
        try {
            fresh = await load_trip_map(trip_id=trip.id, preview_journey=draft.get("journey") if draft and draft.get("journey") else journey);
            if alive.current and sequence.current == token { data = fresh; loadError = ""; }
        } except Exception {
            if alive.current and sequence.current == token {
                data = {}; loadError = "Could not refresh map details.";
            }
        }
    }
    def resize -> None {
        stage: any = document.getElementById(stageId);
        if stage { width = stage.clientWidth; height = stage.clientHeight; }
    }
    def resetView -> None { zoom = 1.0; panX = 0.0; panY = 0.0; }
    def closePopup(restore: bool = True) -> None {
        if popup is None { return; }
        control = popup["control"]; popup = None; editing = False;
        if restore { window.requestAnimationFrame(lambda { focusItineraryControl(control); }); }
    }
    def openPopup(kind: str, id: str, control: str) -> None {
        popup = {"kind": kind, "id": id, "control": control}; popupTab = "plan"; editing = False;
    }
    def startPan(e: any) -> None {
        if e.button != 0 { return; }
        drag.current = {"x": e.clientX, "y": e.clientY, "left": panX, "top": panY, "moved": False};
        e.currentTarget.setPointerCapture(e.pointerId);
    }
    def movePan(e: any) -> None {
        if drag.current is None { return; }
        dx = e.clientX - drag.current["x"]; dy = e.clientY - drag.current["y"];
        if abs(dx) + abs(dy) < 4 and not drag.current["moved"] { return; }
        drag.current["moved"] = True;
        panX = min(width * 3.0, max(-width * 3.0, drag.current["left"] + dx));
        panY = min(height * 3.0, max(-height * 3.0, drag.current["top"] + dy));
    }
    def endPan -> None {
        if drag.current is not None and not drag.current["moved"] { closePopup(False); }
        drag.current = None;
    }

    can with entry {
        alive.current = True; land.current = browser.JSON.parse(landPolygons());
        resize();
        observer.current = new(browser.ResizeObserver, resize);
        observer.current.observe(document.getElementById(stageId));
        onWindowFocus.current = lambda { reload(); };
        window.addEventListener("focus", onWindowFocus.current);
        interval.current = window.setInterval(lambda { if not browser.document.hidden { reload(); } }, 45000);
    }
    can with exit {
        alive.current = False; sequence.current += 1;
        if observer.current { observer.current.disconnect(); }
        browser.clearInterval(interval.current);
        window.removeEventListener("focus", onWindowFocus.current);
    }
    can with [items, revision, journey, draft] entry { reload(); }
    can with [popup] entry { if popup is not None { focusItineraryControl(closeId); } }

    overview = mapOverview(trip, items, data, journey, draft);
    mapItems = overview["items"]; mapData = overview["data"];
    travel = overview.get("travel", []);
    visibleItems = [item for item in mapItems if not day or item.date == day];
    routeItems = [item for item in mapItems if not day or item.date == day or any(leg["id"] == item.id for leg in travel)];
    dates: any = [];
    for item in mapItems { if item.date and item.date not in dates { dates.append(item.date); } }
    dates = sorted(dates);
    locatedItems = [item for item in mapItems if not any(item.journey.get("stop_id") == place["id"] for place in overview["unlocated"])];
    scene = mapScene(trip.destination, locatedItems, mapData, preview);
    cities = scene["cities"]; pins = scene["pins"]; routeData = scene["routes"];
    mappedRoutes: any = [{"id": item.id, "item": item, "route": routeData[item.id]["route"], "tone": scene["tones"][item.id],
        "direction": routeDirection(item.id, travel), "estimated": routeEstimated(item.id, mapData.get("flights", {}))}
        for item in routeItems if item.id in routeData and routeData[item.id]["route"] is not None and
            savedLocationApplies(item, preview) and (not preview or item.id not in preview["changes"] or
                preview["changes"][item.id]["title"] == item.title)];
    pointList = [city["point"] for city in cities] + [pins[item.id] for item in mapItems if item.id in pins];
    view = mapViewport(pointList, width, height, zoom, panX, panY);
    cityMarkers: any = [];
    for city in cities {
        point = screenPoint(city["point"], view);
        cluster = firstOrNone([record for record in cityMarkers if
            abs(record["screen"]["x"] - point["x"]) + abs(record["screen"]["y"] - point["y"]) < 42 and
            abs(record["data"]["point"]["lat"] - city["point"]["lat"]) + abs(record["data"]["point"]["lon"] - city["point"]["lon"]) < 1.0]);
        if cluster is not None {
            for id in city["items"] { if id not in cluster["data"]["items"] { cluster["data"]["items"].append(id); } }
        } else { cityMarkers.append({"data": {**city, "items": [id for id in city["items"]]}, "screen": point}); }
    }
    routeMarkers: any = [{**record, "curve": screenRoute(record["route"], view)} for record in mappedRoutes];
    placeMarkers = [{"item": item, "screen": screenPoint(pins[item.id], view), "tone": scene["tones"][item.id]}
        for item in visibleItems if item.id in pins and savedLocationApplies(item, preview) and
            not any(record["id"] == item.id for record in mappedRoutes)];
    visiblePlaces = [record for record in placeMarkers if inside(record["screen"], width, height) and
        not any(record["item"].id in city["data"]["items"] and
            abs(city["screen"]["x"] - record["screen"]["x"]) + abs(city["screen"]["y"] - record["screen"]["y"]) < 38
            for city in cityMarkers)];
    activeId = popup["id"] if popup else "";
    activeKind = popup["kind"] if popup else "";
    can with [width, height, zoom, panX, panY, data, items, preview, activeId, hoverRoute, journey, draft, day] entry {
        canvas: any = document.getElementById(stageId + "-canvas");
        if canvas and land.current is not None { drawTripMap(canvas, land.current, view, routeMarkers, width, height, hoverRoute or activeId); }
    }
    selectedCity = firstOrNone([city for city in cityMarkers if city["data"]["id"] == activeId and activeKind == "city"]);
    selectedRoute = firstOrNone([route for route in routeMarkers if route["id"] == activeId and activeKind == "route"]);
    selectedItem = firstOrNone([item for item in mapItems if item.id == activeId and
        (activeKind == "route" or (activeKind == "place" and (not day or item.date == day)))]);
    selectedTravel = firstOrNone([leg for leg in travel if leg["id"] == activeId and activeKind == "route"]);
    selectedPlace = firstOrNone([record for record in placeMarkers if record["item"].id == activeId and activeKind == "place"]);
    ids = selectedCity["data"]["items"] if selectedCity is not None else [activeId] if selectedItem is not None else [];
    selectedStops = sorted([item for item in visibleItems if item.id in ids], key=lambda (item: any) { return item.date + item.time; });
    selectedProvisional = activeId in overview["provisional"];
    selectedDraft = activeId in overview["changed"];
    alerts = scene["alerts"];
    relatedAlerts = [record for record in alerts if any(id in record["affected"] for id in ids)];
    relatedPlans = [plan for plan in mapData.get("plans", []) if any(change["replaces_id"] in ids for change in plan["replacements"])];
    activeAlerts = [record for record in alerts if record["risk"]["status"] == "flagged"];
    anchor = selectedCity["screen"] if selectedCity is not None else selectedRoute["curve"]["marker"] if selectedRoute is not None
        else selectedPlace["screen"] if selectedPlace is not None else {"x": width - 80, "y": 72};
    popupWidth = min(width - 24.0, 346.0);
    popupLeft = anchor["x"] + 23.0 if anchor["x"] + popupWidth + 35.0 <= width else anchor["x"] - popupWidth - 23.0;
    popupTop = max(68.0, min(anchor["y"] - 52.0, height - 342.0));
    panelStyle = {"left": str(max(12.0, min(width - popupWidth - 12.0, popupLeft))) + "px",
        "top": str(popupTop) + "px"};
    dialogTitle = selectedCity["data"]["point"]["label"] if selectedCity is not None else selectedItem.title if selectedItem is not None
        else "Trip alerts" if activeKind == "alerts" else "Map details";

    def reviewStop(id: str, reason: str) -> None {
        control = popup["control"]; closePopup(False); onReview(id, reason, control);
    }
    def showAlert(record: any) -> None {
        risk = record["risk"]; control = popup["control"];
        closePopup(False);
        onReview(risk["node_ids"][0], risk.get("summary", "A reported trip disruption"), control);
    }
    def showPlan(option: any) -> None {
        control = popup["control"];
        compatible = [plan for plan in relatedPlans if len(plan["risk_ids"]) == len(option["risk_ids"]) and
            all(id in option["risk_ids"] for id in plan["risk_ids"])];
        closePopup(False);
        onPlanB(option["replacements"][0]["replaces_id"], option["risk_ids"], compatible, option["id"], control);
    }
    def jumpTo(id: str) -> None {
        closePopup(False);
        if id in overview["changed"] or id in overview["provisional"] { if onDraft { onDraft(); } }
        else { onStop(id); }
    }
    def findAlternative(id: str) -> None {
        control = popup["control"]; closePopup(False); onPlanB(id, [], [], "", control);
    }
    def inspectStop(item: any) -> None {
        openPopup("route" if item.category == "transport" else "place", item.id, stageId + "-details");
    }
    def chooseDay(value: str) -> None { closePopup(False); if onDay { onDay(value); } }
    can with [draft, day] entry { hoverRoute = ""; closePopup(False); }
    def closeEditor -> None {
        editing = False;
        window.requestAnimationFrame(lambda { focusItineraryControl(closeId); });
    }
    async def routeSaved -> None { await reload(); resetView(); closeEditor(); }

    <div className="trip-map-explorer">
        <div className="map-explorer-bar">
            <div><strong>Explore your trip</strong><p>Choose a location for its activities, or a route for travel details.</p></div>
            {(<div className="map-working-note" role="status">Preparing your trip… You can keep exploring.</div>) if working else None}
            {(<button className="map-draft-link" type="button" onClick={onDraft}>Review this draft ↗</button>) if draft and not working and onDraft else None}
        </div>
        {(<div className="map-days" role="group" aria-label="Map days">
            <button type="button" aria-pressed={not day} onClick={lambda { chooseDay(""); }}>All days</button>
            {[<button type="button" key={date} aria-label={"Map day " + date} aria-pressed={day == date}
                onClick={lambda { chooseDay(date); }}>{new(browser.Date, date + "T12:00:00").toLocaleDateString("en-US", {"weekday": "short", "month": "short", "day": "numeric"})}</button> for date in dates]}
        </div>) if len(dates) > 0 and onDay else None}
    <section className="trip-map" id={stageId} aria-label="Trip map" data-preview={bool(preview and preview["choice"])}
        data-working={working} data-source={"draft" if draft else "saved" if len(items) > 0 else "overview"} data-day={day} data-travel={len(travel) > 0}
        onKeyDown={lambda (e: any) { if e.key == "Escape" and popup { e.stopPropagation(); closePopup(); } }}>
        <canvas className="map-canvas" id={stageId + "-canvas"} aria-hidden="true"
            onPointerDown={startPan} onPointerMove={movePan} onPointerUp={endPan}
            onPointerCancel={lambda { drag.current = None; }}/>
        <svg className="map-route-targets" viewBox={"0 0 " + str(width) + " " + str(height)} width={width} height={height}>
            {[<path key={record["id"]} className="map-route-hit" data-route={record["id"]} d={routePath(record["curve"])}
                data-direction={record["direction"]} data-estimated={record["estimated"]}
                fill="none" stroke="transparent" strokeWidth={20} role="button" tabIndex={0}
                aria-label={"Open route " + record["item"].title}
                onPointerEnter={lambda { hoverRoute = record["id"]; }} onPointerLeave={lambda { hoverRoute = ""; }}
                onFocus={lambda { hoverRoute = record["id"]; }} onBlur={lambda { hoverRoute = ""; }}
                onClick={lambda { openPopup("route", record["id"], stageId + "-route-" + record["id"]); }}
                onKeyDown={lambda (e: any) { if e.key in ["Enter", " "] { e.preventDefault(); openPopup("route", record["id"], stageId + "-route-" + record["id"]); } }}/>
                for record in routeMarkers]}
        </svg>
        <header className="map-top">
            <div className="map-heading"><span aria-hidden="true">⌖</span><div><h2>Trip map</h2>
                <p>{str(len(cityMarkers)) + (" location" if len(cityMarkers) == 1 else " locations") + " · " +
                    str(len(mappedRoutes)) + (" route" if len(mappedRoutes) == 1 else " routes")}</p></div></div>
            <div className="map-tools">
                {(<button type="button" id={stageId + "-alerts"} className="map-alert-button" data-active={len(activeAlerts) > 0}
                    aria-expanded={activeKind == "alerts"}
                    onClick={lambda { openPopup("alerts", "", stageId + "-alerts"); }}>
                    {str(len(alerts)) + (" alert" if len(alerts) == 1 else " alerts")}</button>) if len(alerts) > 0 else None}
                <button type="button" id={stageId + "-details"} aria-expanded={activeKind == "details"}
                    onClick={lambda { openPopup("details", "", stageId + "-details"); }}>Map details</button>
            </div>
        </header>
        {(<div className="map-travel-strip" role="group" aria-label="Departure and return flights">
            {[<button type="button" className="map-travel-leg" key={leg["direction"]} id={stageId + "-travel-" + leg["direction"].lower()}
                data-direction={leg["direction"]} data-estimated={leg["estimated"]} data-active={activeId == leg["id"] or hoverRoute == leg["id"]}
                aria-label={leg["direction"] + (" flight: " if leg.get("mode", "flight") == "flight" else " travel: ") + leg["from"] + " → " + leg["to"]}
                aria-expanded={activeKind == "route" and activeId == leg["id"]}
                onPointerEnter={lambda { hoverRoute = leg["id"]; }} onPointerLeave={lambda { hoverRoute = ""; }}
                onFocus={lambda { hoverRoute = leg["id"]; }} onBlur={lambda { hoverRoute = ""; }}
                onClick={lambda { openPopup("route", leg["id"], stageId + "-travel-" + leg["direction"].lower()); }}>
                <span className="map-travel-label"><span aria-hidden="true">{"✈" if leg.get("mode", "flight") == "flight" else "↗"}</span>{leg["direction"]}</span>
                <strong>{leg["from"] + " → " + leg["to"]}</strong>
                <small>{("Estimated flight" if leg["estimated"] else "Web-listed flight") if leg.get("mode", "flight") == "flight" else "Planned " + leg["mode"] + " route"}</small>
            </button> for leg in travel]}
        </div>) if len(travel) > 0 else None}
        {[<button type="button" className="map-city-pin" key={record["data"]["id"]} style={markerStyle(record["screen"])}
            id={stageId + "-city-" + record["data"]["id"]} data-tone={record["data"]["tone"]}
            aria-label={"Explore " + record["data"]["point"]["label"]}
            aria-expanded={activeKind == "city" and activeId == record["data"]["id"]}
            onClick={lambda { openPopup("city", record["data"]["id"], stageId + "-city-" + record["data"]["id"]); }}>
            <span className="map-pin-core" aria-hidden="true"/><span className="map-city-label">{record["data"]["point"]["label"]}
                {(<small className="map-endpoint-label">{endpointLabel(record["data"]["point"]["label"], travel)}</small>)
                    if endpointLabel(record["data"]["point"]["label"], travel) else None}
                {(<small>{str(len([item for item in visibleItems if item.id in record["data"]["items"] and item.category != "transport"])) + " activities"}</small>)
                    if any(item.id in record["data"]["items"] and item.category != "transport" for item in visibleItems) else None}</span>
        </button> for record in cityMarkers if inside(record["screen"], width, height)]}
        {[<button type="button" className="map-route-pin" key={record["id"]} style={markerStyle(record["curve"]["marker"])}
            id={stageId + "-route-" + record["id"]} data-tone={record["tone"]} data-direction={record["direction"]}
            data-estimated={record["estimated"]} data-active={activeId == record["id"] or hoverRoute == record["id"]}
            aria-label={("Flight route: " if record["route"]["kind"] == "flight" else "Ground route: ") + record["item"].title}
            aria-expanded={activeKind == "route" and activeId == record["id"]}
            onPointerEnter={lambda { hoverRoute = record["id"]; }} onPointerLeave={lambda { hoverRoute = ""; }}
            onFocus={lambda { hoverRoute = record["id"]; }} onBlur={lambda { hoverRoute = ""; }}
            onClick={lambda { openPopup("route", record["id"], stageId + "-route-" + record["id"]); }}>
            <span className="map-route-symbol" aria-hidden="true" style={ {"transform": "rotate(" + str(record["curve"].get("angle", 0)) + "deg)"} if record["route"]["kind"] == "flight" else {}}>
                {(<svg className="map-flight-glyph" viewBox="-16 -16 32 32" focusable="false"><path d="M14 0 2 -3 -4 -13 -8 -13 -3 -2 -10 -4 -13 -1 -7 2 -9 7 -6 7 0 2Z"/></svg>) if record["route"]["kind"] == "flight" else "↗"}
            </span>
            {(<span className="map-route-caption">{"Outbound" if record["direction"] == "Departure" else "Return"}</span>) if record["direction"] else None}
            {(<span className="map-route-shift">{shiftLabel(preview["time_changes"][record["id"]])}</span>)
                if preview and record["id"] in preview["time_changes"] else None}
        </button> for record in routeMarkers if inside(record["curve"]["marker"], width, height)]}
        {[<button type="button" className="map-place-pin" key={record["item"].id} style={markerStyle(record["screen"])}
            id={stageId + "-place-" + record["item"].id} data-tone={record["tone"]}
            aria-label={"Explore stop " + record["item"].title} aria-expanded={activeKind == "place" and activeId == record["item"].id}
            onClick={lambda { openPopup("place", record["item"].id, stageId + "-place-" + record["item"].id); }}>
            <span aria-hidden="true">•</span>
        </button> for record in visiblePlaces]}
        {(<div className="map-empty"><strong>{trip.destination}</strong>
            <p>Locations without coordinates are listed in Map details. Your activities are still available there.</p>
            <button type="button" className="map-primary" onClick={lambda { openPopup("details", "", stageId + "-details"); }}>Explore locations</button>
        </div>) if len(pointList) == 0 and popup is None else None}
        {(<div className="map-unlocated-note"><button type="button" onClick={lambda { openPopup("details", "", stageId + "-details"); }}>
            {str(len(overview["unlocated"])) + " location(s) not mapped · View list"}</button></div>) if len(overview["unlocated"]) > 0 and len(pointList) > 0 else None}
        {(<div className="map-load-error" role="status">{loadError}
            <button type="button" onClick={reload}>Retry</button></div>) if loadError else None}
        {(<div className="map-preview-tag" role="status">Plan B preview · Saved itinerary unchanged</div>) if preview and preview["choice"] else None}
        <div className="map-zoom" role="group" aria-label="Map view controls">
            <button type="button" aria-label="Zoom in" disabled={zoom >= 4} onClick={lambda { zoom = min(4.0, zoom * 1.35); }}>+</button>
            <button type="button" aria-label="Zoom out" disabled={zoom <= 0.55} onClick={lambda { zoom = max(0.55, zoom / 1.35); }}>−</button>
            <button type="button" aria-label="Fit all trip points" onClick={resetView}>⤢</button>
        </div>
        <footer className="map-footer">
            <div className="map-legend">
                {(<span data-tone="planned">{"Draft preview" if draft else "Planned"}</span>) if len(travel) == 0 else None}
                {(<span className="map-route-key" data-direction="Departure">Outbound</span>) if any(leg["direction"] == "Departure" for leg in travel) else None}
                {(<span className="map-route-key" data-direction="Return">Return</span>) if any(leg["direction"] == "Return" for leg in travel) else None}
                {(<span className="map-estimate-key">Dashed = estimated</span>) if any(record["estimated"] and record["route"]["kind"] == "flight" for record in routeMarkers) else None}
                {(<span data-tone="disruption">Disruption</span>) if len(activeAlerts) > 0 else None}
                {(<span data-tone="check">Needs confirmation</span>) if len(alerts) > len(activeAlerts) else None}
                {(<span data-tone="preview">Plan B preview</span>) if preview and preview["choice"] else None}
            </div>
            <div className="map-footer-links"><small>Natural Earth</small><button type="button" onClick={onTimeline}>Timeline ↓</button></div>
        </footer>
        {(<section className="map-popup" style={panelStyle} role="dialog" aria-label={dialogTitle} data-kind={activeKind}>
            <header className="map-popup-heading">
                <div><p>{ "CITY" if activeKind == "city" else ("ESTIMATED ROUTE" if selectedProvisional else "DRAFT TRANSPORT" if selectedDraft else "SAVED TRANSPORT") if activeKind == "route" else
                    "ITINERARY STOP" if activeKind == "place" else "TRIP MAP"}</p><h3>{dialogTitle}</h3></div>
                <button type="button" id={closeId} aria-label="Close map details" onClick={lambda { closePopup(); }}>×</button>
            </header>
            {(<div className="map-popup-tabs" role="group" aria-label="Map plan views">
                <button type="button" aria-pressed={popupTab == "plan"} onClick={lambda { popupTab = "plan"; }}>{"Draft plan" if draft else "Saved plan"}</button>
                <button type="button" aria-pressed={popupTab == "backup"} onClick={lambda { popupTab = "backup"; }}>Plan B
                    {(" · " + str(len(relatedPlans))) if len(relatedPlans) > 0 else ""}</button>
            </div>) if activeKind in ["city", "route", "place"] and not editing and not draft and not selectedProvisional else None}
            <div className="map-popup-content">
                {(<MapRouteEditor trip_id={trip.id} item={selectedItem} data={routeData.get(activeId, {})}
                    onSaved={routeSaved} onCancel={closeEditor}/>) if editing and selectedItem is not None else None}
                {(<div className="map-popup-stack">
                    {(<FlightCard flight={mapData["flights"][activeId]}/>) if mapData.get("flights", {}).get(activeId) else None}
                    {(<div className="map-endpoints"><strong>{selectedRoute["route"]["from"]["label"]}</strong>
                        <span aria-hidden="true">{ "✈" if selectedRoute["route"]["kind"] == "flight" else "→"}</span>
                        <strong>{selectedRoute["route"]["to"]["label"]}</strong></div>) if selectedRoute is not None else
                        (<div className="map-endpoints"><strong>{selectedTravel["from"]}</strong><span aria-hidden="true">{"✈" if selectedTravel.get("mode", "flight") == "flight" else "→"}</span><strong>{selectedTravel["to"]}</strong></div>) if selectedTravel is not None else None}
                    {(<p className="map-estimated-flight">Estimated flight · No verified schedule or fare</p>) if selectedTravel and selectedTravel["estimated"] and selectedTravel.get("mode", "flight") == "flight" else None}
                    <p>{itinerarySchedule(selectedItem.date, selectedItem.time) + (" · " + selectedItem.journey["zone"] if selectedItem.journey.get("zone") else "")}</p>
                    {(<p>{"Arrives " + selectedItem.journey["arrival_date"] + " " + selectedItem.journey["arrival_time"] + " · " + selectedItem.journey["end_zone"]}</p>) if selectedItem.journey.get("arrival_date") else None}
                    {(<p className="map-proposed-time">{"Proposed " + preview["changes"][activeId]["start"]["local"].replace("T", " ")}</p>)
                        if preview and activeId in preview["changes"] else None}
                    {(<p>{ "Booking reference " + selectedItem.reference}</p>) if selectedItem.reference else None}
                    <p className="map-muted">{ "Planned path · approximate" if selectedRoute is not None else "Location not mapped yet."}</p>
                    {(<p>{selectedItem.notes}</p>) if selectedItem.notes else None}
                    {(<div className="map-state-pill" data-tone={scene["tones"][activeId]}>{toneLabel(scene["tones"][activeId])}</div>)}
                    {(<p className="map-risk-copy">{relatedAlerts[0]["risk"]["summary"]}</p>) if len(relatedAlerts) > 0 else None}
                    <div className="map-popup-actions">
                        {(<button type="button" className="map-primary" onClick={lambda { jumpTo(activeId); }}>{"Review this draft" if selectedDraft else "Show in itinerary"}</button>) if not selectedProvisional else None}
                        {(<button type="button" className="map-secondary" disabled={disabled} onClick={lambda { reviewStop(activeId, "timing"); }}>Report a delay</button>) if not selectedDraft and not selectedProvisional else None}
                        {(<button type="button" className="map-secondary" disabled={disabled} onClick={lambda { editing = True; }}>
                            { "Edit route" if selectedRoute is not None else "Add route"}</button>) if not selectedItem.journey.get("leg_id") and not selectedDraft and not selectedProvisional else None}
                    </div>
                </div>) if activeKind == "route" and selectedItem is not None and popupTab == "plan" and not editing else None}
                {(<div className="map-popup-stack">
                    {(<p className="map-risk-copy">{str(len(relatedAlerts)) + (" alert on this plan" if len(relatedAlerts) == 1 else " alerts on this plan")}</p>) if len(relatedAlerts) > 0 else None}
                    {(<p className="map-muted">No stops are associated with this city yet.</p>) if len(selectedStops) == 0 else None}
                    <p className="map-muted">{str(len(selectedStops)) + (" stop on this day" if day else " stops across your trip")}</p>
                    {[<button type="button" className="map-list-row" key={item.id} onClick={lambda { inspectStop(item); }}>
                        <span className="map-status-dot" data-tone={scene["tones"][item.id]} aria-hidden="true"/>
                        <span><strong>{item.title}</strong><small>{itinerarySchedule(item.date, item.time)}</small></span><span aria-hidden="true">↗</span>
                    </button> for item in selectedStops]}
                </div>) if activeKind == "city" and popupTab == "plan" else None}
                {(<div className="map-popup-stack">
                    <p>{itinerarySchedule(selectedItem.date, selectedItem.time)}</p>
                    {(<p><strong>{selectedItem.location}</strong></p>) if selectedItem.location else None}
                    <p>{selectedItem.notes or "No extra notes for this stop."}</p>
                    <p>{"Cost not estimated yet" if activeId in overview["unknown_prices"] else moneyLabel(selectedItem.cost_cents, trip.currency) + " · estimated cost"}</p>
                    <button type="button" className="map-primary" onClick={lambda { jumpTo(activeId); }}>{"Review this draft" if selectedDraft else "Show in itinerary"}</button>
                    {(<button type="button" className="map-secondary" disabled={disabled} onClick={lambda { findAlternative(activeId); }}>Find alternatives</button>) if not selectedDraft else None}
                </div>) if activeKind == "place" and selectedItem is not None and popupTab == "plan" else None}
                {(<div className="map-popup-stack">
                    {(<p className="map-muted">No current backup options. Choose a recorded alert to find alternatives.</p>) if len(relatedPlans) == 0 and len(relatedAlerts) > 0 else None}
                    {(<p className="map-muted">No current backup options for these stops.</p>) if len(relatedPlans) == 0 and len(relatedAlerts) == 0 else None}
                    {[<button type="button" className="map-list-row map-option" key={option["id"]} disabled={disabled}
                        onClick={lambda { showPlan(option); }}>
                        <span><strong>{planTitle(option)}</strong><small>{moneyLabel(option["comparison"]["projected_total_minor"], trip.currency) +
                            (" · Ready for review" if option["selectable"] else " · Needs confirmation")}</small></span><span aria-hidden="true">→</span>
                    </button> for option in relatedPlans[:5]]}
                    {(<button type="button" className="map-secondary" disabled={disabled}
                        onClick={lambda { reviewStop(selectedStops[0].id, ""); }}>Review a change</button>) if len(relatedAlerts) == 0 and len(selectedStops) > 0 else None}
                </div>) if activeKind in ["city", "route", "place"] and popupTab == "backup" else None}
                {[<div className="map-alert-row" key={record["risk"]["id"]} data-tone={ "disruption" if record["risk"]["status"] == "flagged" else "check"}>
                    <strong>{record["risk"]["summary"]}</strong>
                    <small>{str(len(record["affected"])) + (" stop to check" if len(record["affected"]) == 1 else " stops to check")}</small>
                    <button type="button" className="map-secondary" disabled={disabled} onClick={lambda { showAlert(record); }}>Review alternatives →</button>
                </div> for record in (alerts if activeKind == "alerts" else relatedAlerts if popupTab == "backup" else [])
                    if not editing]}
                {(<div className="map-popup-stack">
                    <p className="map-muted">Browse locations, activities and travel routes.</p>
                    {[<div className="map-unlocated-location" key={place["id"]}><strong>{place["city"]}</strong><small>Location not mapped yet</small></div> for place in overview["unlocated"]]}
                    {(<p className="map-muted">Add an itinerary item to get started.</p>) if len(mapItems) == 0 else None}
                    {[<button type="button" className="map-list-row" key={item.id} onClick={lambda { inspectStop(item); }}><span><strong>{item.title}</strong><small>{ "Flight or ground route" if item.category == "transport"
                        else "Itinerary stop"}</small></span><span aria-hidden="true">↗</span></button> for item in visibleItems]}
                    <button type="button" className="map-secondary" disabled={disabled} onClick={onSample}>Explore sample trip</button>
                </div>) if activeKind == "details" else None}
            </div>
        </section>) if popup is not None else None}
    </section>
    </div>
}
