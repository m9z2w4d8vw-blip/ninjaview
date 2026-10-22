import Foundation

/// The signed-in Instagram engine, injected into instagram.com at document start so its
/// story/highlight guard is in place before the page runs. It reads posts and comments from
/// Instagram's own data (its API answers and the JSON embedded in each page) first, and from the
/// page's markup as a fallback. Tested in Chromium against saved desktop instagram.com pages (a
/// signed-in profile grid and a post with its comments, before and after opening replies).
/// It refuses every story and highlight click, request and navigation.
enum IGSessionAssets {
    static let engineJS = #"""
/* NinjaView signed-in Instagram engine: posts and comments only.
   Never opens, loads or marks seen any story or highlight: a guard installed at
   document start refuses those clicks, navigations and network requests. */
(function () {
  'use strict';
  if (window.__igl) return;

  function post(type, body) {
    try { var m = { type: type }; for (var k in (body || {})) m[k] = body[k]; window.webkit.messageHandlers.igl.postMessage(m); } catch (e) {}
  }
  var blocked = [];
  function note(what) { blocked.push(what); post('blocked', { what: what }); }

  // ---------- Guard: stories and highlights are off limits ----------
  var STORY_URL = /\/stories\/|\/highlights?\/|reels_media|reels_tray|reel\/seen|story_?viewer|highlight/i;
  // Only block operations that directly view or mark stories as seen.
  // Broad keyword matching (Highlight, ReelsMedia, Story…) was intercepting Instagram's
  // session-verification GraphQL call, causing an immediate redirect to the login page
  // every time a profile was loaded while already signed in.
  var STORY_QUERY = /\bReelsTray\b|\bSeenMutation\b/i;
  function isStoryRequest(url, body) {
    if (STORY_URL.test(String(url || ''))) return true;
    var b = typeof body === 'string' ? body : '';
    var name = (b.match(/fb_api_req_friendly_name=([^&]+)/) || [])[1] || '';
    return STORY_QUERY.test(decodeURIComponent(name));
  }
  var realFetch = window.fetch;
  if (realFetch) {
    window.fetch = function (input, init) {
      var url = typeof input === 'string' ? input : (input && input.url) || '';
      if (isStoryRequest(url, init && init.body)) { note('fetch ' + url.slice(0, 120)); return Promise.reject(new TypeError('blocked by NinjaView')); }
      var finish = track(url);
      return realFetch.apply(this, arguments).then(function (res) { finish(); capture(url, res); return res; },
                                                   function (err) { finish(); throw err; });
    };
  }
  var XO = XMLHttpRequest.prototype.open, XS = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (m, u) { this.__iglUrl = u; return XO.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function (body) {
    if (isStoryRequest(this.__iglUrl, body)) { note('xhr ' + String(this.__iglUrl).slice(0, 120)); try { this.abort(); } catch (e) {} return; }
    var xhr = this;
    xhr.addEventListener('loadend', track(this.__iglUrl));
    xhr.addEventListener('load', function () {
      try {
        var api = /graphql|\/api\/v1\//.test(String(xhr.__iglUrl || ''));
        if ((api || /json|javascript/.test(xhr.getResponseHeader('content-type') || '')) && (xhr.responseType === '' || xhr.responseType === 'text')) ingest(xhr.responseText);
      } catch (e) {}
    });
    return XS.apply(this, arguments);
  };
  ['pushState', 'replaceState'].forEach(function (k) {
    var real = history[k];
    history[k] = function (s, t, url) {
      if (url && STORY_URL.test(String(url))) { note(k + ' ' + url); return; }
      return real.apply(this, arguments);
    };
  });
  function storyTarget(el) {
    for (var n = el; n && n.nodeType === 1; n = n.parentElement) {
      var label = n.getAttribute('aria-label') || '';
      if (/highlight|story/i.test(label)) return true;
      if (n.tagName === 'A' && STORY_URL.test(n.getAttribute('href') || '')) return true;
      // The profile picture in a profile header opens stories when it has a ring.
      if (n.tagName === 'HEADER' && el.closest && (el.closest('canvas') || (el.tagName === 'IMG' && /profile picture/i.test(el.alt || '')) || el.querySelector && el.querySelector('img[alt$="profile picture"]'))) return true;
    }
    return false;
  }
  ['click', 'pointerdown', 'mousedown', 'touchstart', 'keydown'].forEach(function (type) {
    document.addEventListener(type, function (e) {
      if (e.isTrusted === false && type !== 'click') return;
      if (e.target && e.target.nodeType === 1 && storyTarget(e.target)) { e.preventDefault(); e.stopImmediatePropagation(); if (type === 'click') note('click ' + (e.target.getAttribute('aria-label') || e.target.tagName)); }
    }, true);
  });

  // ---------- Instagram's requests in flight ----------
  var pending = 0;
  function track(url) {
    if (!/graphql|\/api\/v1\//.test(String(url || ''))) return function () {};
    pending++;
    var done = false;
    return function () { if (!done) { done = true; pending = Math.max(0, pending - 1); } };
  }

  // ---------- Instagram's own data: its API answers and the JSON embedded in each page ----------
  // Posts and comments are read from here first; the page's markup is only a fallback.
  var media = {};      // post code -> what Instagram says about the post
  var comments = {};   // comment id -> comment
  var seq = 0, cseq = 0;
  function area(c) { return (c.width || 0) * (c.height || 0); }
  function best(list) {
    var top = null;
    (list || []).forEach(function (c) { if (c && c.url && (!top || area(c) > area(top))) top = c; });
    return top;
  }
  // A grid-sized copy: the smallest one at least 480 wide, else the biggest there is.
  function gridSize(list) {
    var pick = null;
    (list || []).forEach(function (c) { if (c && c.url && (c.width || 0) >= 480 && (!pick || c.width < pick.width)) pick = c; });
    return pick || best(list);
  }
  function mediaItem(n) {
    var cands = n.image_versions2 && n.image_versions2.candidates;
    var img = best(cands), vid = best(n.video_versions), small = gridSize(cands);
    return { image: img ? img.url : '', video: vid ? vid.url : '', thumb: small ? small.url : '',
             alt: typeof n.accessibility_caption === 'string' ? n.accessibility_caption : '',
             width: n.original_width || (img && img.width) || 0, height: n.original_height || (img && img.height) || 0 };
  }
  function username(u) { return u && typeof u.username === 'string' ? u.username.toLowerCase() : ''; }
  function fullName(u) { return u && typeof u.full_name === 'string' ? u.full_name : ''; }
  function addPost(o) {
    var prev = media[o.code] || {};
    var kids = o.carousel_media && o.carousel_media.length ? o.carousel_media : [o];
    var items = kids.map(mediaItem).filter(function (x) { return x.image || x.video; });
    media[o.code] = {
      order: prev.order !== undefined ? prev.order : seq++,
      taken: o.taken_at || prev.taken || 0,
      caption: o.caption && typeof o.caption.text === 'string' ? o.caption.text : (prev.caption || ''),
      likes: typeof o.like_count === 'number' ? o.like_count : (prev.likes || 0),
      comments: typeof o.comment_count === 'number' ? o.comment_count : (prev.comments || 0),
      pinned: !!(o.timeline_pinned_user_ids && o.timeline_pinned_user_ids.length) || !!prev.pinned,
      carousel: o.media_type === 8 || kids.length > 1 || !!prev.carousel,
      video: o.media_type === 2 || o.product_type === 'clips' || !!prev.video,
      reel: o.product_type === 'clips' || !!prev.reel,
      owner: username(o.user) || username(o.owner) || prev.owner || '',
      ownerName: fullName(o.user) || fullName(o.owner) || prev.ownerName || '',
      coauthors: (o.coauthor_producers || []).map(username).concat(prev.coauthors || []),
      items: items.length ? items : (prev.items || [])
    };
  }
  function isComment(o) {
    return typeof o.text === 'string' && typeof o.created_at === 'number' && !!(o.pk || o.id) &&
           !!o.user && typeof o.user.username === 'string' &&
           ('comment_like_count' in o || 'child_comment_count' in o || 'parent_comment_id' in o || o.__typename === 'XDTCommentDict');
  }
  function firstURL(o, depth) {
    if (!o || typeof o !== 'object' || depth > 6) return '';
    if (typeof o.url === 'string' && /^https?:/.test(o.url)) return o.url;
    for (var k in o) { var u = firstURL(o[k], depth + 1); if (u) return u; }
    return '';
  }
  function addComment(o, inPost) {
    var id = String(o.pk || o.id), prev = comments[id] || {};
    comments[id] = {
      id: id, parent: o.parent_comment_id ? String(o.parent_comment_id) : (prev.parent || ''),
      author: o.user.username, verified: !!o.user.is_verified, text: o.text,
      time: new Date(o.created_at * 1000).toISOString(),
      likes: typeof o.comment_like_count === 'number' ? o.comment_like_count : (prev.likes || 0),
      avatar: o.user.profile_pic_url || prev.avatar || '', image: firstURL(o.giphy_media_info, 0) || prev.image || '',
      post: inPost || prev.post || '',
      order: prev.order !== undefined ? prev.order : cseq++
    };
  }
  var IN_CAROUSEL = 1, IN_CAPTION = 2;
  function walk(o, depth, flags, inPost) {
    if (!o || typeof o !== 'object' || depth > 60) return;
    if (Array.isArray(o)) { for (var i = 0; i < o.length; i++) walk(o[i], depth + 1, flags, inPost); return; }
    // A carousel's slides carry codes of their own, but each is part of its post, never a post itself.
    if (!(flags & IN_CAROUSEL) && typeof o.code === 'string' && o.code && !o.carousel_parent_id &&
        (o.image_versions2 || o.carousel_media || o.video_versions)) {
      addPost(o);
      inPost = o.code;
    } else if (!(flags & IN_CAPTION) && isComment(o)) {
      addComment(o, inPost);
    }
    for (var k in o) {
      if (!Object.prototype.hasOwnProperty.call(o, k)) continue;
      var v = o[k];
      if (!v || typeof v !== 'object') continue;
      var f = flags;
      if (k === 'carousel_media') f |= IN_CAROUSEL;
      if (k === 'caption' || k === 'edge_media_to_caption') f |= IN_CAPTION;
      walk(v, depth + 1, f, inPost);
    }
  }
  function ingest(t) {
    if (typeof t !== 'string' || t.length < 2) return;
    t = t.replace(/^for \(;;\);/, '');
    try { walk(JSON.parse(t), 0, 0, ''); return; } catch (e) {}
    // Streamed GraphQL answers arrive as several JSON documents, one per line.
    t.split(/\r?\n/).forEach(function (line) {
      if (line.charAt(0) !== '{') return;
      try { walk(JSON.parse(line), 0, 0, ''); } catch (e) {}
    });
  }
  function capture(url, res) {
    try {
      if (!/graphql|\/api\/v1\//.test(url)) return;
      res.clone().text().then(ingest, function () {});
    } catch (e) {}
  }
  // The first batch of a grid, and a post's first comments, come inside the page rather than from a request.
  var readScripts = new WeakSet();
  function readEmbedded() {
    qa('script[type="application/json"]').forEach(function (s) {
      if (readScripts.has(s)) return;
      readScripts.add(s);
      var t = s.textContent || '';
      if (t.length > 40 && /image_versions2|carousel_media|comment_like_count|child_comment_count/.test(t)) ingest(t);
    });
  }

  // ---------- Helpers ----------
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function q(s, r) { return (r || document).querySelector(s); }
  function qa(s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); }
  function squash(s) { return String(s || '').replace(/\s+/g, ' ').trim(); }
  function text(el) { return el ? squash(el.textContent) : ''; }
  // innerText keeps <br> line breaks but costs a layout per call, so it's only used where there are some.
  function longText(el) {
    if (!el) return '';
    var raw = el.querySelector('br') ? (el.innerText || el.textContent) : el.textContent;
    return String(raw || '').replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
  }
  function visible(el) {
    if (!el || !el.isConnected) return false;
    for (var n = el; n && n.nodeType === 1; n = n.parentElement) { var cs = getComputedStyle(n); if (cs.display === 'none' || cs.visibility === 'hidden') return false; }
    return true;
  }
  function count(s) {
    var m = String(s || '').replace(/,/g, '').match(/([\d.]+)\s*([KM]?)/i);
    return m ? Math.round(parseFloat(m[1]) * ({ K: 1e3, M: 1e6 }[m[2].toUpperCase()] || 1)) : 0;
  }
  function imgURL(img) {
    if (!img) return '';
    var set = img.getAttribute('srcset') || '', top = '', w = 0;
    set.split(',').forEach(function (part) { var p = part.trim().split(/\s+/); var pw = parseInt(p[1], 10) || 0; if (p[0] && pw >= w) { w = pw; top = p[0]; } });
    var src = top || img.currentSrc || img.getAttribute('src') || '';
    return /^https?:/i.test(src) ? src : '';
  }
  // A control's name: its own aria-label, else the label of the icon inside it ("Load more comments" is an icon).
  function labelOf(el) {
    var own = el.getAttribute('aria-label') || '';
    if (own) return own;
    var icon = el.querySelector('svg[aria-label]');
    return icon ? icon.getAttribute('aria-label') || '' : '';
  }
  // Matching controls, innermost only, so a click lands on the real button rather than a wrapper around it.
  function button(re, root) {
    var hits = qa('button, [role="button"]', root || document).filter(function (b) {
      return visible(b) && (re.test(labelOf(b)) || re.test(text(b))) && !storyTarget(b);
    });
    return hits.filter(function (b) { return !hits.some(function (o) { return o !== b && b.contains(o); }); });
  }
  function codeFrom(href) { var m = String(href || '').match(/\/(p|reel|tv)\/([\w-]+)/); return m ? { kind: m[1], code: m[2] } : null; }

  // ---------- Session state and sign-in ----------
  function state() {
    var form = !!q('input[name="username"]') && !!q('input[name="password"]');
    var onLoginPath = /\/accounts\/login|\/accounts\/emailsignup/.test(location.pathname);
    var challenge = /\/challenge|\/two_factor|\/checkpoint|\/auth_platform/.test(location.pathname) ||
                    !!q('input[name="verificationCode"], input[name="security_code"], input[autocomplete="one-time-code"]');
    // Signs of being signed in, any one of which is enough: the nav icons, a link to the inbox,
    // the new-post control, a link to your own profile, or a feed with no login/sign-up links.
    var navHit = !!q('svg[aria-label="Home"], [aria-label="Home"], svg[aria-label="New post"], [aria-label="New post"], a[href*="/direct/"], a[href="/explore/"]');
    var loginLinks = !!q('a[href*="/accounts/login"], a[href*="/accounts/emailsignup"]');
    var feed = !!q('main article') || !!q('[role="feed"]');
    var loggedIn = !challenge && (navHit || (feed && !loginLinks && !form)) && !onLoginPath;
    var alert = q('#slfErrorAlert, [role="alert"]');
    return { url: location.href, loggedIn: loggedIn, loginForm: form && !loggedIn, challenge: challenge,
             error: alert && visible(alert) ? text(alert) : '' };
  }
  function typeInto(input, value) {
    var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    input.focus();
    setter.call(input, value);
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
  }
  function dismissPrompts() {
    // Cookie banners and "Save your login info?" / "Turn on notifications?" prompts.
    var hits = button(/^(Not now|Allow all cookies|Only allow essential cookies|Decline optional cookies)$/i);
    hits.forEach(function (b) { b.click(); });
    return hits.length;
  }
  async function login(username, password, timeoutMs) {
    dismissPrompts();
    var user = q('input[name="username"]'), pass = q('input[name="password"]');
    if (!user || !pass) return state();
    typeInto(user, username);
    typeInto(pass, password);
    await sleep(300);
    var submit = q('button[type="submit"]') || button(/^Log in$/i)[0];
    if (submit) submit.click();
    var deadline = Date.now() + (timeoutMs || 25000);
    while (Date.now() < deadline) {
      await sleep(500);
      dismissPrompts();
      var s = state();
      if (s.loggedIn || s.challenge || s.error) return s;
    }
    return state();
  }

  // ---------- Profile grid: scroll to the very end ----------
  function profileHandle() {
    var first = (location.pathname.split('/').filter(Boolean)[0] || '').toLowerCase();
    return /^(p|reel|reels|tv|explore|accounts|direct|stories)$/.test(first) ? '' : first;
  }
  function addTile(found, a) {
    if (a.closest('[role="dialog"]')) return;
    var c = codeFrom(a.getAttribute('href'));
    if (!c) return;
    var e = found.get(c.code) || { code: c.code, kind: c.kind, thumb: '', pinned: false, multi: false, video: false };
    var icons = qa('svg[aria-label]', a).map(function (s) { return s.getAttribute('aria-label') || ''; }).join('|');
    if (/pinned/i.test(icons)) e.pinned = true;
    if (/carousel/i.test(icons)) e.multi = true;
    if (/\b(clip|reel|video)\b/i.test(icons)) e.video = true;
    if (!e.thumb) e.thumb = imgURL(q('img', a));
    found.set(c.code, e);
  }
  // Tiles first, in the order the grid draws them (pinned posts, then newest), then any posts
  // Instagram has sent that the grid hasn't drawn yet, in the order it sent them.
  function gridCodes(found) {
    qa('main a[href]').forEach(function (a) { addTile(found, a); });
    var handle = profileHandle();
    Object.keys(media).sort(function (x, y) { return media[x].order - media[y].order; }).forEach(function (code) {
      var m = media[code];
      if (handle && m.owner && m.owner !== handle && m.coauthors.indexOf(handle) < 0) return;   // someone else's post
      if (!found.has(code)) found.set(code, { code: code, kind: m.reel ? 'reel' : 'p', thumb: '', pinned: false, multi: false, video: false });
    });
    return found;
  }
  function finishTile(e) {
    var m = media[e.code];
    var out = { code: e.code, kind: e.kind, thumb: e.thumb, pinned: e.pinned, multi: e.multi, video: e.video,
                media: [], caption: '', likes: 0, comments: 0, taken: 0 };
    if (!m) return out;
    out.pinned = out.pinned || m.pinned;
    out.multi = out.multi || m.carousel;
    out.video = !out.multi && (out.video || m.video);
    if (m.items.length) out.thumb = m.items[0].thumb || m.items[0].image || out.thumb;
    out.media = m.items.map(function (x) { return { image: x.image, video: x.video, alt: x.alt, width: x.width, height: x.height }; });
    out.caption = m.caption; out.likes = m.likes; out.comments = m.comments; out.taken = m.taken;
    return out;
  }
  function postsTotal() {
    var hit = qa('header li, header span, header a').map(text).filter(function (t) { return /^[\d.,KM]+\s+posts?$/i.test(t); })[0];
    return hit ? count(hit) : 0;
  }
  async function grid(opts) {
    opts = opts || {};
    var budget = Date.now() + (opts.maxMs || 15 * 60 * 1000), idleWanted = opts.idleRounds || 6, wait = opts.waitMs || 2500;
    readEmbedded();
    var found = gridCodes(new Map()), total = postsTotal(), idle = 0, rounds = 0;
    while (Date.now() < budget && idle < idleWanted && (!total || found.size < total)) {
      dismissPrompts();
      var before = found.size;
      var links = qa('main a[href*="/p/"], main a[href*="/reel/"]');
      if (links.length) links[links.length - 1].scrollIntoView({ block: 'end' });
      window.scrollTo(0, document.documentElement.scrollHeight);
      var until = Date.now() + wait;
      while (Date.now() < until) { await sleep(250); readEmbedded(); gridCodes(found); if (found.size > before) break; }
      if (!total) total = postsTotal();
      idle = found.size > before ? 0 : idle + 1;
      rounds++;
      if (rounds % 5 === 0) post('progress', { stage: 'grid', found: found.size, total: total });
    }
    var items = Array.from(found.values()).map(finishTile);
    // The profile's display name, which the anonymous viewer site doesn't give.
    var handle = profileHandle(), name = '';
    Object.keys(media).some(function (k) { var m = media[k]; if (m.owner === handle && m.ownerName) { name = m.ownerName; return true; } return false; });
    return { total: total, items: items, name: name, ended: !!total && items.length >= total, rounds: rounds,
             reason: total && items.length >= total ? 'all' : (idle >= idleWanted ? 'nothing more loaded' : 'time limit') };
  }

  // ---------- A post: expand everything, then read it ----------
  var postGen = 0;   // a newer post() or cancel() stops an older one at its next step
  function postRoot() {
    var d = q('[role="dialog"] article') || q('[role="dialog"]');
    if (d) return d;
    // A post opened as its own page: its article if that holds the comments, else the whole page.
    var art = qa('main article').filter(function (a) {
      return q('a[href*="/c/"] time', a) || q('svg[aria-label="Load more comments"]', a);
    })[0];
    return art || q('main') || document.body;
  }
  function commentTimes(root) { return qa('a[href*="/c/"] time', root); }
  function readComments(root) {
    var out = [], seen = {}, times = commentTimes(root), under = new Map();
    times.forEach(function (t) {
      for (var n = t.parentElement; n && n !== root; n = n.parentElement) under.set(n, (under.get(n) || 0) + 1);
    });
    times.forEach(function (t) {
      var a = t.closest('a'), m = (a.getAttribute('href') || '').match(/\/c\/(\d+)(?:\/r\/(\d+))?/);
      if (!m) return;
      var id = m[2] || m[1], parent = m[2] ? m[1] : '';
      if (seen[id]) return;
      seen[id] = true;
      var box = a;
      while (box.parentElement && box.parentElement !== root && under.get(box.parentElement) === 1) box = box.parentElement;
      var h3 = q('h3', box);
      var author = h3 ? text(q('a', h3)) || text(h3) : '';
      var body = qa('span[dir="auto"]', box).filter(function (s) { return !(h3 && h3.contains(s)) && !s.closest('span[dir="ltr"]'); })[0];
      var likeBtn = qa('button, [role="button"]', box).map(text).filter(function (s) { return /^[\d.,KM]+\s+likes?$/i.test(s); })[0];
      var avatar = q('img[alt$="profile picture"]', box);
      var sticker = qa('img', box).filter(function (i) { return !/profile picture/i.test(i.alt || ''); })[0];   // GIF comments
      out.push({ id: id, parent: parent, author: author, verified: !!(h3 && q('svg[aria-label="Verified"]', h3)),
                 text: longText(body), time: t.getAttribute('datetime') || '', likes: likeBtn ? count(likeBtn) : 0,
                 avatar: imgURL(avatar), image: imgURL(sticker) });
    });
    return out;
  }
  // Comments the API sent fill in what the page shows, and add any it hasn't drawn.
  function mergeComments(list, code) {
    var byId = {};
    list.forEach(function (c) { byId[c.id] = c; });
    Object.keys(comments).map(function (k) { return comments[k]; })
      .filter(function (c) { return !c.post || c.post === code; })
      .sort(function (a, b) { return a.order - b.order; })
      .forEach(function (c) {
        var d = byId[c.id];
        if (d) {
          if (!d.author) d.author = c.author;
          if (!d.text) d.text = c.text;
          if (!d.time) d.time = c.time;
          if (!d.avatar) d.avatar = c.avatar;
          if (!d.image) d.image = c.image;
          if (!d.parent && c.parent) d.parent = c.parent;
          d.likes = Math.max(d.likes || 0, c.likes || 0);
          d.verified = d.verified || c.verified;
        } else {
          d = { id: c.id, parent: c.parent, author: c.author, verified: c.verified, text: c.text, time: c.time, likes: c.likes, avatar: c.avatar, image: c.image };
          byId[c.id] = d;
          list.push(d);
        }
      });
    return list;
  }
  function moreControl(root) {
    var icon = qa('svg[aria-label="Load more comments"], svg[aria-label="View more comments"]', root).filter(visible)[0];
    var b = icon && icon.closest('button, [role="button"]');
    return b || button(/^(Load|View) more comments$|^View all \d+ comments$/i, root)[0] || null;
  }
  function threadControls(root) { return button(/^View (all )?(\d+ )?(more )?repl(y|ies)( \(\d+\))?$/i, root); }
  function inComments(el) {
    var li = el.closest('li');
    return !!(li && (q('time', li) || q('h3', li) || q('h1', li)));
  }
  // Fallback when Instagram's data didn't include the post: what the page shows, minus other posts' tiles.
  function pageMedia(root, code, into) {
    qa('img', root).forEach(function (img) {
      if (/profile picture|highlight/i.test(img.alt || '') || inComments(img)) return;
      var link = img.closest('a[href]'), other = link && codeFrom(link.getAttribute('href'));
      if (other && other.code !== code) return;
      var r = img.getBoundingClientRect();
      if (Math.max(r.width, img.naturalWidth || 0) < 150) return;
      var url = imgURL(img);
      if (url && !into.some(function (x) { return x.image === url; }))
        into.push({ image: url, video: '', alt: img.alt || '', width: img.naturalWidth || 0, height: img.naturalHeight || 0 });
    });
    qa('video', root).forEach(function (v) {
      var src = v.currentSrc || v.getAttribute('src') || '', poster = v.getAttribute('poster') || '';
      var playable = /^https?:/.test(src) ? src : '';   // blob: streams only work inside the page
      if (!playable && !poster) return;
      if (!into.some(function (x) { return (playable && x.video === playable) || (!playable && x.image === poster); }))
        into.push({ image: poster, video: playable, alt: '', width: v.videoWidth || 0, height: v.videoHeight || 0 });
    });
  }
  function carouselNext(root) {
    var art = root.closest ? (root.tagName === 'ARTICLE' ? root : q('article', root) || root) : root;
    return qa('button[aria-label="Next"], [role="button"][aria-label="Next"]', art).filter(function (b) { return visible(b) && b.closest('article'); })[0];
  }
  // The post's own date: the time linked to the post itself; the caption's time comes first and is later.
  function postDate(root, code) {
    var outside = qa('time', root).filter(function (t) { return !t.closest('a[href*="/c/"]'); });
    var own = outside.filter(function (t) { var a = t.closest('a[href]'); return a && code && a.getAttribute('href').indexOf('/' + code) >= 0; })[0];
    var pick = own || outside[outside.length - 1];
    return pick ? pick.getAttribute('datetime') || '' : '';
  }
  // Every comment and reply on the page plus every one the API has sent: grows whenever anything loads.
  function commentProgress(root) { return commentTimes(root).length + Object.keys(comments).length; }
  // The comment list scrolls on its own; reaching its end is what makes Instagram load the next batch.
  function commentScroller(root) {
    var t = commentTimes(root)[0];
    for (var n = t && t.parentElement; n && n !== document.documentElement; n = n.parentElement) {
      var oy = getComputedStyle(n).overflowY;
      if ((oy === 'auto' || oy === 'scroll') && n.scrollHeight > n.clientHeight + 2) return n;
    }
    return null;
  }
  function scrollComments(root) {
    var s = commentScroller(root);
    if (s) { s.scrollTop = s.scrollHeight; s.dispatchEvent(new Event('scroll')); }
    else { window.scrollTo(0, document.documentElement.scrollHeight); window.dispatchEvent(new Event('scroll')); }
    var times = commentTimes(root), last = times[times.length - 1];
    if (last) { try { last.scrollIntoView({ block: 'end' }); } catch (e) {} }
  }
  // Waits for something new: at least `wait`, and longer (up to 4x) while a request is still out.
  async function settle(root, before, wait, gen) {
    var start = Date.now(), hard = start + wait * 4;
    await sleep(150);
    while (gen === postGen) {
      if (commentProgress(root) !== before) { await sleep(350); return true; }   // the rest of the batch renders
      var now = Date.now();
      if (now >= hard || (now >= start + wait && pending === 0)) return false;
      await sleep(150);
    }
    return false;
  }
  // Opens every reply thread and presses "Load more comments" (+) until nothing is left, scrolling the
  // list to its end in between. `exhausted` is true only when no control is left and two scrolls in a row
  // brought nothing; stopping for time, the limit, a newer post() or a control that keeps failing leaves it false.
  async function expand(root, opts, gen) {
    var limit = opts.maxComments || 3000, deadline = Date.now() + (opts.maxMs || 5 * 60 * 1000), wait = opts.waitMs || 2000;
    var rounds = 0, idle = 0, tries = new WeakMap(), exhausted = false;
    function fresh(b) { return !!b && (tries.get(b) || 0) < 3; }   // a control that did nothing 3 times is skipped
    while (gen === postGen && Date.now() < deadline && rounds < (opts.maxRounds || 600)) {
      dismissPrompts();
      if (commentTimes(root).length >= limit) break;
      var threads = threadControls(root), more = moreControl(root);
      var target = threads.filter(fresh)[0] || [more].filter(fresh)[0];
      var before = commentProgress(root);
      if (target) {
        try { target.scrollIntoView({ block: 'center' }); } catch (e) {}
        target.click();
        if (!(await settle(root, before, wait, gen))) tries.set(target, (tries.get(target) || 0) + 1);
        idle = 0;
      } else {
        if (threads.length || more) break;   // only controls that keep failing are left: not finished
        scrollComments(root);
        if (await settle(root, before, wait, gen)) idle = 0;
        else if (++idle >= 2) { exhausted = true; break; }
      }
      rounds++;
      if (rounds % 10 === 0) post('progress', { stage: 'comments', found: commentTimes(root).length });
    }
    return { rounds: rounds, exhausted: exhausted };
  }
  function currentCode(root) {
    var here = codeFrom(location.pathname) || codeFrom((q('a[href*="/p/"] time', root) || {}).parentElement && q('a[href*="/p/"] time', root).parentElement.getAttribute('href'));
    return here ? here.code : '';
  }
  async function readPost(opts) {
    opts = opts || {};
    var gen = ++postGen;
    readEmbedded();
    var root = postRoot();
    var code = currentCode(root);
    var ex = opts.comments === false ? { rounds: 0, exhausted: false } : await expand(root, opts, gen);
    readEmbedded();
    var net = media[code], found = [];
    if (!(net && net.items.length)) {
      pageMedia(root, code, found);
      for (var i = 0; i < 25 && gen === postGen; i++) {
        var next = carouselNext(root);
        if (!next) break;
        next.click();
        await sleep(opts.slideMs || 600);
        pageMedia(root, code, found);
      }
    }
    var captionRow = q('h1', root);
    var likesText = qa('a, span', root).filter(function (el) { return !el.closest('button') && !el.closest('li') && /^[\d.,KM]+\s+likes?$/i.test(text(el)); }).map(text)[0] || '';
    var authorLink = qa('header a[href]', root).filter(function (a) { return /^\/?[\w.]+\/?$/.test((a.getAttribute('href') || '').replace(/^https:\/\/www\.instagram\.com/, '')) && text(a); })[0];
    var useNet = !!(net && net.items.length);
    var list = opts.comments === false ? [] : mergeComments(readComments(root), code);
    // Instagram's own count for the post (the number its grid shows on hover), to check against.
    var expected = (net && net.comments) || opts.expected || 0;
    return {
      code: code, author: authorLink ? text(authorLink) : (net ? net.owner : ''),
      caption: longText(captionRow) || (net ? net.caption : ''),
      date: (net && net.taken ? new Date(net.taken * 1000).toISOString() : '') || postDate(root, code),
      likes: likesText ? count(likesText) : (net ? net.likes : 0),
      media: useNet ? net.items.map(function (x) { return { image: x.image, video: x.video, alt: x.alt, width: x.width, height: x.height }; }) : found,
      mediaFrom: useNet ? 'network' : 'page',
      comments: list, expandRounds: ex.rounds,
      expected: expected, exhausted: ex.exhausted,
      complete: opts.comments !== false && ex.exhausted && (!expected || list.length >= expected)
    };
  }
  // The comments loaded so far, while post() is still opening more.
  function snapshot() {
    var root = postRoot(), code = currentCode(root), net = media[code];
    var list = mergeComments(readComments(root), code);
    return { comments: list, expected: (net && net.comments) || 0, found: list.length };
  }
  function probe() {
    var r = postRoot();
    return { more: !!moreControl(r), threads: threadControls(r).length, comments: commentTimes(r).length,
             posts: Object.keys(media).length, apiComments: Object.keys(comments).length };
  }

  window.__igl = { state: state, login: login, dismissPrompts: dismissPrompts, grid: grid, post: readPost, probe: probe, snapshot: snapshot,
                   cancel: function () { postGen++; return 'ok'; },
                   ingest: function (o) { walk(o, 0, 0, ''); return Object.keys(media).length; },
                   blocked: function () { return blocked.slice(); }, media: function () { return media; } };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', function () { post('ready', { url: location.href }); });
  else post('ready', { url: location.href });
})();
"""#
}
