require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]

  # Every system test signs in through the real form, and sessions#create is
  # rate limited to 10 per 3 minutes per process (the counter lives in the
  # test process's memory cache). Start each test with an empty cache so the
  # order of tests and the number of UI logins never trip that limit. Test
  # only: the production limit is unchanged, and the dedicated rate-limit
  # test in sessions_controller_test still exercises it.
  setup { Rails.cache.clear }

  # Test-driver diagnostics for lost clicks (the recurring Cancel failure).
  # Native Selenium clicks stay as they are. Install the log before the
  # interaction; when an expectation then fails, the message carries what the
  # page saw: every pointer event with its target and time, and a snapshot of
  # the window, focus, ready state and what sits at the center of each named
  # control. That separates "the click never reached the page" (no events),
  # "it hit another element" (target differs), and "the page was not ready".
  def install_input_log
    page.execute_script(INPUT_LOG_JS)
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
          visibility: document.visibilityState,
          readyState: document.readyState,
          scrollY: Math.round(scrollY),
          openDialogs: document.querySelectorAll("dialog[open]").length,
          details: [...document.querySelectorAll("details")].map((d) => (d.className || "details") + " open=" + d.open),
          controls,
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
  rescue Minitest::Assertion, Capybara::ExpectationNotFound => e
    raise e.class, "#{e.message}\nInput diagnostics: #{input_diagnostics(*labels)}"
  end

  INPUT_LOG_JS = <<JS
window.__inputLog = [];
window.__docId = window.__docId || Math.random().toString(36).slice(2, 8);
window.__inputInstalledAt = Math.round(performance.now());
window.__lifecycle = [];
const mark = (what) => { if (window.__lifecycle.length < 200) window.__lifecycle.push(Math.round(performance.now()) + "ms " + what); };
["pagehide", "pageshow", "beforeunload", "scroll", "resize", "focus", "blur"].forEach((type) => window.addEventListener(type, () => mark(type + " scrollY=" + Math.round(scrollY) + " inner=" + innerWidth + "x" + innerHeight), true));
["visibilitychange", "turbo:before-visit", "turbo:before-render", "turbo:render", "turbo:load", "readystatechange"].forEach((type) => document.addEventListener(type, () => mark(type + " " + document.visibilityState + "/" + document.readyState), true));
try { new PerformanceObserver((list) => list.getEntries().forEach((e) => mark("layout-shift " + e.value.toFixed(4)))).observe({ type: "layout-shift", buffered: true }); } catch (e) { mark("layout-shift observer unavailable"); }
["keydown", "keyup", "toggle"].forEach((type) => {
  document.addEventListener(type, (e) => {
    const el = e.target;
    window.__inputLog.push(Math.round(performance.now()) + "ms " + type + (e.key ? " key=" + e.key : "") + " " + el.tagName + " '" + (el.textContent || "").trim().slice(0, 16) + "'" + (el.tagName === "DETAILS" ? " open=" + el.open : ""));
  }, true);
});
["pointerdown", "mousedown", "mouseup", "click"].forEach((type) => {
  document.addEventListener(type, (e) => {
    const el = e.target;
    window.__inputLog.push(Math.round(performance.now()) + "ms " + type + " " + el.tagName + " '" + (el.textContent || "").trim().slice(0, 16) + "' @" + Math.round(e.clientX) + "," + Math.round(e.clientY));
  }, true);
});
JS
end
