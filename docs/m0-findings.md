# M0 findings (2026-11-15)

What the spike found while capturing fixtures. Samples are in `test/fixtures/` (`api/` for M1, `m0/` for later
milestones); `bin/capture-fixtures` documents every request.

## Alerts: the OGC API has a `weather-alerts` collection

`api.weather.gc.ca/collections/weather-alerts` serves active ECCC alerts as GeoJSON polygons with bilingual
properties (`alert_name_*`, `alert_text_*`, `risk_colour_*`, `status_*`, `publication_datetime`,
`expiration_datetime`, `event_end_datetime`, `impact_*`, `confidence_*`). A `bbox` query intersects the polygons,
so "alerts at this point" is one request plus a local point-in-polygon check.

This replaces the planned CAP-XML polling fiber for M1: no background work, no CAP parsing. Ended alerts stay in
the collection for a while with `status_en: "ended"`, so `get_alerts` filters them and anything past its
expiration. CAP on Datamart remains a fallback if the collection is ever retired.

## City Page (`citypageweather-realtime`)

- 844 sites. Ids look like `bc-50` (not the Datamart `s0000xxx` codes). The whole site list with names and regions
  is one request (`limit=1000&properties=identifier,name.en,name.fr,region.en,region.fr`, about 220 KB).
- Nested properties need dotted names in `properties` (`name.en`); `name` alone is rejected.
- Every value is a bilingual pair (`{"en": ..., "fr": ...}`), readings sit under `value`.
- Forecast periods can carry `snowLevel.textSummary` (BC mountain sites), `precipitation.accumulation`,
  `windChill`, `humidex`, `uv`, `frost`. Hourly entries have condition, temperature, `lop` (precip chance), wind.
- Current conditions sometimes carry a stale wind chill (for example -1 at +11 °C); `get_forecast` drops wind
  chill above 0 °C and humidex below 20 °C.

## GeoMet WMS layers (for M3)

GetFeatureInfo with `INFO_FORMAT=application/json` returns `value`, a `class` label, `time` and
`dim_reference_time`.

| Need | Layer | Time steps |
| --- | --- | --- |
| Snow level | `HRDPS-WEonG_2.5km_SnowLevelHeight` (48 h), `RDPS-WEonG_10km_SnowLevelHeight` (84 h) | PT1H |
| Snow probability | `HRDPS-WEonG_2.5km_Snow-Prob`, `RDPS-WEonG_10km_Snow-Prob` | PT1H |
| Blowing snow | `HRDPS-WEonG_2.5km_BlowingSnow-Prob`, `...BlowingSnowPresence` | PT1H |
| Solid snow amount | `HRDPS-WEonG_2.5km_SolidSnowCondAmt` | PT1H |
| Snow accumulation | `RDPS_10km_Snow-Accum` (and `-Accum1h/3h/6h/12h/24h`) | PT1H to PT6H |
| Radar snow / rain rate | `RADAR_1KM_RSNO`, `RADAR_1KM_RRAI` | PT6M, last 3 h |
| Radar precip type | `Radar_1km_SfcPrecipType` | PT6M |
| Radar nowcast | `Radar_1km_{Rain,Snow}PrecipRate-Extrapolation`, `Radar_1km_dBZ-Extrapolation` | PT6M, ~1 h ahead |

Snow level returns negative values with a class such as "Partially Melted" when there is no snow level to report;
M3 must map those classes rather than treat the number as metres.

**Radar basemap:** GeoMet's capabilities list no coastline, boundary or road layer that would serve as a basemap,
so the "single GetMap" route is not available. M3 needs a second source (for example NRCan's Canada Base Map
tiles, licence to be checked) composited under the radar PNG, or a text-only radar tool.

## Other collections (for M2/M3)

`swob-realtime` (hundreds of flat properties per observation; sort with `sortby=-date_tm-value`),
`hydrometric-stations`, `hydrometric-realtime` (`LEVEL`, `DISCHARGE`, `DATETIME`), `hydrometric-daily-mean`,
`aqhi-observations-realtime` (`latest=true`), `aqhi-forecasts-realtime`, `marineweather-realtime`,
`marine-standard-forecast-zones`, `climate-normals`, `ltce-snowfall` (filter by `LOCAL_MONTH`/`LOCAL_DAY`).

## Gazetteer

NRCan's CSV has 366,235 names (77 MB unzipped, 16 MB zipped). The SQLite build (FTS5 plus a lat/lon B-tree index)
is 62 MB and takes about 20 seconds. The bundled SQLite (sqlite3 gem 2.10.2) has FTS5 but no R*Tree, so reverse
lookup uses a bbox range query on the lat/lon index, which is fast enough at this size.
