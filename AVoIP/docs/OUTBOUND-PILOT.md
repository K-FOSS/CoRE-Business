# Managed carrier egress

YVR outbound PSTN calls use FreeSWITCH, internal Kamailio and the live AVoIP Admin routing catalog. Asterisk is retained for voicemail only. The [AVoIP ApplicationSet](https://slop.writemy.codes/CoRE/CoRE-Backplane/src/branch/main/Apps/Business/AVoIP.yaml) configures the site services and Vault-backed mTLS peers. Provider, extension, caller ID, and DID assignments remain dynamic catalog data.

## Signaling path

FreeSWITCH sends the canonical `+1` plus ten-digit destination and authenticated extension identity to internal Kamailio. Internal Kamailio selects the authorized caller ID, provider, and site target from the current Admin snapshot, then forwards through the authenticated carrier Kamailio peer. Carrier Kamailio applies the configured quota, sends the same full `+1` user part upstream, and anchors media through the existing RTPEngine path. Asterisk does not participate in outbound call routing.

The FreeSWITCH Flowroute registration is disabled for the active-active
deployment to avoid duplicate carrier contacts. The non-registering TLS
gateway remains available as a provider target selected by the dynamic Admin
catalog; registration ownership must become singleton before restoring the
inbound carrier profile.

The site SIP identity advertised in Record-Route is `sip.<cluster>.<datacenter>.<region>.resolvemy.host` unless the site overrides `sip.siteHost` or the carrier instance `advertisedHost`. Public TLS routing uses the same site hostname. The chart's `RR_BACKEND_TO_CARRIER` route sets the provider-facing Record-Route to that public identity and the private leg to the internal Kamailio service identity.

## Number format and authorization

Every voice DID, caller ID, and PSTN destination is carried unchanged in full `+1` plus ten digit form across each SIP hop. The routing layer rejects values outside that representation; it does not strip or add a plus, normalize punctuation, apply a provider prefix, or filter individual destination numbers. Extension enablement, extension/provider assignments, caller ID ownership verification, inbound DID/provider assignments, and carrier quotas continue to control call authorization.

## Carrier SIP logging

Carrier Kamailio logs complete carrier-facing SIP requests and replies when `roleDefaults.carrier-sbc.sipLogging.carrierTraffic` is enabled. This includes SIP headers, phone identities, and SDP bodies. Keep access to those logs limited to the operators investigating calls and remove or disable the capture after the diagnostic need ends.
