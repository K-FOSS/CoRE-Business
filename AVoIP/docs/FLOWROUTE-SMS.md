# Flowroute SMS messaging

AVoIP runs separate web, API, and webhook deployments for Flowroute SMS.
The webhook runs separately from Asterisk and FreeSWITCH, accepts Flowroute's current
JSON:API callback envelope and the older flat callback format, then writes
messages to a PostgreSQL database provisioned by the cluster-scoped
`CoRE-Voice` User claim. The User Composition generates the database role and
its per-user database; the service creates its message, attachment, and index
tables when it starts.
The current global database provider is `psql-main`, and the User Composition
grants the database owner access to the `public` schema. See Backplane's
[AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml),
[PostgreSQL ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/PSQL.yaml),
[storage base ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/Base.yaml),
and [User implementation](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Operations/SSO/User).

The messaging stack does not depend on FreeSWITCH's `mod_sms` or the
unavailable Flowroute FreeSWITCH module. The authenticated API sends SMS using
[Flowroute Messages v2.2](https://developer.flowroute.com/api/messages/v2.2/send-an-sms/)
with the existing Vault `AccessKey` and `SecretKey`; the webhook only receives
callbacks. For each callback it validates the content type and required fields,
then inserts by Flowroute's MDR ID. A PostgreSQL primary key makes retries
idempotent across replicas: a committed message gets HTTP 200, including on a
duplicate delivery; a database failure gets HTTP 503 so Flowroute can retry.
Flowroute documents HTTP POST callbacks and retrying messages that do not get
HTTP 200 in its [receive SMS API](https://developer.flowroute.com/api/messages/v2.2/receive-an-sms/)
and [callback setup guide](https://developer.flowroute.com/docs/setting-up-inbound-messages-with-flowroute/).

I checked the existing [Flowroute Go client](https://github.com/cjcox17/flowroute-client-go).
It includes API operations and webhook payload parsing, but it is a client
library rather than a deployable receiving service with durable PostgreSQL
storage. This stack owns the HTTP acceptance, authorization, idempotency and
database lifecycle needed here, without requiring Flowroute API credentials to
receive callbacks.

## Deployment inputs

The checked-in values enable `flowrouteSMS` for its configured primary region
(YVR). Enabling it renders separate web, API, and webhook Deployments and Services,
each with at least two replicas. The public Gateway API HTTPRoute sends only
`/flowroute/` to the webhook; the Authentik protected route sends `/inbox` and
`/assets/` to the web UI and `/api/` and `/media/` to the API. The
primary-region guard prevents multiple ApplicationSet targets from claiming
the same public hostname. Each pinned image is published by the
[Forgejo image workflow](../../.forgejo/workflows/flowroute-sms.yaml).
The three images are built from the Go source in [`image/flowroute-sms`](../image/flowroute-sms/)
with the pinned Go 1.27.2 builder image.
The web image serves self-hosted [Roboto](https://fonts.google.com/specimen/Roboto)
under the bundled Open Font License; it does not call a third-party font CDN.

Provision a random URL-safe callback token with at least 32 bytes in Vault at
`AVoIP/SIP/FlowRoute/SMS`, property `CallbackToken`. External Secrets publishes
it to the app namespace under the default name
`<release-full-name>-sms-callback`; override
`flowrouteSMS.callbackSecret.name` only when using a different Secret name.
Configure Flowroute's callback URL as
`https://<flowrouteSMS.hostname>/flowroute/<token>`. Keep the URL and token in
Flowroute's secret settings; do not put them in Git or log the request path.
The receiver does not log SMS text, phone numbers, PINs, authorization values,
or the callback token. Review Gateway access-log policy before enabling the
public route so it does not record full request paths.

`flowrouteSMS.diagnostics.enabled` is currently `true` to troubleshoot MMS
handling. It enables structured debug logs for callback parsing and media
relationship counts, attachment validation/download, persistence, inbox listing,
and image retrieval. Logs include stage, message/media IDs, attachment counts,
MIME types, byte counts, the parsed media URL scheme and host, HTTP status, and
response status, but never message bodies, phone numbers, signed media URLs or
their query tokens, callback tokens, credentials, or attachment contents. Turn
diagnostics off after the investigation. An internal
database error while loading image bytes now returns `503`; an absent or
unauthorized image remains `404`, making storage failures distinguishable from
missing media.

The database credential is read from the `psqlURI` key in the `CoRE-Voice`
connection Secret. Messages are stored in `public.flowroute_inbound_messages`;
MMS image bytes are stored as PostgreSQL `bytea` rows in
`public.flowroute_inbound_media`, linked to their message. The receiver fetches
only HTTPS signed media URLs from Flowroute's documented media host
(`mms-media-prod.s3.amazonaws.com`) or its observed regional S3 endpoint
(`s3.us-west-2.amazonaws.com`), accepts
image MIME types, limits attachments to ten per message and 750 KiB total, and
commits message and media rows together. Flowroute's signed download links
expire, so attachments are copied into PostgreSQL on receipt. See the
[Flowroute inbound MMS callback format](https://developer.flowroute.com/api/messages/v2.2/receive-an-mms/).
Messages and pictures are personal data and are retained in PostgreSQL backups
with the cluster's normal database lifecycle. There is no automatic retention
deletion; define a retention policy before using this for long-term archiving.
The current User Composition orphans its PostgreSQL database on claim deletion,
so removing the chart or claim does not erase stored messages; review the
retained database separately during decommissioning.

## Authenticated inbox

The Authentik-protected inbox is rendered when the receiver is enabled. It
defaults to the callback hostname at `/inbox`; set
`flowrouteSMS.inbox.hostname` only when a separate hostname is desired, and use
an Authentik proxy outpost. The Envoy Gateway
`SecurityPolicy` protects the entire inbox route and forwards Authentik's
`X-Auth-Numbers` response header. The chart manages an Authentik provider scope
mapping that builds this comma-separated allowlist from the user's Authentik
`phone_number` user attribute and `sms_numbers` group attribute. Each attribute
may be a single value or a list of values. The mapping accepts integer values
as well as strings and removes a leading `+` before putting values in
`X-Auth-Numbers`. Prefer strings in E.164 form so leading zeros and country
codes are preserved. The receiver
normalizes inbound sender and recipient numbers to E.164 (`+` plus digits) when
storing them, and checks both prefixed and bare-digit forms for existing rows.
The API filters inbound messages by recipient and outbound messages by sender;
media downloads require an authorized recipient. The API checks the Authentik
number allowlist on each read and send, and requires the Authentik username for
send auditing. Requests without a valid number scope are denied. Do not bypass the authenticated
Gateway route to expose the service directly. The responsive conversation UI renders message text as text, uses 15 second
polling and paginated history, and displays stored images without exposing Flowroute's expiring signed
URLs.

Each SMS workload has an ingress NetworkPolicy allowing port 8080 only from
the main Envoy Gateway pods in `flowrouteSMS.gatewayPods.namespace`. The
selector checks the owning Gateway name and namespace supplied by the site
values. Keep this selector aligned with the installed Envoy data plane; it
protects the API's trusted Authentik headers from direct in-cluster requests.

The primary-region [`avoip-authentik-groups` Workspace](templates/Authentik/AVoIPGroups.yaml)
manages the `AVoIP Users` and `AVoIP Admins` groups, and runs before the inbox
Workspace that looks them up. Assign users to these groups in Authentik; the
chart does not provision a user roster or overwrite group membership or group
attributes. The AVoIP Workspace preserves manually managed attributes such as
`sms_numbers` during Terraform reconciliation. Both groups can open the inbox.
The admin group is scoped to AVoIP and is not an Authentik superuser group. See
Authentik's guide to
[managing groups](https://docs.goauthentik.io/users-sources/groups/manage_groups).

The inbox creates an Authentik proxy provider/application and policy bindings
for both groups. A separate route sends `/outpost.goauthentik.io` on the same
host directly to the Authentik outpost, as required for the proxy login callback;
the SMS application paths remain protected by Gateway external authorization.
The inbox routes have no public DNS ownership label or dashboard exposure
annotation. The Flowroute webhook endpoint remains separately reachable without
inbox authentication, and the Authentik outpost prefix bypasses Gateway external
authorization so the outpost can complete login. Authentik custom provider
headers are implemented through property mappings; see [Authentik's forward-auth
route requirements](https://docs.goauthentik.io/add-secure-apps/providers/proxy/create-proxy-provider/)
and [custom headers](https://docs.goauthentik.io/add-secure-apps/providers/proxy/custom_headers/)
and [Envoy Gateway external authorization](https://gateway.envoyproxy.io/docs/tasks/security/ext-auth/).

Each deployment has `/healthz`; the API and webhook have PostgreSQL-backed
`/readyz`. Each database pod uses at most five PostgreSQL connections, so two
replicas of each database workload can use up to twenty connections.
Additional replicas can be added through `flowrouteSMS.replicas`;
the unique MDR constraint keeps concurrent duplicate deliveries safe. Avoid
raising the replica count without checking global PostgreSQL connection
capacity.

Each SMS pod uses `/healthz` for startup and liveness checks. Database-backed
services use `/readyz` for readiness, so a pod is not sent traffic until its
database connection works. Rolling updates allow one temporary surge pod and
zero unavailable replicas; the old pod remains serving until its replacement
passes readiness.

## Validation and rollout

The Go unit tests cover current and legacy payload decoding, MMS metadata, and
callback-token path matching. The container build runs the tests before
compiling a static, non-root binary. The SMS renderer checks confirm that
disabling the receiver omits its resources, enabling it renders the standalone
workload and public callback route, and a non-primary region cannot claim it.
The inbox renderer checks confirm its Authentik policy, number mapping and
non-public route.

The checked-in values enable the inbox alongside the webhook. All three
published images are pinned in those values, and the default inbox URL is
`https://<flowrouteSMS.hostname>/inbox`; a separate hostname can be configured
if desired. After scoped reconciliation, verify Authentik login, message
filtering, image retrieval, authorized sending,
Flowroute callback HTTP 200 and a single MDR row in PostgreSQL. Check the
[`core-home1-talos-prod` PostgreSQL ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/PSQL.yaml)
and downstream User claim conditions before relying on the generated
connection Secret.

The current database has no contact names, unread state, delivery receipts,
or outbound MMS attachments. The UI displays phone numbers and accepted
outbound SMS records without inventing those fields. Drafts live only in page
memory, and a page reload clears them.

The service uses the [Go standard library](https://go.dev/doc/),
[`pgx`](https://github.com/jackc/pgx/),
[PostgreSQL](https://www.postgresql.org/docs/),
[Gateway API](https://gateway-api.sigs.k8s.io/), and the
[BJW-S common library](https://bjw-s-labs.github.io/helm-charts/docs/common-library/).

## Groups, administrative access and providers

The proxy mapping forwards effective Authentik group names, including inherited
membership, as JSON in `X-Auth-Groups`. The API checks exact membership of
`flowrouteSMS.inbox.adminGroup` (`AVoIP Admins` by default), together with the
trusted authenticated username. This header must come from the outpost; direct
API ingress remains restricted to the named Envoy Gateway. User-supplied group
or number headers are not authorization on an unprotected endpoint.

Ordinary users retain their personal/group `sms_numbers` access. Admins see all
configured SMS numbers plus local numbers found in inbound/outbound history;
this does not automatically discover every number owned at a carrier account.
Admins may delete individual stored messages through the inbox or
`DELETE /api/messages/{id}`. Deletion requires same-origin authentication,
deletes stored attachments through their foreign key and keeps a minimal replay
tombstone. It does not recall a delivered message, delete provider records or
remove PostgreSQL backups. Administrative changes have a protected audit trail.

The stack now supports multiple configured accounts using these adapters:

| Provider | Sending | Inbound authentication and scope |
| --- | --- | --- |
| [Flowroute](https://www.flowroute.com/), [Messages v2.2](https://developer.flowroute.com/api/messages/v2.2/send-an-sms/) | JSON:API SMS; legacy account remains compatible | Existing token callback and MMS/image persistence; additional named accounts currently support outbound SMS only |
| [Twilio](https://www.twilio.com/), [Messages resource](https://www.twilio.com/docs/messaging/api/message-resource) | Form-encoded SMS using account SID and Auth Token | [Signed form webhook](https://www.twilio.com/docs/usage/webhooks/webhooks-security), exact configured URL, account and destination validation; SMS text only |
| [Telnyx](https://telnyx.com/), [messaging API](https://developers.telnyx.com/docs/messaging/messages/send-message) | JSON SMS with bearer API key | [Ed25519 webhook](https://developers.telnyx.com/docs/messaging/messages/receiving-webhooks), five-minute timestamp bound and destination validation; SMS text only |

Twilio/Telnyx callbacks use `/providers/{id}/inbound`. Configure that exact HTTPS
URL without query parameters. Unsupported MMS returns 415 and is not silently
acknowledged or discarded; use the existing Flowroute MMS path until additional
media adapters are implemented. Additional providers' IDs are namespaced in
stored message IDs. Retries deduplicate in PostgreSQL and honor deletion
tombstones. No real provider request is used by default tests.

Admins manage account definitions at the site-local
[AVoIP administration interface](ADMIN.md) or through:

- `GET /api/providers`: redacted account definitions/readiness;
- `PUT /api/providers/{id}`: create with version `0`, update with the returned
  version; conflicts return 409;
- `DELETE /api/providers/{id}`: delete an admin-managed definition, retaining
  already stored messages;
- `POST /api/messages`: optional `provider_id` chooses between explicitly
  configured accounts for an authorized sender. No automatic paid fallback or
  retry follows ambiguous provider acceptance.

Number ownership remains the sender authorization boundary for users. Provider
configuration never grants access to someone else's number. A disabled account's
numbers cannot silently fall back to the legacy account. Sending is acceptance,
not a delivery receipt. Admin number visibility is intentionally broader than
ordinary user assignments and must be reviewed as an access change.

The same definitions can be supplied through `flowrouteSMS.providers`; matching
IDs become read only in the UI and override stored definitions. The ID
`flowroute` is reserved for the existing Vault account. Set
`flowrouteSMS.legacyFlowroute.enabled: false` for a Twilio/Telnyx-only installation;
it then requires neither legacy Flowroute callback nor send credentials.
Configuration ownership changes require review: removing a Git override can
reveal an older retained admin definition with the same ID.

Credential fields contain environment references, not values. References must
start with `SMS_PROVIDER_`; `providerCredentials` maps them to existing Secrets
or optional Vault remote references. Example using reserved synthetic numbers:

```yaml
flowrouteSMS:
  providers:
    - id: 'twilio-example'
      type: 'twilio'
      name: 'Example account'
      enabled: true
      numbers: ['+12065550100']
      key_env: 'SMS_PROVIDER_TWILIO_ACCOUNT'
      secret_env: 'SMS_PROVIDER_TWILIO_TOKEN'
      webhook_url: 'https://sms.example/providers/twilio-example/inbound'
  providerCredentials:
    SMS_PROVIDER_TWILIO_ACCOUNT:
      name: 'sms-twilio-example'
      key: 'AccountSID'
      remoteRef:
        key: 'AVoIP/SMS/Example'
        property: 'AccountSID'
    SMS_PROVIDER_TWILIO_TOKEN:
      name: 'sms-twilio-example'
      key: 'AuthToken'
      remoteRef:
        key: 'AVoIP/SMS/Example'
        property: 'AuthToken'
```

Twilio `key_env` references an `AC...` account SID, not an `SK...` API key.
Telnyx uses `key_env` for its API key and `public_key_env` for the base64 public
verification key. Flowroute accounts use `key_env`/`secret_env` for AccessKey/
SecretKey. No credential is returned to the UI or stored in provider rows.
If a Secret is generated through these mappings, all its mapped keys need
`remoteRef`; otherwise manage that Secret externally. Provider definitions are
shared through the primary application's existing database. Credential Secrets
must be provisioned at every consuming site/workload; local readiness reflects
that site's environment. Changing Secret-backed environment values requires a
controlled pod rollout.

The additive schema introduces provider metadata, message provider ID, deletion
tombstones and audit tables. Startup DDL uses one PostgreSQL advisory lock across
API/webhook/admin replicas. Keep the old tables during rollback. Each database
pod still has a five-connection maximum; the two-replica API/webhook pair totals
up to twenty, and two admin replicas per telephony site add up to ten per site.
The inbox and admin UI share the documented [Material Design 2 spec](UI-DESIGN.md).
