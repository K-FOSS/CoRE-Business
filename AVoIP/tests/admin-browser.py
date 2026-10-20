# Synthetic browser checks. Requires Playwright; no live API traffic.
from playwright.sync_api import sync_playwright
from pathlib import Path
import json
import tempfile
root = Path(__file__).resolve().parents[1] / 'image/flowroute-sms/web'
artifacts = Path(tempfile.mkdtemp(prefix='avoip-ui-'))
print('Synthetic UI artifacts:', artifacts)
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, args=['--no-sandbox'])
    for width, theme in [(1280, 'light'), (360, 'light'), (768, 'dark')]:
        api_state = {'sip': {'providers': [{'id': 'carrier', 'host': 'sip.carrier.example', 'gateways': {'yvr': 'carrier-yvr'}, 'verified_caller_ids': [{'number': '+12065550100', 'evidence': 'fixture approval'}]}], 'dids': [], 'extensions': [{'extension': '7101', 'display_name': 'Desk phone', 'assigned_user': 'august@example.test', 'enabled': True, 'outbound_enabled': True, 'caller_id': '+12065550100', 'provider': 'carrier', 'site': 'yvr'}], 'version': 0}}
        page = browser.new_page(viewport={'width': width, 'height': 900}, color_scheme=theme)
        errors = []
        page.on('pageerror', lambda e: errors.append(str(e)))

        def route(r):
            path = r.request.url.split('fixture.test', 1)[1]
            method = r.request.method
            if path == '/':
                content = (root / 'admin.html').read_text()
                mime = 'text/html'
            elif path.startswith('/assets/'):
                file = root / path.split('/')[-1]
                content = file.read_bytes()
                mime = 'text/css' if file.suffix == '.css' else 'application/javascript' if file.suffix == '.js' else 'font/ttf'
            else:
                fixtures = {'/api/providers': [{'id': 'twilio', 'type': 'twilio', 'name': 'Twilio fixture', 'source': 'admin', 'enabled': True, 'can_send': True, 'numbers': ['+12065550100'], 'version': 1}], '/api/audit': [], '/api/admin': {'routing_enabled': True, 'snapshot_ready': True, 'site': 'yvr'}}
                if path == '/api/sip' and method == 'PUT':
                    updated = json.loads(r.request.post_data)
                    updated['version'] = api_state['sip']['version'] + 1
                    api_state['sip'] = updated
                content = json.dumps(api_state['sip'] if path == '/api/sip' else fixtures.get(path, {}))
                mime = 'application/json'
            r.fulfill(status=200, body=content, content_type=mime)
        page.route('https://fixture.test/**', route)
        page.goto('https://fixture.test/')
        page.wait_for_timeout(1000)
        page.get_by_text('Twilio fixture', exact=True).wait_for()
        page.get_by_role('button', name='Edit', exact=True).click()
        assert page.locator('#edit-record').evaluate('(el)=>el.open')
        page.get_by_role('button', name='Cancel', exact=True).first.click()
        page.get_by_role('button', name='Edit', exact=True).click()
        page.get_by_role('button', name='Save', exact=True).click()
        page.locator('#snackbar.visible').wait_for()
        page.get_by_role('button', name='Delete', exact=True).first.click()
        assert page.locator('#confirm-action').evaluate('(el)=>el.open')
        page.keyboard.press('Escape')
        assert not page.locator('#confirm-action').evaluate('(el)=>el.open')
        page.get_by_role('button', name='Extensions', exact=True).click()
        page.get_by_text('Desk phone', exact=True).wait_for()
        assert 'Outbound enabled' in page.locator('.admin-card').inner_text()
        assert 'Assigned user august@example.test' in page.locator('.admin-card').inner_text()
        assert 'Catalog authorization is configured' in page.locator('.admin-card').inner_text()
        page.locator('#record-search').fill('7101')
        assert page.locator('.admin-card').count() == 1
        page.get_by_role('button', name='Edit', exact=True).click()
        assert page.locator('#field-assigned_user').input_value() == 'august@example.test'
        page.locator('#field-outbound_enabled').uncheck()
        page.get_by_role('button', name='Save', exact=True).click()
        page.get_by_text('Outbound disabled', exact=False).wait_for()
        assert api_state['sip']['extensions'][0]['outbound_enabled'] is False
        page.screenshot(path=artifacts / f'admin-{width}-{theme}.png', full_page=True)
        assert page.evaluate('document.documentElement.scrollWidth <= window.innerWidth'), 'horizontal overflow'
        assert not errors, errors
        print(f'admin {width}px {theme}: loaded, edit/delete dialogs, Escape and no overflow/errors')
        page.close()
    browser.close()
