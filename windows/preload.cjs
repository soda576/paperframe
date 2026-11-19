const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('paperframe', {
  load: () => ipcRenderer.invoke('paperframe:load'),
  save: state => ipcRenderer.invoke('paperframe:save', state),
  pin: enabled => ipcRenderer.invoke('paperframe:pin', enabled),
  library: enabled => ipcRenderer.invoke('paperframe:library', enabled),
});
