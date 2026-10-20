const { app, BrowserWindow, shell, Menu, ipcMain, dialog, nativeTheme } = require('electron');
const path = require('path');
const { autoUpdater } = require('electron-updater');

let win = null;
let lastStatus = { state: 'idle' };

function send(status) {
  lastStatus = status;
  if (win && !win.isDestroyed()) win.webContents.send('update-status', status);
}

// Barre de titre aux couleurs de MonKiosk (boutons Windows conservés à droite)
const BAR_HEIGHT = 36;
const REMOTE = 'https://zyg-off.github.io/MonKiosk/';
function barColors() {
  return nativeTheme.shouldUseDarkColors
    ? { color: '#11161d', symbolColor: '#e7ebf1', height: BAR_HEIGHT }
    : { color: '#f2f4f7', symbolColor: '#17202b', height: BAR_HEIGHT };
}

function createWindow() {
  win = new BrowserWindow({
    width: 1200, height: 820, minWidth: 380, minHeight: 600,
    title: 'MonKiosk', backgroundColor: nativeTheme.shouldUseDarkColors ? '#11161d' : '#f2f4f7',
    titleBarStyle: 'hidden', titleBarOverlay: barColors(),
    icon: path.join(__dirname, 'build', 'icon.png'),
    autoHideMenuBar: true,
    webPreferences: { contextIsolation: true, nodeIntegration: false, preload: path.join(__dirname, 'preload.js') }
  });
  // Charge la version en ligne (toujours à jour, sans réinstaller) ; la copie intégrée sert hors connexion.
  const local = path.join(__dirname, 'app', 'index.html');
  let fellBack = false;
  const fallback = () => { if (!fellBack) { fellBack = true; win.loadFile(local); } };
  win.webContents.on('did-fail-load', (_e, _code, _desc, url, isMain) => { if (isMain && url.startsWith(REMOTE)) fallback(); });
  win.webContents.on('will-navigate', (e, url) => {
    if (!url.startsWith(REMOTE) && !url.startsWith('file:')) { e.preventDefault(); shell.openExternal(url); }
  });
  win.loadURL(REMOTE).catch(fallback);
  win.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: 'deny' }; });
  win.webContents.on('did-finish-load', () => send(lastStatus));
  nativeTheme.on('updated', () => { if (win && !win.isDestroyed()) { try { win.setTitleBarOverlay(barColors()); } catch (e) {} } });
  win.on('maximize', () => win.webContents.send('window-state', 'max'));
  win.on('unmaximize', () => win.webContents.send('window-state', 'normal'));
}

/* ---------- Mises à jour automatiques (depuis les Releases GitHub) ---------- */
autoUpdater.autoDownload = true;
autoUpdater.autoInstallOnAppQuit = true;
autoUpdater.on('checking-for-update', () => send({ state: 'checking' }));
autoUpdater.on('update-available', (i) => send({ state: 'downloading', version: i.version, percent: 0 }));
autoUpdater.on('update-not-available', () => send({ state: 'uptodate' }));
autoUpdater.on('download-progress', (p) => send({ state: 'downloading', version: lastStatus.version, percent: Math.round(p.percent) }));
autoUpdater.on('error', (e) => send({ state: 'error', message: String(e && e.message || e) }));
autoUpdater.on('update-downloaded', async (i) => {
  send({ state: 'ready', version: i.version });
  const r = await dialog.showMessageBox(win, {
    type: 'info', buttons: ['Redémarrer maintenant', 'Plus tard'], defaultId: 0, cancelId: 1,
    title: 'Mise à jour prête',
    message: `MonKiosk ${i.version} est prête.`,
    detail: 'L\'installation se fait en arrière-plan, en quelques secondes, puis MonKiosk se rouvre tout seul. Sinon, elle s\'installera discrètement à la prochaine fermeture.'
  });
  if (r.response === 0) autoUpdater.quitAndInstall(true, true);
});

function check() {
  if (!app.isPackaged) return send({ state: 'uptodate' });
  autoUpdater.checkForUpdates().catch((e) => send({ state: 'error', message: String(e && e.message || e) }));
}

ipcMain.handle('app-version', () => app.getVersion());
ipcMain.handle('check-updates', () => { check(); return true; });
ipcMain.handle('install-update', () => { if (lastStatus.state === 'ready') autoUpdater.quitAndInstall(true, true); return true; });

Menu.setApplicationMenu(null);
app.setAppUserModelId('com.zyg.monkiosk');
if (!app.requestSingleInstanceLock()) app.quit();
app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });
app.whenReady().then(() => {
  createWindow();
  setTimeout(check, 5000);
  setInterval(check, 4 * 60 * 60 * 1000);
});
app.on('window-all-closed', () => app.quit());
