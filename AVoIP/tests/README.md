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
