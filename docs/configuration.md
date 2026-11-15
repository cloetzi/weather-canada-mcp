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
| `WEATHER_MCP_REQUESTS_PER_SECOND` | `1.0` | Sustained rate for all upstream requests together (short bursts of 4 are allowed). |
| `WEATHER_MCP_MAX_CONCURRENCY` | `4` | Requests to ECCC and NRCan in flight at once. |
| `WEATHER_MCP_TIMEOUT` | `20` | Seconds per upstream request attempt. |
| `WEATHER_MCP_MAX_DOWNLOAD_BYTES` | `20971520` | Largest upstream response read, after decompression. |
| `WEATHER_MCP_CACHE_SCALE` | `1.0` | Multiplier on every cache TTL (`0` disables caching). Defaults: forecasts 10 min, alerts 5 min, the forecast site list 24 h. |
| `WEATHER_MCP_API_URL`, `WEATHER_MCP_DATAMART_URL`, `WEATHER_MCP_GEOMET_URL`, `WEATHER_MCP_CGN_URL`, `WEATHER_MCP_BASEMAP_URL` | official services (`BASEMAP` is NRCan's maps.geogratis.gc.ca, for the radar base map) | Point a service at a mirror, caching proxy or local fake. Logged as a warning when not the default. |

## Place names

| Variable | Default | Purpose |
| --- | --- | --- |
| `WEATHER_MCP_GAZETTEER_PATH` | `$XDG_CACHE_HOME/weather-canada-mcp/gazetteer-v1.sqlite3` (`/app/data/gazetteer.sqlite3` in the image) | SQLite place-name database. Built on first use if missing (about 16 MB download, 60 MB on disk); `weather-canada-mcp gazetteer update` rebuilds it. |

## Logging

| Variable | Default | Purpose |
| --- | --- | --- |
| `WEATHER_MCP_LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error`. Logs go to stderr. |
| `WEATHER_MCP_LOG_FORMAT` | `text` | `text` or `json`. Tool arguments (locations) are never logged. |
