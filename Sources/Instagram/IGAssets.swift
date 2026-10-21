import Foundation

/// The Instagram engine injected into insta-stories-viewer.com pages. Byte-identical to the
/// tested igengine.js (see the README); it only reads the rendered page and returns JSON.
enum IGAssets {
    static let engineJS = #"""
/* NinjaView Instagram engine for insta-stories-viewer.com profile pages.
   Reads the rendered page only; every call resolves to plain JSON. */
(function () {
  'use strict';
  if (window.__ig) return;

  function post(type, body) {
    try { var m = { type: type }; for (var k in (body || {})) m[k] = body[k]; window.webkit.messageHandlers.nv.postMessage(m); } catch (e) { /* outside the app */ }
  }
  function log(message) { post('log', { message: 'ig: ' + message }); }
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function q(sel, root) { return (root || document).querySelector(sel); }
  function qa(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }
  function visible(el) {
    if (!el || !el.isConnected) return false;
    for (var n = el; n && n.nodeType === 1; n = n.parentElement) {
      var cs = getComputedStyle(n);
      if (cs.display === 'none' || cs.visibility === 'hidden') return false;
    }
    return true;
  }
  function squash(s) { return String(s || '').replace(/\s+/g, ' ').trim(); }
  function text(el) { return el ? squash(el.textContent) : ''; }
  function ownText(el) {
    if (!el) return '';
    var s = '';
    for (var i = 0; i < el.childNodes.length; i++) if (el.childNodes[i].nodeType === 3) s += el.childNodes[i].nodeValue;
    return squash(s);
  }
  function abs(u) { try { return u ? new URL(u, location.href).href : ''; } catch (e) { return ''; } }
  function imgURL(img) {
    if (!img) return '';
    var src = img.currentSrc || img.getAttribute('src') || '';
    if (src && !/^data:/i.test(src)) return abs(src);
    return abs(img.getAttribute('data-src') || '');
  }
  function int(s) {
    var t = String(s || '').replace(/[\s,]/g, '').toUpperCase();
    var m = t.match(/^([\d.]+)([KMB]?)$/);
    if (!m) return 0;
    var n = parseFloat(m[1]);
    return Math.round(n * ({ K: 1e3, M: 1e6, B: 1e9 }[m[2]] || 1));
  }

  // ---------- page-level states ----------
  function captchaShown() {
    var c = document.getElementById('captcha');
    if (c && visible(c) && (c.children.length > 0 || text(c))) return true;
    var g = q('.popup__game-spider');
    if (g && visible(g) && g.classList.contains('popup__show')) return true;
    return !!q('iframe[src*="captcha"], iframe[src*="challenges.cloudflare.com"], iframe[src*="turnstile"]');
  }
  function stateOf(kind) {
    // Each tab has hidden boxes (inline display:none) that the site shows when there's nothing to list.
    var checks = [['private', '-is-private', 'This account is private.'],
                  ['notFound', '-not-found', 'This account wasn\u2019t found.'],
                  ['retry', '-service-retry', 'The site couldn\u2019t load this right now.'],
                  ['empty', '-no-content', kind === 'stories' ? 'No stories right now.' : 'No posts yet.']];
    for (var i = 0; i < checks.length; i++) {
      var el = q('.profile__' + kind + checks[i][1]);
      if (el && visible(el)) return { status: checks[i][0], message: text(el) || checks[i][2] };
    }
    return null;
  }

  // ---------- profile header ----------
  function readProfile() {
    var nick = q('h1.profile__nickname');
    var tabs = q('.profile__tabs[data-username]');
    var handle = ownText(nick) || (tabs ? tabs.getAttribute('data-username') : '') || '';
    handle = handle.replace(/^@/, '');
    var stats = qa('.profile__stats-item').map(function (li) {
      return { label: ownText(li), value: text(q('.profile__stats-item-value', li)) };
    }).filter(function (s) { return s.label && s.value; });
    var desc = q('.profile__description');
    var bio = desc ? String(desc.innerText || desc.textContent || '').replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim() : '';
    var counter = q('.profile__stories-counter');
    var avatarBox = q('.profile__avatar');
    var storiesCount = counter && visible(counter) ? int(text(counter)) : 0;
    return {
      handle: handle, bio: bio, avatar: imgURL(q('img.profile__avatar-pic')),
      verified: visible(q('.profile__nickname-is-verify')), stats: stats,
      storiesCount: storiesCount, storiesRing: !!(avatarBox && avatarBox.classList.contains('profile__avatar-active'))
    };
  }
  function postsTotal() {
    var v = q('.profile__stats-posts');
    return v ? int(text(v)) : 0;
  }

  async function profile(timeoutMs) {
    var deadline = Date.now() + (timeoutMs || 20000);
    for (;;) {
      if (captchaShown()) return finishProfile(readProfile(), 'captcha', 'The site wants to check that you are a person.');
      var p = readProfile();
      var nf = stateOf('stories');
      if (nf && nf.status === 'notFound') return finishProfile(p, 'notFound', nf.message);
      if (p.handle && q('.profile__stats')) {
        if (nf && nf.status === 'private') return finishProfile(p, 'private', nf.message);
        return finishProfile(p, 'ok', '');
      }
      if (Date.now() > deadline) {
        var title = squash(document.title).toLowerCase();
        var missing = /not found|404|doesn.t exist|no such/.test(title + ' ' + text(q('h1')).toLowerCase());
        return finishProfile(p, missing ? 'notFound' : 'timeout', missing ? 'This account wasn\u2019t found.' : 'The page didn\u2019t finish loading.');
      }
      await sleep(250);
    }
  }
  function finishProfile(p, status, message) {
    return { handle: p.handle, bio: p.bio, avatar: p.avatar, verified: p.verified, stats: p.stats,
             storiesCount: p.storiesCount, status: status, message: message };
  }

  // ---------- tabs ----------
  function tabRoot(kind) { return q('.profile__tabs-content-item.profile__tabs-' + kind); }
  function keyOf(id, filename, url) {
    if (/^\d{6,}$/.test(id)) return id;                         // story ids are Instagram media ids
    var stem = String(filename || '').replace(/\.[a-z0-9]{2,5}$/i, '');
    if (stem) return stem;                                       // post ids change per load; filenames don't
    return id || String(url || '').slice(-80);
  }
  function readItems(kind) {
    var root = tabRoot(kind);
    if (!root) return [];
    var seen = {};
    return qa('li.profile__tabs-media-item', root).map(function (li, i) {
      var link = q('[data-content]', li) || q('.show-modal', li);
      var get = function (a) { return link ? (link.getAttribute(a) || '') : ''; };
      var id = get('data-id'), filename = get('data-filename'), url = abs(get('data-content'));
      var media = get('data-media-type').toLowerCase();
      if (!media) media = q('use[href="#ico-play"]', li) || q('use[*|href="#ico-play"]', li) ? 'video' : 'image';
      return { key: keyOf(id, filename, url), kind: kind === 'stories' ? 'story' : 'post', index: i,
               media: media === 'video' ? 'video' : 'image', url: url, thumb: imgURL(q('img', li)),
               filename: filename, id: id };
    }).filter(function (x) {
      if (!x.url || seen[x.key]) return false;
      seen[x.key] = true;
      return true;
    }).map(function (x, i) { x.index = i; return x; });
  }
  function snapshot(kind, status, message) {
    var items = readItems(kind);
    return { kind: kind, status: status, items: items, message: message || '',
             total: kind === 'posts' ? postsTotal() : items.length };
  }

  function tabItem(kind) { return q('.profile__tabs-item[data-content-type="' + kind + '"]'); }
  function isActive(kind) {
    var li = tabItem(kind);
    return !!(li && li.classList.contains('profile__tabs-item-active'));
  }
  function activate(kind) {
    var li = tabItem(kind);
    if (!li) return false;
    if (isActive(kind)) return true;
    // The tab is a link back to this same page; let the site's own handler run but never navigate.
    var block = function (e) { if (e.target && e.target.closest && e.target.closest('.profile__tabs-item')) e.preventDefault(); };
    document.addEventListener('click', block, true);
    try { (q('a', li) || li).click(); } finally { document.removeEventListener('click', block, true); }
    return true;
  }

  async function tab(kind, timeoutMs) {
    if (kind !== 'stories' && kind !== 'posts') return snapshot(kind, 'missing', 'Unknown tab');
    var deadline = Date.now() + (timeoutMs || 20000);
    if (!tabItem(kind)) return snapshot(kind, 'missing', 'This page has no ' + kind + ' tab.');
    activate(kind);
    var clicked = Date.now(), retried = false;
    for (;;) {
      if (captchaShown()) return snapshot(kind, 'captcha', 'The site wants to check that you are a person.');
      var items = readItems(kind);
      var st = stateOf(kind);
      if (items.length) {
        if (kind === 'stories') {
          // Wait briefly for the rest when the header says how many there are.
          var want = readProfile().storiesCount;
          if (!want || items.length >= want || Date.now() - clicked > 2500) return snapshot(kind, 'ok', '');
        } else {
          return snapshot(kind, 'ok', '');
        }
      } else if (st) {
        return snapshot(kind, st.status, st.message);
      }
      if (!isActive(kind) && !retried && Date.now() - clicked > 1500) { retried = true; activate(kind); }
      if (Date.now() > deadline) {
        if (kind === 'stories') {
          var p = readProfile();
          if (p.handle && !p.storiesCount && !p.storiesRing) return snapshot(kind, 'empty', 'No stories right now.');
        }
        return snapshot(kind, 'timeout', 'The ' + kind + ' didn\u2019t finish loading.');
      }
      await sleep(250);
    }
  }

  // Posts beyond the first batch: scroll to the end of the list and look for a load-more control.
  async function more(kind, rounds) {
    var root = tabRoot(kind);
    if (!root) return snapshot(kind, 'missing', '');
    var before = readItems(kind).length, quiet = 0;
    for (var r = 0; r < (rounds || 4) && quiet < 2; r++) {
      var button = qa('button, a, span, div', root).filter(function (el) {
        return visible(el) && /^(load|show) more|^more$/i.test(text(el)) && text(el).length < 30;
      })[0];
      if (button) button.click();
      var last = qa('li.profile__tabs-media-item', root).pop();
      if (last && last.scrollIntoView) last.scrollIntoView({ block: 'end' });
      window.scrollTo(0, document.documentElement.scrollHeight);
      var until = Date.now() + 2200;
      while (Date.now() < until && readItems(kind).length === before) await sleep(200);
      var now = readItems(kind).length;
      if (now > before) { before = now; quiet = 0; } else { quiet++; }
    }
    return snapshot(kind, 'ok', '');
  }

  function state() {
    var p = readProfile();
    return { captcha: captchaShown(), handle: p.handle, stories: readItems('stories').length, posts: readItems('posts').length };
  }

  window.__ig = { profile: profile, tab: tab, more: more, state: state };
  post('ready', { url: location.href });
})();
"""#
}
