// Test page for windows A (FullPanel), B (control) and C (cleanup test).
// Draws the notch-side markers from native geometry and reports what the
// renderer itself measures, independently of the native window.
'use strict';

const role = new URLSearchParams(location.search).get('role') || 'A';
const $ = (id) => document.getElementById(id);
const bridge = window.fullPanelTest;

let geometry = null;
const pointerLog = [];
const stepStatus = new Map();   // step id → status element

document.body.classList.add(`role-${role.toLowerCase()}`);
$('title').textContent = role === 'B'
  ? 'Window B: ordinary BrowserWindow (no FullPanel session)'
  : `Window ${role}: BrowserWindow with a FullPanel session`;

const fmt = (n) => (Number.isFinite(n) ? Math.round(n * 10) / 10 : '?');
const fmtRect = (r) => (r ? `${fmt(r.x)},${fmt(r.y)} ${fmt(r.width)}×${fmt(r.height)}` : '—');

function rectOf(id) {
  const element = $(id);
  if (element.style.display !== 'block') return null;
  const r = element.getBoundingClientRect();
  return { x: r.x, y: r.y, width: r.width, height: r.height };
}

// Read by the main process with executeJavaScript (main world).
window.readViewport = () => ({
  innerWidth,
  innerHeight,
  outerWidth,
  outerHeight,
  devicePixelRatio,
  screenWidth: screen.width,
  screenHeight: screen.height,
  visualViewport: {
    width: visualViewport.width,
    height: visualViewport.height,
    offsetTop: visualViewport.offsetTop,
    scale: visualViewport.scale,
  },
  documentClient: {
    width: document.documentElement.clientWidth,
    height: document.documentElement.clientHeight,
  },
});
window.readMarkers = () => ({ left: rectOf('aux-left'), right: rectOf('aux-right') });

function place(id, rect) {
  const element = $(id);
  const visible = rect && rect.y + rect.height > 0 && rect.y < innerHeight &&
    rect.x + rect.width > 0 && rect.x < innerWidth;
  element.style.display = visible ? 'block' : 'none';
  if (!visible) return;
  element.style.left = `${rect.x}px`;
  element.style.top = `${rect.y}px`;
  element.style.width = `${rect.width}px`;
  element.style.height = `${rect.height}px`;
}

function contains(rect, x, y) {
  return rect && x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height;
}

function regionAt(x, y) {
  const content = geometry && geometry.content;
  if (!content) return 'unknown';
  if (contains(content.auxiliaryLeftArea, x, y)) return 'auxiliaryLeftArea';
  if (contains(content.auxiliaryRightArea, x, y)) return 'auxiliaryRightArea';
  if (contains(content.cameraHousingRect, x, y)) return 'cameraHousingRect';
  return 'belowTopBand';
}

function render(update) {
  geometry = update.geometry;
  const native = update.native || {};
  const state = update.state || {};
  const content = (geometry && geometry.content) || {};
  document.body.classList.toggle('fullscreen', Boolean(native.fullScreen));
  place('aux-left', content.auxiliaryLeftArea);
  place('aux-right', content.auxiliaryRightArea);
  place('housing', content.cameraHousingRect);
  const vp = window.readViewport();
  if (update.manual) {
    for (const [id, status] of Object.entries(update.manual)) {
      const row = stepStatus.get(id);
      if (!row) continue;
      row.status.textContent = status.text;
      const tone = status.satisfied === true ? 'verdict-pass'
        : status.text.includes('FAIL') || status.text.includes('missing') ? 'verdict-fail' : '';
      row.status.className = `status ${tone}`;
      for (const button of row.verdictButtons) button.disabled = !status.armed;
    }
  }
  $('readout').textContent = [
    `session: ${state.stateName}${state.enabled ? ' (enabled)' : ''}` +
      (state.fallbackReason ? `  fallback: ${state.fallbackDescription}` : ''),
    `fullscreen: ${native.fullScreen ? 'yes' : 'no'}   class: ${native.windowClass}`,
    `NSWindow frame:      ${fmtRect(native.windowFrame)}   covers screen: ${native.frameCoversScreen ? 'YES' : 'no'}`,
    `WindowServer bounds: ${fmtRect(native.windowServerBounds)}   covers display: ${native.windowServerCoversDisplay ? 'YES' : 'no'}`,
    `screen: ${fmtRect(native.screenFrame)}   safe-area top: ${fmt(native.screenSafeAreaTop)}`,
    `content view: ${fmt(content.width)}×${fmt(content.height)}`,
    `viewport (renderer): ${vp.innerWidth}×${vp.innerHeight}   dpr ${vp.devicePixelRatio}` +
      `   visualViewport ${fmt(vp.visualViewport.width)}×${fmt(vp.visualViewport.height)}`,
    `left area (content):  ${fmtRect(content.auxiliaryLeftArea)}`,
    `right area (content): ${fmtRect(content.auxiliaryRightArea)}`,
  ].join('\n');
}

function renderPointerLog() {
  $('pointer-log').textContent = pointerLog.length
    ? `pointer events (latest first):\n${pointerLog.join('\n')}`
    : 'pointer events: none yet — click anywhere, including beside the notch';
}

function addButton(parent, label, onClick) {
  const button = document.createElement('button');
  button.textContent = label;
  button.addEventListener('click', onClick);
  parent.appendChild(button);
  return button;
}

async function buildControls() {
  const controls = $('controls');
  const run = (name) => bridge.command(name).catch((error) => console.error(error));
  addButton(controls, 'Enter fullscreen', () => run('enter'));
  addButton(controls, 'Exit fullscreen', () => run('exit'));
  if (role !== 'A') return;
  addButton(controls, 'Disable', () => run('disable'));
  addButton(controls, 'Enable', () => run('enable'));
  addButton(controls, 'Detach', () => run('detach'));
  addButton(controls, 'Attach + enable', () => run('attach'));
  addButton(controls, 'Save report', () => run('save'));

  // Start a step, do it, then Pass or Fail. The report keeps the pointer
  // events and window-state changes observed since Start with the verdict.
  const manual = $('manual');
  const steps = await bridge.manualSteps();
  let optionalHeading = false;
  for (const step of steps) {
    if (step.optional && !optionalHeading) {
      optionalHeading = true;
      const heading = document.createElement('div');
      heading.className = 'row';
      heading.textContent = 'Optional checks';
      manual.appendChild(heading);
    }
    const row = document.createElement('div');
    row.className = 'row';
    const text = document.createElement('span');
    text.className = 'label';
    text.textContent = step.label;
    const status = document.createElement('span');
    status.className = 'status';
    status.textContent = 'not started';
    row.append(text);
    addButton(row, 'Start', () => bridge.startStep(step.id));
    const verdictButtons = ['pass', 'fail'].map((verdict) => {
      const button = addButton(row, verdict === 'pass' ? 'Pass' : 'Fail',
        () => bridge.recordVerdict(step.id, verdict));
      button.disabled = true;
      return button;
    });
    row.append(status);
    manual.appendChild(row);
    stepStatus.set(step.id, { status, verdictButtons });
  }
}

window.addEventListener('pointerdown', (event) => {
  const region = regionAt(event.clientX, event.clientY);
  bridge.reportPointer({
    type: event.type,
    pointerType: event.pointerType,
    isTrusted: event.isTrusted,
    clientX: event.clientX,
    clientY: event.clientY,
    screenX: event.screenX,
    screenY: event.screenY,
    region,
  });
  pointerLog.unshift(`${new Date().toLocaleTimeString()}  ${region}  client ${fmt(event.clientX)},${fmt(event.clientY)}` +
    `  ${event.pointerType}${event.isTrusted ? '' : ' (untrusted)'}`);
  pointerLog.length = Math.min(pointerLog.length, 8);
  renderPointerLog();
}, { capture: true });

buildControls().catch((error) => console.error(error));
renderPointerLog();
bridge.onUpdate(render);
