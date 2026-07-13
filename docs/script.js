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

  // ---------- layer-card glow: subtle pulse once scrolled into view ----------
  var layerCards = document.querySelectorAll('.layer-card');
  if (layerCards.length) {
    if ('IntersectionObserver' in window && !reduceMotion) {
      var lcIo = new IntersectionObserver(
        function (entries) {
          entries.forEach(function (entry) {
            if (entry.isIntersecting) {
              entry.target.classList.add('lc-glow');
              lcIo.unobserve(entry.target);
            }
          });
        },
        { threshold: 0.3 }
      );
      layerCards.forEach(function (card) {
        lcIo.observe(card);
      });
    }
    // hover glow works regardless, via CSS :hover — no JS needed for that.
  }

  // ---------- scrambled -> proven stat hover ----------
  // Elements carry their real value as textContent already (so no-JS / reduced-
  // motion users always see the correct value). On hover we briefly scramble
  // the characters, then resolve them left-to-right back to the real value —
  // a fast (~500ms) cryptographic-reveal flourish, not a hacker-movie loop.
  var scrambleChars = '0123456789ABCDEF%/+.';
  var scrambleEls = document.querySelectorAll('.scramble');
  if (scrambleEls.length && !reduceMotion) {
    scrambleEls.forEach(function (el) {
      var final = el.textContent;
      var running = false;

      function randChar() {
        return scrambleChars[(Math.random() * scrambleChars.length) | 0];
      }

      function run() {
        if (running) return;
        running = true;
        var start = performance.now();
        var duration = 480;

        function tick(now) {
          var elapsed = now - start;
          var progress = Math.min(elapsed / duration, 1);
          var resolvedCount = Math.floor(progress * final.length);
          var out = '';
          for (var i = 0; i < final.length; i++) {
            if (final[i] === ' ') {
              out += ' ';
            } else if (i < resolvedCount) {
              out += final[i];
            } else {
              out += randChar();
            }
          }
          el.textContent = out;
          if (progress < 1) {
            requestAnimationFrame(tick);
          } else {
            el.textContent = final;
            running = false;
          }
        }
        requestAnimationFrame(tick);
      }

      el.addEventListener('mouseenter', run);
      el.addEventListener('focus', run);
    });
  }
})();
