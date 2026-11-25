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
  # Selection when a test produced more than MAX_RECORDS records and at least one
  # action record: the newest TAIL_RECORDS records are always kept, the rest of the
  # budget goes to the newest whole action groups (see Selector).
  TAIL_RECORDS = 100

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

  # Action records: the commands that change the page (and their responses), every
  # DevTools input/navigate call and every page event. Polling (find, script, text
  # reads) and W records are not action records. Matched on the allowlisted token only.
  ACTION_VERBS = %w[
    Navigate Refresh GoBack GoForward ClickElement TypeElement ClearElement
    SubmitElement PerformActions ReleaseActions SetWindowRect DismissAlert AcceptAlert
  ].freeze

  STATUSES = %w[ok timeout].freeze

  STAMP = /\A\[(\d{10,12}\.\d{3})\]\[(?:INFO|DEBUG)\]: /n
  WEBDRIVER = /\A\[[0-9a-f]{32}\] (COMMAND|RESPONSE) ([A-Za-z]{1,40})(?:[ {]|\z)/n
  WAITING = /\AWaiting for pending navigations\.\.\.\z/n
  DONE = /\ADone waiting for pending navigations\. Status: ([a-z ]{1,40})\z/n
  DEVTOOLS = /\ADevTools WebSocket (Command|Response|Event): ([A-Za-z]{1,20}\.[A-Za-z]{1,40})(?: \(|\z)/n

  # Output line grammar, used by the regression tests.
  # G is a gap marker: the count of allowlisted records left out at that point.
  LINE_FORMAT = /\A\+\d+ms (?:[CRDdEW] [A-Za-z.]{1,60}(?: (?:ok|timeout|other))?|G gap \d{1,9})\z/

  # records: allowlisted records seen. selected: records printed (gap markers not
  # counted). dropped_tail / dropped_action / dropped_other: records not printed, by class.
  Result = Struct.new(:lines, :records, :dropped, :truncated, :selected, :dropped_tail,
                      :dropped_action, :dropped_other, keyword_init: true)

  # Streaming selection, constant storage: at most MAX_RECORDS records in a ring of the
  # newest records, plus at most MAX_RECORDS action records (closed groups and the active
  # group together). An action group runs from an action command to the record before the
  # next action command (action records only). The newest TAIL_RECORDS records are the
  # tail, taken from the ring. Logs with <= MAX_RECORDS records, or with no action record,
  # keep exactly the old last-MAX_RECORDS behavior.
  class Selector
    attr_reader :total, :action_total

    def initialize
      @total = 0
      @action_total = 0
      @recent = []
      @groups = []
      @stored = 0
      @cur = []
    end

    def add(record)
      record[:seq] = @total
      @total += 1
      @recent << record
      @recent.shift if @recent.size > MAX_RECORDS
      return unless self.class.action?(record)

      @action_total += 1
      close_group if self.class.action_start?(record)
      @cur << record
      @cur.shift if @cur.size > MAX_RECORDS
      @stored -= @groups.shift.size while @stored + @cur.size > MAX_RECORDS && @groups.any?
    end

    def self.action?(record)
      case record[:kind]
      when "C", "R" then ACTION_VERBS.include?(record[:token])
      when "D", "d", "E" then true
      else false
      end
    end

    def self.action_start?(record)
      record[:kind] == "C" && ACTION_VERBS.include?(record[:token])
    end

    # The records to print, in log order. Rule: print the tail; then add action groups
    # newest to oldest while the printed lines (records plus gap markers) stay within
    # MAX_RECORDS lines and MAX_OUTPUT_BYTES bytes, stopping at the first group that does
    # not fit. A group that could never fit whole (more than MAX_RECORDS - TAIL_RECORDS
    # records) contributes its newest records that fit. Records already in the tail are
    # not repeated.
    def select_records
      close_group
      return @recent if @total <= MAX_RECORDS || @action_total.zero?

      chosen = @recent.last(TAIL_RECORDS)
      boundary = chosen.first[:seq]
      @groups.reverse_each do |group|
        candidate = group.select { |r| r[:seq] < boundary }
        next if candidate.empty?

        trial = candidate + chosen
        unless over_budget?(Selector.layout(trial))
          chosen = trial
          next
        end
        if candidate.size > MAX_RECORDS - TAIL_RECORDS
          candidate.size.downto(1) do |k|
            trial = candidate.last(k) + chosen
            next if over_budget?(Selector.layout(trial))

            chosen = trial
            break
          end
        end
        break
      end
      chosen
    end

    # One printed line per record, plus a gap marker wherever allowlisted records
    # are missing between two printed ones. ms is relative to the first record.
    def self.layout(records, base = records.first[:t])
      lines = []
      prev = nil
      records.each do |r|
        lines << "+#{ms(prev[:t], base)}ms G gap #{r[:seq] - prev[:seq] - 1}" if prev && r[:seq] != prev[:seq] + 1
        lines << [ "+#{ms(r[:t], base)}ms", r[:kind], r[:token], r[:status] ].compact.join(" ")
        prev = r
      end
      lines
    end

    def self.ms(t, base)
      ((t - base) * 1000).round
    end

    private

    def over_budget?(lines)
      lines.size > MAX_RECORDS || lines.sum { |l| l.bytesize + 1 } > MAX_OUTPUT_BYTES
    end

    def close_group
      return if @cur.empty?

      @groups << @cur
      @stored += @cur.size
      @cur = []
    end
  end

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
      selector = Selector.new
      dropped = 0
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
          selector.add(record)
        end
      end
      render(selector, dropped)
    rescue SystemCallError, IOError
      Result.new(lines: [], records: 0, dropped: 0, truncated: false, selected: 0,
                 dropped_tail: 0, dropped_action: 0, dropped_other: 0)
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

    def render(selector, dropped)
      records = selector.select_records
      lines = records.empty? ? [] : Selector.layout(records)
      # Old byte rule. Each record it sheds is counted once, as dropped_tail, and not
      # again in its class counter.
      shed = []
      while lines.sum { |l| l.bytesize + 1 } > MAX_OUTPUT_BYTES
        lines.shift
        shed << records.first
        records = records.drop(1)
      end
      actions = records.count { |r| Selector.action?(r) }
      shed_actions = shed.count { |r| Selector.action?(r) }
      Result.new(
        lines: lines, records: selector.total, dropped: dropped,
        truncated: records.size < selector.total, selected: records.size,
        dropped_tail: shed.size,
        dropped_action: selector.action_total - actions - shed_actions,
        dropped_other: (selector.total - selector.action_total) - (records.size - actions) - (shed.size - shed_actions)
      )
    end

    # The text printed to stderr for a failed test. Test identity and counts only.
    def report(test_id, result)
      header = "CHROMEDRIVER_TIMELINE test=#{test_id} kept=#{result.lines.size} records=#{result.records} selected=#{result.selected} dropped_tail=#{result.dropped_tail} dropped_action=#{result.dropped_action} dropped_other=#{result.dropped_other} dropped_lines=#{result.dropped} truncated=#{result.truncated}"
      ([ header ] + result.lines.map { |l| "CHROMEDRIVER_TIMELINE #{l}" }).join("\n")
    end
  end
end
