# CoRE OpenProject

This chart deploys the [OpenProject Community image](https://www.openproject.org/)
with the [BJW-S common library](https://bjw-s-labs.github.io/helm-charts/docs/common-library/).
The active [Projects ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Business/Projects.yaml)
selects `core-home1-talos-prod`, renders this path with Lovely and deploys it to
`core-prod` at `projects.mylogin.space`.

## Identity and secret loading

The chart uses the current
[`mylogin.space/v1alpha1` User XRD](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml)
and its active `sso-user` Composition. The claim grants the existing
`Gmdfb5HXbk` PostgreSQL database and named S3 bucket, creates temporary
LDAP-derived S3 credentials, and writes them to
`business-projects-openproject-s3-prod`. The required credential reference is
explicit because the XRD rejects `createCredentials: true` without it.

The OpenProject pod reads the User claim Secret for the generated PostgreSQL
username/password and bucket directory, and reads the generated S3 Secret for
`AccessKey`, `SecretAccessKey`, and `SessionToken`. Stakater Reloader restarts
the pod when either Secret changes; temporary S3 credentials are refreshed by
the User Composition and should not be copied into Vault or Git.

The claim's database and bucket resources use the current Composition's orphan
behavior. Removing the Argo application therefore does not constitute data
deletion; decommission PostgreSQL roles, databases, buckets and S3 policies
separately after confirming backups and retention requirements.

## Validation

```sh
helm dependency build Projects
helm lint Projects
helm template core-home1-talos-prod-business-projects-prod Projects \
  --namespace core-prod \
  --api-versions gateway.networking.k8s.io/v1/HTTPRoute \
  >/tmp/core-business-projects.yaml
git diff --check -- Projects
```

Inspect the complete Lovely render before reconciliation. Verify the User
claim, PostgreSQL role/grants, S3 credential Secret, PVC, Service and Gateway
route conditions after Argo CD applies the chart. Do not print rendered Secret
data.

## Upstream projects

- [OpenProject website and documentation](https://www.openproject.org/docs/)
- [OpenProject source repository](https://github.com/opf/openproject)
- [OpenProject container images](https://hub.docker.com/r/openproject/community)
- [BJW-S common chart](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
- [Stakater Reloader](https://github.com/stakater/Reloader)
- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/)
