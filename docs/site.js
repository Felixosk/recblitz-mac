// Theme toggle (System -> Light -> Dark) and the light/dark demo switch.
(function () {
  var root = document.documentElement;
  var KEY = 'rb-theme';
  function get() { try { return localStorage.getItem(KEY); } catch (e) { return null; } }
  function set(v) { try { v ? localStorage.setItem(KEY, v) : localStorage.removeItem(KEY); } catch (e) {} }
  function apply(v) { if (v) root.setAttribute('data-theme', v); else root.removeAttribute('data-theme'); }
  apply(get());
  document.addEventListener('DOMContentLoaded', function () {
    var btn = document.querySelector('.theme-btn');
    if (btn) {
      var label = function () {
        var v = get();
        btn.setAttribute('aria-label', 'Theme: ' + (v || 'system'));
        btn.title = 'Theme: ' + (v ? v.charAt(0).toUpperCase() + v.slice(1) : 'System');
      };
      label();
      btn.addEventListener('click', function () {
        var v = get();
        var next = v === null ? 'light' : v === 'light' ? 'dark' : null;
        set(next); apply(next); label();
      });
    }
    var seg = document.querySelectorAll('[data-demo]');
    seg.forEach(function (b) {
      b.addEventListener('click', function () {
        var mode = b.getAttribute('data-demo');
        seg.forEach(function (o) { o.setAttribute('aria-pressed', o === b ? 'true' : 'false'); });
        document.querySelectorAll('[data-demo-img]').forEach(function (img) {
          img.hidden = img.getAttribute('data-demo-img') !== mode;
        });
      });
    });
  });
})();
