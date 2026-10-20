// Pont sécurisé entre l'appli Windows et la page : version et mises à jour.
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('monkioskDesktop', {
  version: () => ipcRenderer.invoke('app-version'),
  checkUpdates: () => ipcRenderer.invoke('check-updates'),
  installUpdate: () => ipcRenderer.invoke('install-update'),
  onUpdate: (cb) => ipcRenderer.on('update-status', (_e, s) => cb(s)),
  titleBar: true
});
