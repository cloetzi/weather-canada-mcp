# AGENTS.md

Guidance for AI coding agents working in this repository. Human contributors: see CONTRIBUTING.md.

## What this is

An unofficial, read-only MCP server (Ruby 4, Falcon, official `mcp` gem) with outdoor-focused weather tools for
Canada, built on ECCC open data (MSC GeoMet OGC API, GeoMet WMS, Datamart) and NRCan's Canadian Geographical
Names. Users run it over stdio or from the Docker image on GHCR. No upstream credentials exist.

## Layout

- `lib/weather_canada_mcp/`
  - `tools/`: one class per MCP tool (`Tools::Base` subclasses), and `MapImage` (PNG compositing, chunky_png);
    `tools.rb` lists them in order;
    `Tools::Runner` runs a tool call, drops nulls, adds the attribution, enforces the size cap (on the JSON, not
    on an image a tool returns), turns errors into tool errors
  - `sources/`: everything that fetches ECCC and NRCan data. `HttpClient` (GET only, fixed origins, gzip, size cap,
    retries), `RateLimiter` (GCRA, global), `Cache` (TTL with request coalescing), and a thin client per service
    returning parsed data (`OgcApi`; `Wms`, GeoMet point values and map images; `Basemap`, NRCan's base map);
    `sources.rb` holds the error classes
  - `places/`: `Gazetteer`, offline place names in SQLite (FTS5; plain lat/lon index, since the bundled SQLite has
    no R*Tree), built from NRCan's CSV by `Builder`, downloaded (rubyzip) and built on demand by `Provider`;
    `Locator`, nearest City Page forecast sites
  - `server/`: the HTTP transport. `HttpApp`, `HostOriginGuard`, `StaticTokenVerifier`, `HealthCheck`,
    `ListenAddress`, `ExceptionReporter`
  - `config.rb`, `application.rb`, `cli.rb`, `logger.rb`: wiring; `geo.rb`: distance, bbox, point in polygon
- `bin/`: `weather-canada-mcp` (CLI), `capture-fixtures`, `healthcheck`, `docker-smoke-test`
- `test/`: Minitest. `test/support/fake_eccc.rb` serves `test/fixtures/` on a local port;
  `test/fixtures/tools.json` snapshots the tool manifest; `test/fixtures/m0/` holds samples for future tools.

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
