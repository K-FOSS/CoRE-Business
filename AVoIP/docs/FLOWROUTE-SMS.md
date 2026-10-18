# Flowroute SMS receiver

AVoIP includes an independent Go HTTP service for Flowroute inbound messaging.
It runs separately from Asterisk and FreeSWITCH, accepts Flowroute's current
JSON:API callback envelope and the older flat callback format, then writes
messages to a PostgreSQL database provisioned by the cluster-scoped
`CoRE-Voice` User claim. The User Composition generates the database role and
its per-user database; the service creates its table and index when it starts.
The current global database provider is `psql-main`, and the User Composition
grants the database owner access to the `public` schema. See Backplane's
[AVoIP ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/AVoIP.yaml),
[PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml),
[storage base ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Base.yaml),
and [User implementation](https://github.com/K-FOSS/CoRE-Backplane/tree/main/Operations/SSO/User).

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

`flowrouteSMS.enabled` defaults to `false`. Enabling it renders two or more
stateless replicas, an internal Service, and a public Gateway API HTTPRoute on
the configured hostname. The route is restricted to the configured primary
region (YVR by default) so multiple ApplicationSet targets cannot claim the
same public hostname. Set the immutable image repository and digest from the
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

The database credential is read from the `psqlURI` key in the `CoRE-Voice`
connection Secret. The table is `public.flowroute_inbound_messages`, keyed by
`message_id`, with sender, recipient, body, message type and timestamps. SMS
body text is personal data and is retained in PostgreSQL backups with the
cluster's normal database lifecycle. This initial service has no automatic
retention deletion; define an explicit retention policy before using it for
long-term message archiving. The current User Composition orphans its
PostgreSQL database on claim deletion, so removing the chart or claim does not
erase stored messages; review the retained database separately during
decommissioning. MMS callbacks are acknowledged and store their
sender/recipient/time and MMS flag, but do not download attachments.

The receiver has `/healthz` and a PostgreSQL-backed `/readyz`. Each pod uses a
maximum of five PostgreSQL connections, so two replicas cap this service at ten
connections. Additional replicas can be added through `flowrouteSMS.replicas`;
the unique MDR constraint keeps concurrent duplicate deliveries safe. Avoid
raising the replica count without checking global PostgreSQL connection
capacity.

## Validation and rollout

The Go unit tests cover current and legacy payload decoding and callback-token
path matching. The container build runs the tests before compiling a static,
non-root binary. `AVoIP/tests/flowroute-sms-render.sh` checks that the stack is
disabled by default, that enabling it renders the standalone workload and
public route, and that a non-primary region cannot claim it.

The service is not enabled by the chart defaults and has not been deployed.
Before activation, publish the image, set the Home1/YVR image digest and
hostname through the AVoIP ApplicationSet values, provision the Vault token,
then reconcile only the owning AVoIP Application. Verify that Flowroute
receives HTTP 200 for a test SMS and that the matching MDR ID appears once in
PostgreSQL. Check the `core-home1-talos-prod` PostgreSQL ApplicationSet and
Downstream claim conditions before relying on the generated connection Secret.

The service uses the [Go standard library](https://go.dev/doc/),
[`pgx`](https://github.com/jackc/pgx/),
[PostgreSQL](https://www.postgresql.org/docs/),
[Gateway API](https://gateway-api.sigs.k8s.io/), and the
[BJW-S common library](https://bjw-s-labs.github.io/helm-charts/docs/common-library/).
