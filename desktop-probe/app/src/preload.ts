import { contextBridge, ipcRenderer } from 'electron'
contextBridge.exposeInMainWorld('probe', {
  command: (command: string, payload?: unknown) => ipcRenderer.invoke('probe-command', command, payload),
  onUpdate: (callback: (data: unknown) => void) => { ipcRenderer.on('probe-update', (_event, data) => callback(data)) }
})
