require "test_helper"
require_relative "test_helpers/chromedriver_timeline"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  DESKTOP_WINDOW = [ 1400, 1400 ].freeze
  # Diagnostics only (see ChromedriverTimeline): on CI the driver writes its own
  # verbose log to a private temp file; only a sanitized timing skeleton of it is
  # ever printed, and only for a failed test. No wait, retry or classification.
  driven_by :selenium, using: :headless_chrome, screen_size: DESKTOP_WINDOW,
            options: ChromedriverTimeline.driver_options

  if ChromedriverTimeline.enabled?
    ActiveSupport::Testing::Parallelization.after_fork_hook { |worker| ChromedriverTimeline.after_fork(worker) }
    Minitest.after_run { ChromedriverTimeline.cleanup }
  end

  def before_setup
    @driver_log_mark = ChromedriverTimeline.enabled? ? ChromedriverTimeline.mark : nil
    super
  end

  # Every system test signs in through the real form, and sessions#create is
  # rate limited to 10 per 3 minutes per process (the counter lives in the
  # test process's memory cache). Start each test with an empty cache so the
  # order of tests and the number of UI logins never trip that limit. Test
  # only: the production limit is unchanged, and the dedicated rate-limit
  # test in sessions_controller_test still exercises it.
  setup { Rails.cache.clear }

  # The browser window survives between tests. A test that resizes it to phone
  # width (390px) left the next test at that width, where the desktop layout
  # assertions (.app-shell-plan-name and others) fail depending on test order.
  # Every test starts at the configured desktop size; phone tests resize inside
  # the test as before.
  setup do
    window = page.driver.browser.manage.window
    before = window.size
    window.resize_to(*DESKTOP_WINDOW)
    after = window.size
    (@window_trace ||= []) << { before: [ before.width, before.height ], after: [ after.width, after.height ] }
  end

  # One CDP registration per browser session (Capybara reuses a single browser
  # for the whole process; reset! only navigates to about:blank). The script id
  # is kept so the registration is removed at exit and re-made only when the
  # browser object changes. Setup never raises: a failed registration is
  # warned once and install_input_log falls back to a per-document install.
  class << self
    attr_accessor :input_capture
  end

  setup { register_input_capture }

  # Experiment, not a fix: ask the browser to activate its page once per test, in
  # setup, after the window is sized and the capture is registered and before any
  # test step or login. One CDP call per test, never per gesture, no wait and no
  # retry. Success is silent. A failure never fails the test: the first one is
  # warned with the error class only, and the test runs as before. Every call of
  # the method is counted before the CDP call (page_activation_calls counts method
  # calls, so a direct call from a test counts too), failures are counted in the
  # rescue, and the tally is printed once at exit only when there was a failure.
  class << self
    attr_accessor :page_activation_warned
    attr_writer :page_activation_calls, :page_activation_failures

    def page_activation_calls = @page_activation_calls || 0
    def page_activation_failures = @page_activation_failures || 0
  end

  setup { activate_page }

  def activate_page
    ApplicationSystemTestCase.page_activation_calls += 1
    page.driver.browser.execute_cdp("Page.bringToFront")
  rescue StandardError => e
    ApplicationSystemTestCase.page_activation_failures += 1
    return if ApplicationSystemTestCase.page_activation_warned

    ApplicationSystemTestCase.page_activation_warned = true
    warn "PAGE_ACTIVATION unavailable: #{e.class.name}"
  end

  Minitest.after_run do
    if ApplicationSystemTestCase.page_activation_failures.positive?
      begin
        warn "PAGE_ACTIVATION tally method_calls=#{ApplicationSystemTestCase.page_activation_calls} failures=#{ApplicationSystemTestCase.page_activation_failures}"
      rescue StandardError
        nil
      end
    end
  end

  Minitest.after_run do
    reg = ApplicationSystemTestCase.input_capture
    if reg && reg[:script_id]
      begin
        reg[:browser].execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: reg[:script_id])
      rescue StandardError
        nil
      end
    end
  end

  def register_input_capture
    browser = page.driver.browser
    reg = ApplicationSystemTestCase.input_capture
    return if reg && reg[:browser].equal?(browser)

    id = browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: INPUT_LOG_JS)["identifier"]
    ApplicationSystemTestCase.input_capture = { browser: browser, script_id: id }
  rescue StandardError => e
    ApplicationSystemTestCase.input_capture = { browser: browser, script_id: nil, error: e.class.name }
    warn "INPUT_CAPTURE registration unavailable: #{e.class}"
  end

  INPUT_CAPTURE_READ_JS = <<~JS.freeze
    (() => JSON.stringify({
      docId: window.__docId || null,
      installed: !!window.__inputLogInstalled,
      error: window.__inputLogError || null,
      now: Math.round(performance.now()),
      origin: Math.round(performance.timeOrigin),
      ready: document.readyState,
      focus: document.hasFocus(),
      visibility: document.visibilityState,
      active: window.__inputLogToken ? window.__inputLogToken(document.activeElement) : null,
      inputLog: window.__inputLog || [],
      inputDropped: window.__inputLogDropped || 0,
      lifecycle: window.__lifecycle || [],
      lifecycleDropped: window.__lifecycleDropped || 0
    }))()
  JS

  INPUT_CAPTURE_BYTES = 6000
  INPUT_CAPTURE_ENTRY = 120

  # Failed tests only. Reads the bounded page-side log and prints it to stderr.
  # Isolation: reads under a short timeout, never touches failures or the
  # exception, rescues only StandardError (Timeout::Error included) and reports
  # the class name. Entries are re-sanitized here (printable ASCII, 120 chars)
  # and the newest entries are kept within INPUT_CAPTURE_BYTES per list.
  def report_input_capture
    return unless failures.any?

    reg = ApplicationSystemTestCase.input_capture
    raw = Timeout.timeout(5) { page.evaluate_script(INPUT_CAPTURE_READ_JS) }
    data = JSON.parse(raw)
    report = {
      registration: reg.nil? ? "none" : (reg[:script_id] ? "cdp" : "failed"),
      docId: data["docId"].to_s[0, 8], installed: data["installed"] == true, error: data["error"].to_s[0, 20],
      now: data["now"].to_i, origin: data["origin"].to_i, ready: data["ready"].to_s[0, 12], focus: data["focus"] == true,
      visibility: data["visibility"].to_s[0, 12], active: bounded_capture_entry(data["active"]),
      inputDropped: data["inputDropped"].to_i, lifecycleDropped: data["lifecycleDropped"].to_i
    }
    report[:inputLog], report[:inputOmitted] = newest_within_bytes(data["inputLog"])
    report[:lifecycle], report[:lifecycleOmitted] = newest_within_bytes(data["lifecycle"])
    warn "INPUT_CAPTURE test=#{self.class}##{name} #{JSON.generate(report)}"
  rescue StandardError => e
    warn "INPUT_CAPTURE unavailable: #{e.class}"
  end

  def bounded_capture_entry(value)
    value.to_s.gsub(/[^\x20-\x7e]/, "?")[0, INPUT_CAPTURE_ENTRY]
  end

  def newest_within_bytes(entries)
    list = Array(entries).map { |entry| bounded_capture_entry(entry) }
    kept = []
    used = 0
    list.reverse_each do |entry|
      break if used + entry.bytesize + 4 > INPUT_CAPTURE_BYTES

      kept.unshift(entry)
      used += entry.bytesize + 4
    end
    [ kept, list.size - kept.size ]
  end

  # Observation only, for the intermittent driver error "Node with given id
  # does not belong to the document" (seen in several different system tests).
  # The original error is untouched and still fails the test. When a test
  # ended with that error, print to stderr what the stripped backtrace hides
  # (the test-file frames of the raw backtrace) and a small bounded snapshot of
  # the page at that moment. Synthetic test data only; no retry, no rescue.
  NODE_LOST_MESSAGE = "Node with given id does not belong to the document".freeze

  def before_teardown
    report_lost_node
    report_driver_timeline
    report_input_capture
  ensure
    super
  end

  # Failed tests only. Prints the sanitized skeleton of the driver log written
  # during this test; the real failure is reported by minitest as before.
  def report_driver_timeline
    return unless @driver_log_mark && failures.any?

    result = ChromedriverTimeline.skeleton(ChromedriverTimeline.current_path, from: @driver_log_mark)
    warn ChromedriverTimeline.report("#{self.class}##{name}", result)
  rescue StandardError => e
    warn "CHROMEDRIVER_TIMELINE unavailable: #{e.class}"
  end

  def report_lost_node
    lost = failures.filter_map { |f| f.error if f.respond_to?(:error) && f.error.message.to_s.include?(NODE_LOST_MESSAGE) }.first
    if lost
      frames = lost.backtrace.to_a
      snapshot = begin
        page.evaluate_script(<<~JS)
          (() => JSON.stringify({
            path: location.pathname,
            readyState: document.readyState,
            visibility: document.visibilityState,
            title: document.title,
            heading: (document.querySelector("h1") || {}).textContent,
            text: document.body ? document.body.innerText.replace(/\s+/g, " ").slice(0, 300) : null,
            elementCount: document.getElementsByTagName("*").length,
            turboVisiting: document.documentElement.hasAttribute("data-turbo-preview") || document.documentElement.hasAttribute("aria-busy")
          }))()
        JS
      rescue => e
        "page snapshot unavailable: #{e.class}"
      end
      warn "NODE_LOST_DIAGNOSTIC test=#{self.class}##{name} error=#{lost.class}"
      warn "NODE_LOST_DIAGNOSTIC test-frames:\n#{frames.grep(%r{/test/|^test/}).first(15).join("\n")}"
      warn "NODE_LOST_DIAGNOSTIC raw-frames-total=#{frames.size} all-frames(bounded 40):\n#{frames.first(40).join("\n")}"
      warn "NODE_LOST_DIAGNOSTIC lifecycle=#{lost_node_lifecycle(lost)}"
      warn "NODE_LOST_DIAGNOSTIC doc-state=#{doc_state}"
      warn "NODE_LOST_DIAGNOSTIC page=#{snapshot}"
    end
  rescue => e
    warn "NODE_LOST_DIAGNOSTIC unavailable: #{e.class}"
  end

  # Where in the test lifecycle the error was raised, from state the test
  # object already holds. Bounded, no retry, no rescue of the original error.
  def lost_node_lifecycle(error)
    {
      failure_count: failures.size,
      current_url: (page.current_url rescue "unavailable"),
      window_handles: (page.driver.browser.window_handles.size rescue "unavailable"),
      click_trace_entries: (@click_trace || []).size,
      window_trace_entries: (@window_trace || []).size,
      error_cause: error.cause&.class&.name,
      time: Time.now.utc.iso8601(3)
    }.to_json
  rescue => e
    "unavailable: #{e.class}"
  end

  SHELL_STATE_JS = <<~JS
    (() => {
      const shell = document.querySelector("[data-controller~=app-shell]");
      const names = [...document.querySelectorAll(".app-shell-plan-name")].map((el) => {
        const cs = getComputedStyle(el), r = el.getBoundingClientRect();
        return { text: el.textContent.trim(), display: cs.display, visibility: cs.visibility, rect: [r.x, r.y, r.width, r.height].map(Math.round), innerText: el.innerText };
      });
      let storage;
      try { storage = window.localStorage.getItem("budgetify.sidebarCollapsed"); } catch (e) { storage = "unavailable: " + e.name; }
      return JSON.stringify({
        href: location.pathname,
        inner: [innerWidth, innerHeight],
        outer: [outerWidth, outerHeight],
        screen: [screen.width, screen.height],
        dpr: devicePixelRatio,
        shellClass: shell ? shell.className : "no shell element",
        shellTag: shell ? shell.tagName : null,
        collapsedStorage: storage,
        media: { phone: matchMedia("(max-width: 600px)").matches, small: matchMedia("(max-width: 900px)").matches, wide: matchMedia("(max-width: 1200px)").matches },
        planNames: names,
        readyState: document.readyState
      });
    })()
  JS

  def shell_state
    page.evaluate_script(SHELL_STATE_JS)
  rescue => e
    "shell state unavailable: #{e.class}: #{e.message.to_s.lines.first&.strip}"
  end

  # Re-raises an expectation failure with the window history of this test and
  # the shell layout state (width, collapsed class, storage, computed plan name
  # visibility) appended. Observation only: the assertion is unchanged.
  def with_shell_diagnostics
    yield
  rescue Minitest::Assertion, Capybara::ExpectationNotMet => e
    raise e.class, "#{e.message}\nWindow trace: #{(@window_trace || []).to_json}\nShell state: #{shell_state}", e.backtrace
  end

  # Test-driver diagnostics for lost clicks (the recurring Cancel failure).
  # Native Selenium clicks stay as they are. Install the log before the
  # interaction; when an expectation then fails, the message carries what the
  # page saw: every pointer event with its target and time, and a snapshot of
  # the window, focus, ready state and what sits at the center of each named
  # control. That separates "the click never reached the page" (no events),
  # "it hit another element" (target differs), and "the page was not ready".
  def install_input_log
    # Idempotent: INPUT_LOG_JS does nothing when the document already has the
    # log (the per-session preload registers it before any page script runs).
    # This call only adds an ordering mark; it never resets the log.
    page.execute_script("#{INPUT_LOG_JS}\nwindow.__inputLogMark && window.__inputLogMark('manual install');")
  end

  DOC_STATE_JS = <<~JS
    (() => JSON.stringify({
      docId: window.__docId || null,
      timeOrigin: Math.round(performance.timeOrigin),
      now: Math.round(performance.now()),
      installedAt: window.__inputInstalledAt === undefined ? null : window.__inputInstalledAt,
      href: location.pathname + location.search,
      readyState: document.readyState,
      visibility: document.visibilityState,
      focus: document.hasFocus(),
      navType: (performance.getEntriesByType("navigation")[0] || {}).type || null,
      topFrame: window === window.top,
      scrollY: Math.round(scrollY),
      inner: [innerWidth, innerHeight]
    }))()
  JS

  CONTROL_STATE_JS = <<~JS
    (function (el) {
      const r = el.getBoundingClientRect();
      const cx = r.x + r.width / 2, cy = r.y + r.height / 2;
      const top = document.elementFromPoint(cx, cy);
      return JSON.stringify({
        rect: [r.x, r.y, r.width, r.height].map(Math.round),
        center: [Math.round(cx), Math.round(cy)],
        top: top ? top.tagName + " '" + (top.textContent || "").trim().slice(0, 16) + "'" + (top === el || el.contains(top) ? " (same control)" : " (DIFFERENT element)") : "none",
        connected: el.isConnected
      });
    })(arguments[0])
  JS

  def doc_state
    page.evaluate_script(DOC_STATE_JS)
  rescue => e
    "unavailable: #{e.class}"
  end

  # A native Selenium click with a before/after record in @click_trace:
  # document identity and lifecycle, plus the control's geometry and what sits
  # at its center. Nothing here replaces or retries the click. The after
  # record can say the node is gone, which is itself evidence (navigation).
  def diag_click(node, name)
    @click_trace ||= []
    before_control = begin
      page.evaluate_script(CONTROL_STATE_JS, node)
    rescue => e
      "unavailable: #{e.class}"
    end
    entry = { name: name, before: { doc: doc_state, control: before_control } }
    @click_trace << entry
    node.click
    entry[:after] = { doc: doc_state, control: begin
      page.evaluate_script(CONTROL_STATE_JS, node)
    rescue => e
      "unavailable: #{e.class}"
    end }
    entry[:clicked] = true
  rescue => e
    entry[:raised] = "#{e.class}: #{e.message.to_s.lines.first&.strip}" if entry
    raise
  end

  def input_diagnostics(*labels)
    json = page.evaluate_script(<<~JS)
      (() => {
        const labels = #{labels.to_json};
        const controls = labels.map((label) => {
          const el = [...document.querySelectorAll("a, button")].find((x) => x.textContent.trim() === label);
          if (!el) return label + ": not found";
          const r = el.getBoundingClientRect();
          const cx = r.x + r.width / 2, cy = r.y + r.height / 2;
          const top = document.elementFromPoint(cx, cy);
          return label + ": rect=" + [r.x, r.y, r.width, r.height].map(Math.round) + " center=" + Math.round(cx) + "," + Math.round(cy) + " top=" + (top ? top.tagName + " '" + (top.textContent || "").trim().slice(0, 16) + "'" : "none") + " offscreen=" + (cy < 0 || cy > innerHeight || cx < 0 || cx > innerWidth);
        });
        return JSON.stringify({
          path: location.pathname,
          window: [innerWidth, innerHeight],
          outer: [outerWidth, outerHeight],
          dpr: devicePixelRatio,
          focus: document.hasFocus(),
          active: document.activeElement ? document.activeElement.tagName + "#" + document.activeElement.id : "none",
          fields: [...document.querySelectorAll("input.field__input")].map((i) => i.id + "=" + JSON.stringify(i.value) + " invalid=" + i.getAttribute("aria-invalid")),
          buttons: [...document.querySelectorAll("form button")].map((b) => b.textContent.trim() + ":" + (b.disabled ? "disabled" : "enabled")),
          visibility: document.visibilityState,
          readyState: document.readyState,
          scrollY: Math.round(scrollY),
          openDialogs: document.querySelectorAll("dialog[open]").length,
          details: [...document.querySelectorAll("details")].map((d) => (d.className || "details") + " open=" + d.open),
          controls,
          // Probe-local try/catch: a throw here must not black out the rest of
          // the dump. Read it as state at failure time, after the wait expired;
          // an unconnected controller narrows the state, it does not prove why.
          stimulus: (() => {
            try {
              const app = window.Stimulus;
              if (!app) return "window.Stimulus missing";
              const registered = app.router.modules.map((m) => m.definition.identifier).sort();
              const pending = [...document.querySelectorAll("[data-controller]")].flatMap((el) => el.dataset.controller.split(/\s+/).filter(Boolean).filter((id) => !app.getControllerForElementAndIdentifier(el, id)));
              return { registered, notConnected: [...new Set(pending)], turbo: typeof window.Turbo };
            } catch (e) {
              return "stimulus probe failed: " + String(e && e.message || e).slice(0, 200);
            }
          })(),
          inputLog: window.__inputLog || "not installed",
          lifecycle: window.__lifecycle || "not installed"
        });
      })()
    JS
    "#{json}\nDocument now: #{doc_state}\nClick trace: #{(@click_trace || []).to_json}"
  rescue => e
    "diagnostics unavailable: #{e.class}: #{e.message}"
  end

  # Re-raises an expectation failure with the diagnostics appended.
  def with_input_diagnostics(*labels)
    yield
  rescue Minitest::Assertion, Capybara::ExpectationNotMet => e
    raise e.class, "#{e.message}\nInput diagnostics: #{input_diagnostics(*labels)}", e.backtrace
  end

  # Page-side action log for failure diagnosis. Registered once per browser
  # session through CDP (see register_input_capture) so it exists from the start
  # of every document, and also usable through install_input_log. Rules:
  # - idempotent per document, top frame only, never throws into the page;
  # - listeners only (capture, passive): no wrapped fetch/XHR, no DOM writes;
  # - records event type, tag, input type, disabled flag and an allowlisted id.
  #   It never records input values, printable key names, element text, URLs or
  #   hosts. Non-printable keys are named from a fixed list; the rest is "char".
  # - ring buffers of at most 200 entries (120 chars each) with a dropped count.
  INPUT_LOG_JS = <<~'JS'
    (function () {
      try {
        if (window !== window.top || window.__inputLogInstalled) return;
        window.__inputLogInstalled = true;
        var MAX = 200, MAXLEN = 120;
        var now = function () { return Math.round(performance.now()); };
        window.__docId = Math.random().toString(36).slice(2, 8);
        window.__inputInstalledAt = now();
        window.__inputLog = []; window.__inputLogDropped = 0;
        window.__lifecycle = []; window.__lifecycleDropped = 0;
        var push = function (list, dropped, text) {
          if (window[list].length >= MAX) { window[list].shift(); window[dropped]++; }
          window[list].push((now() + "ms " + text).slice(0, MAXLEN));
        };
        var KEYS = { Enter: 1, Escape: 1, Tab: 1, Backspace: 1, Delete: 1, ArrowUp: 1, ArrowDown: 1, ArrowLeft: 1, ArrowRight: 1, Home: 1, End: 1, PageUp: 1, PageDown: 1, Shift: 1, Control: 1, Alt: 1, Meta: 1 };
        var TYPES = { text: 1, number: 1, email: 1, password: 1, checkbox: 1, radio: 1, submit: 1, button: 1, date: 1, search: 1, hidden: 1, tel: 1, url: 1 };
        var IDS = /^(transaction_(outflow|inflow|payee|memo|date|category_id)|split_(outflow|inflow)|split_rows_[0-9]{1,2}_(outflow|inflow|memo|category_id)|reconcile_balance|target_amount|account_name|wz-name|wz-bal|dlg-(basic|basic-t|editor|editor-t|err-t|error|fresh-start|fresh-t|mig-t|migrate|reconciled-delete|reconciled-delete-t|reconciled-save|reconciled-save-t|warn|warn-t|wiz-t|wizard))$/;
        var token = function (el) {
          if (!el || !el.tagName) return el && el.nodeType === 9 ? "#document" : "none";
          var out = String(el.tagName).toLowerCase().replace(/[^a-z0-9]/g, "").slice(0, 12);
          if (el.tagName === "INPUT") out += ":" + (TYPES[el.type] ? el.type : "other");
          if (el.id) out += IDS.test(el.id) ? "#" + el.id : "#?";
          if (el.disabled === true) out += " disabled";
          return out;
        };
        window.__inputLogToken = token;
        window.__inputLogMark = function (label) { if (label === "manual install") push("__inputLog", "__inputLogDropped", "mark " + label); };
        var act = function (type, extra) { document.addEventListener(type, function (e) { try { push("__inputLog", "__inputLogDropped", type + (extra ? extra(e) : "") + " " + token(e.target)); } catch (x) { window.__inputLogError = x.name; } }, { capture: true, passive: true }); };
        var keyInfo = function (e) {
          var k = KEYS[e.key] ? e.key : (typeof e.key === "string" && e.key.length === 1 ? "char" : "key?");
          return " " + k + (e.ctrlKey ? "+ctrl" : "") + (e.metaKey ? "+meta" : "") + (e.altKey ? "+alt" : "");
        };
        ["keydown", "keyup"].forEach(function (t) { act(t, keyInfo); });
        ["beforeinput", "input"].forEach(function (t) { act(t, function (e) { return " " + String(e.inputType || "").replace(/[^A-Za-z]/g, "").slice(0, 30); }); });
        ["pointerdown", "mousedown", "mouseup", "click"].forEach(function (t) { act(t); });
        act("toggle", function (e) { return " open=" + (e.target && e.target.open === true); });
        ["turbo:click", "turbo:before-fetch-request", "turbo:before-fetch-response", "turbo:visit", "turbo:submit-start", "turbo:submit-end", "turbo:frame-load"].forEach(function (t) { act(t); });
        var life = function (target, type) { target.addEventListener(type, function () { try { push("__lifecycle", "__lifecycleDropped", type + " " + document.visibilityState + "/" + document.readyState); } catch (x) { window.__inputLogError = x.name; } }, { capture: true, passive: true }); };
        ["pagehide", "pageshow", "beforeunload"].forEach(function (t) { life(window, t); });
        ["visibilitychange", "readystatechange", "DOMContentLoaded", "turbo:before-visit", "turbo:before-render", "turbo:render", "turbo:load"].forEach(function (t) { life(document, t); });
        if (window.navigation) window.navigation.addEventListener("navigate", function (e) { try { push("__lifecycle", "__lifecycleDropped", "navigate " + String(e.navigationType).replace(/[^a-z]/g, "").slice(0, 10)); } catch (x) { window.__inputLogError = x.name; } }, { capture: true, passive: true });
      } catch (e) {
        try { window.__inputLogError = e && e.name; } catch (x) {}
      }
    })();
  JS
end
