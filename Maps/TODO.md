# CoRE Maps TODO

This is an implementation plan for the proposed CoRE Maps platform. The
directory currently contains documentation only. Do not mark work complete
unless repository content, an approved design record, or an operator
verification establishes that it is complete.

## Phase 0 — Research and design

- [ ] Confirm the active CoRE-Backplane Business ApplicationSet owner, target
  clusters, destination namespace, injected values, and Lovely renderer.
- [ ] Confirm whether `core-maps-prod`,
  `core-home1-talos-prod-business-maps-prod`, `core-maps`, `maps`,
  `maps.mylogin.space`, and `maps-api.mylogin.space` fit active naming rules.
- [ ] Inspect the final composition unit before implementation: Helm,
  Kustomize, raw resources, remote resources, and injected values.
- [ ] Verify the current upstream releases, supported APIs, image availability,
  and licenses for MapLibre, Martin, Photon, Valhalla, Planetiler, Osmium,
  MOTIS, OpenTripPlanner, and Dawarich.
- [ ] Confirm the compatible [BJW-S Common library](https://bjw-s-labs.github.io/helm-charts/docs/common-library/)
  version from current repository and upstream constraints.
- [ ] Decide whether Maps is one Helm release or whether build/import jobs need
  separate ownership from serving workloads.
- [ ] Determine regional source datasets and the permitted refresh method.
- [ ] Record expected PBF, PMTiles, index, graph, PostgreSQL, scratch, and
  backup sizes for British Columbia and Ontario.
- [ ] Estimate CPU, memory, build time, and persistent storage requirements for
  each service and import job.
- [ ] Define initial API contracts, response formats, rate limits, CORS, cache
  behavior, and attribution behavior.
- [ ] Define the TS-TransitRouting contextual request model for battery,
  measured walking/running pace, charging needs, trusted pickup/drop-off
  options, and mixed-mode itinerary legs.
- [ ] Define privacy boundaries so battery, health/fitness, contacts, and
  relationship data never appear in public tiles, public URLs, or public logs.
- [ ] Identify the authoritative CoRE sources for battery state, health/fitness
  summaries, contacts, availability, rideshare state, and personal history.
- [ ] Define public versus private endpoints and the required Authentik or other
  access policy for each API.
- [ ] Confirm the Gateway, listener, cross-namespace permissions, and route
  policy required for the proposed hostnames.
- [ ] Review the site-local storage and PostgreSQL configuration from the
  [storage ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/Base.yaml)
  and [PostgreSQL ApplicationSet](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Apps/Storage/PSQL.yaml).
- [ ] Define dataset manifests, checksums, signing/integrity metadata, and
  immutable version naming.
- [ ] Define per-trip consent, revocation, permission scopes, stale-data
  handling, and an audit trail for contextual recommendations.
- [ ] Decide how YVR and YXL replication will work for object artifacts,
  indexes, graphs, and custom spatial records.
- [ ] Confirm the current [mylogin.space User resource definition](https://github.com/K-FOSS/CoRE-Backplane/blob/main/Operations/SSO/User/templates/User/UserResourceDef.yaml)
  before creating any identity or entitlement resources.

### Phase 0 acceptance criteria

- [ ] A written design records the owner, namespace, renderer, routes, data
  sources, component versions, licenses, storage estimates, API boundaries,
  and public/private exposure.
- [ ] The selected initial tile, geocoder, and routing approaches are supported
  by a small local proof of concept or explicit documented reason for deferral.
- [ ] No required dependency relies on a commercial per-request mapping API.

## Phase 1 — Vancouver map

- [ ] Prepare an initial BC/Vancouver extract from the approved
  [Geofabrik BC source](https://download.geofabrik.de/north-america/canada/british-columbia.html).
- [ ] Record source URL, source timestamp, license, file size, and checksum.
- [ ] Validate the PBF and extract boundaries with Osmium.
- [ ] Decide whether the proof of concept uses the smaller Vancouver extract or
  the full BC extract.
- [ ] Deploy or package a compatible MapLibre frontend.
- [ ] Deploy or package Martin if the selected serving strategy requires it.
- [ ] Generate and publish Vancouver PMTiles or another validated tile archive.
- [ ] Configure MapLibre styles, fonts, sprites, source URLs, and attribution.
- [ ] Validate HTTP Range requests, cache headers, CORS, and compression.
- [ ] Verify map rendering across low, medium, and high zoom levels.
- [ ] Verify Vancouver, Burnaby, Coquitlam, Port Coquitlam, Port Moody, New
  Westminster, Richmond, Surrey, Delta, North/West Vancouver, Langley, Maple
  Ridge, and Fraser Valley coverage.
- [ ] Verify that a low-zoom global context map remains available.
- [ ] Add black-box tile and style checks.
- [ ] Verify visible OSM attribution and any additional tile-source attribution.

### Phase 1 acceptance criteria

- [ ] A user can load `maps.mylogin.space` through the approved Gateway route
  and see the Vancouver proof-of-concept map.
- [ ] Representative points render at every intended zoom range without
  browser CORS, Range, style, or sprite failures.
- [ ] The dataset manifest identifies the exact source and artifact version,
  and the previous artifact can be restored without rebuilding it.

## Phase 2 — Search and routing

- [ ] Choose Photon or Nominatim as the initial geocoder; keep the other
  optional rather than deploying both by default.
- [ ] Prepare a search index for the exact Vancouver coverage.
- [ ] Deploy or package the selected geocoder and its persistent index.
- [ ] Test address autocomplete and multilingual/place-name search.
- [ ] Test forward place search, bounding-box bias, and POI filtering.
- [ ] Test reverse geocoding for roads, addresses, and rural locations.
- [ ] Add index freshness and import health checks.
- [ ] Build Valhalla routing graphs for continuous Vancouver coverage.
- [ ] Deploy or package Valhalla with independent resources and probes.
- [ ] Test driving routes.
- [ ] Test walking routes.
- [ ] Test cycling routes.
- [ ] Test route continuity across municipal boundaries and highways.
- [ ] Test GPS trace map matching with representative traces and poor GPS
  points.
- [ ] Define and test routing error behavior, timeouts, and request limits.
- [ ] Publish route and geocoding API contracts behind `maps-api.mylogin.space`.
- [ ] Prototype per-person walking/running pace from an authorized aggregated
  health/fitness summary, with confidence and conservative fallback behavior.
- [ ] Add battery-reserve constraints and recommend a public charger or an
  explicitly permitted friend/family charging stop.
- [ ] Model mixed-mode itineraries such as train → Uber → friend pickup and
  expose each leg’s provider, consent requirement, and fallback.
- [ ] Test friend/family pickup and drop-by options without exposing their
  location or availability to unauthorized users.
- [ ] Explain contextual recommendations with the signal, freshness, confidence,
  and time/privacy trade-off used.

### Phase 2 acceptance criteria

- [ ] Search returns correct results for representative Vancouver addresses,
  places, and reverse coordinates.
- [ ] Driving, walking, and cycling requests return valid routes across the
  initial regional boundary and fail with useful errors outside coverage.
- [ ] Map matching is tested with a known trace and its coverage/accuracy
  limitations are documented.
- [ ] Search and routing are independently observable through latency, error,
  freshness, and black-box checks.

## Phase 3 — Ottawa–Windsor

- [ ] Download the approved
  [Geofabrik Ontario extract](https://download.geofabrik.de/north-america/canada/ontario.html).
- [ ] Record source URL, source timestamp, license, file size, and checksum.
- [ ] Prepare continuous Ottawa–Windsor coverage rather than disconnected city
  datasets.
- [ ] Confirm whether the full Ontario dataset is required for connectivity.
- [ ] Publish southern Ontario tiles.
- [ ] Extend the selected geocoding index and validate index sizing.
- [ ] Extend Valhalla routing coverage and validate graph sizing.
- [ ] Verify Ottawa, Kingston, Belleville, Peterborough, Oshawa, Durham,
  Toronto, Peel, York, Halton, Hamilton, Niagara, Guelph, Kitchener, Waterloo,
  Cambridge, Brantford, London, Sarnia, Windsor, surrounding communities, and
  connecting highways.
- [ ] Test Ottawa–Toronto routing.
- [ ] Test Toronto–London routing.
- [ ] Test London–Windsor routing.
- [ ] Test cross-boundary routing between the listed municipalities.
- [ ] Document the resource difference between full Ontario and a custom
  Ottawa–Windsor extract.

### Phase 3 acceptance criteria

- [ ] A route can be calculated from Ottawa to Windsor without a disconnected
  dataset boundary.
- [ ] The requested cities, regions, communities, and connecting highways are
  present in basemap, search, and routing coverage or are explicitly listed as
  an upstream-data limitation.
- [ ] Ontario artifacts can be rolled back independently of Vancouver artifacts.

## Phase 4 — Europe

- [ ] Finalize selected European regions; London, Paris, Amsterdam, and Berlin
  remain examples rather than approved scope.
- [ ] Choose extracts from the [Geofabrik Europe source](https://download.geofabrik.de/europe.html).
- [ ] Verify local language, address, place-name, and attribution requirements.
- [ ] Prepare selected regional tiles.
- [ ] Extend geocoding coverage and test multilingual searches.
- [ ] Extend routing coverage and test regional boundaries.
- [ ] Test cross-boundary routes where the selected extracts support them.
- [ ] Confirm storage and build capacity before adding each region.
- [ ] Do not require a complete Europe or planet import for this phase.

### Phase 4 acceptance criteria

- [ ] Each European region has an explicit source, version, checksum, license,
  tile artifact, search artifact, and routing artifact.
- [ ] The global low-zoom basemap remains available outside detailed regions.
- [ ] Coverage, search, and routing boundaries are documented separately.

## Phase 5 — application integrations

- [ ] Connect Dawarich to self-hosted map tiles.
- [ ] Configure a supported self-hosted reverse-geocoding endpoint for Dawarich.
- [ ] Evaluate Valhalla map matching against the supported Dawarich version.
- [ ] Preserve existing Dawarich location-history records during integration.
- [ ] Evaluate Immich mapping integration and geographic photo searches.
- [ ] Expose geographic APIs to the personal-history application with explicit
  authorization and source identifiers.
- [ ] Add authorized local-AI tools for place search, reverse geocoding,
  routing, POI queries, and private-history queries.
- [ ] Evaluate Home Assistant private map rendering and geocoding.
- [ ] Ensure tracked devices and private zones cannot reach public endpoints.
- [ ] Verify that no integration duplicates complete source datasets without a
  retention or query requirement.

### Phase 5 acceptance criteria

- [ ] Dawarich works against CoRE Maps without making Dawarich the owner of
  shared map datasets.
- [ ] Immich, Home Assistant, and local-AI access is scoped to the minimum
  required APIs and cannot expose personal history publicly.
- [ ] Existing location history remains intact and recoverable.

## Phase 6 — extended features

- [ ] Evaluate whether an Overpass API is required for actual POI query demand.
- [ ] Implement bounded, rate-limited POI queries if required.
- [ ] Compare MOTIS versus OpenTripPlanner using the same representative OSM,
  GTFS, and GTFS-Realtime inputs.
- [ ] Review the early GO train/platform/car-position planning in
  [TransitRouting-Lab](https://github.com/K-FOSS/TransitRouting-Lab) and capture
  its assumptions before designing a production data model.
- [ ] Import TransLink GTFS and validate its license and refresh schedule.
- [ ] Investigate BC Transit GTFS and realtime availability.
- [ ] Import Metrolinx/GO Transit and UP Express data if permitted.
- [ ] Import OC Transpo data if permitted.
- [ ] Investigate TTC and other Ottawa–Windsor corridor operators.
- [ ] Validate static feeds with the [MobilityData GTFS Validator](https://github.com/MobilityData/gtfs-validator).
- [ ] Investigate realtime vehicle positions, trip updates, and service alerts;
  do not assume credentials are unnecessary.
- [ ] Add walking-to-transit access, transfers, and multimodal trip planning.
- [ ] Define versioned GO operational data for stations, platforms, train
  direction, consist size, car ordering, stopping position, accessible doors,
  platform paths, exits, and transfer geometry.
- [ ] Prototype recommending which GO train car or platform portion to board so
  the rider exits nearer to a transfer, accessible path, or pickup point.
- [ ] Add confidence labels and station-level fallback when consist, stop
  position, or platform assignment is unavailable.
- [ ] Evaluate terrain and custom geographic overlays.
- [ ] Evaluate offline mobile maps and MapLibre Native support.
- [ ] Define TS-TransitRouting experiments and compare context-aware ranking
  with unmodified OTP or MOTIS results.
- [ ] Test context-aware alternatives for battery reserve, charging access,
  friend/family pickup, public transit, rideshare, and measured walking pace.
- [ ] Test conservative fallbacks when health data, battery state, transit
  realtime, charger availability, or trusted-person availability is missing.

### Phase 6 acceptance criteria

- [ ] Transit is optional and does not make the base maps deployment unavailable.
- [ ] Every imported feed has a source, license, refresh policy, validation
  report, and rollback path.
- [ ] The chosen transit engine has documented API, memory, update, and
  maintenance characteristics for the intended regions.

## Phase 7 — resilience and operations

- [ ] Implement versioned dataset publishing with immutable manifests.
- [ ] Implement activation and rollback procedures for tiles, search, and
  routing artifacts independently.
- [ ] Configure service monitoring, alerting, and dashboards.
- [ ] Add black-box tile, search, reverse-geocode, route, and API checks.
- [ ] Implement scheduled dataset-refresh Jobs only after the build process is
  reproducible and resource-bounded.
- [ ] Separate scratch build storage from production serving storage.
- [ ] Configure S3 replication where the active storage design supports it.
- [ ] Evaluate YXL map-serving replicas and define stale-data behavior.
- [ ] Test PostgreSQL/PostGIS backup and recovery if custom spatial records are
  introduced.
- [ ] Test recovery from a failed PBF download, failed tile build, failed
  index build, failed graph build, and bad upstream feed.
- [ ] Document deletion behavior for PVCs, object versions, indexes, graphs,
  PostgreSQL records, and generated Secrets.
- [ ] Document operational ownership, runbooks, and failure handling.

### Phase 7 acceptance criteria

- [ ] A known-good dataset can be restored at both the artifact and serving
  layers without regenerating it.
- [ ] A failed refresh leaves the currently active dataset serving.
- [ ] Operators can identify stale data, broken imports, route failures,
  storage exhaustion, and public API errors from dashboards and alerts.
- [ ] Recovery and deletion effects are documented before production exposure.

## Blockers, dependencies, and unresolved decisions

- [ ] Active Backplane ownership and renderer have not yet been confirmed.
- [ ] Namespace, Application, release, chart, gateway, listener, and hostname
  compatibility remain provisional.
- [ ] Exact BJW-S Common version and whether multi-controller behavior covers
  each service must be verified before chart creation.
- [ ] Photon versus Nominatim is unresolved.
- [ ] Protomaps archives versus Planetiler-generated tiles is unresolved.
- [ ] MOTIS versus OpenTripPlanner is unresolved.
- [ ] S3 bucket/provider, PostgreSQL/PostGIS availability, StorageClasses,
  backups, retention, and YVR/YXL replication depend on site-local Backplane
  configuration.
- [ ] OSM and transit data terms may limit redistribution, realtime access, or
  public API exposure.
- [ ] Dawarich, Immich, Home Assistant, and local-AI compatibility requires
  version-specific testing.
- [ ] Business indicators and review ownership, moderation, licensing, and
  deletion rules are undefined.
- [ ] Contextual-routing data ownership, consent, revocation, auditability, and
  retention are undefined.
- [ ] The health/fitness summary contract must avoid exposing raw health records
  to the map service unnecessarily.
- [ ] Battery and charger compatibility, public charger status, rideshare
  availability, and trusted-person availability sources are not selected.
- [ ] Resource sizing is unknown until BC and Ontario proof-of-concept builds
  are measured.

## First implementation gate

Do not create Kubernetes resources until Phase 0 acceptance criteria are met.
The first technical proof should be a non-deployed Vancouver pipeline:

1. acquire a permitted OSM extract;
2. record its source metadata and checksum;
3. generate a small compatible vector-tile archive;
4. build one search index;
5. build and query one Valhalla graph; and
6. measure storage, memory, build time, and cross-boundary route behavior.

That result should drive the implementation chart, storage allocation, and
Backplane ApplicationSet design in a separate change.
