# Synthetic browser checks. Requires Playwright; no live API traffic.
from playwright.sync_api import sync_playwright
from pathlib import Path
from urllib.parse import urlsplit
import json
import tempfile
root = Path(__file__).resolve().parents[1] / 'image/flowroute-sms/web'
artifacts = Path(tempfile.mkdtemp(prefix='avoip-ui-'))
print('Synthetic UI artifacts:', artifacts)
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, args=['--no-sandbox'])
    for width in [1280, 360]:
        page = browser.new_page(viewport={'width': width, 'height': 900})
        errors = []
        page.on('pageerror', lambda e: errors.append(str(e)))
        calls = []
        messages = [{'id': f'fixture-{i:03}', 'sender': '+12065550101', 'recipient': '+12065550100', 'body': 'Fixture message ' + str(i), 'received_at': '2026-10-18T00:00:00Z', 'direction': 'inbound'} for i in range(200)]

        def route(r):
            path = urlsplit(r.request.url).path
            if path == '/inbox':
                content = (root / 'index.html').read_text()
                mime = 'text/html'
            elif path.startswith('/assets/'):
                file = root / path.split('/')[-1]
                content = file.read_bytes()
                mime = 'text/css' if file.suffix == '.css' else 'application/javascript' if file.suffix == '.js' else 'font/ttf'
            else:
                calls.append((r.request.method, path))
                if path == '/api/numbers':
                    data = {'numbers': ['+12065550100'], 'can_send': True, 'can_delete': True, 'admin_url': 'https://admin.example', 'senders': [{'number': '+12065550100', 'provider_id': 'twilio'}, {'number': '+12065550100', 'provider_id': 'telnyx'}]}
                elif r.request.method == 'DELETE':
                    messages[:] = [m for m in messages if m['id'] != path.split('/')[-1]]
                    r.fulfill(status=204)
                    return
                elif 'before=' in r.request.url:
                    data = [{'id': 'fixture-older', 'sender': '+12065550101', 'recipient': '+12065550100', 'body': 'Earlier fixture', 'received_at': '2025-10-18T00:00:00Z', 'direction': 'inbound'}]
                else:
                    data = messages
                content = json.dumps(data)
                mime = 'application/json'
            r.fulfill(status=200, body=content, content_type=mime)
        page.route('https://fixture.test/**', route)
        page.goto('https://fixture.test/inbox')
        page.locator('.conversation').click()
        page.locator('#provider').wait_for()
        assert page.locator('#provider option').count() == 2
        page.get_by_role('button', name='Load older messages', exact=True).click()
        page.get_by_text('Earlier fixture', exact=True).wait_for()
        page.locator('.message-meta .text-button').last.click()
        page.locator('#confirm-action button[value=delete]').click()
        page.wait_for_timeout(300)
        assert any((method == 'DELETE' for method, path in calls))
        assert page.locator('#send').bounding_box()['x'] + page.locator('#send').bounding_box()['width'] <= width
        assert not errors, errors
        page.screenshot(path=artifacts / f'inbox-{width}.png', full_page=True)
        print(f'inbox {width}px: provider selection, pagination, confirmed deletion, send button within viewport; no browser errors', flush=True)
        page.close()
    browser.close()
