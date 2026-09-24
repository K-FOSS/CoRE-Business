# CoRE-Business Social/Matrix

This chart deploys the [Element Synapse homeserver](https://github.com/element-hq/synapse)
with the [BJW-S Common library chart](https://bjw-s-labs.github.io/helm-charts/docs/common-library/).
It also deploys the [Element Web client](https://github.com/element-hq/element-web)
at `element.mylogin.space`, preconfigured for the local Synapse server at
`matrix.mylogin.space`.
Synapse includes profile updates in `/sync` responses for Matrix user-status
profile updates (MSC4429/MSC4262).
Federation is advertised through Synapse's server well-known endpoint at
`https://matrix.mylogin.space/.well-known/matrix/server`, with external traffic
on port 443 routed by the Gateway to Synapse's internal port 8008.
It creates a `mylogin.space/v1alpha1` `User` service account and a retained
`synapse` database on the Backplane global PostgreSQL provider. The database
endpoint is intentionally `psql-int...`, never the site-local `psql-local...`
service; update the provider and host together through the owning ApplicationSet.

The chart also deploys [Matrix Authentication Service (MAS)](https://element-hq.github.io/matrix-authentication-service/)
at `matrix-auth.mylogin.space` for ElementX/native Matrix authentication. MAS
uses a dedicated PostgreSQL `User` database and the existing Authentik OIDC
client. When MAS is enabled, it owns the browser/OIDC login flow; Synapse's
legacy `oidc_providers` block is intentionally omitted to avoid conflicting
with delegated OAuth authentication. On first install, a restricted bootstrap Job generates its
`MATRIX_SECRET`, `ENCRYPTION_KEY`, and `RSA_KEY` into the retained Kubernetes
Secret `matrix-mas-runtime`; later reconciliations only reuse that Secret.
Alternatively, set `mas.keyGeneration.enabled` to `false` and provide the
existing Vault-backed Secret at `Social/Matrix/MAS`. Synapse delegates
authentication to MAS and serves the `org.matrix.msc2965.authentication`
advertisement from `/.well-known/matrix/client`.

The Authentik `preferred_username` is mapped to the Matrix localpart. Existing
MAS accounts are linked to this provider only when they do not already have a
link for it (`on_conflict: set`); keep the Authentik username stable and unique.

## Element Web optional features

Element Web feature flags are configured under the `features` object in the
generated `config.json`. The upstream [Labs feature list](https://github.com/element-hq/element-web/blob/develop/docs/labs.md)
is non-exhaustive and varies by Element release; this chart pins Element Web
`v1.12.29`. The following is the current inventory and the corresponding
homeserver assessment for this chart:

| Flag | Home-server status | Notes |
| --- | --- | --- |
| `feature_latex_maths` | Client-only | No additional Synapse setting is configured. |
| `feature_pinning` | Client/room support | No additional Synapse setting is configured. |
| `feature_jump_to_date` | Not enabled | Requires Synapse MSC3030 support; `msc3030_enabled` is not configured. |
| `feature_mjolnir` | Client/room support | Requires ban-list rooms and compatible moderation tooling. |
| `feature_dm_verification` | Client/room support | Uses MSC2241; compatibility should be tested with the deployed Synapse version. |
| `feature_bridge_state` | Client/room support | Requires compatible `m.bridge` state from a bridge. |
| `feature_location_share_live` | Client/room support | Requires compatible Matrix location-event support. |
| `feature_video_rooms` | Client/room support | Persistent video rooms require compatible room and call support. |
| `feature_element_call_video_rooms` | Conditional | Also requires `feature_video_rooms` and Element Call support. |
| `feature_disable_call_per_sender_encryption` | Client/Call support | Disables per-participant encryption for embedded Element Call. |
| `feature_notifications` | Client/room support | Element documents this as unreliable in encrypted rooms. |
| `feature_ask_to_join` | Server-dependent | Requires room-knock support in the homeserver. |
| `feature_exclude_insecure_devices` | Client/E2EE support | Changes which devices receive encrypted messages. |
| `feature_msc4362_encrypted_state_events` | Not enabled | Requires MSC4362 support from the homeserver and compatible clients. |
| `feature_notification_settings2` | Client/server-dependent | Replaces legacy push-rule settings; verify client-server compatibility. |
| `feature_user_status` | Supported by pinned image | Element is enabled and Synapse `v1.161.0` supports the chart's `include_profile_updates_in_sync: true` setting for MSC4429/MSC4262. |
| `feature_login_with_qr` | Not enabled | Requires the MSC4108 rendezvous endpoints; this chart does not configure them. |
| `feature_msc4095_url_preview_bundle` | Not enabled | Requires MSC4095 support from the homeserver. |

The current `feature_user_status` setting is paired with Synapse's
`include_profile_updates_in_sync: true` server setting. Validate the advertised
unstable features on the live homeserver before relying on it. See
the [Synapse profile-update setting](https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#-include-profile-updates-in-sync)
and [Element Web configuration reference](https://github.com/element-hq/element-web/blob/develop/docs/config.md).

The bootstrap Job has only namespace-scoped `get` and `create` access to
Secrets. It generates the RSA signing key as PKCS#8 PEM, which MAS accepts;
the encryption and Matrix secrets are generated as random hexadecimal values.
Deleting `matrix-mas-runtime` requires another Argo CD sync to regenerate it,
and should only be done after confirming that MAS data and recovery material
are no longer needed.

OIDC is provisioned through Authentik using the same Crossplane Terraform
`Workspace` pattern as the [Fediverse stack](https://github.com/K-FOSS/CoRE-Business/tree/main/Social/Fediverse).
Element automatically redirects unauthenticated users to Synapse SSO, which
then uses the Authentik OIDC provider. Authentik can in turn use CoRE LDAP.
Synapse's optional [LDAP password provider](https://github.com/matrix-org/matrix-synapse-ldap3)
is disabled by default and requires a separately managed bind-password Secret.

The future/live owner must be an explicit Backplane ApplicationSet using the
[global PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml)
and the [storage base ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Base.yaml).
The `User` claim follows the current [mylogin.space User XRD](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml).

Synapse signing keys, uploaded media, and temporary upload files are retained
on the Longhorn-backed homeserver PVC under `/data`. Before activation,
add an owner under `Apps/Business/Social/` and inject `cluster.name`,
`datacenter`, `region`, the global PostgreSQL values, and the target Gateway.
Verify both User/XR conditions and PostgreSQL Role/Database resources, the
Authentik Workspace callbacks, MAS health and discovery endpoints, the
ElementX well-known advertisement, federation port policy, and a real Element
and ElementX login after Argo CD reconciliation. Synapse recommends PostgreSQL
for production deployments and
documents federation and reverse-proxy requirements in its [installation guide](https://github.com/element-hq/synapse/blob/develop/docs/setup/installation.md).

The chart currently sets Synapse's `allow_unsafe_locale` because the existing
global PostgreSQL database was created with `en_US.UTF-8` collation. Synapse
documents this as a compatibility override; the safest permanent remediation
is to stop the service, dump the database, and recreate it with UTF-8,
`LC_COLLATE=C`, `LC_CTYPE=C`, and `template0`, then restore it. Do not drop the
database or change its locale in place without a tested backup.

## Synapse to MAS migration

The manually enabled, one-shot `syn2mas` Job and its check, disposable dry-run,
maintenance, validation, and rollback procedure are in
[docs/MAS-MIGRATION.md](docs/MAS-MIGRATION.md). It uses the existing pinned MAS
`1.20.0` image and generated runtime configuration, preserves the
`oidc-authentik` provider mapping, and is disabled during ordinary Argo CD
synchronizations.
