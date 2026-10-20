// Sets the MonKiosk icon and version info on the Windows .exe without needing rcedit.
const fs = require('fs'); const path = require('path');
exports.default = async function (ctx) {
  if (ctx.electronPlatformName !== 'win32') return;
  const ResEdit = await import('resedit'); const PE = await import('pe-library');
  const exe = path.join(ctx.appOutDir, 'MonKiosk.exe');
  const exeObj = PE.NtExecutable.from(fs.readFileSync(exe), { ignoreCert: true });
  const res = PE.NtExecutableResource.from(exeObj);
  const ico = ResEdit.Data.IconFile.from(fs.readFileSync(path.join(__dirname, 'build', 'icon.ico')));
  const groups = ResEdit.Resource.IconGroupEntry.fromEntries(res.entries);
  const ids = groups.length ? groups.map(g => g.id) : [1];
  ids.forEach(id => ResEdit.Resource.IconGroupEntry.replaceIconsForResource(res.entries, id, 1033, ico.icons.map(i => i.data)));
  const vi = ResEdit.Resource.VersionInfo.fromEntries(res.entries)[0];
  if (vi) {
    vi.setStringValues({ lang: 1033, codepage: 1200 }, { ProductName: 'MonKiosk', FileDescription: 'MonKiosk', CompanyName: 'zyg', OriginalFilename: 'MonKiosk.exe', InternalName: 'MonKiosk', LegalCopyright: '© 2026 zyg' });
    vi.setFileVersion(1, 0, 0, 0, 1033); vi.setProductVersion(1, 0, 0, 0, 1033);
    vi.outputToResourceEntries(res.entries);
  }
  res.outputResource(exeObj);
  fs.writeFileSync(exe, Buffer.from(exeObj.generate()));
};
