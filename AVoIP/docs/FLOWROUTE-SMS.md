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
with the existing Vault `AccessKey` and `SecretKey`; the webhook only receives callbacks. For each callback it validates the content type and required fields,
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

The checked-in values enable `flowrouteSMS` for YVR. The
[AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml)
also selects YXL with distinct `sms-yxl.mylogin.space` and
`sms-media-yxl.mylogin.space` hostnames; this remains pending live reconciliation.
Enabling it renders separate web, API, and webhook Deployments and Services,
each with at least two replicas. The public Gateway API HTTPRoute sends only
`/flowroute/` to the webhook; the Authentik protected route sends `/inbox` and
`/assets/` to the web UI and `/api/` and `/media/` to the API. The
secondary-site hostname checks prevent the default YVR SMS and media names
from being claimed by another site. YXL disables the legacy Flowroute receiver
and does not receive YVR's callback token; provider callbacks must be configured
explicitly for its own hostname. Each pinned image is published by the
[Forgejo image workflow](../../.forgejo/workflows/flowroute-sms.yaml).
The images are built from the Go source in [`image/flowroute-sms`](../image/flowroute-sms/)
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
connection Secret. YXL's existing site-specific `User` claim continues to
provision its own database and service identity with the global PostgreSQL
providers, but `flowrouteSMS.databaseHost` publishes the site-local
`psql.core-dc1-talos-prod.dc1.yxl.mylogin.space` PGPool endpoint in its
connection URI. That DNS name resolves to YXL's local `psql` Service, fronts
the shared global PostgreSQL cluster, and is covered by YXL's serving
certificate. It does not merge YXL and YVR message histories. Check the
[PostgreSQL ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/PSQL.yaml)
and the [User XRD](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Operations/SSO/User/templates/User/UserResourceDef.yaml)
before changing this path. Messages are stored in `public.flowroute_inbound_messages`;
new MMS image attachments are stored as S3 objects
under `sms-media/inbound/`, with object keys and metadata in
`public.flowroute_inbound_media`. Legacy PostgreSQL `bytea` rows remain
readable during migration. The receiver fetches only HTTPS signed media URLs
from Flowroute's documented media host
(`mms-media-prod.s3.amazonaws.com`) or its observed regional S3 endpoint
(`s3.us-west-2.amazonaws.com`), accepts
image MIME types, limits attachments to ten per message and 750 KiB total, and
commits message and media metadata together. Flowroute's signed download links
expire, so attachments are copied into the configured S3 bucket on receipt.
YVR uses its local TenantLab bucket; YXL uses the peered YVR bucket. Twilio's API
redirects are followed only over HTTPS to approved Twilio/S3 media hosts, and
credentials are not forwarded to the redirected host. See the
[Flowroute inbound MMS callback format](https://developer.flowroute.com/api/messages/v2.2/receive-an-mms/).

The YXL AVoIP Admin/SMS workload uses the YVR TenantLab S3 endpoint through the
existing CoRE-Backplane peer. Its endpoint and credential Secret are injected by
the [AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml),
while the [TenantLab storage ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/S3/TenantLab.yaml)
owns the peer and credential publication. The AVoIP `User` claim therefore does
not create a second YXL bucket or credentials for that deployment. The YVR
deployment retains its existing site-local S3 provisioning.
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
Gateway route to expose the service directly. The responsive conversation UI
renders message text as text, uses 15 second polling and paginated history,
and displays stored images without exposing provider-signed URLs. Selecting an
attachment opens an in-app dialog; its three-dot menu provides a download
action.

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

Each deployment has `/healthz`; the API and webhook have PostgreSQL-backed `/readyz`. Each pod uses a
maximum of five PostgreSQL connections, so two replicas cap this service at ten
connections. Additional replicas can be added through `flowrouteSMS.replicas`;
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
workload and public callback route, and a secondary site must use separate
public hostnames and can publish a local PGPool hostname without changing the
global PostgreSQL providers.
The inbox renderer checks confirm its Authentik policy, number mapping and
non-public route.

The checked-in values enable the inbox alongside the webhook. The current
published image is pinned in those values, and the default inbox URL is
`https://<flowrouteSMS.hostname>/inbox`; a separate hostname can be configured
if desired. These commits have not been synced to the cluster. After scoped
reconciliation, verify Authentik login, message filtering, image retrieval,
Flowroute callback HTTP 200 and a single MDR row in PostgreSQL. Check the
[`core-home1-talos-prod` PostgreSQL ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Storage/PSQL.yaml)
and downstream User claim conditions before relying on the generated
connection Secret.

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
| [Twilio](https://www.twilio.com/), [Messages resource](https://www.twilio.com/docs/messaging/api/message-resource) | Form-encoded SMS and MMS using account SID and Auth Token; uploaded images are served through the site media proxy | [Signed form webhook](https://www.twilio.com/docs/usage/webhooks/webhooks-security), exact configured URL, account and destination validation; inbound images are downloaded with account authentication and stored in site-local S3 |
| [Telnyx](https://telnyx.com/), [messaging API](https://developers.telnyx.com/docs/messaging/messages/send-message) | JSON SMS with bearer API key | [Ed25519 webhook](https://developers.telnyx.com/docs/messaging/messages/receiving-webhooks), five-minute timestamp bound and destination validation; SMS text only |

Twilio/Telnyx callbacks use `/providers/{id}/inbound`. Configure that exact HTTPS
URL without query parameters. Twilio outbound MMS is available in the inbox by
selecting the Twilio provider and uploading one or more image files (up to ten).
The service stores the files in site-local S3 and gives Twilio short-lived
public HTTPS media-proxy URLs. Twilio applies file type, size, geography, and
carrier limits; see
its [MMS sending guide](https://www.twilio.com/docs/messaging/tutorials/how-to-send-sms-messages)
and [accepted media types](https://www.twilio.com/docs/messaging/guides/accepted-mime-types).
Do not use private URLs or URLs containing credentials. Inbound Twilio MMS
supports up to ten image attachments, fetched from Twilio's authenticated media
resource and stored with the message in site-local S3. The existing 750 KiB total
message-plus-media cap applies; non-image media types are rejected. Twilio's
webhook signature, account, Message SID, Media SIDs, and exact media resource
paths are checked before fetching. Inbound Telnyx MMS remains unsupported and
returns 415 rather than being acknowledged and discarded; inbound Flowroute
MMS remains supported by its existing adapter. See Twilio's
[incoming media webhook fields](https://www.twilio.com/docs/messaging/guides/webhook-request)
and [authenticated media resource](https://www.twilio.com/docs/messaging/api/media-resource).
Additional providers' IDs are namespaced in
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

The API accepts Authentik's standard pipe-separated `X-Authentik-Groups` header
as well as the JSON custom group header, both supplied by the trusted external
authorization response. This preserves admin number visibility for existing
sessions while custom property mappings roll out. Exact group names and an
authenticated username are still required; no access is inferred from UI state.

Envoy's HTTP external-auth response allowlist uses exact header names. Explicitly
forward `x-authentik-username`, `x-authentik-groups` and `x-authentik-uid`; a
literal `x-authentik-*` is not a wildcard. Standard group membership is
authoritative when that header is present, including an empty group set, so
a custom header cannot override verified membership.
