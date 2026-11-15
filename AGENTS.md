# AGENTS.md

Guidance for AI coding agents working in this repository. Human contributors: see CONTRIBUTING.md.

## What this is

An unofficial, read-only MCP server (Ruby 4, Falcon, official `mcp` gem) with outdoor-focused weather tools for
Canada, built on ECCC open data (MSC GeoMet OGC API, GeoMet WMS) and NRCan's Canadian Geographical
Names. Users run it over stdio or from the Docker image on GHCR. No upstream credentials exist.

## Layout

- `lib/weather_canada_mcp/`
  - `tools/`: one class per MCP tool (`Tools::Base` subclasses; the opt-in Avalanche Canada tools live in
    `tools/avalanche/`, under `Tools::Avalanche::Base`). A tool declares `tool_name`, `title`, `description`,
    `location_arguments`, `argument ...`, `output ...` (a top-level result field, for `outputSchema`) and `enabled_when` at
    class level and implements `call(args)`; `Argument`
    builds the schema and checks each value, and `Registry` lists the tools and selects them by configuration.
    `Tools::Runner` builds a new tool instance per call, drops nulls, joins the attributions the tool declared
    (`Tools::Result`), enforces the size cap (on the JSON, not on an image a tool returns), turns `Tools::Error`s and
    upstream errors into tool errors
  - `maps/`: `Compositor`, PNG compositing (chunky_png)
  - `sources/`: everything that fetches upstream data. `HttpClient` (GET only, fixed `Origin`s, gzip, size cap,
    retries), `RateLimiters` (one GCRA `RateLimiter` per provider: ECCC, NRCan, Avalanche Canada), `Cache` (TTL, LRU
    and byte budget, request coalescing, stale-if-error), `Trace` (per-call request, cache-hit and stale counts in fiber
    storage), `RequestLog` (what debug logs may say of a path), `JsonClient` (cached JSON GET with status and shape checks, shared by the
    ECCC and Avalanche Canada clients), `Wms` (one generic WMS client, for GeoMet and for NRCan's base map), and a thin
    client per service returning parsed data: `ECCC::OgcApi`; `ECCC::StationDirectory` (the stations of a collection,
    nearest search in memory, read whole or by 0.5 degree grid cell) with `ECCC::Stations` and `ECCC::ForecastSites`
    on it; `ECCC::CityPage` (the only class that knows City Page's property names); `NRCan::Basemap`; and, when
    enabled, `AvalancheCanada::Forecasts`, `::WeatherStations` and `::FieldReports` (bundled as
    `AvalancheCanada::Services`); `sources.rb` holds the error classes
  - `places/`: `Gazetteer`, offline place names in SQLite (FTS5; plain lat/lon index, since the bundled SQLite has
    no R*Tree), built from NRCan's CSV by `Builder`, downloaded (rubyzip) and built on demand by `Store`
  - `server/`: the HTTP transport. `HttpApp`, `HostOriginGuard`, `StaticTokenVerifier`, `HealthCheck`,
    `ExceptionReporter`
  - `config.rb` (with `Config::ListenAddress`), `application.rb`, `cli.rb`, `logger.rb`: wiring; `geo.rb`: distance, bbox, point in polygon
- `bin/`: `weather-canada-mcp` (CLI), `capture-fixtures`, `generate-site-zones` (rewrites `sources/eccc/site_zones.json`,
  the IANA zone of each City Page site; needs Python `timezonefinder`, offline), `healthcheck`, `docker-smoke-test`
- `test/`: Minitest. `test/support/fake_eccc.rb` serves `test/fixtures/` on a local port;
  `test/fixtures/tools.json` snapshots the tool manifest; `test/fixtures/results/` holds one result per tool and the
  key vocabulary (see CONTRIBUTING.md); `test/fixtures/m0/` holds samples for future tools.

## Commands

```sh
bundle exec rake                              # RuboCop + tests; must pass before you finish
UPDATE_SNAPSHOTS=1 bundle exec rake test      # after intentional tool changes; review the diff
bin/capture-fixtures [prefix]                 # recapture real fixtures; review the diff
bin/weather-canada-mcp tools                  # inspect the tool manifest
docker build -t weather-canada-mcp:dev . && bin/docker-smoke-test weather-canada-mcp:dev
```

## Rules

- **Licence.** Every tool result carries `ATTRIBUTION` (`Tools::Runner` adds it). Alert text is passed through
  verbatim: never summarize, reword or truncate it. Never use ECCC logos or imply endorsement.
- **Avalanche Canada.** It publishes no open licence, so its tools (`Tools::Avalanche::Base` subclasses) exist only
  behind `WEATHER_MCP_AVALANCHE`, and its hosts are origins only then. Their results carry their own attribution
  naming the owning agency, plus the fixed safety note with the official link. Forecast text is passed through with
  only the HTML stripped; ratings keep Avalanche Canada's values; no coverage is never "low"; no logos or rating
  graphics. Field reports never include who submitted them. Fixture captures drop `userID` and `username`.
- **Fair use.** All upstream requests go through `Sources::HttpClient` (rate limiter, User-Agent) and should be
  cached through `Sources::Cache`. Prefer `bbox`, `limit` and `properties` to keep responses small.
- **Fixtures are real.** Capture them with `bin/capture-fixtures`; never hand-write or edit upstream data.
- **Privacy.** Never log tool arguments or results: locations reveal where people are. Log tool names,
  durations and error classes only.
- **Security.** GET only, to configured origins only. Validate tool arguments and URL-encode anything that reaches
  a path. Cap sizes after decompression. MCP auth stays required by default for HTTP.
- **Fibers.** Code runs under the Async fiber scheduler. Use non-blocking IO (async-http); CPU-heavy work (the
  gazetteer build, composing radar map images) may use a thread. Logs go to stderr; stdout is the stdio transport's
  protocol channel.
- **Style.** Follow the surrounding code: small classes, `Data` value objects, endless methods for one-liners,
  comments only where intent is not obvious. RuboCop is the arbiter.
- **Loading.** Zeitwerk autoloads `lib/` (inflections in `lib/weather_canada_mcp.rb`): one top-level constant per
  file, named after its path. Never `require_relative` files under `lib/`. `test/weather_canada_mcp/loader_test.rb`
  checks the naming.
- **Dependencies.** Keep them minimal; ask before adding a gem.
- **Commits.** Conventional Commits; PR titles drive release-please. Do not edit `CHANGELOG.md` or the version.
- **Docs.** Update `docs/configuration.md` for environment variables and the README tool table for tools.
