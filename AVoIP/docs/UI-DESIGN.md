# AVoIP interface design specification

The SMS inbox and AVoIP administration interface share a **Material Design 2**
baseline, corresponding to the 2019–2022 design language. This is the project
specification for subsequent UI changes. Reference the authoritative
[Material Design 2 design guidance](https://m2.material.io/design) and
[component guidance](https://m2.material.io/components). Dynamic Material You
palettes and Material 3 navigation are outside this baseline.

## Shared foundations

| Element | Required treatment |
| --- | --- |
| Typography | Locally bundled Roboto: 400 body, 500 controls/headings, 700 emphasis; system sans-serif fallback. Body/input 16 px; labels/captions 12 px; controls 14 px; app bar 20 px medium; page titles 24 px regular, 20 px on narrow screens |
| Spacing | 8 px grid, 4 px adjustments for compact content; 16 px cards/gutters, 24 px wide-screen content padding |
| Color | Existing blue primary `#1976d2`, darker interaction `#1565c0`; white surfaces, `#fafafa` background, `#212121` text, `#616161` secondary text, `#e0e0e0` dividers |
| Dark theme | Retain the existing inbox theme tokens and system preference; preserve readable text and focus states; use light red destructive text against dark surfaces |
| Shape | 4 px corners for admin cards, outlined fields and controls; retain existing conversation bubbles and avatar circles |
| Elevation | Restrained shadows: app bar elevation 2, cards elevation 1, modal dialogs visibly above content; no glass or translucent content panels |
| App bar/tabs | 64 px desktop app bar, 56 px mobile; 48 px horizontally scrollable tabs with blue indicator and explicit selected state |
| Inputs | Persistent labels, outlined fields, clear required/error feedback; no placeholder-only labels; credential inputs name secret references and never reveal stored credentials |
| Actions | Text actions for secondary choices; contained blue primary action; destructive actions use red plus explicit wording, never color alone |

Use the existing shared `web/app.css` tokens. Administration-specific selectors
are scoped under `.admin-page`; changes must preserve the inbox's layout and
conversation rendering. Both pages use local fonts/assets and restrictive CSPs,
with untrusted text inserted through `textContent`. No third-party CDN is needed.

## Layout and behavior

The inbox retains its conversation list, local-number selector, message thread
and composer. Admin users receive per-message deletion controls. A provider
selector appears only when a number has multiple explicitly configured sending
providers. Access controls remain server-side; hiding a button is not authorization.

The administration page uses the same typography, colors and control patterns:
app bar, section tabs, responsive cards, labeled edit dialogs, explicit cancel/
save actions and snackbar feedback. Sections cover SMS providers, SIP providers,
DIDs, extension outbound permissions and audit activity. The searchable
extension list includes display name, enabled and outbound-enabled controls,
verified caller ID, provider, and egress site. Configuration-managed records
are clearly read only. Edits use optimistic concurrency and show conflicts
rather than silently overwriting another administrator's work.

Layouts collapse to a single column on narrow screens. Content has a 1200 px
maximum width, 24 px desktop and 16 px mobile gutters. Tabs scroll horizontally;
dialogs stay within the viewport and can scroll vertically. Preserve draft
input on server validation errors. Never show a save success as proof that SIP
routing is activated or that every replica has refreshed.

## Accessibility and acceptance

Use semantic controls and persistent labels, visible keyboard focus, accessible
names, dialog focus management and Escape/cancel behavior. Selected navigation
must expose its state. Text should meet WCAG AA contrast (4.5:1 for ordinary
text); interactive touch targets should be at least 44 px, preferably 48 px.
Do not communicate delivery, verification or deletion solely with color/icons.

Review light/dark themes, keyboard-only navigation, long provider names,
validation errors, empty/loading/error states and approximately 360 px, 768 px
and 1280 px viewports. Distinguish configured number ownership, provider
verification evidence, SIP authentication and message acceptance/delivery; the
UI must not imply that one proves another. Provider reference fields never
accept a production password or token.

Functional/API validation and rendering checks are recorded with the relevant
implementation. Browser visual and assistive-technology checks must be reported
separately from syntax checks; a valid JavaScript file is not visual acceptance.

## Reproducible browser fixtures

The optional [admin](../tests/admin-browser.py) and
[inbox](../tests/sms-inbox-browser.py) Chromium checks intercept every application
request with synthetic responses. They exercise admin dialogs, visible save
feedback, provider selection, history pagination and confirmed deletion. They
produce screenshots in a temporary directory and check for browser errors and
layout overflow. They do not exercise production Authentik, carriers or SIP.

Use a disposable environment with Python, fonts and Chromium dependencies:

```sh
python3 -m venv /tmp/avoip-ui-check
/tmp/avoip-ui-check/bin/pip install 'playwright==1.64.0'
/tmp/avoip-ui-check/bin/playwright install chromium
/tmp/avoip-ui-check/bin/python AVoIP/tests/admin-browser.py
/tmp/avoip-ui-check/bin/python AVoIP/tests/sms-inbox-browser.py
```

The fixture launcher disables Chromium sandboxing for disposable test containers.
The observed fixtures cover admin at 360/768/1280 px, light and dark themes, and
inbox at 360/1280 px. Manual screen-reader and production login/call acceptance
remain rollout checks.
