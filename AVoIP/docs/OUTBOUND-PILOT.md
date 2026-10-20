# Managed carrier egress

YVR outbound PSTN calls use the Asterisk SIP Core identity and the live AVoIP Admin routing catalog. The [AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml) configures the site services and Vault backed mTLS peers. Provider, extension, caller ID, and DID assignments remain dynamic catalog data.

## Signaling path

Asterisk sends an already canonical `+1` followed by ten digits to its selected private Kamailio. The private Kamailio authenticates the extension header and selects the authorized caller ID, provider, and site target from the current Admin snapshot. It preserves the Request-URI unchanged while forwarding through the authenticated carrier Kamailio peer. Carrier Kamailio applies the configured quota, sends the same full `+1` user part upstream, and anchors media through the existing RTPEngine path. No FreeSWITCH provider route or number prefix participates in outbound calls.

The FreeSWITCH Flowroute registration remains available for the inbound carrier profile and as a gateway target selected by the dynamic provider catalog. Its registration and TLS identity are transport configuration; Admin chooses the provider route for each call.

The site SIP identity advertised in Record-Route is `sip.<cluster>.<datacenter>.<region>.resolvemy.host` unless the site overrides `sip.siteHost` or the carrier instance `advertisedHost`. Public TLS routing uses the same site hostname. The chart's `RR_BACKEND_TO_CARRIER` route sets the provider-facing Record-Route to that public identity and the private leg to the internal Kamailio service identity.

## Number format and authorization

Every voice DID, caller ID, and PSTN destination is carried unchanged in full `+1` plus ten digit form across each SIP hop. The routing layer rejects values outside that representation; it does not strip or add a plus, normalize punctuation, apply a provider prefix, or filter individual destination numbers. Extension enablement, extension/provider assignments, caller ID ownership verification, inbound DID/provider assignments, and carrier quotas continue to control call authorization.

## Carrier SIP logging

Carrier Kamailio logs complete carrier-facing SIP requests and replies when `roleDefaults.carrier-sbc.sipLogging.carrierTraffic` is enabled. This includes SIP headers, phone identities, and SDP bodies. Keep access to those logs limited to the operators investigating calls and remove or disable the capture after the diagnostic need ends.
