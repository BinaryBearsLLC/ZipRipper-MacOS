"""Build a signed, drag-to-Applications DMG without automating Finder."""
import os
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

from ds_store import DSStore
from mac_alias import Alias

ROOT = Path(__file__).resolve().parents[1]
APP_VERSION = '0.5.3'


def run(*args):
    subprocess.run(list(map(str, args)), check=True)


def main():
    app = Path(os.environ.get('ZIPRIPPER_APP', ROOT / 'dist/ZipRipper.app')).resolve()
    identity = os.environ.get('MACOS_SIGN_IDENTITY')
    if not identity or identity == '-':
        raise SystemExit('A Developer ID signing identity is required for a release DMG')
    with (app / 'Contents/Info.plist').open('rb') as stream:
        assert plistlib.load(stream)['CFBundleShortVersionString'] == APP_VERSION
    run('codesign', '--verify', '--deep', '--strict', app)
    layout = json.loads((ROOT / 'packaging/dmg/config/layout.json').read_text())
    website = layout['website']['filename']
    output = ROOT / f'dist/packages/ZipRipper-{APP_VERSION}-macOS-arm64.dmg'
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='zipripper-dmg-') as temporary:
        temp = Path(temporary)
        stage = temp / 'stage'
        stage.mkdir()
        run('ditto', app, stage / app.name)
        (stage / 'Applications').symlink_to('/Applications')
        background = stage / '.background'
        background.mkdir()
        run('swift', ROOT / 'packaging/dmg/render-dmg-background.swift', background / 'background.png',
            ROOT / 'packaging/dmg/assets/watermark.png', ROOT / 'packaging/dmg/assets/arrow.jpeg',
            ROOT / 'packaging/dmg/config/layout.json')
        # Only release documentation; no local source, logs or settings.
        documentation = stage / '.documentation'
        documentation.mkdir()
        for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
            shutil.copy2(ROOT / name, documentation / name)
        with (stage / website).open('wb') as stream:
            plistlib.dump({'URL': layout['website']['url']}, stream)
        run('xcrun', 'SetFile', '-a', 'E', stage / website)
        run('swift', ROOT / 'packaging/dmg/set-file-icon.swift', stage / website,
            ROOT / 'packaging/dmg/assets/website-icon.png',
            str(layout['website']['visibleIconSize']), str(layout['finder']['iconSize']))
        run('hdiutil', 'create', '-quiet', '-fs', 'HFS+', '-format', 'UDRW',
            '-volname', 'ZipRipper Installer', '-srcfolder', stage, temp / 'writable.dmg')
        mount = temp / 'mount'
        run('hdiutil', 'attach', '-quiet', '-nobrowse', '-mountpoint', mount, temp / 'writable.dmg')
        try:
            alias = Alias.for_file(str(mount / '.background/background.png'))
            # Never embed the builder's temporary mount path in the shipped alias.
            alias.volume.posix_path = '/Volumes/ZipRipper Installer'
            alias.volume.disk_image_alias = None
            bounds = layout['finder']['windowBounds']
            # Finder bounds include title bar and persistent scrollbars; retain the full canvas.
            window_bounds = '{{%d, %d}, {%d, %d}}' % (bounds[0], bounds[1], bounds[2] - bounds[0] + 16, bounds[3] - bounds[1] + 48)
            with DSStore.open(str(mount / '.DS_Store'), 'w+') as store:
                store['.']['bwsp'] = {'ShowToolbar': False, 'ShowStatusBar': False,
                    'ShowPathbar': False, 'ShowSidebar': False, 'ContainerShowSidebar': False,
                    'WindowBounds': window_bounds, 'PreviewPaneVisibility': False,
                    'SidebarWidth': 0, 'ShowTabView': False}
                store['.']['icvp'] = {'viewOptionsVersion': 1, 'backgroundType': 2,
                    'backgroundImageAlias': alias.to_bytes(),
                    'iconSize': float(layout['finder']['iconSize']), 'textSize': 14.0, 'gridSpacing': 100.0,
                    'gridOffsetX': 0.0, 'gridOffsetY': 0.0,
                    'scrollPositionX': 0.0, 'scrollPositionY': 0.0,
                    'backgroundColorRed': 1.0, 'backgroundColorGreen': 1.0, 'backgroundColorBlue': 1.0,
                    'arrangeBy': 'none', 'labelOnBottom': True, 'showIconPreview': True,
                    'showItemInfo': False}
                store['.']['vSrn'] = ('long', 1)
                store['.']['icvl'] = ('type', b'icnv')
                for name, pos in {'ZipRipper.app': tuple(layout['finder']['items']['application']),
                    'Applications': tuple(layout['finder']['items']['applicationsFolder']),
                    website: tuple(layout['finder']['items']['website'])}.items():
                    store[name]['Iloc'] = pos
            shutil.copy2(ROOT / 'assets/AppIcon.icns', mount / '.VolumeIcon.icns')
            run('xcrun', 'SetFile', '-a', 'C', mount)
            run('sync')
        finally:
            run('hdiutil', 'detach', '-quiet', mount)
        run('hdiutil', 'convert', '-quiet', temp / 'writable.dmg', '-format', 'UDZO', '-o', temp / 'release.dmg')
        shutil.copy2(temp / 'release.dmg', output)
    run('codesign', '--force', '--timestamp', '--sign', identity, output)
    run('hdiutil', 'verify', '-quiet', output)
    run('codesign', '--verify', '--strict', output)
    print(f'Signed DMG created: {output.name}; notarization is a separate required gate')


if __name__ == '__main__':
    main()
