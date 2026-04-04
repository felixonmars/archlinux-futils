// ==UserScript==
// @name         Bumpbuddy: Last Updated from archlinux.org
// @namespace    https://github.com/felixonmars/archlinux-futils
// @version      1.4.0
// @description  Appends last_update time (from archlinux.org) after the local version on bumpbuddy.archlinux.org
// @author       Felix Yan <felixonmars@archlinux.org>
// @homepageURL  https://github.com/felixonmars/archlinux-futils
// @supportURL   https://github.com/felixonmars/archlinux-futils/issues
// @downloadURL  https://raw.githubusercontent.com/felixonmars/archlinux-futils/master/bumpbuddy-last-updated.user.js
// @updateURL    https://raw.githubusercontent.com/felixonmars/archlinux-futils/master/bumpbuddy-last-updated.user.js
// @match        https://bumpbuddy.archlinux.org/*
// @grant        GM_xmlhttpRequest
// @connect      archlinux.org
// ==/UserScript==

(function () {
  'use strict';

  const SEARCH_BASE = 'https://archlinux.org/packages/search/json/';

  // Cache: pkgbase -> ISO date string | null
  const cache = new Map();

  // Pending fetches: pkgbase -> Promise<string|null>
  const pending = new Map();

  // Concurrency queue
  const MAX_CONCURRENT = 5;
  let activeFetches = 0;
  const queue = [];

  function runQueue() {
    while (activeFetches < MAX_CONCURRENT && queue.length > 0) {
      queue.shift()();
    }
  }

  function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  /**
   * Fetch a URL via GM and return the response text (or null on error).
   * Retries automatically on HTTP 429, honouring the Retry-After header.
   */
  function httpGet(url, retries = 4) {
    return new Promise((resolve) => {
      queue.push(() => {
        activeFetches++;
        GM_xmlhttpRequest({
          method: 'GET',
          url,
          timeout: 10000,
          onload(r) {
            activeFetches--;
            runQueue();
            if (r.status === 429 && retries > 0) {
              // Honour Retry-After header (seconds); default to 10s
              const match = r.responseHeaders && r.responseHeaders.match(/retry-after:\s*(\d+)/i);
              const delay = match ? parseInt(match[1], 10) * 1000 : 10000;
              sleep(delay).then(() => httpGet(url, retries - 1).then(resolve));
            } else {
              resolve(r.status >= 400 ? null : r.responseText);
            }
          },
          onerror()   { activeFetches--; runQueue(); resolve(null); },
          ontimeout() { activeFetches--; runQueue(); resolve(null); },
        });
      });
      runQueue();
    });
  }

  /**
   * Parse a packages/search/json response and return the most-recent
   * last_update among results whose pkgbase matches the given pkgbase.
   * Returns null if no match is found.
   */
  function parseLastUpdate(responseText, pkgbase) {
    if (!responseText) return null;
    try {
      const data = JSON.parse(responseText);
      const matches = (data.results || []).filter(r => r.pkgbase === pkgbase);
      if (matches.length === 0) return null;
      matches.sort((a, b) => new Date(b.last_update) - new Date(a.last_update));
      return matches[0].last_update;
    } catch (e) {
      return null;
    }
  }

  /**
   * Fetch the last_update for a pkgbase using a multi-step fallback:
   *
   *  1. ?name=PKGBASE   — works when pkgbase == pkgname (single packages)
   *  2. ?q=PKGBASE      — catches split packages where pkgbase appears in pkgnames
   *  3. ?q=<PKGBASE minus last hyphen-segment>
   *                     — catches split packages whose pkgnames share a common prefix
   *                       e.g. adobe-source-han-sans-fonts → q=adobe-source-han-sans
   *
   * All steps filter results by pkgbase to avoid false positives.
   */
  async function doFetch(pkgbase) {
    const enc = encodeURIComponent(pkgbase);

    // Step 1: exact pkgname match
    let val = parseLastUpdate(
      await httpGet(`${SEARCH_BASE}?name=${enc}`),
      pkgbase,
    );
    if (val) return val;

    // Step 2: full-text search with the complete pkgbase string
    val = parseLastUpdate(
      await httpGet(`${SEARCH_BASE}?q=${enc}`),
      pkgbase,
    );
    if (val) return val;

    // Step 3: remove last hyphen-segment and try again
    const parts = pkgbase.split('-');
    if (parts.length > 1) {
      parts.pop();
      const shorter = encodeURIComponent(parts.join('-'));
      val = parseLastUpdate(
        await httpGet(`${SEARCH_BASE}?q=${shorter}`),
        pkgbase,
      );
      if (val) return val;
    }

    return null;
  }

  function fetchLastUpdate(pkgbase) {
    if (cache.has(pkgbase)) return Promise.resolve(cache.get(pkgbase));
    if (pending.has(pkgbase)) return pending.get(pkgbase);

    const promise = doFetch(pkgbase).then((val) => {
      cache.set(pkgbase, val);
      pending.delete(pkgbase);
      return val;
    });
    pending.set(pkgbase, promise);
    return promise;
  }

  // ── Formatting ──────────────────────────────────────────────────────────────

  function formatRelative(isoString) {
    const diffMs = Date.now() - new Date(isoString).getTime();
    const d = Math.floor(diffMs / 86400000);
    if (d === 0) {
      const h = Math.floor(diffMs / 3600000);
      if (h === 0) { const m = Math.floor(diffMs / 60000); return m <= 1 ? 'just now' : `${m}m ago`; }
      return `${h}h ago`;
    }
    if (d < 30)  return `${d}d ago`;
    if (d < 365) return `${Math.floor(d / 30)}mo ago`;
    return `${Math.floor(d / 365)}y ago`;
  }

  // ── DOM manipulation ─────────────────────────────────────────────────────────

  let processing = false;

  function processVisibleRows(table) {
    if (processing) return;
    processing = true;

    const tbody = table.querySelector('tbody');
    if (!tbody) { processing = false; return; }

    tbody.querySelectorAll('tr').forEach((row) => {
      const cells = row.querySelectorAll('td');
      if (cells.length < 2) return;

      const pkgbase = cells[0].textContent.trim();
      if (!pkgbase) return;

      const versionCell = cells[1]; // "Local version" column
      if (versionCell.querySelector('.bb-last-updated')) return; // already injected

      const span = document.createElement('span');
      span.className = 'bb-last-updated';
      span.style.cssText = 'margin-left:0.4em; font-size:0.85em; color:#888;';
      span.textContent = '(…)';
      versionCell.appendChild(span);

      if (cache.has(pkgbase)) {
        renderSpan(span, cache.get(pkgbase));
      } else {
        fetchLastUpdate(pkgbase).then((val) => renderSpan(span, val));
      }
    });

    processing = false;
  }

  function renderSpan(span, val) {
    if (!val) {
      span.textContent = '';
    } else {
      span.textContent = `(${formatRelative(val)})`;
      span.title = new Date(val).toISOString();
    }
  }

  // ── Initialisation ───────────────────────────────────────────────────────────

  function debounce(fn, ms) {
    let t;
    return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
  }

  function setup(table) {
    processVisibleRows(table);

    const tbody = table.querySelector('tbody');
    if (!tbody) return;

    const debouncedProcess = debounce(() => processVisibleRows(table), 150);

    // Only react when DataTables replaces rows (adds TR nodes directly under tbody).
    // Our own SPAN appends are inside TD nodes — they won't trigger this.
    new MutationObserver((mutations) => {
      const isRedraw = mutations.some((m) =>
        Array.from(m.addedNodes).some((n) => n.nodeName === 'TR')
      );
      if (isRedraw) debouncedProcess();
    }).observe(tbody, { childList: true, subtree: false });
  }

  function waitForTable() {
    const interval = setInterval(() => {
      const table = document.querySelector('table.dataTable');
      if (!table) return;
      const firstTd = table.querySelector('tbody tr td');
      if (!firstTd || !firstTd.textContent.trim()) return;
      clearInterval(interval);
      setup(table);
    }, 300);
  }

  waitForTable();
})();
