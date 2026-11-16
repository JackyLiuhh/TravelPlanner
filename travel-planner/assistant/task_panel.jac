"""Simple AI entry points for alternatives and changed travel plans."""
def:pub AITaskPanel(mode: str, busy: bool, onRun: any) -> JsxElement {
    has details: str = "";
    can with [mode] entry { details = ""; }
    def generate(e: FormEvent) -> None {
        e.preventDefault();
        if busy { return; }
        prompt = "Suggest one practical backup using my saved trip, preferences and budget. Keep existing bookings."
            if mode == "backup" else "Replan my saved trip using reported changes. Keep unaffected bookings and include departure and return travel. If no change is recorded, offer a labeled contingency.";
        if details.strip() { prompt += " My details: " + details.strip(); }
        onRun(mode, prompt);
    }
    <section className="replan-workspace ai-task-panel" aria-label={"AI backup plans" if mode == "backup" else "AI replanning"}>
        <div className="card replan-intro">
            <h2>{"Find a backup plan" if mode == "backup" else "Replan your trip"}</h2>
            <p>{"Get a practical alternative using your saved itinerary and preferences." if mode == "backup" else "Get an updated itinerary using your saved trip and any changes you describe."}</p>
            <form onSubmit={generate}>
                <label htmlFor={"ai-task-details-" + mode}>{"Anything to focus on? (optional)" if mode == "backup" else "What changed? (optional)"}</label>
                <textarea id={"ai-task-details-" + mode} value={details} rows={3} maxLength={2000} disabled={busy}
                    placeholder={"For example: indoor activities if it rains" if mode == "backup" else "For example: my outbound flight is delayed by two hours"}
                    onChange={lambda (e: ChangeEvent) { details = e.target.value; }}/>
                <p className="section-caption">Your saved dates, locations, budget and preferences are included automatically. Leave this blank to use them as they are.</p>
                <button className="primary" type="submit" disabled={busy}>{"Preparing your draft…" if busy else "Generate backup plan ↗" if mode == "backup" else "Generate revised trip ↗"}</button>
            </form>
        </div>
    </section>
}
