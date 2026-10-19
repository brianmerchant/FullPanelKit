// FullPanel Tauri test page. window.FP_LABEL is set by an initialization script
// in main.rs ("a" = FullPanel window, "b" = ordinary window, others = transient
// autotest windows).

const invoke = window.__TAURI__.core.invoke;
const label = window.FP_LABEL || '?';
const isA = label === 'a';
const $ = (id) => document.getElementById(id);
const regions = { left: $('notch-left'), right: $('notch-right'), housing: $('housing') };
let lastState = null;

document.body.classList.add(`role-${isA ? 'a' : 'b'}`);
$('title').textContent = isA ? 'Window A: FullPanelKit attached' : `Window ${label.toUpperCase()}: ordinary Tauri window`;
$('role-note').textContent = isA
  ? 'Enter fullscreen here: the orange and teal regions should fill the band beside the camera housing.'
  : 'Control window. FullPanelKit is not attached; its fullscreen leaves the camera-housing band to macOS.';

const actions = isA
  ? [['Attach', 'attach'], ['Enable', 'enable'], ['Disable', 'disable'], ['Detach', 'detach'],
     ['Enter fullscreen', 'enter'], ['Exit fullscreen', 'exit'], ['Diagnostics', 'diagnostics']]
  : [['Enter fullscreen', 'enter'], ['Exit fullscreen', 'exit'], ['Diagnostics', 'diagnostics']];
for (const [text, action] of actions) {
  const button = document.createElement('button');
  button.textContent = text;
  button.addEventListener('click', () => run(action));
  $('controls').appendChild(button);
}

async function run(action) {
  try {
    const result = await invoke('fp_call', { label, action });
    if (action === 'diagnostics') $('state').textContent = JSON.stringify(result, null, 2);
    else await refresh();
  } catch (error) {
    $('state').textContent = `${action} failed: ${JSON.stringify(error)}`;
  }
}

function place(element, rect) {
  if (!rect) { element.classList.remove('shown'); return; }
  Object.assign(element.style, {
    left: `${rect.x}px`, top: `${rect.y}px`, width: `${rect.width}px`, height: `${rect.height}px`,
  });
  element.classList.add('shown');
}

// Regions are drawn from the geometry whenever the window covers the screen
// (FullPanel active); otherwise they would sit outside the window.
function layout(state) {
  const geometry = state && state.geometry;
  const active = state && state.state && state.state.active;
  place(regions.left, active && geometry ? geometry.leftInWindow : null);
  place(regions.right, active && geometry ? geometry.rightInWindow : null);
  place(regions.housing, active && geometry ? geometry.housingInWindow : null);
}

async function refresh() {
  try {
    lastState = await invoke('fp_call', { label, action: 'state' });
  } catch (error) {
    lastState = { error };
  }
  layout(lastState);
  const s = lastState.state || {};
  $('state').textContent = [
    `session: ${s.stateName}  attached=${s.attached} enabled=${s.enabled} active=${s.active}`,
    `viewport: ${innerWidth}×${innerHeight} CSS px  dpr=${devicePixelRatio}  screen=${screen.width}×${screen.height}`,
    `notch-left:  ${JSON.stringify(lastState.geometry && lastState.geometry.leftInWindow)}`,
    `notch-right: ${JSON.stringify(lastState.geometry && lastState.geometry.rightInWindow)}`,
  ].join('\n');
}

// ---- Pointer diagnostics ---------------------------------------------------------
const log = [];
const counts = {};
function onPointer(event) {
  const target = event.target && event.target.id ? `#${event.target.id}` : event.target.tagName;
  const line = `${event.type} ${event.pointerType} client=(${event.clientX.toFixed(1)}, ${event.clientY.toFixed(1)}) ` +
    `screen=(${event.screenX}, ${event.screenY}) buttons=${event.buttons} target=${target}`;
  $('pointer').textContent = line;
  if (event.type === 'pointermove') return;
  counts[target] = (counts[target] || 0) + (event.type === 'pointerdown' ? 1 : 0);
  log.unshift(`${new Date().toISOString().slice(11, 23)} ${line}`);
  log.length = Math.min(log.length, 12);
  $('pointer-log').textContent = `pointerdown counts: ${JSON.stringify(counts)}\n${log.join('\n')}`;
  for (const region of Object.values(regions)) region.classList.toggle('hit', event.target === region && event.type === 'pointerdown');
  if (event.type === 'pointerdown') invoke('log_event', { label, line }).catch(() => {});
}
for (const type of ['pointerdown', 'pointerup', 'pointermove', 'pointercancel']) {
  document.addEventListener(type, onPointer, { capture: true });
}

// ---- Autotest probe --------------------------------------------------------------
// Called by the Rust autotest through eval(): lays out the regions from fresh
// geometry, then reports the viewport and which element is hit at the centre
// of each notch-side region and at the top corners.
const nextFrame = () => new Promise((resolve) => requestAnimationFrame(() => resolve()));
window.__fpProbe = async (token) => {
  await refresh();
  await nextFrame(); await nextFrame();
  const geometry = lastState.geometry || {};
  const hit = (x, y) => { const e = document.elementFromPoint(x, y); return e ? (e.id || e.tagName) : null; };
  const centre = (r) => (r ? hit(r.x + r.width / 2, r.y + r.height / 2) : null);
  const box = (e) => { const r = e.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height, shown: e.classList.contains('shown') }; };
  await invoke('report_probe', {
    label,
    data: {
      token,
      innerWidth, innerHeight, outerWidth, outerHeight,
      devicePixelRatio, screenWidth: screen.width, screenHeight: screen.height,
      leftCentreHit: centre(geometry.leftInWindow),
      rightCentreHit: centre(geometry.rightInWindow),
      topLeftCornerHit: hit(1, 1),
      topRightCornerHit: hit(innerWidth - 2, 1),
      leftBox: box(regions.left), rightBox: box(regions.right),
      sessionState: lastState.state || null,
    },
  });
};

addEventListener('resize', refresh);
setInterval(refresh, 1000);
refresh();
