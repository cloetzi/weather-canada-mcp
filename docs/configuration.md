# Configuration

Everything is set through environment variables. Secrets can also be read from a file named by the `*_FILE`
variant (for example Docker secrets); setting both is an error. stdio mode needs no variables at all.
Invalid settings stop the server at startup with every problem listed; `weather-canada-mcp check-config` shows
what a configuration enables.

## MCP endpoint

| Variable | Default | Purpose |
| --- | --- | --- |
| `WEATHER_MCP_AUTH_TOKEN` | (required for HTTP) | Bearer token(s) clients must send, comma-separated, each at least 32 characters (`openssl rand -hex 32`). `WEATHER_MCP_AUTH_TOKEN_FILE` reads them from a file. |
| `WEATHER_MCP_AUTH_DISABLED` | `false` | Serve HTTP without authentication. Only for a loopback-only setup; logged as a warning at every start. |
| `WEATHER_MCP_HOST` | `127.0.0.1` (`0.0.0.0` in the image) | Listen address for HTTP. |
| `WEATHER_MCP_PORT` | `8080` | Listen port for HTTP. |
| `WEATHER_MCP_PATH` | `/mcp` | Path of the MCP endpoint. `/healthz` is the health check. |
| `WEATHER_MCP_ALLOWED_HOSTS` | | Extra `Host` names accepted besides `localhost` and loopback addresses, comma-separated (`*` for any). |
| `WEATHER_MCP_ALLOWED_ORIGINS` | | Browser origins allowed to call the endpoint, comma-separated. |

## Tools and output

| Variable | Default | Purpose |
| --- | --- | --- |
| `WEATHER_MCP_TOOLS` | all | Only expose these tools (comma-separated names). |
| `WEATHER_MCP_EXCLUDE_TOOLS` | | Hide these tools. Unknown names in either list stop the server. |
| `WEATHER_MCP_LANG` | `en` | Default language of text fields (`en` or `fr`); each call can override it with `lang`. |
| `WEATHER_MCP_MAX_RESPONSE_BYTES` | `60000` | Largest tool result. A larger result is replaced by an error asking for less, never cut. The radar map image (about 120 to 200 KB) is not counted. |

## Requests to ECCC and NRCan

| Variable | Default | Purpose |
| --- | --- | --- |
| `WEATHER_MCP_USER_AGENT_CONTACT` | repository URL | URL or email appended to the User-Agent, so ECCC can reach whoever runs the server. |
| `WEATHER_MCP_REQUESTS_PER_SECOND` | `1.0` | Sustained rate of upstream requests, applied to each provider separately (ECCC, NRCan, and Avalanche Canada when enabled), with bursts of up to 12. A request waits for its turn as long as its tool call's 45-second deadline allows; one that would wait longer fails at once with a "try again" error. |
| `WEATHER_MCP_MAX_CONCURRENCY` | `4` | Requests to ECCC and NRCan in flight at once. |
| `WEATHER_MCP_TIMEOUT` | `20` | Seconds per upstream request attempt. |
| `WEATHER_MCP_MAX_DOWNLOAD_BYTES` | `5242880` | Largest upstream JSON response read, after decompression. Map images and the place-name archive have their own, fixed limits. |
| `WEATHER_MCP_CACHE_SCALE` | `1.0` | Multiplier on every cache TTL (`0` disables caching). Defaults: forecasts 10 min, alerts 5 min, the forecast site list 24 h. An expired entry is kept as long again (at most 6 h): when the service cannot be reached or answers with a server error the stale data is returned with a `note` giving its time (the next try waits a few seconds), and a stale alert list says prominently that it could not be refreshed. |
| `WEATHER_MCP_ECCC_API_URL`, `WEATHER_MCP_GEOMET_URL`, `WEATHER_MCP_CGN_URL`, `WEATHER_MCP_BASEMAP_URL` | official services (`BASEMAP` is NRCan's maps.geogratis.gc.ca, for the radar base map) | Point a service at a mirror, caching proxy or local fake. Logged as a warning when not the default. |

### Limits that are not settings

A tool call is stopped after 45 seconds, and a call that arrives while 8 are already running is refused, so a slow
upstream cannot pile up work. The caches keep at most 64 MB of data and 32 MB of map images, dropping the least recently
used entries first.

## Avalanche Canada (opt-in)

Off by default. Avalanche Canada publishes no open licence, and its Terms of Use forbid reproducing its content
without prior written consent, so turn these on only where you have that consent or your use is otherwise
permitted. While they are off, the tool manifest is unchanged and no request goes to Avalanche Canada.

| Variable | Default | Purpose |
| --- | --- | --- |
| `WEATHER_MCP_AVALANCHE` | `false` | Adds `get_avalanche_forecast`, `get_avalanche_danger_overview` and `get_mountain_weather_stations`, and allows requests to the two URLs below. |
| `WEATHER_MCP_AVALANCHE_REPORTS` | `false` | Also adds `get_field_reports` (Mountain Information Network reports). Needs `WEATHER_MCP_AVALANCHE=true`. Submitters' names and ids are never returned, and contact details in the text are removed. |
| `WEATHER_MCP_AVALANCHE_URL` | `https://avcan-services-api.prod.avalanche.ca` | Forecasts, forecast metadata and field reports. |
| `WEATHER_MCP_AVALANCHE_STATIONS_URL` | `https://weather.prod.avalanche.ca` | Mountain weather stations and their measurements. |

These requests use their own rate limit (Avalanche Canada's, apart from ECCC's and NRCan's) and share the concurrency limit and timeout above. Cache times: forecasts 20 min (per point,
rounded to 0.01°), forecast metadata 1 h, the station list 24 h, station measurements 10 min, field reports 15 min.

## Place names

| Variable | Default | Purpose |
| --- | --- | --- |
| `WEATHER_MCP_GAZETTEER_PATH` | `$XDG_CACHE_HOME/weather-canada-mcp/gazetteer-v1.sqlite3` (`/app/data/gazetteer.sqlite3` in the image) | SQLite place-name database. Built on first use if missing (about 16 MB download, 60 MB on disk). Over stdio the build starts at startup in the background, and place-name lookups answer "being set up, retry" until it is done (pass `lat` and `lon` meanwhile); over HTTP the first lookup waits for it. `weather-canada-mcp gazetteer update` rebuilds it. |

## Logging

| Variable | Default | Purpose |
| --- | --- | --- |
| `WEATHER_MCP_LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error`. Logs go to stderr. `debug` adds one `upstream_request` line per upstream request or cache hit (origin, collection or layer, status, `duration_ms`, `limiter_wait_ms`, `cache_hit`; never a query, id or coordinate); `tool_call` lines carry `upstream_requests` and `cache_hits`. |
| `WEATHER_MCP_LOG_FORMAT` | `text` | `text` or `json`. Tool arguments (locations) are never logged. |
