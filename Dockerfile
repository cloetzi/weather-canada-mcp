# syntax=docker/dockerfile:1

# Base images are pinned by digest; Renovate keeps tag and digest current.
FROM ruby:4.0.9-alpine3.24@sha256:8ad6909db16ad53b5dc90bb8cc157e5fdd89ba1172798316b95cfd2a61f14b1e AS build

RUN apk add --no-cache build-base openssl-dev yaml-dev

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle

WORKDIR /app
COPY Gemfile Gemfile.lock .ruby-version weather-canada-mcp.gemspec ./
COPY lib/weather_canada_mcp/version.rb lib/weather_canada_mcp/
# release-please bumps the version in version.rb and in the PATH entry of Gemfile.lock but not in its CHECKSUMS entry, and
# frozen mode refuses a lockfile that is out of date: set the gem's own version in that entry from version.rb.
RUN sed -i -E "s/^  (weather-canada-mcp) \([^)]*\)$/  \1 ($(ruby -r./lib/weather_canada_mcp/version -e 'print WeatherCanadaMCP::VERSION'))/" Gemfile.lock \
    && bundle install --jobs 4 \
    && rm -rf /usr/local/bundle/cache /usr/local/bundle/ruby/*/cache \
    && find /usr/local/bundle -type f \( -name "*.o" -o -name "*.c" -o -name "*.h" -o -name "Makefile" -o -name "mkmf.log" \) -delete \
    && find /usr/local/bundle/ruby/*/gems -maxdepth 2 -type d \( -name test -o -name spec -o -name examples -o -name ext \) -prune -exec rm -rf {} +

COPY bin/weather-canada-mcp bin/healthcheck bin/
COPY lib lib

# The place-name database is built into the image (NRCan Canadian Geographical Names, Open Government Licence -
# Canada), so the container never writes to disk. Rebuild the image to refresh it.
ENV WEATHER_MCP_GAZETTEER_PATH=/app/data/gazetteer.sqlite3
RUN bin/weather-canada-mcp gazetteer update

FROM ruby:4.0.9-alpine3.24@sha256:8ad6909db16ad53b5dc90bb8cc157e5fdd89ba1172798316b95cfd2a61f14b1e

ARG VERSION=dev
LABEL org.opencontainers.image.title="weather-canada-mcp" \
      org.opencontainers.image.description="Unofficial MCP server for Environment and Climate Change Canada weather open data" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="${VERSION}"

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_APP_CONFIG=/usr/local/bundle \
    HOME=/nonexistent \
    WEATHER_MCP_HOST=0.0.0.0 \
    WEATHER_MCP_PORT=8080 \
    WEATHER_MCP_GAZETTEER_PATH=/app/data/gazetteer.sqlite3

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app
COPY LICENSE NOTICE /app/
WORKDIR /app

# Unprivileged, no home directory, nothing writable: runs with a read-only root filesystem.
USER 65532:65532
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD ["ruby", "/app/bin/healthcheck"]

ENTRYPOINT ["/app/bin/weather-canada-mcp"]
CMD ["http"]
