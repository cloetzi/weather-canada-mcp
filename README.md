# weather-canada-mcp

An unofficial, read-only [MCP](https://modelcontextprotocol.io) server that lets an AI assistant answer outdoor-trip
weather questions for Canada with Environment and Climate Change Canada (ECCC) open data. No API keys, nothing to
configure for local use.

> "What's the forecast for Squamish this weekend, and are there any warnings?"
>
> "Is there a weather alert near Lake Louise right now?"

**Status: pre-release.** All ten planned ECCC tools work, plus opt-in Avalanche Canada tools. A first release (gem on GitHub Packages and a multi-architecture image on GHCR) follows once the tool contract is settled (see the [roadmap](#roadmap)).

## Tools

| Tool | What it answers | Source |
| --- | --- | --- |
| `find_location` | Which places match a name (towns, parks, lakes, peaks, rivers), and the nearest ECCC forecast sites to a place or point | NRCan Canadian Geographical Names (offline), City Page site list |
| `get_forecast` | Current conditions, the official text forecast for about 6 days (with mountain snow levels where ECCC issues them), hourly forecast, sunrise/sunset and warning headlines | OGC API `citypageweather-realtime` |
| `get_alerts` | Active warnings, watches, advisories and statements covering a point, with the official text as issued | OGC API `weather-alerts` |
| `get_current_observations` | The latest measured temperature, wind and gusts, pressure, visibility, precipitation, snowfall and snow depth at the nearest weather stations, with their elevation | OGC API `swob-stations`, `swob-realtime` |
| `get_river_conditions` | Real-time water level and flow at the nearest gauges, the 24-hour change and 3-day range, and how the flow compares with the historical mean for the month | OGC API `hydrometric-stations`, `hydrometric-realtime`, `hydrometric-monthly-mean` |
| `get_air_quality` | The Air Quality Health Index now and forecast for the next days, with the health messages for each risk level | OGC API `aqhi-observations-realtime`, `aqhi-forecasts-realtime` |
| `get_snow_outlook` | Model guidance for the next 12 to 48 hours: snow level, new snow (water equivalent) and blowing snow probability at a point | GeoMet WMS: HRDPS and RDPS model fields |
| `get_marine_forecast` | The marine forecast for coastal waters and large lakes: wind, weather, waves, freezing spray, the extended outlook and marine warnings | OGC API `marineweather-realtime` |
| `get_climate_context` | The daily records for a calendar day and the monthly climate normals, to judge how unusual a forecast is | OGC API `ltce-temperature`, `ltce-precipitation`, `ltce-snowfall`, `climate-normals` |
| `get_radar_map` | The latest radar as a map image over NRCan's base map, with rain and snow rates at the point now and over the past hour | GeoMet WMS: 1 km radar composite; NRCan Canada Base Map |

Every tool takes a `location` (`"Squamish"`, `"Lake Louise, AB"`) or `lat`/`lon`, and `lang` (`en` or `fr`).
Results are compact JSON with units in the field names, name the forecast site or station used and its distance, and carry
the required attribution. `bin/weather-canada-mcp tools` prints the full schemas.

### Avalanche Canada (opt-in)

Off unless `AVALANCHE_CANADA_ENABLED=true` (and `AVALANCHE_CANADA_FIELD_REPORTS_ENABLED=true` for field reports): see
[Avalanche Canada data](#avalanche-canada-data) and [docs/configuration.md](docs/configuration.md).

| Tool | What it answers | Source |
| --- | --- | --- |
| `get_avalanche_forecast` | The avalanche forecast covering a point for up to 3 days: danger ratings in the alpine, at treeline and below treeline, avalanche problems (type, elevations, aspects, likelihood, expected size), highlights, confidence, summaries, travel advice, the owning agency and the official link | Avalanche Canada forecast products |
| `get_avalanche_danger_overview` | Every current avalanche forecast with its owner, centre point, link, highest danger and current ratings | Avalanche Canada forecast metadata |
| `get_mountain_weather_stations` | The nearest mountain weather stations with elevation, distance, the latest reading and a summary of up to 7 days (snow height change, new snow, temperature range, strongest gust) | Avalanche Canada weather stations |
| `get_field_reports` | Recent Mountain Information Network field reports near a point: avalanches seen, signs of instability and comments, without who submitted them | Avalanche Canada MIN |

## Running it

### Claude Desktop or Claude Code (stdio)

With Ruby 4.0:

```sh
gem install weather-canada-mcp --source https://rubygems.org --source https://rubygems.pkg.github.com/cloetzi
claude mcp add weather-canada -- weather-canada-mcp stdio
```

The gem is published to GitHub Packages (rubygems.org is listed too, for its dependencies), which asks for a token with the `read:packages` scope even for public
gems: add it to `~/.gem/credentials` or `~/.bundle/config` as GitHub describes. Until the first release, run
`bin/weather-canada-mcp` from a checkout. (RubyGems.org may follow later.)

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
- Radar base map: Canada Base Map (CBMT), Natural Resources Canada, under the same licence.
- This project is not affiliated with or endorsed by ECCC or NRCan. For safety-critical decisions use
  [weather.gc.ca](https://weather.gc.ca).
- The server stays well inside ECCC's fair-use guidance: one request per second sustained across all tools, a
  cache, and a User-Agent that names the project (add your own contact with `WEATHER_MCP_USER_AGENT_CONTACT`).

### Avalanche Canada data

The avalanche tools are off by default because **Avalanche Canada publishes no open licence, and its
[Terms of Use](https://avalanche.ca/terms-of-use) forbid reproducing its content without prior written consent**. Enable
them only where you have that consent or your use is otherwise permitted.

- Forecasts are by Avalanche Canada or the agency that owns them (Parks Canada, Avalanche Québec, Kananaskis
  Country and others); every result names that agency and links to the official forecast on avalanche.ca. Forecast
  text is passed through as written, with only the HTML removed, and danger ratings keep Avalanche Canada's own
  values. A point no forecast covers is reported as such, never as low danger. No logos or rating graphics are used.
- Every avalanche result carries a safety note: avalanche forecasts are regional and do not replace avalanche
  training, your own observations or terrain judgement.
- Field reports come from the public through the Mountain Information Network and are not verified. Who submitted
  them is never returned, and contact details in their text are removed.
- This project is not affiliated with or endorsed by Avalanche Canada or any forecasting agency.

## Roadmap

1. **Before 1.0:** settle the tool contract (names, units, times), then publish the gem to GitHub Packages and the
   `linux/amd64` + `linux/arm64` image to GHCR from the release workflow.
2. **Later:** also publish the gem to RubyGems.org.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md). `bundle exec rake` runs RuboCop and the tests, which use real captured
ECCC responses served by a local fake, never the live services.

## Licence

[Apache 2.0](LICENSE). See [NOTICE](NOTICE) for data attributions.
