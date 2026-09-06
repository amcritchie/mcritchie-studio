source "https://rubygems.org"

ruby "3.3.11"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1"
# The original asset pipeline for Rails [https://github.com/rails/sprockets-rails]
gem "sprockets-rails"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Durable Active Job backend for production worker dynos.
gem "solid_queue", "~> 1.4"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Use Redis adapter to run Action Cable in production
# gem "redis", ">= 4.0.1"

# Use Kredis to get higher-level data types in Redis [https://github.com/rails/kredis]
# gem "kredis"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt", "~> 3.1.7"

gem "omniauth"
gem "omniauth-google-oauth2"
gem "omniauth-rails_csrf_protection"

# Rate limiting (prelaunch audit H6 — SSO hub brute-force prevention)
gem "rack-attack"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ mswin mswin64 mingw x64_mingw jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 1.2"
# Declared DIRECTLY rather than left to image_processing to supply it. Active
# Storage hardens libvips against untrusted content by calling
# Vips.block_untrusted(true), but only when `require "ruby-vips"` succeeds
# (activestorage/lib/active_storage/vips.rb). If the gem ever leaves the bundle
# that require fails, VIPS_AVAILABLE flips to false, and the hardening silently
# never runs — the app still boots and still handles images through mini_magick,
# so nothing reports the loss. image_processing 1.14 happens to pull ruby-vips
# in; 2.0 declares no such dependency, so bumping it alone would delete the gem.
# 2.2.1 is the floor that has block_untrusted.
#
# `require: false` is LOAD-BEARING, not tidiness. ruby-vips binds the libvips C
# library at REQUIRE time, so letting Bundler.require it would abort boot with
# LoadError on any machine that lacks libvips — every developer Mac. Active
# Storage does its own require inside a rescue, which is the only require this
# gem needs. Guarded by test/lib/vips_dependency_test.rb.
gem "ruby-vips", ">= 2.2.1", "< 3", require: false
gem "aws-sdk-s3", require: false

# Charts for the /intelligence task-development trends dashboard. Chartkick
# renders Chart.js (pinned via importmap, no build step); Groupdate powers the
# time-series (group_by_week) trend aggregations.
gem "chartkick"
gem "groupdate"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri mswin mswin64 mingw x64_mingw ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
  # minitest 6.0 dropped minitest/mock (Object#stub / Minitest::Mock); the suite
  # relies on Object#stub. Rails only needs >= 5.15, so pin to the 5.x line.
  gem "minitest", "~> 5.25"
end
gem "dotenv-rails", groups: [:development, :test]
gem "redcarpet"
gem "tailwindcss-rails", "~> 4.5"
# Sentry — production error monitoring. ErrorLog.capture! fans out to Sentry
# when SENTRY_DSN env var is set. No-op if absent.
gem "sentry-ruby"
gem "sentry-rails"

# 0.33.0 made the environment banner the navbar's SIBLING rather than its child:
# the layout renders studio/banners/stack immediately before the header. 0.39.0
# changed how the header clears those bars, and THAT is why this floor is 0.39
# and not 0.33. Through 0.38 the stack was sticky and measured itself with a
# ResizeObserver, publishing --studio-bars-h for the header to offset by; the
# header therefore painted at the server's guess and JUMPED when the measurement
# landed. 0.39.0 deleted the property and put the bars in normal flow, so they
# reserve their own space and the header pins at a plain, static top-0.
#
# The floor is LOAD-BEARING, not cosmetic. The render call this layout makes
# works on 0.33+, so a lower floor still resolves, still boots, and still looks
# correct at the top of the page — which is exactly what makes it dangerous.
# MEASURED here against 0.38.0 with this layout: the stack is sticky at z-60 and
# our static top-0 header is sticky at z-50, so the two collide ONLY ONCE
# SCROLLED. At scroll 0 they do not overlap at all; at scrollY 600 the bars
# covered 47px of the header's 53px — the navbar is underneath the bars, and a
# check run at the top of the page reports it healthy. Lower this floor and that
# comes back, invisibly to any scroll-0 or markup-level test.
#
# Bars brand off --color-warning / --color-danger, so they follow this app's theme.
#
# 0.40.0 RAISED THE FLOOR AGAIN, and this one is not a rendering nicety — it is a
# missing file. 0.40.0 is the first version to ship `studio/_at_time_script`, and
# the layout now renders it after deleting the hub's fork. On 0.39.x that render
# raises ActionView::MissingTemplate on EVERY page, so the failure is at least
# loud. The quieter half is the helper: Studio::AtTimeHelper also arrives in
# 0.40.0, and release_state_label calls at_time_tag.
#
# 0.42.0 raised it again, for the email side rather than the layout: this app's
# UserMailer calls Studio::Banner.for(name:) and EmailCatalog.subject_for, and
# /admin/emails is drawn from Studio::EmailSetting + Studio::EmailPreviewTarget.
#
# 0.43.0 WAS THE FLOOR until the pinned stack (below), and it fails the same way
# 0.40.0 did — the API is simply not there, so it is a NoMethodError rather than
# a cosmetic regression. user_mailer.rb:44-46 reads the operator's body copy and
# button straight off the catalog: EmailCatalog.body, .cta_text, .cta_color and
# .cta_enabled?. MEASURED against the installed 0.42.0 sources, none of those
# four methods exists, its Entry struct declares no :body / :cta_text /
# :cta_color / :cta_enabled / :supports_cta members, and its
# user_mailer/magic_link.html.erb never reads @body or @cta_text at all.
#
# The schema half moves with the same version: studio_email_settings gains body,
# cta_text, cta_color, cta_enabled and discord_url from 0.43's
# add_body_cta_footer_to_studio_email_settings migration. So a host resolved
# below 0.43 has neither the methods nor the columns behind them, and the
# operator's copy on /admin/emails has nowhere to be stored and nothing to read
# it.
#
# THE PIN DOES FLOOR — `~> 0.65` is `>= 0.65, < 1.0`, so a plain `bundle update`
# cannot walk this app backwards. What a pin string cannot do is speak for the
# version that RESOLVED: a pin loosened later, a `path:`/`git:` override, a
# hand-edited lockfile, or an unmigrated database all get past it.
# test/lib/engine_pin_contract_test.rb asserts the resolved version and columns.
#
# 0.65.0 IS THE FLOOR NOW, and a HARD one: it ships the pinned-stack publisher
# (any element carrying data-pin publishes --pin-<name>-h and --pin-<name>-bottom)
# and the task board POSITIONS OFF IT — the app-ladder strip from
# --pin-nav-bottom, the lane headers from max(--pin-nav-bottom, --pin-apps-bottom),
# with no JS measuring either. Below 0.65 neither property is published, both
# var() fall back to 0px, and the strip and every stage header pile up under the
# navbar. It replaced ~40 lines of Alpine that measured the header and chased it
# through its collapse (task stop-headers-chasing-navbar). The old `~> 0.43`
# already RESOLVED 0.65.2, so the resolver never saw this bump; it is the floor
# that moved, which is what this comment records.
gem "studio-engine", "~> 0.65"

# Pin the majors this app already runs so an engine bump cannot carry a new one
# in silently. studio-engine declares `redis >= 4.0.1` with NO upper bound — the
# unbounded dependency rubygems warns about at build time — so bundler re-resolves
# it on every engine version change; `--conservative` and `--strict` both still
# floated redis 5.4.1 -> 6.0.0, a MAJOR, inside a banner change. `~> 5.4` is the
# guard that stopped it.
#
# `resend ~> 1.6` raises the FLOOR, it does not add a ceiling: the engine already
# caps resend at `~> 1.1` (< 2.0). Do not copy it as the template for guarding a
# major — that needs a bound tighter than the gemspec's.
#
# Lift either one deliberately, in its own task, with the suite behind it.
gem "redis", "~> 5.4"
gem "resend", "~> 1.13"
