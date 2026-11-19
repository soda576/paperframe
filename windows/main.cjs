const { app, BrowserWindow, ipcMain, net, protocol } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { normalize } = require('./model.js');

const startUrl = 'paperframe://app/index.html';
let window;
let dataFile;
let loadError;
let noteSize;
let libraryOpen = false;

app.setName('Paperframe');
app.setAppUserModelId('com.soda.paperframe.windows');
protocol.registerSchemesAsPrivileged([{
  scheme: 'paperframe', privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true },
}]);

if (process.env.PAPERFRAME_TEST_DATA) {
  const directory = path.resolve(process.env.PAPERFRAME_TEST_DATA);
  fs.mkdirSync(directory, { recursive: true });
  app.setPath('userData', directory);
}

function readData() {
  try {
    return normalize(JSON.parse(fs.readFileSync(dataFile, 'utf8')));
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    return normalize({ plans: {} });
  }
}

function listen(channel, run) {
  ipcMain.handle(channel, (event, ...args) => {
    if (event.sender !== window?.webContents || event.senderFrame?.url !== startUrl) {
      throw new Error('未知的请求来源');
    }
    return run(...args);
  });
}

async function serve({ url }) {
  const request = new URL(url);
  if (request.hostname !== 'app') return new Response(null, { status: 404 });
  const pathname = decodeURIComponent(request.pathname);
  if (!/^\/(?:assets\/)?[\w.-]+$/.test(pathname) || pathname.endsWith('/..')) {
    return new Response(null, { status: 404 });
  }
  if (pathname === '/model.js') return net.fetch(pathToFileURL(path.join(__dirname, 'model.js')).href);
  const base = pathname.startsWith('/assets/')
    ? (app.isPackaged ? path.join(__dirname, 'assets') : path.resolve(__dirname, '../Assets'))
    : path.join(__dirname, 'renderer');
  return net.fetch(pathToFileURL(path.join(base, path.basename(pathname))).href);
}

function showWindow() {
  window = new BrowserWindow({
    width: 400, height: 500, minWidth: 300, minHeight: 270,
    show: false, backgroundColor: '#d8e1e6', title: 'Paperframe',
    icon: path.join(__dirname, 'icon.ico'), autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, sandbox: true,
      nodeIntegration: false,
    },
  });
  if (process.platform === 'win32') window.removeMenu();
  window.webContents.on('will-navigate', event => event.preventDefault());
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.on('closed', () => { window = undefined; libraryOpen = false; noteSize = undefined; });
  window.once('ready-to-show', () => window.show());
  window.loadURL(startUrl);
}

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (window?.isMinimized()) window.restore();
    window?.focus();
  });
  app.whenReady().then(() => {
    dataFile = path.join(app.getPath('userData'), 'paperframe.json');
    protocol.handle('paperframe', serve);
    listen('paperframe:load', () => {
      try { return readData(); }
      catch (error) { loadError = error; throw error; }
    });
    listen('paperframe:save', snapshot => {
      if (loadError) throw loadError;
      const data = normalize(snapshot);
      fs.writeFileSync(dataFile + '.tmp', JSON.stringify(data, null, 2), { mode: 0o600 });
      fs.renameSync(dataFile + '.tmp', dataFile);
    });
    listen('paperframe:pin', enabled => window.setAlwaysOnTop(enabled === true));
    listen('paperframe:library', enabled => {
      if (libraryOpen === enabled) return;
      libraryOpen = enabled === true;
      if (libraryOpen) {
        noteSize = window.getSize();
        window.setMinimumSize(730, 450);
        window.setSize(Math.max(1060, noteSize[0]), Math.max(700, noteSize[1]));
      } else {
        window.setMinimumSize(300, 270);
        if (noteSize) window.setSize(...noteSize);
      }
    });
    showWindow();
  });
  app.on('activate', () => { if (!window) showWindow(); });
  app.on('window-all-closed', () => app.quit());
}
