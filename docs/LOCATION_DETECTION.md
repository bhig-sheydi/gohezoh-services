# Permission-based delivery address detection

The customer opens **Edit my delivery info**, then chooses **Get address** or manual entry. Opening the dashboard/editor never requests device location. A suggested address must be reviewed before Save location. Missing provider fields preserve existing input. Customers can correct every field and adjust a pin on a map.

## Architecture and privacy

- `proximity.ts` retains the existing browser and native-container interfaces. Browser location can combine GPS, Wi-Fi and network sources: the app calls it a device reading, never guaranteed GPS. Native containers must obtain operating-system permission themselves and return the real accuracy/timestamp. They receive high-accuracy/max-age/timeout options; missing or fabricated fields are rejected. The web page cannot verify that a native container implemented its permission UI.
- Browser acquisition requires a secure context, requests high accuracy, maximumAge 0 and a 12-second timeout. Native replies have a 15-second watchdog. Address detection takes at most two readings, retries only temporary unavailability/timeouts, and keeps the better valid reading. Denied permission is never automatically retried. Coarse readings are also reverse-geocoded after refinement, with a short approximate-address notice. Better readings do not guarantee building accuracy.
- Readings record latitude, longitude, reported accuracy in meters, capture timestamp and source in memory only. A map-selected point has source `map`, a selection timestamp and accuracy `null`. Neither map selection nor provider confidence is device accuracy.
- Authenticated Supabase Edge Function `location-address` owns `GEOAPIFY_API_KEY`. The frontend sends POST bodies with only coordinates or explicitly entered search text. The key is absent from the frontend bundle. Do not configure it with a `VITE_` prefix.
- The proxy uses fixed Geoapify hosts and whitelisted actions, validates input/output, rejects redirects, caps body sizes, and sends `Cache-Control: no-store`. It does not log payloads, keep result caches, or write to the database. Provider infrastructure and platform request metadata remain subject to their own retention policies.
- The editor clears transient location evidence when closed/unmounted or saved. The existing destination table saves only the address, city, state and optional phone. Accepted Parcel Pal access follows existing database policies. No location history or automatic tracking is added; no migration is needed.

## Supported Geoapify capabilities

Documentation checked on 2026-10-14:

| Capability | Documented endpoint and parameters | Response used |
| --- | --- | --- |
| Reverse geocoding | `GET https://api.geoapify.com/v1/geocode/reverse`, `lat`, `lon`, `format=json`, `lang=en`, `limit=1`, `apiKey` | `results[]`, address parts, `lat`, `lon`, `result_type`, optional `distance`, optional `rank.confidence` |
| Address search for map correction | `GET https://api.geoapify.com/v1/geocode/search`, `text`, `filter=countrycode:ng`, `bias=countrycode:none`, `format=json`, `lang=en`, `limit=1`, `apiKey` | Same normalized address schema; no provider IP-location bias |
| Map imagery | `GET https://maps.geoapify.com/v1/tile/osm-bright/{z}/{x}/{y}.png`, `apiKey` | Validated 256 px PNG raster tiles; application zoom cap 19 |

API-key authentication is documented for these endpoints. IP geolocation, route snapping and undocumented precision/GPS capabilities are not used. Returned city/state may be absent; the customer supplies missing fields manually. Provider result distance and optional confidence are evaluated independently from device accuracy. Unknown/malformed schemas are rejected.

Sources: [reverse geocoding](https://apidocs.geoapify.com/docs/geocoding/reverse-geocoding/), [address search](https://apidocs.geoapify.com/docs/geocoding/), [raster maps](https://apidocs.geoapify.com/docs/maps/map-tiles/), [pricing](https://www.geoapify.com/pricing/), [credit costs](https://www.geoapify.com/pricing-details/), [W3C Geolocation](https://www.w3.org/TR/geolocation/).

The published free plan provides 3,000 credits/day and up to 5 requests/second for geocoding, with one reverse/search request costing one credit. Raster tiles cost 0.25 credit each. The customer editor makes no search or tile requests. Existing server search/tile capabilities remain unused. Geoapify/OpenStreetMap attribution is displayed. Actual account usage and key restrictions must be checked in the owner's provider dashboard.

## Google Maps evaluation mode

For this prototype, set `VITE_GOOGLE_MAPS_DEMO_KEY` in ignored `.env.local` or the Vercel environment used for app testing. The customer address search, reverse lookup, nearby suggestions, and correction map then use Google Maps. `/google-location-test` is a development-only comparison page. The key is loaded in the browser as required by Maps JavaScript API. Google describes demo keys as for testing and prototyping, not a permanent production setup; replace it with a standard restricted key before commercial launch. Google place content is shown with Google Maps attribution and on a Google map. Rider road-matrix planning continues to use Geoapify until its own provider migration is implemented and verified.

The chosen GPS or manual pin stays the authoritative point; a geocoder's nearby building coordinate is only a label and is not substituted for a phone fix. Google Maps can still return an incorrect or distant address, so check the result and confirm the pin. See [Google demo-key restrictions](https://developers.google.com/maps/demo-key), [Maps JavaScript text search](https://developers.google.com/maps/documentation/javascript/place-search), and [Google Places display policies](https://developers.google.com/maps/documentation/places/web-service/policies).

## Reliability and limits

Concurrent identical requests share in-flight work, with no persistent result cache. Closing the editor aborts pending requests and ignores late replies. Inputs are disabled while detection runs so a late response cannot overwrite edits. Requests stop on denied permission, invalid readings, cancellation or HTTP 429. HTTP 429 exposes Retry-After to the UI; there is no automatic client retry storm. Provider network/5xx failures get at most two server attempts with an 8-second upstream timeout per attempt and bounded response sizes. Client proxy calls time out after 20 seconds; Auth verification uses a 5-second timeout. The total worst-case path may exceed the client deadline; stale responses are ignored after cancellation.

Per-user abuse counters retain only identifiers/counts for up to a minute, capped at 2,000 entries. They allow 30 geocoding operations and 180 tile operations per minute per running isolate. They are best-effort protection, **not a distributed account-wide quota**. A distributed limiter/provider account quota is needed before substantial public traffic if strict budget enforcement is required. No hard daily billing guarantee is claimed.

Tile responses use `application/octet-stream` with `X-Image-Type: image/png`: the installed Supabase Functions client otherwise parses `image/png` as text. The frontend wraps validated binary as PNG for rendering.

## Deployment and verification

Set Supabase secret `GEOAPIFY_API_KEY` for project `yejiqfocqmdxjeajoexd`; optional `PUBLIC_APP_URL` sets the single allowed production origin. Production defaults to `https://gohezoh-services.vercel.app`; localhost 3000/5173 is also allowed. Preview origins require an explicit policy change, rather than wildcard access. Missing Origin is permitted for native/CLI clients but still requires authentication.

Deploy `location-address` with this repo's `verify_jwt=false` function configuration. Every POST independently checks the bearer token with Supabase Auth; disabling the legacy gateway check does not make requests anonymous. The function uses the anonymous project key for Auth verification and no service-role key.

Deploy the frontend only after the proxy is available. `VITE_GEOAPIFY_API_KEY` becomes unused and can be removed from Vercel after deploying this frontend. A previously published browser key is not made secret retroactively; issue a separate server key in Geoapify and update the Supabase secret if secrecy is required. Do not create false HTTP-referrer headers to evade provider key restrictions.

Automated coverage includes device permission/security/native validation/cancellation, bounded capture attempts, normalized API validation, authorization/origin/input limits, provider quotas/outages/timeouts, real Supabase binary parsing, coarse autofill and manual correction, manual save without geolocation, late-result handling and non-persistence of location evidence. Browser mocks cannot establish real phone or MiFi accuracy. A physical phone test must verify permission prompts, precise-location settings, manual correction and building confirmation.
