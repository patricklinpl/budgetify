require "test_helper"
require "selenium-webdriver"
require_relative "../test_helpers/focus_before_keys"

# Deterministic coverage for the focus wait that runs before send_keys in system
# tests. [engineering] Fake clock, sleeper, probe and bridge; no browser.
class FocusBeforeKeysTest < ActiveSupport::TestCase
  Guard = FocusBeforeKeys

  setup do
    @now = 0.0
    @clock = -> { @now }
    @sleeps = []
    @lines = []
    @warner = ->(line) { @lines << line }
    @sleeper = ->(seconds) { @sleeps << seconds; @now += seconds }
  end

  def state(focus) = { "focus" => focus, "visibility" => "visible", "active" => "input#target_amount" }

  def wait(states, wait: 2.0)
    queue = states.dup
    calls = 0
    result = Guard.wait_for_focus(probe: -> { calls += 1; v = queue.size > 1 ? queue.shift : queue.first; v.respond_to?(:call) ? v.call : v },
                                  wait: wait, clock: @clock, sleeper: @sleeper, warner: @warner)
    [ result, calls ]
  end

  test "a focused page passes on the first check with no pause" do
    result, calls = wait([ state(true) ])
    assert_equal true, result["focus"]
    assert_equal 1, calls
    assert_empty @sleeps
    assert_empty @lines
  end

  test "a recovered focus loss prints one FOCUS_WAIT line with checks, seconds and state" do
    wait([ state(false), state(false), state(true) ])
    assert_equal [ "FOCUS_WAIT recovered checks=3 waited=0.10s focus=true visibility=visible active=input#target_amount" ], @lines
  end

  test "an unfocused page is checked again until focus returns" do
    result, calls = wait([ state(false), state(false), state(true) ])
    assert_equal true, result["focus"]
    assert_equal 3, calls
    assert_equal [ 0.05, 0.05 ], @sleeps
  end

  test "a page that never gets focus raises with the state it reported, within the wait" do
    error = assert_raises(Guard::PageNotFocused) { wait([ state(false) ], wait: 0.2) }
    assert_includes error.message, "document.hasFocus() stayed false for 0.2s"
    assert_includes error.message, "focus=false visibility=visible active=input#target_amount"
    assert_includes error.message, "Keys were not sent"
    assert_in_delta 0.2, @sleeps.sum, 1e-9
    assert_operator @sleeps.max, :<=, 0.05
    assert_equal 1, @lines.size
    assert_match(/\AFOCUS_WAIT failed checks=\d+ waited=0\.20s focus=false visibility=visible active=input#target_amount\z/, @lines.first)
  end

  test "a probe that cannot run lets the original send_keys proceed" do
    result, calls = wait([ -> { raise Selenium::WebDriver::Error::UnexpectedAlertOpenError, "alert open" } ])
    assert_nil result
    assert_equal 1, calls
    assert_empty @lines
  end

  test "an odd probe result is reported without raising anything but PageNotFocused" do
    error = assert_raises(Guard::PageNotFocused) { wait([ "nope" ], wait: 0.1) }
    assert_includes error.message, "focus= visibility= active="
  end

  test "non printable text in the reported state is masked" do
    bad = { "focus" => false, "visibility" => "visible", "active" => "input#a\u0000b" }
    error = assert_raises(Guard::PageNotFocused) { wait([ bad ], wait: 0.1) }
    assert_includes error.message, "active=input#a?b"
  end

  class FakeBridge
    attr_reader :log

    def initialize(focus_states)
      @focus_states = focus_states
      @log = []
    end

    def execute_script(script, *)
      @log << :probe
      @focus_states.size > 1 ? @focus_states.shift : @focus_states.first
    end

    def send_keys_to_element(id, keys)
      @log << [ :keys, id, keys ]
    end
  end

  test "Selenium's element send_keys probes first and then sends the keys" do
    assert_includes Selenium::WebDriver::Element.ancestors, FocusBeforeKeys::ElementGuard
    bridge = FakeBridge.new([ state(true) ])
    Selenium::WebDriver::Element.new(bridge, "node-1").send_keys("abc")
    assert_equal :probe, bridge.log.first
    assert_equal [ :keys, "node-1", [ "abc" ] ], bridge.log.last
    assert_equal 2, bridge.log.size
  end

  test "the probe script reads only focus, visibility and the active element label" do
    assert_includes FocusBeforeKeys::PROBE, "document.hasFocus()"
    assert_includes FocusBeforeKeys::PROBE, "document.visibilityState"
    refute_match(/\.value|innerText|textContent|cookie|localStorage/, FocusBeforeKeys::PROBE)
  end
end
