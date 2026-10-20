// Copies the web version into the desktop app before each build, so both stay identical.
const fs = require('fs'); const path = require('path');
const src = path.join(__dirname, '..', 'web'); const dst = path.join(__dirname, 'app');
fs.rmSync(dst, { recursive: true, force: true });
fs.cpSync(src, dst, { recursive: true });
console.log('Version web copiée dans desktop/app');
