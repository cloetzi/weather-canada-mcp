# Security

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/cloetzi/weather-canada-mcp/security/advisories/new),
not in public issues. You will get an answer within a week. Fixes are released as soon as they are ready and
credited in the advisory unless you prefer otherwise.

Only the latest release is supported.

## Threat model

The server holds no upstream credentials: ECCC and NRCan open data need no key. What it protects is the MCP
endpoint itself (so strangers cannot use your server, or your share of ECCC's fair-use budget) and the machine it
runs on. The design assumes the network between the client and the server may be shared (a home network, a
container network) and that a browser on the same machine may visit hostile web pages.

| Asset | Protection |
| --- | --- |
| MCP endpoint | Bearer token required by default for HTTP, compared in constant time; at least 32 characters. Disabling authentication requires an explicit setting and is logged as a warning at every start. |
| Local browser attacks | `Host` and `Origin` validation against DNS rebinding and cross-site requests. |
| Locations people ask about | Tool arguments (which can reveal where someone is) are never logged; only tool names, durations and error classes are. |
| ECCC fair use | A global rate limiter (1 request/s by default), a TTL cache with request coalescing, and a descriptive User-Agent. |

Further design properties:

- **Read-only, fixed hosts.** The server only sends `GET` requests, and only to the configured upstream origins
  (`api.weather.gc.ca`, `geo.weather.gc.ca`, `ftp.maps.canada.ca` and `maps.geogratis.gc.ca` by default, plus
  `avcan-services-api.prod.avalanche.ca` and `weather.prod.avalanche.ca` only when the opt-in Avalanche Canada
  tools are enabled). Tool arguments
  are validated against their schema and never become a host or a path segment without validation and encoding.
- **Bounded resources.** Request bodies are capped at 1 MiB; upstream responses are capped after decompression
  (gzip bombs stop at the cap); requests are concurrency-limited and time-limited; results over
  `WEATHER_MCP_MAX_RESPONSE_BYTES` are replaced by an error rather than cut; the cache has a fixed size.
- **Parsing.** JSON is parsed with a nesting limit. The gazetteer archive is read with rubyzip, and the CSV inside is
  capped as it inflates (the size the archive declares is not trusted); a build that fails is never installed.
- **Minimal container.** Non-root user (65532), no writable paths, works with `--read-only` and
  `--cap-drop ALL`; the place-name database is built into the image; base images are pinned by digest.

## Out of scope

- TLS: the server speaks plain HTTP. Use a reverse proxy or VPN to reach it over untrusted networks.
- The accuracy of ECCC data, and what an MCP client or model does with it. This is an unofficial tool; for
  safety-critical decisions use [weather.gc.ca](https://weather.gc.ca).

## Recommendations

- Keep the port bound to `127.0.0.1` or a private network; do not expose it to the internet.
- Use Docker secrets (`WEATHER_MCP_AUTH_TOKEN_FILE`) rather than plain environment variables, which are visible in
  `docker inspect`.
- Give each client its own token (comma-separated) so you can revoke one without touching the others.
