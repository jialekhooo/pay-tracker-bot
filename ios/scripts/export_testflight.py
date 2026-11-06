#!/usr/bin/env python3
"""Build and verify an App Store IPA using Xcode's cloud-managed signing."""
import argparse
import json
import os
import plistlib
import subprocess
import tempfile
import zipfile
from pathlib import Path

IOS = Path(__file__).resolve().parents[1]
TEAM = '8FSHKXDVJ2'
BUNDLE = 'com.jialekhoo.howmuch'
WIDGET_BUNDLE = BUNDLE + '.widgets'
SHARE_BUNDLE = BUNDLE + '.share'
WIDGET_GROUP = 'group.com.jialekhoo.howmuch.widgets'
ARCHIVE = IOS / 'build/HowMuch-accounts.xcarchive'
OUTPUT = IOS / 'build/TestFlight'


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-archive', action='store_true', help='Use the existing Release archive.')
    parser.add_argument('--upload', action='store_true',
                        help='After verifying the IPA, upload the same archive to App Store Connect using Xcode\'s signed-in account.')
    parser.add_argument('--api-key-id', default=os.environ.get('ASC_KEY_ID'),
                        help='App Store Connect API key ID; signs and uploads without an Xcode account.')
    parser.add_argument('--api-issuer', default=os.environ.get('ASC_ISSUER_ID'),
                        help='App Store Connect API issuer ID (needed with --api-key-id).')
    args = parser.parse_args()
    auth = []
    if args.api_key_id:
        key = Path(os.environ.get('ASC_KEY_PATH') or
                   Path.home()/'.appstoreconnect/private_keys'/f'AuthKey_{args.api_key_id}.p8')
        if not args.api_issuer or not key.is_file():
            raise SystemExit('API key needs --api-issuer and the key file at '+str(key))
        auth = ['-authenticationKeyPath', key, '-authenticationKeyID', args.api_key_id,
                '-authenticationKeyIssuerID', args.api_issuer]
    if not args.skip_archive:
        run('xcodebuild', '-project', IOS/'HowMuch.xcodeproj', '-scheme', 'HowMuch',
            '-configuration', 'Release', '-destination', 'generic/platform=iOS',
            '-archivePath', ARCHIVE, 'CODE_SIGNING_ALLOWED=NO', 'archive')
    # Unsigned archives omit capability entitlements. Preserve them in a temporary
    # ad-hoc signature so export can re-sign with Apple's distribution certificate.
    with tempfile.TemporaryDirectory(prefix='howmuch-export-') as scratch:
        scratch = Path(scratch)
        requested = {'com.apple.developer.applesignin': ['Default'], 'aps-environment': 'production',
                     'com.apple.security.application-groups': [WIDGET_GROUP],
                     'application-identifier': TEAM+'.'+BUNDLE,
                     'com.apple.developer.team-identifier': TEAM, 'get-task-allow': False}
        entitlements = scratch/'entitlements.plist'
        entitlements.write_bytes(plistlib.dumps(requested))
        widget_requested = {'com.apple.security.application-groups': [WIDGET_GROUP],
                            'application-identifier': TEAM+'.'+WIDGET_BUNDLE,
                            'com.apple.developer.team-identifier': TEAM, 'get-task-allow': False}
        widget_entitlements = scratch/'widget-entitlements.plist'
        widget_entitlements.write_bytes(plistlib.dumps(widget_requested))
        run('codesign', '--force', '--sign', '-', '--entitlements', widget_entitlements,
            ARCHIVE/'Products/Applications/HowMuch.app/PlugIns/HowMuchWidgets.appex')
        share_requested = {'com.apple.security.application-groups': [WIDGET_GROUP],
                           'application-identifier': TEAM+'.'+SHARE_BUNDLE,
                           'com.apple.developer.team-identifier': TEAM, 'get-task-allow': False}
        share_entitlements = scratch/'share-entitlements.plist'
        share_entitlements.write_bytes(plistlib.dumps(share_requested))
        run('codesign', '--force', '--sign', '-', '--entitlements', share_entitlements,
            ARCHIVE/'Products/Applications/HowMuch.app/PlugIns/HowMuchShare.appex')
        run('codesign', '--force', '--sign', '-', '--entitlements', entitlements,
            ARCHIVE/'Products/Applications/HowMuch.app')
        options = scratch/'ExportOptions.plist'
        options.write_bytes(plistlib.dumps({'method': 'app-store-connect', 'destination': 'export',
            'teamID': TEAM, 'signingStyle': 'automatic', 'manageAppVersionAndBuildNumber': True,
            'uploadSymbols': True}))
        run('xcodebuild', '-exportArchive', '-archivePath', ARCHIVE, '-exportPath', OUTPUT,
            '-exportOptionsPlist', options, '-allowProvisioningUpdates', *auth)
        with zipfile.ZipFile(OUTPUT/'HowMuch.ipa') as package:
            package.extractall(scratch/'package')
        app = scratch/'package/Payload/HowMuch.app'
        run('codesign', '--verify', '--deep', '--strict', app)
        actual = plistlib.loads(run('codesign', '-d', '--entitlements', ':-', app,
                                   capture_output=True).stdout)
        for key, expected in requested.items():
            if actual.get(key) != expected:
                raise RuntimeError('Incorrect signed entitlement: '+key)
        info = plistlib.loads((app/'Info.plist').read_bytes())
        if info.get('HowMuchAPNSEnvironment') != 'production' or info['CFBundleIdentifier'] != BUNDLE:
            raise RuntimeError('Incorrect release push environment or bundle identifier')
        primary_icon = info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {})
        if primary_icon.get('CFBundleIconName') != 'HowMuchHIcon':
            raise RuntimeError('Release must use the H app icon set')
        icon_assets = json.loads(run('xcrun', 'assetutil', '--info', app/'Assets.car',
                                    capture_output=True).stdout)
        for pixels, scale in ((40, 2), (60, 3)):
            if not any(asset.get('Name') == 'HowMuchHIcon' and asset.get('AssetType') == 'Icon Image'
                       and asset.get('Idiom') == 'phone' and asset.get('Scale') == scale
                       and asset.get('PixelWidth') == pixels and asset.get('PixelHeight') == pixels
                       and asset.get('RenditionName') == f'HowMuch-H-{pixels}.png' for asset in icon_assets):
                raise RuntimeError(f'Missing H notification icon: {pixels}px @{scale}x')
        print('Verified H primary icon and explicit 20pt notification icons at 2x and 3x')
        profile = plistlib.loads(run('security', 'cms', '-D', '-i', app/'embedded.mobileprovision',
                                    capture_output=True).stdout)
        if profile.get('ProvisionedDevices') or not profile['Entitlements'].get('beta-reports-active'):
            raise RuntimeError('Expected an App Store distribution profile')
        for key in ('aps-environment', 'com.apple.developer.applesignin', 'com.apple.security.application-groups'):
            if profile['Entitlements'].get(key) != requested[key]:
                raise RuntimeError('Distribution profile lacks capability: '+key)
        widget = app/'PlugIns/HowMuchWidgets.appex'
        run('codesign', '--verify', '--strict', widget)
        widget_actual = plistlib.loads(run('codesign', '-d', '--entitlements', ':-', widget, capture_output=True).stdout)
        for key, expected in widget_requested.items():
            if widget_actual.get(key) != expected:
                raise RuntimeError('Incorrect widget entitlement: '+key)
        widget_info = plistlib.loads((widget/'Info.plist').read_bytes())
        if (widget_info['CFBundleIdentifier'] != WIDGET_BUNDLE
                or widget_info['CFBundleVersion'] != info['CFBundleVersion']
                or widget_info['NSExtension']['NSExtensionPointIdentifier'] != 'com.apple.widgetkit-extension'):
            raise RuntimeError('Incorrect embedded WidgetKit extension metadata')
        widget_profile = plistlib.loads(run('security', 'cms', '-D', '-i', widget/'embedded.mobileprovision', capture_output=True).stdout)
        if (widget_profile.get('ProvisionedDevices') or widget_profile['Entitlements'].get('com.apple.security.application-groups') != [WIDGET_GROUP]):
            raise RuntimeError('Widget must have an App Store profile for the shared group')
        print('Verified embedded WidgetKit extension and shared app-group profiles')
        share = app/'PlugIns/HowMuchShare.appex'
        run('codesign', '--verify', '--strict', share)
        share_actual = plistlib.loads(run('codesign', '-d', '--entitlements', ':-', share, capture_output=True).stdout)
        for key, expected in share_requested.items():
            if share_actual.get(key) != expected:
                raise RuntimeError('Incorrect share extension entitlement: '+key)
        share_info = plistlib.loads((share/'Info.plist').read_bytes())
        if (share_info['CFBundleIdentifier'] != SHARE_BUNDLE or share_info['CFBundleVersion'] != info['CFBundleVersion']
                or share_info['NSExtension']['NSExtensionPointIdentifier'] != 'com.apple.share-services'):
            raise RuntimeError('Incorrect embedded share extension metadata')
        share_profile = plistlib.loads(run('security', 'cms', '-D', '-i', share/'embedded.mobileprovision', capture_output=True).stdout)
        if share_profile.get('ProvisionedDevices') or share_profile['Entitlements'].get('com.apple.security.application-groups') != [WIDGET_GROUP]:
            raise RuntimeError('Share extension must have an App Store profile for the shared group')
        if not info.get('NSSupportsLiveActivities'):
            raise RuntimeError('Live Activities must be enabled in the release Info.plist')
        print('Verified embedded share extension and Live Activity support')
        print('Verified signed TestFlight IPA:', OUTPUT/'HowMuch.ipa')
        print('Version:', info['CFBundleShortVersionString'], 'build:', info['CFBundleVersion'])
        if args.upload:
            upload = scratch/'UploadOptions.plist'
            upload.write_bytes(plistlib.dumps({'method': 'app-store-connect', 'destination': 'upload',
                'teamID': TEAM, 'signingStyle': 'automatic', 'manageAppVersionAndBuildNumber': False,
                'uploadSymbols': True}))
            run('xcodebuild', '-exportArchive', '-archivePath', ARCHIVE, '-exportPath', scratch/'upload',
                '-exportOptionsPlist', upload, '-allowProvisioningUpdates', *auth)
            print('Uploaded build', info['CFBundleVersion'], 'to App Store Connect')


if __name__ == '__main__':
    main()
