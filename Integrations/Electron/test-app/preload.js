// Minimal renderer bridge for the test pages. Diagnostics only: the native
// addon stays in the main process.
'use strict';

const { contextBridge, ipcRenderer } = require('electron');

const number = (value) => (Number.isFinite(value) ? value : null);

contextBridge.exposeInMainWorld('fullPanelTest', {
  onUpdate: (callback) => {
    ipcRenderer.on('fullpanel:update', (_event, update) => callback(update));
  },
  command: (name) => ipcRenderer.invoke('fullpanel:command', String(name)),
  reportPointer: (event) => ipcRenderer.send('fullpanel:pointer', {
    type: String(event.type),
    pointerType: String(event.pointerType),
    isTrusted: Boolean(event.isTrusted),
    clientX: number(event.clientX),
    clientY: number(event.clientY),
    screenX: number(event.screenX),
    screenY: number(event.screenY),
    region: String(event.region),
  }),
  manualSteps: () => ipcRenderer.invoke('fullpanel:manual-steps'),
  startStep: (test) => ipcRenderer.send('fullpanel:manual-arm', { test: String(test) }),
  recordVerdict: (test, verdict) => ipcRenderer.send('fullpanel:verdict', {
    test: String(test),
    verdict: String(verdict),
  }),
});
