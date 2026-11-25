require "application_system_test_case"

# A session reset must leave no cookie and no local storage behind on any origin
# the test visited. Guards the Chrome 158 reset compatibility shim: a shim that
# only skipped the clear would pass every other test and fail this one.
class ResetIsolationTest < ApplicationSystemTestCase
  test "reset leaves no cookie and no local storage on any visited origin" do
    port = Capybara.current_session.server.port
    origins = [ "http://127.0.0.1:#{port}", "http://localhost:#{port}" ]

    origins.each do |origin|
      visit "#{origin}/session/new"
      execute_script("document.cookie = 'probe=1; path=/'; localStorage.setItem('probe', '1')")
    end

    Capybara.reset_sessions!

    browser = page.driver.browser
    cookies = browser.execute_cdp("Storage.getCookies").fetch("cookies").map { |c| c["name"] }
    assert_not_includes cookies, "probe"

    origins.each do |origin|
      visit "#{origin}/session/new"
      assert_nil evaluate_script("localStorage.getItem('probe')"), "local storage survived reset on #{origin}"
    end
  end
end
