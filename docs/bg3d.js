/*
 * VoltPass — persistent 3D background field.
 *
 * A restrained, full-viewport Three.js particle network suggesting
 * encrypted data: drifting nodes, faint connecting lines, occasional
 * "proof pulses" traveling between linked nodes, and a handful of
 * scrambling hex-glyph sprites.
 *
 * Fallback strategy:
 *  - No WebGL support        -> bail before touching Three.js; CSS gradient
 *                                (set on <body> in style.css) is the backdrop.
 *  - prefers-reduced-motion  -> bail; CSS gradient only, no animation loop.
 *  - Narrow viewport (<=700) -> bail entirely; CSS gradient only (perf).
 *  - three.js CDN load fails -> caught, bail to CSS gradient.
 *  - WebGLRenderer() throws  -> caught, bail to CSS gradient.
 *  - Tab hidden              -> render loop paused via visibilitychange,
 *                                resumed when visible again.
 */
(function () {
  'use strict';

  var canvas = document.getElementById('bg3d');
  if (!canvas) return;

  var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var mobileMQ = window.matchMedia('(max-width: 700px)');

  function hasWebGL() {
    try {
      var test = document.createElement('canvas');
      return !!(
        window.WebGLRenderingContext &&
        (test.getContext('webgl') || test.getContext('experimental-webgl'))
      );
    } catch (e) {
      return false;
    }
  }

  // Any of these -> leave the canvas untouched (transparent, invisible) and
  // let the CSS gradient fallback on <body> do the work. No animation loop.
  if (reduceMotion || mobileMQ.matches || !hasWebGL()) {
    return;
  }

  import('three')
    .then(function (THREE) {
      startScene(THREE);
    })
    .catch(function () {
      // CDN unreachable / module load failed — silently fall back to the
      // CSS gradient background already painted behind the canvas.
    });

  function startScene(THREE) {
    var renderer;
    try {
      renderer = new THREE.WebGLRenderer({ canvas: canvas, alpha: true, antialias: true });
    } catch (e) {
      return; // WebGL context creation failed — CSS gradient remains visible.
    }

    var scene = new THREE.Scene();
    var camera = new THREE.PerspectiveCamera(55, window.innerWidth / window.innerHeight, 0.1, 100);
    camera.position.z = 22;

    var dpr = Math.min(window.devicePixelRatio || 1, 2);
    renderer.setPixelRatio(dpr);
    renderer.setSize(window.innerWidth, window.innerHeight);

    var COUNT = 90; // conservative particle budget
    var LINK_DIST = 4.2;
    var BOUNDS = 18;

    var positions = new Float32Array(COUNT * 3);
    var velocities = [];
    var colors = new Float32Array(COUNT * 3);

    var cyan = new THREE.Color(0x00d4ff);
    var violet = new THREE.Color(0xa78bfa);

    for (var i = 0; i < COUNT; i++) {
      positions[i * 3] = (Math.random() - 0.5) * BOUNDS * 2;
      positions[i * 3 + 1] = (Math.random() - 0.5) * BOUNDS * 2;
      positions[i * 3 + 2] = (Math.random() - 0.5) * BOUNDS;
      velocities.push({
        x: (Math.random() - 0.5) * 0.12,
        y: (Math.random() - 0.5) * 0.12,
        z: (Math.random() - 0.5) * 0.06
      });
      var c = Math.random() < 0.7 ? cyan : violet;
      colors[i * 3] = c.r;
      colors[i * 3 + 1] = c.g;
      colors[i * 3 + 2] = c.b;
    }

    var pointsGeo = new THREE.BufferGeometry();
    pointsGeo.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    pointsGeo.setAttribute('color', new THREE.BufferAttribute(colors, 3));

    var pointsMat = new THREE.PointsMaterial({
      size: 0.2,
      vertexColors: true,
      transparent: true,
      opacity: 0.38,
      depthWrite: false
    });

    var points = new THREE.Points(pointsGeo, pointsMat);
    scene.add(points);

    // ---- connecting lines between nearby nodes ----
    var maxLines = COUNT * 4;
    var lineGeo = new THREE.BufferGeometry();
    lineGeo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(maxLines * 2 * 3), 3));
    lineGeo.setAttribute('color', new THREE.BufferAttribute(new Float32Array(maxLines * 2 * 3), 3));
    var lineMat = new THREE.LineBasicMaterial({
      vertexColors: true,
      transparent: true,
      opacity: 0.055,
      depthWrite: false
    });
    var lines = new THREE.LineSegments(lineGeo, lineMat);
    scene.add(lines);

    // ---- proof pulse: a bright point traveling along an active link ----
    var pulseGeo = new THREE.SphereGeometry(0.1, 8, 8);
    var pulseMat = new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0 });
    var pulseMesh = new THREE.Mesh(pulseGeo, pulseMat);
    scene.add(pulseMesh);

    var pulse = null;
    var nextPulseAt = performance.now() + 2000 + Math.random() * 3000;

    function schedulePulse(links) {
      if (!links.length) return;
      var link = links[(Math.random() * links.length) | 0];
      pulse = {
        a: link.a,
        b: link.b,
        t: 0,
        last: null,
        dur: 900 + Math.random() * 500,
        color: Math.random() < 0.5 ? cyan : violet
      };
    }

    // ---- occasional scrambling hex-glyph sprites ----
    var hexChars = '0123456789abcdef';
    var glyphCount = 10;
    var glyphSprites = [];

    function makeGlyphTexture(ch, color) {
      var c = document.createElement('canvas');
      c.width = 64;
      c.height = 64;
      var g = c.getContext('2d');
      g.clearRect(0, 0, 64, 64);
      g.font = '48px SFMono-Regular, Consolas, monospace';
      g.fillStyle = color;
      g.textAlign = 'center';
      g.textBaseline = 'middle';
      g.fillText(ch, 32, 34);
      var tex = new THREE.CanvasTexture(c);
      tex.needsUpdate = true;
      return tex;
    }

    for (var gi = 0; gi < glyphCount; gi++) {
      var idx = (Math.random() * COUNT) | 0;
      var ch = hexChars[(Math.random() * hexChars.length) | 0];
      var color = Math.random() < 0.5 ? '#00d4ff' : '#a78bfa';
      var mat = new THREE.SpriteMaterial({
        map: makeGlyphTexture(ch, color),
        transparent: true,
        opacity: 0.32,
        depthWrite: false
      });
      var sprite = new THREE.Sprite(mat);
      sprite.scale.set(0.6, 0.6, 0.6);
      sprite.userData.particleIndex = idx;
      sprite.userData.color = color;
      sprite.userData.nextFlip = performance.now() + 3000 + Math.random() * 6000;
      scene.add(sprite);
      glyphSprites.push(sprite);
    }

    function resize() {
      var w = window.innerWidth,
        h = window.innerHeight;
      camera.aspect = w / h;
      camera.updateProjectionMatrix();
      renderer.setSize(w, h);
    }
    window.addEventListener('resize', resize);

    var rafId = null;
    var lastFrame = null;
    var frameCount = 0;
    var cachedLinks = null;

    function frame(t) {
      if (lastFrame === null) lastFrame = t;
      var dt = Math.min((t - lastFrame) / 1000, 0.05);
      lastFrame = t;

      var pos = pointsGeo.attributes.position.array;
      for (var i = 0; i < COUNT; i++) {
        pos[i * 3] += velocities[i].x * dt * 6;
        pos[i * 3 + 1] += velocities[i].y * dt * 6;
        pos[i * 3 + 2] += velocities[i].z * dt * 6;
        var bx = BOUNDS,
          by = BOUNDS,
          bz = BOUNDS / 2;
        if (pos[i * 3] > bx) pos[i * 3] = -bx;
        if (pos[i * 3] < -bx) pos[i * 3] = bx;
        if (pos[i * 3 + 1] > by) pos[i * 3 + 1] = -by;
        if (pos[i * 3 + 1] < -by) pos[i * 3 + 1] = by;
        if (pos[i * 3 + 2] > bz) pos[i * 3 + 2] = -bz;
        if (pos[i * 3 + 2] < -bz) pos[i * 3 + 2] = bz;
      }
      pointsGeo.attributes.position.needsUpdate = true;

      // Recompute the link set every few frames — O(n^2) over 120 points
      // is cheap, but no need to do it 60x/sec.
      frameCount++;
      if (frameCount % 6 === 0 || !cachedLinks) {
        var links = [];
        outer: for (var a = 0; a < COUNT; a++) {
          for (var b = a + 1; b < COUNT; b++) {
            var dx = pos[a * 3] - pos[b * 3];
            var dy = pos[a * 3 + 1] - pos[b * 3 + 1];
            var dz = pos[a * 3 + 2] - pos[b * 3 + 2];
            var d2 = dx * dx + dy * dy + dz * dz;
            if (d2 < LINK_DIST * LINK_DIST) {
              links.push({ a: a, b: b });
              if (links.length >= maxLines) break outer;
            }
          }
        }
        cachedLinks = links;
      }

      var lpos = lineGeo.attributes.position.array;
      var lcol = lineGeo.attributes.color.array;
      var li = 0;
      for (var k = 0; k < cachedLinks.length && li < maxLines; k++) {
        var link = cachedLinks[k];
        var ia = link.a,
          ib = link.b;
        lpos[li * 6] = pos[ia * 3];
        lpos[li * 6 + 1] = pos[ia * 3 + 1];
        lpos[li * 6 + 2] = pos[ia * 3 + 2];
        lpos[li * 6 + 3] = pos[ib * 3];
        lpos[li * 6 + 4] = pos[ib * 3 + 1];
        lpos[li * 6 + 5] = pos[ib * 3 + 2];
        var lc = Math.random() < 0.5 ? cyan : violet;
        lcol[li * 6] = lc.r;
        lcol[li * 6 + 1] = lc.g;
        lcol[li * 6 + 2] = lc.b;
        lcol[li * 6 + 3] = lc.r;
        lcol[li * 6 + 4] = lc.g;
        lcol[li * 6 + 5] = lc.b;
        li++;
      }
      lineGeo.setDrawRange(0, li * 2);
      lineGeo.attributes.position.needsUpdate = true;
      lineGeo.attributes.color.needsUpdate = true;

      // proof pulse — infrequent, one at a time
      if (!pulse && t > nextPulseAt) {
        schedulePulse(cachedLinks);
        nextPulseAt = t + 3500 + Math.random() * 4500;
      }
      if (pulse) {
        if (pulse.last === null) pulse.last = t;
        pulse.t += t - pulse.last;
        pulse.last = t;
        var frac = Math.min(pulse.t / pulse.dur, 1);
        var ax = pos[pulse.a * 3],
          ay = pos[pulse.a * 3 + 1],
          az = pos[pulse.a * 3 + 2];
        var bbx = pos[pulse.b * 3],
          bby = pos[pulse.b * 3 + 1],
          bbz = pos[pulse.b * 3 + 2];
        pulseMesh.position.set(ax + (bbx - ax) * frac, ay + (bby - ay) * frac, az + (bbz - az) * frac);
        pulseMesh.material.color = pulse.color;
        pulseMesh.material.opacity = frac < 1 ? 0.9 * (1 - Math.abs(frac - 0.5) * 0.5) : 0;
        if (frac >= 1) pulse = null;
      }

      // scrambling hex glyphs
      for (var s = 0; s < glyphSprites.length; s++) {
        var sp = glyphSprites[s];
        var pi = sp.userData.particleIndex;
        sp.position.set(pos[pi * 3], pos[pi * 3 + 1], pos[pi * 3 + 2]);
        if (t > sp.userData.nextFlip) {
          var newCh = hexChars[(Math.random() * hexChars.length) | 0];
          var oldTex = sp.material.map;
          sp.material.map = makeGlyphTexture(newCh, sp.userData.color);
          sp.material.needsUpdate = true;
          if (oldTex) oldTex.dispose();
          sp.userData.nextFlip = t + 3000 + Math.random() * 6000;
        }
      }

      scene.rotation.y += dt * 0.015;
      scene.rotation.x = Math.sin(t * 0.00005) * 0.05;

      renderer.render(scene, camera);
      rafId = requestAnimationFrame(frame);
    }

    function start() {
      if (rafId === null) {
        lastFrame = null;
        rafId = requestAnimationFrame(frame);
      }
    }
    function stop() {
      if (rafId !== null) {
        cancelAnimationFrame(rafId);
        rafId = null;
      }
    }

    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'visible') start();
      else stop();
    });

    // If the viewport crosses the mobile breakpoint after load, tear the
    // layer down entirely rather than keep rendering off-screen work.
    function handleMQChange(e) {
      if (e.matches) {
        stop();
        canvas.style.display = 'none';
      } else {
        canvas.style.display = '';
        start();
      }
    }
    if (mobileMQ.addEventListener) mobileMQ.addEventListener('change', handleMQChange);
    else if (mobileMQ.addListener) mobileMQ.addListener(handleMQChange);

    start();
  }
})();
