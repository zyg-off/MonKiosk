const { app, BrowserWindow, shell, Menu } = require('electron');
const path = require('path');

function createWindow() {
  const win = new BrowserWindow({
    width: 1200, height: 820, minWidth: 380, minHeight: 600,
    title: 'MonKiosk', backgroundColor: '#f2f4f7',
    icon: path.join(__dirname, 'build', 'icon.png'),
    autoHideMenuBar: true,
    webPreferences: { contextIsolation: true, nodeIntegration: false }
  });
  win.loadFile(path.join(__dirname, 'app', 'index.html'));
  win.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: 'deny' }; });
}
Menu.setApplicationMenu(null);
app.setAppUserModelId('com.zyg.monkiosk');
app.whenReady().then(createWindow);
app.on('window-all-closed', () => app.quit());
