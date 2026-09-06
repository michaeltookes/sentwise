import Foundation

/// Builds the small HTML page that hosts the Paddle.js overlay checkout inside a
/// WKWebView (backlog item 56c). The page loads Paddle.js from Paddle's CDN,
/// initializes it with the client-side token in the configured environment, and
/// bridges Paddle's `eventCallback` events back to Swift over the
/// `window.webkit.messageHandlers.sentwise` message handler.
///
/// The page exposes `window.sentwiseOpenCheckout(argsObject)`, which Swift calls
/// (via `evaluateJavaScript`) with the `PaddleCheckoutRequest` argument once the
/// view is ready — this keeps user-supplied values (email) out of the HTML source
/// and off any injection surface. The harness also emits two non-Paddle signals:
/// `paddle.ready` (script loaded + initialized) and `paddle.failed` (load or init
/// error), so the Swift model can distinguish a wiring failure from a user close.
enum PaddleCheckoutHTML {

    /// The full HTML document string for `config`. Load it into a WKWebView with
    /// `config.checkoutOrigin` as the base URL so Paddle's approved-domain check
    /// sees a stable origin.
    static func page(config: PaddleConfig) -> String {
        // Paddle.Environment.set is only needed (and only valid) for sandbox;
        // production is Paddle.js's default, so we omit the call there.
        let environmentSetup = config.environment == .sandbox
            ? #"Paddle.Environment.set("sandbox");"#
            : ""
        return template
            .replacingOccurrences(of: "__ENV_SETUP__", with: environmentSetup)
            .replacingOccurrences(of: "__TOKEN__", with: escapeForJSString(config.clientSideToken))
    }

    /// Minimal escaping for embedding a value inside a double-quoted JS string
    /// literal. Applied to the (constant, non-user) client-side token defensively.
    private static func escapeForJSString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    /// The page template. `__ENV_SETUP__` and `__TOKEN__` are substituted per
    /// config. A stored constant (not a function body) so the harness stays
    /// readable in one place.
    private static let template = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        html, body {
          margin: 0; height: 100%;
          font: -apple-system-short-body, sans-serif;
          background: transparent; color: #6b7280;
        }
        .status {
          display: flex; align-items: center; justify-content: center;
          height: 100%; padding: 24px; text-align: center;
        }
      </style>
    </head>
    <body>
      <div class="status" id="status">Loading secure checkout…</div>
      <script>
        var __paddleReady = false;
        var __pendingArgs = null;

        function post(name, detail) {
          try {
            window.webkit.messageHandlers.sentwise.postMessage({
              name: name, detail: detail == null ? "" : String(detail)
            });
          } catch (e) { /* bridge unavailable outside the app */ }
        }

        function setStatus(text) {
          var el = document.getElementById("status");
          if (el) { el.textContent = text; }
        }

        // Swift calls this with the Paddle.Checkout.open argument object.
        window.sentwiseOpenCheckout = function (args) {
          __pendingArgs = args;
          tryOpen();
        };

        function tryOpen() {
          if (!__paddleReady || !__pendingArgs) { return; }
          try {
            Paddle.Checkout.open(__pendingArgs);
            __pendingArgs = null;
            setStatus("Complete your purchase in the checkout window.");
          } catch (e) {
            post("paddle.failed", e && e.message ? e.message : e);
          }
        }

        function initPaddle() {
          if (typeof Paddle === "undefined") {
            post("paddle.failed", "Paddle.js failed to load.");
            setStatus("Couldn't load checkout. Please try again.");
            return;
          }
          try {
            __ENV_SETUP__
            Paddle.Initialize({
              token: "__TOKEN__",
              eventCallback: function (data) {
                var name = (data && data.name) ? data.name : "";
                if (name === "checkout.completed") { post("checkout.completed"); }
                else if (name === "checkout.closed") { post("checkout.closed"); }
                else if (name === "checkout.error") {
                  var detail = (data && data.error && (data.error.detail || data.error.message)) || "";
                  post("checkout.error", detail);
                }
              }
            });
            __paddleReady = true;
            post("paddle.ready");
            tryOpen();
          } catch (e) {
            post("paddle.failed", e && e.message ? e.message : e);
            setStatus("Couldn't start checkout. Please try again.");
          }
        }
      </script>
      <script
        src="https://cdn.paddle.com/paddle/v2/paddle.js"
        onload="initPaddle()"
        onerror="post('paddle.failed', 'Could not load Paddle.js. Check your connection.')"></script>
    </body>
    </html>
    """
}
