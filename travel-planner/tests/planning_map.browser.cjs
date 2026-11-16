/** Restored interactive map with held/mock AI replies; no live OpenAI requests. */
const assert = require('node:assert/strict');
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const appUrl = process.env.TRAVEL_APP_URL || 'http://127.0.0.1:8379';
const apiUrl = process.env.TRAVEL_API_URL || appUrl + '/api/server';

(async () => {
  const browser = await chromium.launch({channel: process.env.TRAVEL_BROWSER_CHANNEL || 'chrome'});
  const page = await browser.newPage({viewport: {width: 1440, height: 1000}});
  page.setDefaultTimeout(20000);
  const errors = [], trips = [], states = new Map(), calls = [], gates = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => {
    if (message.type() === 'error' && /ErrorBoundary|TypeError|ReferenceError/.test(message.text())) errors.push(message.text());
  });
  let notifyStarted;
  async function api(name, data) {
    const response = await page.request.post(apiUrl + '/function/' + name, {data});
    const payload = await response.json();
    assert(response.ok() && payload.ok, JSON.stringify(payload));
    return payload.data.result;
  }
  const fulfilled = (route, result) => route.fulfill({json: {ok: true, data: {result}}});
  const map = () => page.getByRole('region', {name: 'Trip map', exact: true});
  async function attribute(name, value) {
    await page.waitForFunction(({name, value}) =>
      document.querySelector('[aria-label="Trip map"]')?.getAttribute(name) === value, {name, value});
  }
  function journey(trip) {
    const known = trip.destination === 'New York';
    const endpoint = city => ({city, zone: 'America/Detroit', lat: known ? 42.33 : null, lon: known ? -83.05 : null});
    const stops = [{id: 'destination', city: trip.destination, zone: 'America/New_York',
      lat: known ? 40.71 : null, lon: known ? -74.01 : null,
      arrival_date: trip.start_date, departure_date: trip.end_date}];
    if (known) stops.push({id: 'boston', city: 'Boston', zone: 'America/New_York', lat: 42.36, lon: -71.06,
      arrival_date: trip.end_date, departure_date: trip.end_date});
    const order = ['origin', ...stops.map(stop => stop.id), 'return'];
    return {version: 1, origin: endpoint(trip.departure_location), return_to: endpoint(trip.return_location), stops,
      legs: order.slice(0, -1).map((from_id, index) => ({id: from_id + ':' + order[index + 1], from_id,
        to_id: order[index + 1], mode: 'flight', before_minutes: 60, after_minutes: 30}))};
  }
  function changes(trip, route, index) {
    const known = trip.destination === 'New York';
    const item = (suffix, title, date, time, category, detail, notes) => ({
      item_id: '', before: null, price_unknown: false, after: {
        id: 'draft-' + index + '-' + suffix, trip_id: trip.id, title, date, time, category,
        location: detail.stop_id ? trip.destination : detail.leg_id, notes,
        duration_minutes: category === 'transport' ? 120 : 90, cost_cents: category === 'transport' ? 20000 : 3000,
        done: false, paid: false, protected: false, fixed: false, reference: '', latest_start: '',
        flight: {}, journey: {zone: 'America/New_York', end_zone: 'America/New_York', ...detail}
      }
    });
    const rows = [
      item('outbound', 'Outbound flight', trip.start_date, '08:00', 'transport',
        {leg_id: route.legs[0].id, arrival_date: trip.start_date, arrival_time: '10:00', mode: 'flight'}, 'Estimated outbound flight; not a confirmed booking.'),
      item('park', known ? 'Central Park walk' : 'Arrival neighborhood walk', trip.start_date, '14:00', 'activity',
        {stop_id: 'destination'}, 'A relaxed walk with time for photos and a coffee stop.'),
      item('museum', 'Museum afternoon', '2027-01-02', '13:00', 'activity',
        {stop_id: 'destination'}, 'Explore the museum collection at your own pace.'),
      item('return', 'Return flight', trip.end_date, '18:00', 'transport',
        {leg_id: route.legs.at(-1).id, arrival_date: trip.end_date, arrival_time: '20:00', mode: 'flight'}, 'Estimated return flight; not a confirmed booking.')
    ];
    if (known) rows.push(item('boston', 'Boston waterfront', trip.end_date, '12:00', 'activity',
      {stop_id: 'boston'}, 'A short waterfront visit before returning home.'));
    return rows;
  }
  function response(args, index) {
    const trip = trips.find(trip => trip.id === args.trip_id), state = states.get(args.trip_id), route = journey(trip);
    const draft = {id: 'map-draft-' + index, status: 'pending', expires: new Date(Date.now() + 1800000).toISOString(),
      title: 'Estimated route ' + index, summary: 'Synthetic estimated trip for the browser regression.',
      mode: args.mode, relaxed: true, journey: route, changes: changes(trip, route, index),
      trip_edits: [], trip_changes: {}, trip_before: trip, trip_after: trip,
      original_total_cents: 0, total_cents: 49000, reserve_cents: 0, checks: [], issues: [], warnings: [], can_apply: true};
    return {...state, pending: false, drafts: [draft], messages: [...state.messages,
      {id: 'map-reply-' + index, role: 'assistant', mode: args.mode, text: 'Estimated itinerary ready for ' + trip.title}]};
  }
  function nextRequest() { return new Promise(resolve => { notifyStarted = resolve; }); }
  async function assertStaticMap() {
    assert.equal(await page.locator('.planning-map').count(), 0, 'The replacement map must not be mounted');
    assert.equal(await map().locator('.planning-plane, animateMotion').count(), 0, 'The restored map must not animate flight planes');
  }
  async function assertPending(expectedMode, mapped = true) {
    await attribute('data-working', 'true');
    const args = calls.at(-1);
    assert.equal(args.mode, expectedMode);
    assert.equal(args.automatic, true);
    assert.equal(args.draft_only, true);
    assert(args.message.length < 500, 'Task requests should remain short');
    assert.equal(await page.locator('#ai-message').inputValue(), '');
    assert.equal(await page.locator('.chat-message.user').count(), 0, 'Internal button prompt must remain hidden');
    await assertStaticMap();
    if (mapped) assert(await map().locator('.map-route-hit').count() >= 2, 'Outbound and return routes should be explorable before GPT replies');
  }
  async function release(index) {
    const completed = page.waitForResponse('**/function/assistant_chat');
    gates[index].release(); await completed;
  }
  async function select(index) {
    await page.locator('.trip-card').filter({hasText: trips[index].title}).click();
    await page.locator('.chat-heading').getByText(trips[index].title + ' · ' + trips[index].destination, {exact: true}).waitFor();
    await page.waitForFunction(() => document.querySelector('.chat-messages')?.getAttribute('aria-busy') === 'false');
    await page.getByRole('button', {name: 'AI planner', exact: true}).click();
    await map().waitFor();
  }
  async function closeDetails() {
    const close = map().getByRole('button', {name: 'Close map details', exact: true});
    if (await close.count()) await close.click();
  }
  async function clickCurve(title) {
    const route = map().getByLabel('Open route ' + title, {exact: true});
    await route.waitFor();
    const point = await route.evaluate(el => {
      const position = el.getPointAtLength(el.getTotalLength() * 0.3);
      const result = new DOMPoint(position.x, position.y).matrixTransform(el.getScreenCTM());
      return {x: result.x, y: result.y};
    });
    await page.mouse.click(point.x, point.y);
  }
  try {
    const suffix = Date.now().toString(36);
    for (const [title, origin, destination] of [
      ['Interactive route ' + suffix, 'Detroit', 'New York'],
      ['Unlocated route ' + suffix, 'Unlisted Departure', 'Unlisted Destination']
    ]) {
      const trip = await api('save_trip', {title, destination, departure_location: origin, return_location: origin,
        start_date: '2027-01-01', end_date: '2027-01-03', budget: '5000'});
      trips.push(trip);
      states.set(trip.id, {...await api('assistant_state', {trip_id: trip.id}), config: {configured: true}});
    }
    await page.route('**/function/assistant_state', route => {
      const state = states.get(route.request().postDataJSON().trip_id);
      return state ? fulfilled(route, state) : route.continue();
    });
    await page.route('**/function/assistant_chat', async route => {
      const args = route.request().postDataJSON(), index = calls.length;
      calls.push(args);
      let unblock;
      const gate = new Promise(resolve => { unblock = resolve; });
      gates.push({release: unblock});
      notifyStarted(index);
      await gate;
      const reply = response(args, index);
      states.set(args.trip_id, reply);
      if (!page.isClosed()) await fulfilled(route, reply);
    });
    await page.goto(appUrl);
    await select(0);
    await assertStaticMap();
    await map().getByRole('button', {name: 'Explore New York', exact: true}).click();
    await map().getByRole('dialog', {name: 'New York', exact: true}).waitFor();
    await closeDetails();
    let started = nextRequest();
    await page.locator('.ai-quick-actions button').filter({hasText: 'Plan my trip'}).click();
    await started; await assertPending('plan');
    await map().getByRole('button', {name: 'Explore Detroit', exact: true}).click();
    await map().getByRole('dialog', {name: 'Detroit', exact: true}).waitFor();
    await closeDetails();
    await map().getByRole('button', {name: 'Zoom in', exact: true}).click();
    await map().getByRole('button', {name: 'Fit all trip points', exact: true}).click();
    assert.equal(calls.length, 1, 'Map interactions must not send extra AI requests');
    await release(0);
    await attribute('data-working', 'false');
    await attribute('data-source', 'draft');
    await map().getByRole('button', {name: 'Explore Boston', exact: true}).waitFor();
    await map().getByRole('button', {name: 'Explore New York', exact: true}).click();
    const popup = map().getByRole('dialog');
    await popup.getByRole('button', {name: /Central Park walk/}).click();
    await popup.getByText('A relaxed walk with time for photos and a coffee stop.', {exact: true}).waitFor();
    await popup.getByRole('button', {name: 'Review this draft', exact: true}).waitFor();
    await closeDetails();
    await page.getByRole('group', {name: 'Map days', exact: true}).getByRole('button', {name: 'Map day 2027-01-02', exact: true}).click();
    await attribute('data-day', '2027-01-02');
    await map().getByRole('button', {name: 'Explore New York', exact: true}).click();
    await popup.getByRole('button', {name: /Museum afternoon/}).waitFor();
    assert.equal(await popup.getByRole('button', {name: /Central Park walk/}).count(), 0, 'Day filter must remove other days from city activities');
    await closeDetails();
    await page.getByRole('group', {name: 'Map days', exact: true}).getByRole('button', {name: 'All days', exact: true}).click();
    await clickCurve('Outbound flight');
    await popup.getByText('Estimated outbound flight; not a confirmed booking.', {exact: true}).waitFor();
    await closeDetails();
    assert.equal(calls.length, 1);
    await map().screenshot({path: '/tmp/roam-restored-map-desktop.png'});
    await page.setViewportSize({width: 390, height: 844});
    await map().getByRole('button', {name: 'Explore New York', exact: true}).click();
    await popup.getByRole('button', {name: /Museum afternoon/}).waitFor();
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'Mobile map must not overflow horizontally');
    await map().screenshot({path: '/tmp/roam-restored-map-mobile.png'});
    await closeDetails();
    await page.setViewportSize({width: 1440, height: 1000});

    await page.getByRole('button', {name: 'Backup plans', exact: true}).click();
    await page.getByLabel('Anything to focus on? (optional)', {exact: true}).fill('Indoor options if it rains.');
    started = nextRequest();
    await page.getByRole('button', {name: 'Generate backup plan ↗', exact: true}).click();
    await started; await assertPending('backup');
    assert(calls.at(-1).message.includes('Indoor options if it rains.'));
    await release(1); await attribute('data-working', 'false');

    await page.getByRole('button', {name: 'Replan', exact: true}).click();
    started = nextRequest();
    await page.getByRole('button', {name: 'Generate revised trip ↗', exact: true}).click();
    await started; await assertPending('replan');
    await select(1);
    await attribute('data-working', 'false');
    await map().getByRole('button', {name: 'Map details', exact: true}).click();
    assert((await popup.innerText()).includes('Unlisted Destination'));
    assert((await popup.innerText()).includes('Location not mapped yet'));
    await release(2);
    assert(!(await map().innerText()).includes('Boston'), 'Late replies must not replace another trip’s map');
    assert.equal(await page.locator('.chat-message.assistant').count(), 0);
    await closeDetails();
    started = nextRequest();
    await page.locator('.ai-quick-actions button').filter({hasText: 'Plan my trip'}).click();
    await started; await assertPending('plan', false);
    await release(3); await attribute('data-working', 'false');
    await attribute('data-source', 'draft');
    assert.equal(calls.length, 4, 'Each planning action should send exactly one request');
    assert.deepEqual(errors, []);
    console.log('Passed: restored map, clickable cities/activities/routes, day filter, pending and draft states, backup/replan, trip isolation, unknown locations, and mobile layout.');
  } catch (error) {
    if (errors.length) console.error('Browser render errors:', errors);
    throw error;
  } finally {
    for (const gate of gates) gate.release();
    for (const trip of trips) await api('delete_trip', {trip_id: trip.id});
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
