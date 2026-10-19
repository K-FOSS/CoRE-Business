#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
render_file="$(mktemp)"
trap 'rm -f "$render_file"' EXIT

helm template core-home1-talos-prod-business-mail "$repo_root/Mail" \
  --namespace core-prod \
  --set cluster.name=core-home1-talos-prod \
  --set clusterDNS=k0s.resolvemy.host \
  --set site.ldap.hostname=ldap-yvr.mylogin.space \
  --set site.psql.hostname=psql-local.home1-k3s-node1.yvr.mylogin.space \
  --set credentialsSync.hubCluster=dc1-k3s-node1 \
  >"$render_file"

require_rendered() {
  if ! rg -Fq -- "$1" "$render_file"; then
    printf 'Missing rendered configuration: %s\n' "$1" >&2
    exit 1
  fi
}

reject_rendered() {
  if rg -Fq -- "$1" "$render_file"; then
    printf 'Unexpected rendered configuration: %s\n' "$1" >&2
    exit 1
  fi
}

require_rendered "CONF_VIRTUAL_ALIAS_DOMAINS: 'snd.fyi,resolvemy.host,writemy.codes'"
require_rendered "CONF_VIRTUAL_MAILBOX_DOMAINS: 'mail.mylogin.space'"
require_rendered "CONF_VIRTUAL_ALIAS_MAPS: 'ldap:/etc/postfix/ldap.cf'"
require_rendered "CONF_VIRTUAL_MAILBOX_MAPS: 'ldap:/etc/postfix/ldap-in.cf'"
require_rendered "CONF_VIRTUAL_TRANSPORT: 'lmtp:inet:mail.mylogin.space:2525'"
require_rendered "CONF_MYNETWORKS: '172.20.52.0/22'"
require_rendered "CONF_MESSAGE_SIZE_LIMIT: '100000000'"
require_rendered "CONF_SMTPD_SASL_TYPE: 'dovecot'"
require_rendered "CONF_SMTPD_SASL_AUTH_ENABLE: 'yes'"
require_rendered "CONF_SMTPD_USE_TLS: 'yes'"
require_rendered "CONF_SMTPD_REJECT_UNLISTED_RECIPIENT: 'yes'"
require_rendered "permit_sasl_authenticated,permit_mynetworks,reject_unauth_destination"
require_rendered 'reject_authenticated_sender_login_mismatch'
require_rendered "query_filter = (&(objectClass=group)(mailacceptinggeneralid=%s))"
require_rendered "result_attribute ="
require_rendered "special_result_attribute = member"
require_rendered "leaf_result_attribute = mail"
require_rendered 'query_filter = (&(objectClass=user)(ak-active=TRUE)(|(cn=%u)(mail=%s)))'
require_rendered 'result_attribute = mail, cn'
require_rendered 'result_attribute = cn'
require_rendered "CONF_SMTPD_SENDER_LOGIN_MAPS: 'ldap:/etc/postfix/ldap-auth.cf'"
require_rendered "CONF_SMTPD_MILTERS: 'inet:int-rspamd.mylogin.space:11332'"
require_rendered "CONF_NON_SMTPD_MILTERS: 'inet:int-rspamd.mylogin.space:11332'"
require_rendered 'image: kristianfoss/postfix:core@sha256:a799022b5250ecf83b3cb2d3a07ea6bf492a63a8fece7a1de1e5f37288305593'
reject_rendered 'CONF_RELAY_DOMAINS:'
reject_rendered 'ldap-relay.cf'

printf 'Postfix alias Helm render checks passed.\n'
