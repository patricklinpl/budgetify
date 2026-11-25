require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  DESKTOP_WINDOW = [ 1400, 1400 ].freeze
  driven_by :selenium, using: :headless_chrome, screen_size: DESKTOP_WINDOW

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

  # Observation only, for the intermittent driver error "Node with given id
  # does not belong to the document" (seen in several different system tests).
  # The original error is untouched and still fails the test. When a test
  # ended with that error, print to stderr what the stripped backtrace hides
  # (the test-file frames of the raw backtrace) and a small bounded snapshot of
  # the page at that moment. Synthetic test data only; no retry, no rescue.
  NODE_LOST_MESSAGE = "Node with given id does not belong to the document".freeze

  def before_teardown
    report_lost_node
  ensure
    super
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
      warn "NODE_LOST_DIAGNOSTIC raw-frames-total=#{frames.size} first-frames:\n#{frames.first(8).join("\n")}"
      warn "NODE_LOST_DIAGNOSTIC doc-state=#{doc_state}"
      warn "NODE_LOST_DIAGNOSTIC page=#{snapshot}"
    end
  rescue => e
    warn "NODE_LOST_DIAGNOSTIC unavailable: #{e.class}"
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
          active: document.activeElement ? document.activeElement.tagName + "#" + document.activeElement.id : "none",
          fields: [...document.querySelectorAll("input.field__input")].map((i) => i.id + "=" + JSON.stringify(i.value) + " invalid=" + i.getAttribute("aria-invalid")),
          buttons: [...document.querySelectorAll("form button")].map((b) => b.textContent.trim() + ":" + (b.disabled ? "disabled" : "enabled")),
          visibility: document.visibilityState,
          readyState: document.readyState,
          scrollY: Math.round(scrollY),
          openDialogs: document.querySelectorAll("dialog[open]").length,
          details: [...document.querySelectorAll("details")].map((d) => (d.className || "details") + " open=" + d.open),
          controls,
          stimulus: (() => {
            const app = window.Stimulus;
            if (!app) return "window.Stimulus missing";
            const registered = app.router.modules.map((m) => m.definition.identifier).sort();
            const pending = [...document.querySelectorAll("[data-controller]")].flatMap((el) => el.dataset.controller.split(/\s+/).filter(Boolean).filter((id) => !app.getControllerForElementAndIdentifier(el, id)));
            return { registered: registered.length, notConnected: [...new Set(pending)], turbo: typeof window.Turbo };
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

  INPUT_LOG_JS = <<JS
window.__inputLog = [];
window.__docId = window.__docId || Math.random().toString(36).slice(2, 8);
window.__inputInstalledAt = Math.round(performance.now());
window.__lifecycle = [];
const mark = (what) => { if (window.__lifecycle.length < 200) window.__lifecycle.push(Math.round(performance.now()) + "ms " + what); };
["pagehide", "pageshow", "beforeunload", "scroll", "resize", "focus", "blur"].forEach((type) => window.addEventListener(type, () => mark(type + " scrollY=" + Math.round(scrollY) + " inner=" + innerWidth + "x" + innerHeight), true));
["visibilitychange", "turbo:before-visit", "turbo:before-render", "turbo:render", "turbo:load", "readystatechange"].forEach((type) => document.addEventListener(type, () => mark(type + " " + document.visibilityState + "/" + document.readyState), true));
try { new PerformanceObserver((list) => list.getEntries().forEach((e) => mark("layout-shift " + e.value.toFixed(4)))).observe({ type: "layout-shift", buffered: true }); } catch (e) { mark("layout-shift observer unavailable"); }
["keydown", "keyup", "beforeinput", "input", "toggle"].forEach((type) => {
  document.addEventListener(type, (e) => {
    const el = e.target;
    window.__inputLog.push(Math.round(performance.now()) + "ms " + type + (e.key ? " key=" + e.key : "") + " " + el.tagName + " '" + (el.textContent || "").trim().slice(0, 16) + "'" + (el.tagName === "DETAILS" ? " open=" + el.open : ""));
  }, true);
});
const log = (what) => window.__inputLog.push(Math.round(performance.now()) + "ms " + what);
if (!window.__fetchWrapped) {
  window.__fetchWrapped = true;
  const originalFetch = window.fetch;
  window.fetch = function (input, init) { log("fetch " + ((init && init.method) || "GET") + " " + (typeof input === "string" ? input : (input && input.url))); return originalFetch.apply(this, arguments); };
  const originalOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) { log("xhr " + method + " " + url); return originalOpen.apply(this, arguments); };
}
["turbo:click", "turbo:before-fetch-request", "turbo:before-fetch-response", "turbo:visit", "turbo:submit-start", "turbo:submit-end", "turbo:frame-load"].forEach((type) => {
  document.addEventListener(type, (e) => log(type + " " + ((e.detail && (e.detail.url || (e.detail.fetchOptions && e.detail.fetchOptions.method))) || "")), true);
});
document.addEventListener("click", (e) => { const a = e.target.closest && e.target.closest("a"); if (a) setTimeout(() => log("after click link href=" + a.getAttribute("href") + " defaultPrevented=" + e.defaultPrevented), 0); }, false);
window.addEventListener("beforeunload", () => log("beforeunload"), true);
if (window.navigation) window.navigation.addEventListener("navigate", (e) => log("navigate " + e.navigationType + " " + e.destination.url + " userInitiated=" + e.userInitiated), true);
["pointerdown", "mousedown", "mouseup", "click"].forEach((type) => {
  document.addEventListener(type, (e) => {
    const el = e.target;
    window.__inputLog.push(Math.round(performance.now()) + "ms " + type + " " + el.tagName + " '" + (el.textContent || "").trim().slice(0, 16) + "' @" + Math.round(e.clientX) + "," + Math.round(e.clientY));
  }, true);
});
JS
end
