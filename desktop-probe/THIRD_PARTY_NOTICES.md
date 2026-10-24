# Third-party notices

- Router-бинарник использует только Go standard library. `build-router.ps1` кладёт соответствующий `GO-LICENSE.txt` в `dist/`; распространяйте его вместе с бинарниками.
- Windows bundle включает Electron, Chromium и Node.js. Сохраняйте включённые packager-файлы `LICENSE.electron.txt` и `LICENSES.chromium.html`.
- TypeScript и Electron Packager используются только при сборке; runtime npm-зависимостей у приложения нет.
- Исходный код mawg, MagiTrickle и sing-box-lx не переносился и их бинарники не включаются в поставку. Установленный sing-box-lx использовался только как отдельный сравнительный PoC.
- `nfqws2`, Lua и fake payloads берутся из существующей установки Zator и не включаются в новый router-бинарник.
