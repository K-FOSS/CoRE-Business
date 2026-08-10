# CoRE Vaultwarden

This chart deploys Vaultwarden and its platform identity/secret resources.
[The VaultWarden ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Tools/VaultWarden.yaml) selects all tenant
bare-metal clusters and deploys into `core-prod` through Lovely.

Backplane injects the public domain, PostgreSQL connection URI and SMTP values
from existing secrets. Local templates can create a CoRE `User`, pull
credentials with ExternalSecret and publish generated credentials with
PushSecret. The `user.enabled` switch controls that lifecycle.

Important current settings include disabled persistence, PostgreSQL as the
injected database backend and enabled public sign-up/invitation behaviors.
Review those values as security and data-durability decisions, not merely
application preferences. Multi-cluster selection also requires checking which
cluster owns writable data and external identity resources.

```sh
helm dependency build Passwords/VaultWarden
helm lint Passwords/VaultWarden
helm template core-business-vaultwarden Passwords/VaultWarden --values Passwords/VaultWarden/values.yaml >/tmp/core-business-vaultwarden.yaml
```

Validate database and SMTP secret keys, gateway exposure, account-creation
policy, backup/restore behavior and Crossplane/External Secrets conditions.
Test login, invite/email delivery and vault read/write after reconciliation.

## Upstream projects

- [Vaultwarden website](https://www.vaultwarden.net/) and [project wiki](https://github.com/dani-garcia/vaultwarden/wiki)
- [Vaultwarden source](https://github.com/dani-garcia/vaultwarden)
- [External Secrets website and documentation](https://external-secrets.io/)
- [bjw-s common chart documentation](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
