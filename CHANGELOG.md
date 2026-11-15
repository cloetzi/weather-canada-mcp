# Changelog

## [0.2.1](https://github.com/cloetzi/weather-canada-mcp/compare/v0.2.0...v0.2.1) (2026-11-15)


### Bug Fixes

* build the image after a release bumps the version ([#24](https://github.com/cloetzi/weather-canada-mcp/issues/24)) ([863a659](https://github.com/cloetzi/weather-canada-mcp/commit/863a659ee5d7fde93162e7218c9afc0747d11fcd))

## [0.2.0](https://github.com/cloetzi/weather-canada-mcp/compare/v0.1.0...v0.2.0) (2026-11-15)


### ⚠ BREAKING CHANGES

* settle the public contract (vocabulary, local times, lang, include_image) ([#16](https://github.com/cloetzi/weather-canada-mcp/issues/16))
* rename module to WeatherCanadaMCP, shorten Avalanche env vars, drop datamart upstream ([#12](https://github.com/cloetzi/weather-canada-mcp/issues/12))

### Features

* add get_current_observations, get_river_conditions and get_air_quality (M2) ([#3](https://github.com/cloetzi/weather-canada-mcp/issues/3)) ([b7e7de5](https://github.com/cloetzi/weather-canada-mcp/commit/b7e7de52170a1e19707de5e18d6cb5507540d447))
* add snow outlook, marine forecast, climate context and radar map tools (M3) ([#6](https://github.com/cloetzi/weather-canada-mcp/issues/6)) ([409091f](https://github.com/cloetzi/weather-canada-mcp/commit/409091f8b7b5aa36f337dd8dda378b600f5aee3d))
* M1 skeleton with find_location, get_forecast and get_alerts ([#1](https://github.com/cloetzi/weather-canada-mcp/issues/1)) ([35802a2](https://github.com/cloetzi/weather-canada-mcp/commit/35802a2e4ca40afdf864f83b3f778f493a90c799))
* opt-in Avalanche Canada forecasts, mountain weather stations and field reports ([#5](https://github.com/cloetzi/weather-canada-mcp/issues/5)) ([e1ca524](https://github.com/cloetzi/weather-canada-mcp/commit/e1ca52488a2e3726c4280abe8c745c94ae253af6))
* per-provider rate limits, call deadline, bounded caches ([#17](https://github.com/cloetzi/weather-canada-mcp/issues/17)) ([67a6b6d](https://github.com/cloetzi/weather-canada-mcp/commit/67a6b6d02fb3078528b921c0406e5407b4103934))
* settle the public contract (vocabulary, local times, lang, include_image) ([#16](https://github.com/cloetzi/weather-canada-mcp/issues/16)) ([04e5173](https://github.com/cloetzi/weather-canada-mcp/commit/04e517351c2d29af201a62ced81507776719b637))
* shorter tool descriptions, snow estimate in cm and output schemas ([#21](https://github.com/cloetzi/weather-canada-mcp/issues/21)) ([133ad91](https://github.com/cloetzi/weather-canada-mcp/commit/133ad91a59e43895742c7085b765149f5b134694))
* stale-if-error, stdio warm-up and upstream debug logging ([#20](https://github.com/cloetzi/weather-canada-mcp/issues/20)) ([0cff27f](https://github.com/cloetzi/weather-canada-mcp/commit/0cff27facde977b1a5efbdd12776468d7e2c94ea))


### Bug Fixes

* check count arguments the same way in every tool ([#8](https://github.com/cloetzi/weather-canada-mcp/issues/8)) ([b211907](https://github.com/cloetzi/weather-canada-mcp/commit/b211907922e92ccdf110d4c3650269ffb4d1d50c))
* let a request wait for its rate slot until its call's deadline ([#22](https://github.com/cloetzi/weather-canada-mcp/issues/22)) ([8ec2fbf](https://github.com/cloetzi/weather-canada-mcp/commit/8ec2fbf5eae82b026c5ce879ceefaf717ffee3d2))


### Code Refactoring

* rename module to WeatherCanadaMCP, shorten Avalanche env vars, drop datamart upstream ([#12](https://github.com/cloetzi/weather-canada-mcp/issues/12)) ([d63a81e](https://github.com/cloetzi/weather-canada-mcp/commit/d63a81ef2121abd24261f8aa8614cec5bf34f14b))
