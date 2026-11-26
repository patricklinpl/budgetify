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
# One cheap script call per send_keys. Nothing else changes: no click is touched,
# no retry of the typing, no assertion, no activation call. If the page is still
# unfocused when the time is up, the typing is NOT sent and the failure says what
# the page reported. If the probe itself cannot run (an alert is open, the session
# is gone), the original send_keys runs exactly as before.
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
  def wait_for_focus(probe:, wait: WAIT, clock: nil, sleeper: nil)
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
      return state if state.is_a?(Hash) && state["focus"] == true

      left = deadline - clock.call
      raise PageNotFocused, failure_message(state, wait, attempts) unless left.positive?

      sleeper.call([ PAUSE, left ].min)
    end
  end

  def failure_message(state, wait, attempts)
    state = {} unless state.is_a?(Hash)
    shown = %w[focus visibility active].map { |key| "#{key}=#{state[key].to_s.gsub(/[^[:print:]]/, '?')[0, 80]}" }.join(" ")
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
