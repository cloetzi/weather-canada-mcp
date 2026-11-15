# Contributing

Thanks for helping! Bug reports, new data sources and fixes are all welcome.

## Setup

Requires Ruby 4.0 (see `.ruby-version`) and, for the image, Docker.

```sh
bundle install
bundle exec rake                 # RuboCop and the test suite
bin/weather-canada-mcp tools     # print the tool manifest
```

Run the server locally over stdio (no settings needed) or HTTP:

```sh
bin/weather-canada-mcp stdio
WEATHER_MCP_AUTH_TOKEN=$(openssl rand -hex 32) bin/weather-canada-mcp
```

The first place-name lookup downloads NRCan's Canadian Geographical Names (about 16 MB) and builds the SQLite
gazetteer (about 60 MB, 20 seconds). Run `bin/weather-canada-mcp gazetteer update` to do that up front.

Build and smoke-test the image:

```sh
docker build -t weather-canada-mcp:dev .
bin/docker-smoke-test weather-canada-mcp:dev
```

## Fixtures

Tests never call ECCC: `test/support/fake_eccc.rb` serves the files in `test/fixtures/` on a local port.
Fixtures are real responses captured with `bin/capture-fixtures`; never write or edit them by hand. When an
upstream changes shape, recapture (`bin/capture-fixtures api/` for one group), review the diff, and fix the tests.
After changing a tool's name, description or schema, regenerate the manifest snapshot with
`UPDATE_SNAPSHOTS=1 bundle exec rake test` and review it like code.

## Result vocabulary

The same thing has the same key in every tool. Times are local ISO 8601 with an offset: a tool returns `Time` objects and
`Tools::Base` converts them for the point's zone, so a tool never formats one. A key outside this list needs a reason;
`test/weather_canada_mcp/tools/result_snapshots_test.rb` fails on keys missing from `test/fixtures/results/vocabulary.txt`.

Arguments: `location`, `lat`, `lon`, `lang` wherever they apply; `limit` for "how many"; `hours`, `days`, `radius_km`,
`date`, `river`, `province`, `precipitation`.

| Concept | Key | Notes |
| --- | --- | --- |
| Air temperature | `temperature_c` | `min_temperature_c`, `max_temperature_c` for extremes |
| Dew point | `dewpoint_c` | |
| Relative humidity | `humidity_pct` | |
| Wind speed, gust | `wind_speed_kmh`, `wind_gust_kmh` | marine stays in knots, as ECCC writes it |
| Wind direction | `wind_direction` (compass text), `wind_direction_deg` (number) | never a number under `wind_direction` |
| Pressure | `pressure_kpa`, `pressure_sea_level_kpa`, `pressure_station_kpa` | hPa divided by 10 |
| Wind chill, humidex | `wind_chill`, `humidex` | unitless indices |
| Visibility | `visibility_km` | |
| Precipitation amounts | `..._mm` for rain and water equivalent, `..._cm` for snow | forecast `precipitation` is `{type:, amount_mm:}` or `{type:, amount_cm:}` |
| Snow on the ground | `snow_depth_cm` | |
| When measured | `observed_at` | `time` only for entries of a time series |
| When issued | `issued_at` | |
| Validity | `valid_from`, `valid_until`, `expires_at` | |
| Site used | block with `id`, `name`, `distance_km`, and `elevation_m`, `lat`, `lon` where known | |
| Caveat | `note` | one string |
| Links, credit | `source_url`, `url`, `attribution` | |

Result snapshots (`test/fixtures/results/`) are regenerated with `UPDATE_SNAPSHOTS=1 bundle exec rake test`; review them
like code.

## Commits and pull requests

- PRs are squash-merged, and the **PR title must follow [Conventional Commits](https://www.conventionalcommits.org)**
  (checked in CI): `feat: ...`, `fix: ...`, `docs: ...`, `chore: ...`, `ci: ...`, `refactor: ...`, `test: ...`.
  Use `feat!:` or a `BREAKING CHANGE:` footer for breaking changes.
- [release-please](https://github.com/googleapis/release-please) turns merged titles into the changelog and
  version: `feat` bumps the minor version, `fix` the patch version (while below 1.0, breaking changes bump the
  minor version).
- Keep changes focused, add tests for behavior changes, and update docs when configuration changes.

## Releases

Maintainers merge the release PR that release-please keeps open. That creates the tag and GitHub release and
publishes `ghcr.io/cloetzi/weather-canada-mcp:<version>`, `:<major>.<minor>` and `:latest`, and pushes the gem to
the GitHub Packages RubyGems registry. Every push to `main` also publishes `:edge`.

Images are built natively for `linux/amd64` and `linux/arm64` (one runner per architecture, no emulation) and
assembled into one manifest list by `.github/workflows/publish-image.yml`.

By contributing you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md) and that your contributions are
licensed under the [Apache License 2.0](LICENSE).
