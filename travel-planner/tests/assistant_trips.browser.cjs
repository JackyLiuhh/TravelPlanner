/** Conversation isolation and delayed-response regression; every AI call is intercepted. */
const assert = require('node:assert/strict');
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const appUrl = process.env.TRAVEL_APP_URL || 'http://127.0.0.1:8379';
const apiUrl = process.env.TRAVEL_API_URL || appUrl + '/api/server';
(async () => {
  const browser = await chromium.launch({channel: process.env.TRAVEL_BROWSER_CHANNEL || 'chrome'});
  const page = await browser.newPage({viewport: {width: 1440, height: 1000}});
  page.setDefaultTimeout(20000);
  const errors = [], trips = [], states = new Map(), calls = [];
  page.on('pageerror', error => errors.push(error.message));
  async function api(name, data) {
    const response = await page.request.post(apiUrl + '/function/' + name, {data});
    const payload = await response.json();
    assert(response.ok() && payload.ok, JSON.stringify(payload));
    return payload.data.result;
  }
  const fulfilled = (route, result) => route.fulfill({json: {ok: true, data: {result}}});
  let release, started;
  let pendingStarted = new Promise(resolve => { started = resolve; });
  try {
    for (const title of ['Conversation A regression', 'Conversation B regression']) {
      const trip = await api('save_trip', {title, destination: 'Boston', start_date: '2027-01-01', end_date: '2027-01-03', budget: '500'});
      trips.push(trip);
      states.set(trip.id, {...await api('assistant_state', {trip_id: trip.id}), config: {configured: true}});
    }
    await page.route('**/function/assistant_state', route => fulfilled(route, states.get(route.request().postDataJSON().trip_id)));
    await page.route('**/function/assistant_chat', async route => {
      const args = route.request().postDataJSON(); calls.push(args);
      if (args.message === 'Test connection failure') {
        await route.fulfill({status: 500, json: {ok: false, error: {code: 'EXECUTION_ERROR', message: 'Could not reach OpenAI or read its response. Please retry.'}}});
        return;
      }
      const state = states.get(args.trip_id);
      const reply = {...state, messages: [...state.messages,
        ...(!args.automatic ? [{id: 'user-' + calls.length, role: 'user', text: args.message, mode: args.mode}] : []),
        {id: 'reply-' + calls.length, role: 'assistant', text: 'Reply for ' + args.trip_id, mode: args.mode}]};
      if (args.message === 'First trip pending request' || args.automatic) {
        const gate = new Promise(resolve => { release = resolve; }); started(); await gate;
      }
      states.set(args.trip_id, reply);
      await fulfilled(route, reply);
    });
    await page.goto(appUrl);
    async function select(index) {
      await page.locator('.trip-card').filter({hasText: trips[index].title}).click();
      await page.locator('.chat-heading').getByText(trips[index].title + ' · Boston', {exact: true}).waitFor();
      await page.waitForFunction(() => document.querySelector('.chat-messages')?.getAttribute('aria-busy') === 'false');
    }
    await select(0);
    await page.locator('#ai-message').fill('First trip pending request');
    await page.getByRole('button', {name: 'Send ↗', exact: true}).click();
    await pendingStarted;
    await select(1);
    assert.equal(await page.locator('#ai-message').inputValue(), '');
    assert.equal(await page.locator('#ai-mode').inputValue(), 'ask');
    assert.equal(await page.locator('.chat-message').count(), 0);
    const completed = page.waitForResponse('**/function/assistant_chat'); release(); await completed;
    await page.getByRole('button', {name: 'Reload conversation'}).click();
    await page.waitForFunction(() => document.querySelector('.chat-messages')?.getAttribute('aria-busy') === 'false');
    assert.equal(await page.locator('.chat-message').count(), 0);
    await page.locator('#ai-message').fill('Second trip only');
    await page.getByRole('button', {name: 'Send ↗', exact: true}).click();
    await page.locator('.chat-message.assistant').getByText('Reply for ' + trips[1].id, {exact: true}).waitFor();
    await select(0);
    await page.locator('.chat-message').getByText('First trip pending request', {exact: true}).waitFor();
    assert.equal(await page.locator('.chat-message').getByText('Second trip only', {exact: true}).count(), 0);
    await page.getByRole('button', {name: 'AI planner', exact: true}).click();
    pendingStarted = new Promise(resolve => { started = resolve; });
    await page.locator('.ai-quick-actions button').filter({hasText: 'Plan my trip'}).click();
    await pendingStarted;
    assert.equal(calls.at(-1).automatic, true);
    assert.equal(calls.at(-1).draft_only, true);
    assert.equal(await page.locator('#ai-message').inputValue(), '');
    await select(1);
    const automaticCompleted = page.waitForResponse('**/function/assistant_chat'); release(); await automaticCompleted;
    await page.getByRole('button', {name: 'Reload conversation'}).click();
    await page.waitForFunction(() => document.querySelector('.chat-messages')?.getAttribute('aria-busy') === 'false');
    assert.equal(calls.length, 3, 'Switching trips must not replay the previous AI button action');
    assert.equal(await page.locator('.chat-message').getByText('First trip pending request', {exact: true}).count(), 0);
    assert.equal(await page.locator('.chat-message.assistant').count(), 1);
    await page.locator('#ai-message').fill('Test connection failure');
    await page.getByRole('button', {name: 'Send ↗', exact: true}).click();
    await page.locator('.chat-composer [role="alert"]').waitFor();
    assert.equal(await page.locator('.chat-composer [role="alert"]').textContent(), 'AI connection failed. Try again.');
    assert.equal(await page.getByRole('button', {name: 'Send ↗', exact: true}).isEnabled(), true);
    assert.deepEqual(errors, []);
    console.log('Passed: separate trip conversations, composer reset, delayed responses, and no automatic action replay.');
  } finally {
    if (release) release();
    for (const trip of trips) await api('delete_trip', {trip_id: trip.id});
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
