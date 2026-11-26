# Test harness only. Before a key is sent to an element, wait (bounded) until the
# page reports document.hasFocus() == true.
#
# Why: in CI run 45896301310 one system test sent 25 key events right after
# ChromeDriver's own document.hasFocus() check returned false. Chrome acknowledged
# all 25 and the page received none of them. Over that whole run that check was
# false once (266 of 267 true). Why the page lost focus is not known, so this is a
# guard against typing into an unfocused page, not a claim that it fixes that
# failure.
#
# This is a mitigation, not a pure observer. It adds one script call (a probe) to
# every send_keys, and it changes behavior when the page is unfocused: it waits,
# and if the time runs out the keys are NOT sent and the test fails. No click is
# touched, and there is no retry of the typing, no assertion change and no
# activation call. Whenever the first check is false, one FOCUS_WAIT line is
# printed (checks, seconds waited, final state; no field values), so a recovered
# focus loss is still visible in CI logs. If the probe itself cannot run (an alert
# is open, the session is gone), the original send_keys runs unchanged.
module FocusBeforeKeys
  WAIT = 2.0
  PAUSE = 0.05
  PROBE = <<~JS.freeze
    var a = document.activeElement;
    var label = a ? a.tagName.toLowerCase() + (a.id ? "#" + a.id : "") : "none";
    return { focus: document.hasFocus(), visibility: document.visibilityState, active: label };
  JS

  class PageNotFocused < StandardError; end

  module_function

  # probe: -> Hash with "focus", "visibility", "active" (string keys, as Selenium
  # returns them). Returns the last state seen. Raises PageNotFocused after `wait`.
  def wait_for_focus(probe:, wait: WAIT, clock: nil, sleeper: nil, warner: nil)
    warner ||= ->(line) { warn line }
    clock ||= -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    sleeper ||= ->(seconds) { sleep seconds }
    started = clock.call
    deadline = started + wait
    attempts = 0
    loop do
      state = begin
        probe.call
      rescue StandardError
        return nil
      end
      attempts += 1
      if state.is_a?(Hash) && state["focus"] == true
        warner.call(wait_line("recovered", state, attempts, clock.call - started)) if attempts > 1
        return state
      end

      left = deadline - clock.call
      unless left.positive?
        warner.call(wait_line("failed", state, attempts, clock.call - started))
        raise PageNotFocused, failure_message(state, wait, attempts)
      end

      sleeper.call([ PAUSE, left ].min)
    end
  end

  def shown_state(state)
    state = {} unless state.is_a?(Hash)
    %w[focus visibility active].map { |key| "#{key}=#{state[key].to_s.gsub(/[^[:print:]]/, '?')[0, 80]}" }.join(" ")
  end

  def wait_line(outcome, state, attempts, waited)
    "FOCUS_WAIT #{outcome} checks=#{attempts} waited=#{format('%.2f', waited)}s #{shown_state(state)}"
  end

  def failure_message(state, wait, attempts)
    shown = shown_state(state)
    "Page never had focus: document.hasFocus() stayed false for #{wait}s (#{attempts} checks, last state: #{shown}). " \
      "Keys were not sent."
  end

  # Prepended on Selenium::WebDriver::Element (Capybara's send_keys, fill_in and set
  # all end here).
  module ElementGuard
    def send_keys(*args)
      FocusBeforeKeys.wait_for_focus(probe: -> { bridge.execute_script(FocusBeforeKeys::PROBE) })
      super
    end
    alias_method :send_key, :send_keys
  end

  def self.install
    return if Selenium::WebDriver::Element.ancestors.include?(ElementGuard)

    Selenium::WebDriver::Element.prepend(ElementGuard)
  end
end

FocusBeforeKeys.install
