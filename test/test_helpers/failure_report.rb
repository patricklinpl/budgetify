require "json"
require "fileutils"

# Failure report for system tests. Observation only.
#
# It adds no wait, no retry, no assertion and no error classification, and it
# never changes or hides the real failure (minitest still prints it as before).
# Everything here is off unless DIAG_ARTIFACT_DIR is set (CI sets it).
#
# What it adds for a failed test (printed as FAILURE_SUMMARY lines and written to
# <DIAG_ARTIFACT_DIR>/failures/<position>-<test>.json, which CI uploads):
#   the test, its position in the process, the seed, the Chrome and driver
#   versions, the failing step (test-file line), the error, the element named in
#   a Capybara message, the browser targets and window bounds when the test ended,
#   the full page-side input capture (no byte limit), and the last inputs with the
#   browser state read right after each one returned (DIAG_INPUT_STATE=1 only).
#
# For a passing test, DIAG_PASS_CONTROL=1 prints one INPUT_OK line (counts of the
# captured keydown, input and click events), so a log shows the capture works.
#
# The test data is synthetic. Raw driver and Chrome logs in the artifact carry
# URLs, element ids and field values of that synthetic data.
module FailureReport
  MESSAGE_BYTES = 400
  LINE_BYTES = 160
  INPUT_RING = 12

  ELEMENT_PATTERN = /(?:Unable to find|expected to find)\s+(?:visible\s+|non-visible\s+)?([a-z][a-z ]{0,20}?)\s*"([^"]{1,120})"/

  module_function

  def dir
    ENV["DIAG_ARTIFACT_DIR"].presence
  end

  def enabled?
    !dir.nil?
  end

  def pass_control?
    enabled? && ENV["DIAG_PASS_CONTROL"] == "1"
  end

  def input_state?
    enabled? && ENV["DIAG_INPUT_STATE"] == "1"
  end

  # Extra Chrome flags: Chrome's own log, written inside the artifact directory.
  def chrome_args
    return [] unless enabled? && ENV["DIAG_CHROME_LOG"] == "1"

    FileUtils.mkdir_p(dir)
    [ "--enable-logging", "--log-level=0", "--log-file=#{File.join(dir, 'chrome.log')}" ]
  end

  # Printable ASCII only, bounded.
  def clean(value, limit)
    value.to_s.gsub(/[^\x20-\x7e]/, "?")[0, limit]
  end

  def element_from(message)
    match = ELEMENT_PATTERN.match(message.to_s)
    match ? "#{clean(match[1].strip, 20)} #{clean(match[2], 120)}" : "not named in the error"
  end

  # First frame of the backtrace inside the test directory, with the source line.
  def step_from(backtrace, root = Dir.pwd)
    frame = Array(backtrace).find { |f| f.to_s.match?(%r{(?:\A|/)test/.*\.rb:\d+}) }
    return "no test frame in the backtrace" unless frame

    path, line = frame.to_s.match(/\A(.*?):(\d+)/).captures
    text = begin
      File.readlines(File.expand_path(path, root))[line.to_i - 1].to_s.strip
    rescue SystemCallError
      ""
    end
    short = path.sub(%r{\A.*?(test/)}, '\1')
    "#{short}:#{line} #{clean(text, LINE_BYTES)}".strip
  end

  def summary(test_id:, position:, seed:, versions:, error:, backtrace:)
    {
      test: clean(test_id, 200),
      position: position,
      seed: seed,
      chrome: clean(versions[:chrome], 40),
      chromedriver: clean(versions[:chromedriver], 80),
      step: step_from(backtrace),
      error_class: clean(error&.class&.name, 80),
      error: clean(error&.message.to_s.lines.first.to_s.chomp, MESSAGE_BYTES),
      element: element_from(error&.message)
    }
  end

  def summary_lines(hash)
    hash.map { |key, value| "FAILURE_SUMMARY #{key}=#{value}" }
  end

  def slug(position, test_id)
    format("%03d-%s", position.to_i, test_id.to_s.gsub(/[^A-Za-z0-9]+/, "_")[0, 80])
  end

  def write(position, test_id, payload)
    return unless enabled?

    FileUtils.mkdir_p(File.join(dir, "failures"))
    path = File.join(dir, "failures", "#{slug(position, test_id)}.json")
    File.write(path, JSON.pretty_generate(payload))
    path
  end

  # Browser-side state: targets and the window bounds, read over CDP. Read only.
  def browser_state(browser)
    targets = browser.execute_cdp("Target.getTargets")["targetInfos"].map do |t|
      { type: t["type"], attached: t["attached"], id: t["targetId"].to_s[0, 8], path: URI(t["url"].to_s).path.to_s[0, 80] }
    rescue URI::InvalidURIError
      { type: t["type"], attached: t["attached"], id: t["targetId"].to_s[0, 8], path: "?" }
    end
    window = browser.execute_cdp("Browser.getWindowForTarget")
    bounds = window["bounds"] || browser.execute_cdp("Browser.getWindowBounds", windowId: window["windowId"])["bounds"]
    { targets: targets, window: bounds, handles: browser.window_handles.size }
  rescue StandardError => e
    { error: e.class.name }
  end

  # Recent inputs, newest last. Filled by ElementHook only when input_state?.
  def inputs
    @inputs ||= []
  end

  def reset_inputs(browser)
    @inputs = []
    @browser = browser
    @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Called after the driver command returned, so the input itself is not delayed.
  def after_input(kind)
    return unless input_state? && @browser

    entry = { input: kind, at_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started) * 1000).round }
    entry[:state] = browser_state(@browser)
    inputs << entry
    inputs.shift while inputs.size > INPUT_RING
  rescue StandardError
    nil
  end

  # Wraps the native element's click and send_keys. The original result and any
  # error pass through unchanged; the record is made after the command returned.
  module ElementHook
    def click(*args, **kwargs, &block)
      result = super
      FailureReport.after_input(:click)
      result
    end

    def send_keys(*args)
      result = super
      FailureReport.after_input(:send_keys)
      result
    end
  end

  def install_hook
    return unless input_state?
    return if Selenium::WebDriver::Element.ancestors.include?(ElementHook)

    Selenium::WebDriver::Element.prepend(ElementHook)
  end
end
