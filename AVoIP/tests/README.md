# AVoIP render checks

Run the WSS edge rendering checks from the repository root:

```sh
helm lint AVoIP
AVoIP/tests/wss-ha-render.sh
```

The WSS test renders both a selected three-replica tier and a separate staged
pilot. It checks the headless owner Service, stable StatefulSet identity,
two-pod disruption floor, existing Envoy backend Service and `/ws` contract,
Path module/configuration, Asterisk `support_path=yes`, legacy proxy omission,
gateway timeout values, TLS SAN, and invalid timeout rejection. It does not
exercise live Path routing, the custom Asterisk runtime image, WSS connection
draining, Envoy distribution, or RTP.

The working tree provided for this implementation does not contain the
previously referenced `kamailio-instances.sh`,
`asterisk-sipcore-render.sh`, `sip-security-render.sh`, or
`sip-registrar-render.sh` scripts. Verify their current tracked status before
using older runbook commands; they were not replaced by this focused test.

Before activation, validate the generated configuration with the pinned
Kamailio image and validate generated PJSIP with the deployed Asterisk image.
Then execute every live acceptance step in
[SIP Stateful HA](../docs/SIP-STATEFUL-HA.md#operational-inspection-and-live-acceptance).
