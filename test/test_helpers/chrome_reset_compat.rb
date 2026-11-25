# Test-harness compatibility for Chrome 158 and newer.
#
# Capybara 3.40.0's ChromeDriver#reset! ends with
#   execute_cdp("Storage.clearDataForOrigin", origin: "*", storageTypes: ...)
# Chrome 158 rejects "*" ("invalid argument: * is not a valid URL"), so every
# system test errors in after_teardown on a runner that ships Chrome 158, while
# the same tree is green on Chrome 157. Upstream: teamcapybara/capybara issue
# 2865 and pull request 2867 (not released at the time of writing).
#
# This module keeps Capybara's own reset! and only replaces that one final call,
# and only when Chrome rejects it. Reset semantics are kept: every cookie is
# cleared, and local storage is cleared (when Capybara would clear it) for each
# http(s) origin in the tab's navigation history. On Chrome 157 the original
# call succeeds and this code does nothing.
#
# Delete this file and its require when the Capybara in Gemfile.lock includes the
# upstream fix. test/system/reset_isolation_test.rb checks that a reset leaves no
# cookie and no local storage behind on the origins a test visited, so skipping
# the clear altogether would fail it.
require "uri"

module ChromeResetCompat
  REJECTED = "* is not a valid URL".freeze

  def reset!
    super
  rescue Selenium::WebDriver::Error::InvalidArgumentError => e
    raise unless e.message.include?(REJECTED)

    clear_all_origins_for_reset
  end

  private

  def clear_all_origins_for_reset
    execute_cdp("Network.clearBrowserCookies")
    return unless clear_all_storage?

    history_origins.each do |origin|
      execute_cdp("Storage.clearDataForOrigin", origin: origin, storageTypes: "local_storage")
    end
  end

  def history_origins
    entries = execute_cdp("Page.getNavigationHistory").fetch("entries", [])
    entries.filter_map do |entry|
      uri = URI.parse(entry["url"].to_s)
      next unless %w[http https].include?(uri.scheme) && uri.host

      "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless uri.port == uri.default_port}"
    rescue URI::InvalidURIError
      nil
    end.uniq
  end
end

Capybara::Selenium::Driver::ChromeDriver.prepend(ChromeResetCompat)
