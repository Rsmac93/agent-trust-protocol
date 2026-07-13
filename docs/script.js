(function () {
  'use strict';

  var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // ---------- scroll reveal ----------
  var revealEls = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window && !reduceMotion) {
    var io = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            entry.target.classList.add('visible');
            io.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.12, rootMargin: '0px 0px -40px 0px' }
    );
    revealEls.forEach(function (el) {
      io.observe(el);
    });
  } else {
    revealEls.forEach(function (el) {
      el.classList.add('visible');
    });
  }

  // ---------- private -> proven interaction ----------
  var demo = document.getElementById('private-proven');
  if (demo) {
    if ('IntersectionObserver' in window) {
      var demoIo = new IntersectionObserver(
        function (entries) {
          entries.forEach(function (entry) {
            if (entry.isIntersecting) {
              demo.classList.add('is-active');
            }
          });
        },
        { threshold: 0.5 }
      );
      demoIo.observe(demo);
    } else {
      demo.classList.add('is-active');
    }
  }

  // ---------- hero canvas: drifting hex glyphs ----------
  var canvas = document.getElementById('hero-canvas');
  if (!canvas || !canvas.getContext) return;

  var hero = canvas.closest('.hero');
  if (!hero) return;

  var ctx = canvas.getContext('2d');
  var chars = '0123456789abcdef';
  var FONT = "'SFMono-Regular', Consolas, monospace";
  var COUNT = 42;
  var dpr = Math.min(window.devicePixelRatio || 1, 2);
  var glyphs = [];
  var rafId = null;

  function rectOf() {
    return hero.getBoundingClientRect();
  }

  function resize() {
    var rect = rectOf();
    canvas.width = Math.max(1, rect.width * dpr);
    canvas.height = Math.max(1, rect.height * dpr);
    canvas.style.width = rect.width + 'px';
    canvas.style.height = rect.height + 'px';
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function seed() {
    var rect = rectOf();
    glyphs = [];
    for (var i = 0; i < COUNT; i++) {
      glyphs.push({
        x: Math.random() * rect.width,
        y: Math.random() * rect.height,
        vy: 5 + Math.random() * 12,
        ch: chars[(Math.random() * chars.length) | 0],
        size: 10 + Math.random() * 8,
        alpha: 0.05 + Math.random() * 0.14,
        flip: 2.5 + Math.random() * 4,
        t: 0
      });
    }
  }

  function drawStatic() {
    var rect = rectOf();
    ctx.clearRect(0, 0, rect.width, rect.height);
    glyphs.forEach(function (g) {
      ctx.fillStyle = 'rgba(0, 212, 255, ' + g.alpha + ')';
      ctx.font = g.size + 'px ' + FONT;
      ctx.fillText(g.ch, g.x, g.y);
    });
  }

  var lastFrame = null;

  function frame(t) {
    if (lastFrame === null) lastFrame = t;
    var dt = Math.min((t - lastFrame) / 1000, 0.05);
    lastFrame = t;

    var rect = rectOf();
    ctx.clearRect(0, 0, rect.width, rect.height);

    glyphs.forEach(function (g) {
      g.y += g.vy * dt;
      g.t += dt;
      if (g.y > rect.height + 20) {
        g.y = -20;
        g.x = Math.random() * rect.width;
      }
      if (g.t > g.flip) {
        g.ch = chars[(Math.random() * chars.length) | 0];
        g.t = 0;
      }
      ctx.fillStyle = 'rgba(0, 212, 255, ' + g.alpha + ')';
      ctx.font = g.size + 'px ' + FONT;
      ctx.fillText(g.ch, g.x, g.y);
    });

    rafId = requestAnimationFrame(frame);
  }

  resize();
  seed();

  window.addEventListener('resize', function () {
    resize();
    if (reduceMotion) drawStatic();
  });

  if (reduceMotion) {
    drawStatic();
  } else {
    rafId = requestAnimationFrame(frame);
  }

  // pause the loop when the hero scrolls out of view (cheap perf win)
  if ('IntersectionObserver' in window && !reduceMotion) {
    var heroIo = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting && rafId) {
          cancelAnimationFrame(rafId);
          rafId = null;
        } else if (entry.isIntersecting && !rafId) {
          lastFrame = null;
          rafId = requestAnimationFrame(frame);
        }
      });
    });
    heroIo.observe(hero);
  }
})();
