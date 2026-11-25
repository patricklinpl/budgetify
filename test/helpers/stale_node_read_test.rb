require "test_helper"
require "selenium-webdriver"
require_relative "../test_helpers/stale_node_read"

# Deterministic coverage for the read-only stale-node retry used by system tests.
# [engineering] Fake clock, sleeper and wait scope; no browser.
class StaleNodeReadTest < ActiveSupport::TestCase
  include StaleNodeRead

  STALE = "unknown error: unhandled inspector error: Node with given id does not belong to the document".freeze

  setup do
    @now = 0.0
    @clock = -> { @now }
    @sleeps = []
    @sleeper = ->(seconds) { @sleeps << seconds; @now += seconds }
    @waits = []
    @waiter = ->(seconds, &block) { @waits << seconds; block.call }
  end

  def settle(wait: 2.0, &block) = settle_read(wait: wait, clock: @clock, sleeper: @sleeper, waiter: @waiter, &block)

  test "the exact signature is retried and the read then passes" do
    calls = 0
    settle { calls += 1; raise Selenium::WebDriver::Error::UnknownError, STALE if calls < 3 }
    assert_equal 3, calls
    assert_equal [ 0.05, 0.05 ], @sleeps
  end

  test "each attempt gets only the time left, never a fresh full wait" do
    calls = 0
    settle { calls += 1; @now += 0.5; raise Selenium::WebDriver::Error::UnknownError, STALE if calls < 3 }
    assert_equal 3, @waits.size
    assert_in_delta 2.0, @waits[0], 1e-9
    assert_in_delta 1.45, @waits[1], 1e-9
    assert_in_delta 0.9, @waits[2], 1e-9
    assert_operator @waits.each_cons(2).count { |a, b| b < a }, :==, 2
  end

  test "after the deadline the original exact error is raised unchanged" do
    error = Selenium::WebDriver::Error::UnknownError.new(STALE)
    raised = assert_raises(Selenium::WebDriver::Error::UnknownError) { settle { @now += 1.0; raise error } }
    assert_same error, raised
    assert_operator @sleeps.sum, :<=, 2.0
  end

  test "the pause never runs past the deadline" do
    assert_raises(Selenium::WebDriver::Error::UnknownError) { settle(wait: 0.12) { raise Selenium::WebDriver::Error::UnknownError, STALE } }
    assert_operator @sleeps.sum, :<=, 0.12 + 1e-9
    assert_in_delta 0.12, @sleeps.sum, 1e-9
  end

  test "another UnknownError is raised unchanged at once" do
    error = Selenium::WebDriver::Error::UnknownError.new("something else")
    raised = assert_raises(Selenium::WebDriver::Error::UnknownError) { settle { raise error } }
    assert_same error, raised
    assert_empty @sleeps
  end

  test "an assertion failure is raised unchanged at once" do
    assert_raises(Minitest::Assertion) { settle { flunk "nope" } }
    assert_empty @sleeps
  end
end
