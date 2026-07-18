# Security

Please report security issues privately through GitHub Security Advisories.

The installer deliberately:

- binds Chromium DevTools to `127.0.0.1` only;
- validates the browser and page WebSocket identities before connecting;
- downloads Node.js only from `nodejs.org` and verifies its SHA-256 against
  the official checksum list;
- writes only below `%LOCALAPPDATA%\CodexNativeDock` plus two user shortcuts;
- never modifies `WindowsApps`, `app.asar`, or the Codex installation;
- stops an injector process only when PID, executable, command line, script
  path, and process start time match the recorded state.
