# weather-canada-mcp

An unofficial, read-only [MCP](https://modelcontextprotocol.io) server that lets an AI assistant answer outdoor-trip
weather questions for Canada with Environment and Climate Change Canada (ECCC) open data. No API keys, nothing to
configure for local use.

> "What's the forecast for Squamish this weekend, and are there any warnings?"
>
> "Is there a weather alert near Lake Louise right now?"

**Status: early development (M1).** Three tools work today; observations, rivers, air quality, snow outlook, radar,
marine forecasts and climate context follow (see the [roadmap](#roadmap)).

## Tools

| Tool | What it answers | Source |
| --- | --- | --- |
| `find_location` | Which places match a name (towns, parks, lakes, peaks, rivers), and the nearest ECCC forecast sites to a place or point | NRCan Canadian Geographical Names (offline), City Page site list |
| `get_forecast` | Current conditions, the official text forecast for about 6 days (with mountain snow levels where ECCC issues them), hourly forecast, sunrise/sunset and warning headlines | OGC API `citypageweather-realtime` |
| `get_alerts` | Active warnings, watches, advisories and statements covering a point, with the official text as issued | OGC API `weather-alerts` |

Every tool takes a `location` (`"Squamish"`, `"Lake Louise, AB"`) or `lat`/`lon`, and `lang` (`en` or `fr`).
Results are compact JSON with units in the field names, name the forecast site used and its distance, and carry
the required attribution. `bin/weather-canada-mcp tools` prints the full schemas.

## Running it

### Claude Desktop or Claude Code (stdio)

With Ruby 4.0:

```sh
gem install weather-canada-mcp        # once published; until then, run bin/weather-canada-mcp from a checkout
claude mcp add weather-canada -- weather-canada-mcp stdio
```

The first place-name lookup downloads NRCan's Canadian Geographical Names (about 16 MB) and builds a local SQLite
database (about 60 MB, 20 seconds). `weather-canada-mcp gazetteer update` does that up front, or refreshes it.

### Docker (HTTP)

```sh
openssl rand -hex 32 > token
docker run -d --name weather-canada-mcp --read-only --cap-drop ALL --security-opt no-new-privileges \
  -p 127.0.0.1:8080:8080 -e WEATHER_MCP_AUTH_TOKEN="$(cat token)" ghcr.io/cloetzi/weather-canada-mcp:latest
claude mcp add --transport http weather-canada http://127.0.0.1:8080/mcp --header "Authorization: Bearer $(cat token)"
```

The image includes the place-name database. See [compose.yaml](compose.yaml) for a deployment with Docker secrets
and [docs/configuration.md](docs/configuration.md) for every setting.

## Data, licences and fair use

- Weather data: **Data Source: Environment and Climate Change Canada**, under the
  [ECCC Data Servers End-use Licence](https://eccc-msc.github.io/open-data/licence/readme_en/). Alert text is
  passed through exactly as issued.
- Place names: Canadian Geographical Names, Natural Resources Canada, under the
  [Open Government Licence - Canada](https://open.canada.ca/en/open-government-licence-canada).
- This project is not affiliated with or endorsed by ECCC or NRCan. For safety-critical decisions use
  [weather.gc.ca](https://weather.gc.ca).
- The server stays well inside ECCC's fair-use guidance: one request per second sustained across all tools, a
  cache, and a User-Agent that names the project (add your own contact with `WEATHER_MCP_USER_AGENT_CONTACT`).

## Roadmap

1. **M2:** `get_current_observations` (SWOB stations, including snow depth), `get_river_conditions` (real-time
   hydrometric data compared with historical means), `get_air_quality` (AQHI).
2. **M3:** `get_snow_outlook` (HRDPS/RDPS snow level, accumulation and blowing snow), `get_radar_map`,
   `get_marine_forecast`, `get_climate_context` (normals and records).
3. **M4:** v1.0 with the gem and image published.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md). `bundle exec rake` runs RuboCop and the tests, which use real captured
ECCC responses served by a local fake, never the live services.

## Licence

[Apache 2.0](LICENSE). See [NOTICE](NOTICE) for data attributions.
