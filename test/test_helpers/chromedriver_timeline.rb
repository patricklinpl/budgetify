require "tmpdir"
require "fileutils"

# Timing skeleton of ChromeDriver's own verbose log, for system tests.
#
# Diagnostics only. It adds no wait, no retry and no error classification, and
# it never changes or hides the real test failure (that still prints through
# the normal minitest report).
#
# Why: for the intermittent system test failures we need to see the ORDER of
# a click's dispatch, its "Waiting for pending navigations" steps, its response
# and the browser's navigation events. The raw ChromeDriver log has all of
# that, but it also carries URLs, element and session ids, script text, page
# text and field values, so it is never printed or uploaded.
#
# What comes out: one line per allowlisted record, made of only
#   +<ms since the first kept record> <kind> <token> [<status>]
# kind  C/R  WebDriver command/response   token from VERBS
#       D/d  DevTools command/response    token from DEVTOOLS_CALLS
#       E    DevTools event               token from EVENTS
#       W    pending-navigation wait      token "wait" or "done", status ok|timeout|other
# Everything else is dropped and only counted: payload lines, error text, ids,
# URLs, unknown verbs or events, malformed or oversized lines. A line is parsed
# from its first PREFIX_BYTES bytes only and a token is accepted only when it
# is in its fixed list, so no text from the log can reach the output. The raw
# log stays in a private temp directory and is removed when the run ends.
module ChromedriverTimeline
  PREFIX_BYTES = 300
  MAX_RECORDS = 300
  MAX_OUTPUT_BYTES = 8192

  VERBS = %w[
    Navigate GetUrl Refresh GoBack GoForward GetTitle
    FindElement FindElements ClickElement TypeElement ClearElement SubmitElement
    GetElementText GetElementAttribute GetElementProperty IsElementDisplayed
    GetElementTagName GetElementRect ExecuteScript ExecuteAsyncScript
    PerformActions ReleaseActions GetWindowRect SetWindowRect GetWindows
    DismissAlert AcceptAlert GetAlertText
  ].freeze

  DEVTOOLS_CALLS = %w[Input.dispatchMouseEvent Input.dispatchKeyEvent Page.navigate].freeze

  EVENTS = %w[
    Page.frameRequestedNavigation Page.frameScheduledNavigation Page.frameStartedNavigating
    Page.frameNavigated Page.navigatedWithinDocument Page.frameStartedLoading
    Page.frameStoppedLoading Page.domContentEventFired Page.loadEventFired
    Runtime.executionContextsCleared Runtime.executionContextCreated
  ].freeze

  STATUSES = %w[ok timeout].freeze

  STAMP = /\A\[(\d{10,12}\.\d{3})\]\[(?:INFO|DEBUG)\]: /n
  WEBDRIVER = /\A\[[0-9a-f]{32}\] (COMMAND|RESPONSE) ([A-Za-z]{1,40})(?:[ {]|\z)/n
  WAITING = /\AWaiting for pending navigations\.\.\.\z/n
  DONE = /\ADone waiting for pending navigations\. Status: ([a-z ]{1,40})\z/n
  DEVTOOLS = /\ADevTools WebSocket (Command|Response|Event): ([A-Za-z]{1,20}\.[A-Za-z]{1,40})(?: \(|\z)/n

  # Output line grammar, used by the regression tests.
  LINE_FORMAT = /\A\+\d+ms [CRDdEW] [A-Za-z.]{1,60}(?: (?:ok|timeout|other))?\z/

  Result = Struct.new(:lines, :records, :dropped, :truncated, keyword_init: true)

  class << self
    # Off unless CHROMEDRIVER_TIMELINE_DIR is set (the CI system-test job sets it,
    # so the raw log lives in a directory the job removes) or CHROMEDRIVER_TIMELINE=1
    # (local opt-in, private temp dir).
    def enabled?
      ENV["CHROMEDRIVER_TIMELINE_DIR"].present? || ENV["CHROMEDRIVER_TIMELINE"] == "1"
    end

    def dir
      @dir ||= begin
        configured = ENV["CHROMEDRIVER_TIMELINE_DIR"].presence
        if configured
          FileUtils.mkdir_p(configured, mode: 0o700)
          File.chmod(0o700, configured)
          configured
        else
          Dir.mktmpdir("chromedriver-timeline-").tap { |d| File.chmod(0o700, d) }
        end
      end
    end

    def log_path(worker = Process.pid)
      File.join(dir, "driver-#{worker}.log")
    end

    # Selenium service for Capybara's driver. One Service object is created in
    # the parent; every forked test worker points it at its own file (after_fork).
    def service
      @service ||= Selenium::WebDriver::Service.chrome(args: [ "--verbose", "--log-path=#{log_path}" ])
    end

    def driver_options
      enabled? ? { service: service } : {}
    end

    def after_fork(worker)
      return unless enabled?
      service.args.reject! { |arg| arg.start_with?("--log-path=") }
      service.args << "--log-path=#{log_path("w#{worker}")}"
      @current_path = log_path("w#{worker}")
    end

    def current_path
      @current_path ||= log_path
    end

    # Removes the raw logs. Called when the run ends, after extraction. The CI job
    # also removes the directory itself (shell EXIT trap and an always() step), so
    # a crashed or killed worker does not leave raw files behind.
    def cleanup
      FileUtils.rm_rf(@dir) if @dir
    end

    def mark
      File.exist?(current_path) ? File.size(current_path) : 0
    end

    # Skeleton of the part of the raw log written after byte offset +from+.
    def skeleton(path, from: 0)
      records = []
      dropped = 0
      truncated = false
      first = nil
      File.open(path, "rb") do |io|
        io.seek(from)
        io.gets("\n", PREFIX_BYTES) if from.positive? # may start inside a line
        io.each_line("\n", PREFIX_BYTES) do |raw|
          record = parse(raw.chomp, first)
          if record.nil?
            dropped += 1
            next
          end
          first ||= record[:t]
          records << record
          if records.size > MAX_RECORDS
            records.shift
            truncated = true
          end
        end
      end
      render(records, dropped, truncated, first)
    rescue SystemCallError, IOError
      Result.new(lines: [], records: 0, dropped: 0, truncated: false)
    end

    def parse(line, first)
      stamp = STAMP.match(line)
      return nil unless stamp

      rest = line.byteslice(stamp.end(0)..)
      t = stamp[1].to_f
      if (m = WEBDRIVER.match(rest))
        return nil unless VERBS.include?(m[2])
        { t: t, kind: (m[1] == "COMMAND" ? "C" : "R"), token: m[2] }
      elsif (m = DEVTOOLS.match(rest))
        name = m[2]
        case m[1]
        when "Event" then EVENTS.include?(name) ? { t: t, kind: "E", token: name } : nil
        else DEVTOOLS_CALLS.include?(name) ? { t: t, kind: (m[1] == "Command" ? "D" : "d"), token: name } : nil
        end
      elsif WAITING.match?(rest)
        { t: t, kind: "W", token: "wait" }
      elsif (m = DONE.match(rest))
        { t: t, kind: "W", token: "done", status: (STATUSES.include?(m[1]) ? m[1] : "other") }
      end
    end

    def render(records, dropped, truncated, first)
      lines = records.map do |r|
        ms = ((r[:t] - (records.first[:t])) * 1000).round
        [ "+#{ms}ms", r[:kind], r[:token], r[:status] ].compact.join(" ")
      end
      while lines.sum { |l| l.bytesize + 1 } > MAX_OUTPUT_BYTES
        lines.shift
        truncated = true
      end
      Result.new(lines: lines, records: records.size, dropped: dropped, truncated: truncated)
    end

    # The text printed to stderr for a failed test. Test identity and counts only.
    def report(test_id, result)
      header = "CHROMEDRIVER_TIMELINE test=#{test_id} kept=#{result.lines.size} records=#{result.records} dropped_lines=#{result.dropped} truncated=#{result.truncated}"
      ([ header ] + result.lines.map { |l| "CHROMEDRIVER_TIMELINE #{l}" }).join("\n")
    end
  end
end
