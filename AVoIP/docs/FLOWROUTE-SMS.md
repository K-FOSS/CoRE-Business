# Flowroute SMS receiver

AVoIP includes an independent Go HTTP service for Flowroute inbound messaging.
It runs separately from Asterisk and FreeSWITCH, accepts Flowroute's current
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

The receiver is a standalone AVoIP stack and does not depend on FreeSWITCH's
`mod_sms` or the unavailable Flowroute FreeSWITCH module. It does not send
messages. For each callback it validates the content type and required fields,
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
(YVR). Enabling it renders two or more stateless replicas, an internal
Service, and a public Gateway API HTTPRoute on the configured hostname. The
primary-region guard prevents multiple ApplicationSet targets from claiming
the same public hostname. The checked-in image tag and digest point to the
successful [Forgejo image workflow](../../.forgejo/workflows/flowroute-sms.yaml).
The image is built from the Go source in [`image/flowroute-sms`](../image/flowroute-sms/)
and uses the pinned Go 1.27.2 builder image.

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
MIME types, byte counts, HTTP status, and response status, but never message
bodies, phone numbers, signed media URLs, callback tokens, credentials, or
attachment contents. Turn diagnostics off after the investigation. An internal
database error while loading image bytes now returns `503`; an absent or
unauthorized image remains `404`, making storage failures distinguishable from
missing media.

The database credential is read from the `psqlURI` key in the `CoRE-Voice`
connection Secret. Messages are stored in `public.flowroute_inbound_messages`;
MMS image bytes are stored as PostgreSQL `bytea` rows in
`public.flowroute_inbound_media`, linked to their message. The receiver fetches
only HTTPS signed media URLs from Flowroute's documented media host, accepts
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
It filters messages by recipient for both the message list and media download;
requests without a valid number scope are denied. Do not bypass the authenticated
Gateway route to expose the service directly. The web page renders message text
as text and displays stored images without exposing Flowroute's expiring signed
URLs.

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

The receiver has `/healthz` and a PostgreSQL-backed `/readyz`. Each pod uses a
maximum of five PostgreSQL connections, so two replicas cap this service at ten
connections. Additional replicas can be added through `flowrouteSMS.replicas`;
the unique MDR constraint keeps concurrent duplicate deliveries safe. Avoid
raising the replica count without checking global PostgreSQL connection
capacity.

## Validation and rollout

The Go unit tests cover current and legacy payload decoding, MMS metadata, and
callback-token path matching. The container build runs the tests before
compiling a static, non-root binary. The SMS renderer checks confirm that
disabling the receiver omits its resources, enabling it renders the standalone
workload and public callback route, and a non-primary region cannot claim it.
The inbox renderer checks confirm its Authentik policy, number mapping and
non-public route.

The checked-in values enable the inbox alongside the receiver. The current
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
