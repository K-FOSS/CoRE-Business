# AVoIP signaling regression scenarios

`udp-carrier-ack-bye.xml` exercises a UDP INVITE through one Kamailio replica,
checks that the 200 Contact is public UDP/5060 with a TOPOS token, and directs
the 2xx ACK and BYE to a second Kamailio pod. This verifies cross-replica
TOPOS lookup while the one-replica FreeSWITCH backend retains the call.
`tls-carrier-ack-bye.xml` exercises the site hostname's public TLS path and
checks that its Contact remains the site TLS identity on 5061. Both scenarios
hold the answered call for 65 seconds and require a successful BYE response.

Run only against a non-production test deployment with a DID whose backend
answers and holds the call for at least 65 seconds, and a controlled SIPp
runner. Keep the production `flowroute.signalingCIDRs` values
intact. For an isolated test deployment, inject only the runner's source range
through its test values; the production ACL is never broadened. Keep the runner
IP, site domain and call ID with the test record.

For UDP, use different running Kamailio pod IPs for the initial request and
dialog requests (they must be on the same site and use the same TOPOS store):

```sh
sipp -t u1 -sf udp-carrier-ack-bye.xml -s "$TEST_ANSWER_DID" \
  -set replica_ip "$KAMAILIO_POD_B_IP" \
  "$KAMAILIO_POD_A_IP":5060
```

The initial INVITE must enter pod A. SIPp's `setdest` directs the ACK and BYE
to pod B while their Request-URI remains the received TOPOS Contact. Run the
TLS scenario against the public site hostname. Confirm whether DNS/NAT delivers
that host to the Gateway TLSRoute or the direct KubeVIP Service before claiming
which ingress handled the session:

```sh
sipp -t l1 -tls_version 1.2 -sf tls-carrier-ack-bye.xml \
  -s "$TEST_ANSWER_DID" "$SITE_SIP_HOST":5061
```

For each scenario, correlate the same Call-ID in both Kamailio replicas, the
backend-facing Kamailio/Homer trace, and FreeSWITCH. Require the ACK at
FreeSWITCH, no repeat 200 or `ACK Timeout`, a call duration above 60 seconds,
and BYE/200 completion. A successful fax is a separate check: SIPp's audio
fixture is PCMU and does not emulate fax signaling or validate T.38/fax output.

The scenarios are regression fixtures, not evidence of a live fix. They have
not yet been run against a deployed Home1/DC1 stack; the acceptance steps above
must be recorded after a reviewed GitOps rollout.

## Authorization and outbound-call probes

Run `./sip-security-render.sh` after changing site values. It renders both
sites and checks that public UDP/TCP/TLS listeners retain the source ACL,
registration is denied, unmatched FreeSWITCH public destinations are rejected,
and the event socket remains bound to loopback. This is a configuration guard,
not a substitute for SIP responses from the deployed stack.

`sip-security-probes.py` sends negative SIP requests to a **non-production**
deployment. Use a test DID and an unassigned, non-routable outbound number;
capture each probe's Call-ID in Kamailio, FreeSWITCH, and Asterisk logs and
confirm no outbound gateway INVITE or billable call was generated. The script
prints response codes and Call-IDs and uses a deliberately wrong credential; do not
pass or log production credentials. Set the runner's source IP so the ACL role
under test is unambiguous. For example:

```sh
python3 sip-security-probes.py edge-denied \
  --host "$TEST_KAMAILIO_IP" --port 5060 --transport udp \
  --domain "$TEST_SIP_HOST" --did "$TEST_DID" \
  --outbound-number "$UNASSIGNED_TEST_NUMBER"

python3 sip-security-probes.py edge-allowed \
  --host "$TEST_KAMAILIO_IP" --port 5060 --transport udp \
  --domain "$TEST_SIP_HOST" --did "$TEST_DID" \
  --outbound-number "$UNASSIGNED_TEST_NUMBER"

python3 sip-security-probes.py private-auth \
  --host "$TEST_FREESWITCH_IP" --port 5062 --transport tls \
  --sni "$TEST_FREESWITCH_TLS_HOST" --ca "$TEST_CA_FILE" \
  --domain "$TEST_FREESWITCH_TLS_HOST" --did "$TEST_DID" \
  --outbound-number "$UNASSIGNED_TEST_NUMBER"

python3 sip-security-probes.py asterisk-auth \
  --host "$TEST_ASTERISK_IP" --port 5061 --transport tls \
  --sni "$TEST_ASTERISK_TLS_HOST" --ca "$TEST_CA_FILE" \
  --domain "$TEST_ASTERISK_TLS_HOST" --did "$TEST_DID" \
  --outbound-number "$UNASSIGNED_TEST_NUMBER"
```

`edge-denied` must receive 403 for OPTIONS, REGISTER, MESSAGE, and both DID
and outbound INVITEs, including a request with a bogus Authorization header.
`edge-allowed` verifies that an ACL-authorized carrier still cannot REGISTER
or dial an unmatched outbound destination. Carrier DID calls are intentionally
authorized by source CIDR; they do not use SIP digest credentials. Run the
edge probes over TLS as well (`--transport tls --port 5061 --sni ... --ca ...`)
and over TCP/5060 where the site enables it. On TLS, validate the certificate
hostname and chain through the supplied CA.

`private-auth` and `asterisk-auth` require an initial 401/407 challenge and
then rejection of a deliberately wrong digest for both the test DID and
unassigned number. Run these from a test pod whose source is permitted by the
private profile's ACL so a source denial cannot masquerade as a credential
check. The current Asterisk endpoint config has `outbound_auth` but no
inbound `auth` setting, and its identify rule matches broad private ranges;
**do not mark the private credential boundary accepted until this probe passes
and the backend configuration is corrected if it fails.**

No live authorization probe has been run by these repository checks. Passing
render assertions alone does not prove unauthenticated callers cannot reach
a SIP endpoint or that invalid credentials are rejected.
