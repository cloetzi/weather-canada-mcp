# frozen_string_literal: true

source "https://rubygems.org"

# No `ruby` directive: .ruby-version and the Dockerfile pick Ruby. With one, Gemfile.lock records the Ruby version, so a
# Ruby patch update (which Renovate makes without touching the lockfile) fails `bundle install` in frozen mode.
gemspec

group :development, :test do
  gem "minitest", "~> 6.0"
  gem "rake", "~> 13.3"
  gem "rubocop", "~> 1.92", require: false
  gem "rubocop-minitest", require: false
  gem "rubocop-rake", require: false
end
