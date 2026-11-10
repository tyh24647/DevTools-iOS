#!/usr/bin/env python3
"""Validate generated project structure and plists using only Python's standard library."""
from pathlib import Path
import re
import json
import plistlib

root = Path(__file__).resolve().parents[1]
source = (root / 'DevTools.xcodeproj/project.pbxproj').read_text()
pattern = re.compile(r'\s+|//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}()=;,]|[A-Za-z0-9_.$<>/@+-]+', re.S)
tokens = []
position = 0
for match in pattern.finditer(source):
    assert match.start() == position, 'Unrecognized project text at ' + str(position)
    position = match.end()
    token = match.group()
    if not token.isspace() and not token.startswith('//') and not token.startswith('/*'):
        tokens.append(token)
assert position == len(source)
cursor = 0

def take(expected=None):
    global cursor
    value = tokens[cursor]
    cursor += 1
    if expected is not None:
        assert value == expected, (value, expected, cursor)
    return value

def value():
    token = take()
    if token == '{':
        result = {}
        while tokens[cursor] != '}':
            key = value()
            take('=')
            result[key] = value()
            take(';')
        take('}')
        return result
    if token == '(':
        result = []
        while tokens[cursor] != ')':
            result.append(value())
            take(',')
        take(')')
        return result
    if token.startswith('"'):
        return json.loads(token)
    return int(token) if token.isdigit() else token

def embeds_extensions(phase):
    return phase.get('dstSubfolderSpec') == 13 or phase.get('dstSubfolder') == 'PlugIns'

project = value()
assert cursor == len(tokens)
objects = project['objects']
assert objects[project['rootObject']]['isa'] == 'PBXProject'
targets = [obj for obj in objects.values() if obj['isa'] == 'PBXNativeTarget']
assert len(targets) == 8
assert all(target["name"] != "DevTools (macOS)" for target in targets)
missing = []
for obj in objects.values():
    if obj['isa'] == 'PBXFileReference' and obj.get('sourceTree') == '<group>':
        if not (root / obj['path']).exists():
            missing.append(obj['path'])
assert not missing, 'Missing referenced files: ' + repr(missing)

app = next(target for target in targets if target['name'] == 'DevTools')
assert sum('target' in objects[key] for key in app['dependencies']) == 7
embed = [objects[key] for key in app['buildPhases'] if objects[key]['isa'] == 'PBXCopyFilesBuildPhase']
assert len(embed) == 1 and len(embed[0]['files']) == 7 and embeds_extensions(embed[0])

for target in targets:
    settings = objects[objects[target['buildConfigurationList']]['buildConfigurations'][0]]['buildSettings']
    assert settings['CODE_SIGN_ENTITLEMENTS'] == 'Configuration/Shared.entitlements'
    plist = plistlib.loads((root / settings['INFOPLIST_FILE']).read_bytes())
    assert plist['DevToolsAppGroup'] == '$(DT_APP_GROUP)'
    for phaseID in target['buildPhases']:
        phase = objects[phaseID]
        if phase['isa'] in ('PBXSourcesBuildPhase', 'PBXResourcesBuildPhase'):
            for buildID in phase['files']:
                fileID = objects[buildID]['fileRef']
                assert (root / objects[fileID]['path']).exists()
        if target.get('productType') != 'com.apple.product-type.application' and phase['isa'] == 'PBXFrameworksBuildPhase':
            assert phase['files'] == [], 'Advertising must not be linked to extensions.'
    if target.get('productType') != 'com.apple.product-type.application' and target['name'] != 'DevToolsSafari':
        extension = plist['NSExtension']
        assert extension['NSExtensionPointIdentifier'] == 'com.apple.ui-services'
        assert extension['NSExtensionAttributes']['NSExtensionJavaScriptPreprocessingFile'] == 'Action'

# Local media, browser and script management belong to the containing app.
for target in targets:
    is_app = target.get('productType') == 'com.apple.product-type.application'
    for dependency_id in target.get('dependencies', []):
        dependency = objects[dependency_id]
        assert dependency['isa'] == 'PBXTargetDependency'
        assert 'target' in dependency or 'targetProxy' in dependency
    native = []
    for phaseid in target['buildPhases']:
        phase = objects[phaseid]
        if phase['isa'] == 'PBXSourcesBuildPhase':
            native += [objects[objects[build]['fileRef']]['path'] for build in phase['files'] if objects[objects[build]['fileRef']]['path'].startswith(('Media/', 'Browser/', 'Plugins/'))]
    assert bool(native) == is_app
    assert not any(objects[key].get('productName') == 'AetherFFmpegBuild'
                   for key in target.get('packageProductDependencies', []))
    if is_app:
        embed = [objects[key] for key in target['buildPhases'] if objects[key]['isa'] == 'PBXCopyFilesBuildPhase']
        assert any(len(phase['files']) == 7 and embeds_extensions(phase) for phase in embed)
        for key in objects[target['buildConfigurationList']]['buildConfigurations']:
            settings = objects[key]['buildSettings']
            assert 'SWIFT_OBJC_BRIDGING_HEADER' not in settings
            assert settings['SKIP_INSTALL'] == 'NO'
            assert settings['INSTALL_PATH'] == '/Applications'

# The review candidate must not ship the former web-media acquisition pipeline.
removed_resources = {
    'BrowserResources/media-discovery.js',
    'BrowserResources/media-resources.js',
    'BrowserResources/mse-capture.js',
    'BrowserResources/native-bridge.js',
    'SafariExtension/Resources/media-handoff.js',
    'Media/HLSPlaylist.swift',
    'Media/HLSRecorder.swift',
    'Media/MediaRemux.c',
    'Media/MediaRemux.h',
    'DTMediaRemux.h',
}
assert not any((root / path).exists() for path in removed_resources), 'Obsolete acquisition source remains.'
assert not any(obj.get('path') in removed_resources for obj in objects.values())
assert not any('FFmpegBuild' in obj.get('repositoryURL', '') for obj in objects.values())
bootstrap = (root / 'BrowserResources/native-bootstrap.js').read_text()
controller = (root / 'Browser/BrowserController.swift').read_text()
for token in ('devtoolsMedia', '__devtoolsNativeSave', '__MEDIA_DISCOVERY__', '__MSE_CAPTURE__'):
    assert token not in bootstrap and token not in controller, 'Native media bridge remains: ' + token
app_plist = plistlib.loads((root / 'Configuration/App-Info.plist').read_bytes())
schemes = [scheme for item in app_plist.get('CFBundleURLTypes', []) for scheme in item.get('CFBundleURLSchemes', [])]
assert 'devtools' not in schemes, 'Removed media acquisition deep links must not be registered.'
assert 'NSPhotoLibraryUsageDescription' not in app_plist
assert app_plist['NSPhotoLibraryAddUsageDescription']

xcconfig = (root / 'Configuration/Project.xcconfig').read_text()
version = re.search(r'^MARKETING_VERSION\s*=\s*(\S+)', xcconfig, re.M).group(1)
build = re.search(r'^CURRENT_PROJECT_VERSION\s*=\s*(\d+)', xcconfig, re.M).group(1)

for configuration_name in ('Debug', 'Release'):
    bundle_ids = []
    for target in targets:
        configurations = [objects[key] for key in objects[target['buildConfigurationList']]['buildConfigurations']]
        settings = next(item['buildSettings'] for item in configurations if item['name'] == configuration_name)
        assert settings.get('SUPPORTS_MACCATALYST', 'NO') == 'NO'
        assert settings.get('SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD', 'NO') == 'NO'
        assert 'macosx' not in settings.get('SUPPORTED_PLATFORMS', '')
        assert str(settings.get('MARKETING_VERSION', version)) == version
        assert str(settings.get('CURRENT_PROJECT_VERSION', build)) == build
        plist = plistlib.loads((root / settings['INFOPLIST_FILE']).read_bytes())
        assert plist['CFBundleShortVersionString'] == '$(MARKETING_VERSION)'
        assert plist['CFBundleVersion'] == '$(CURRENT_PROJECT_VERSION)'
        if target.get('productType') != 'com.apple.product-type.application':
            assert settings['SKIP_INSTALL'] == 'YES'
        bundle_ids.append(settings['PRODUCT_BUNDLE_IDENTIFIER'])
    assert len(bundle_ids) == len(set(bundle_ids)), 'Duplicate iOS bundle identifiers.'

for path in (root / 'Configuration').glob('*.plist'):
    plistlib.loads(path.read_bytes())
plistlib.loads((root / 'Configuration/Shared.entitlements').read_bytes())
plistlib.loads((root / 'Shared/PrivacyInfo.xcprivacy').read_bytes())
storekit = json.loads((root / 'Configuration/DevTools.storekit').read_text())
assert storekit['products'][0]['displayPrice'] == '19.99'
assert storekit['subscriptionGroups'][0]['subscriptions'][0]['displayPrice'] == '2.99'
catalog = json.loads((root / 'Shared/tool-catalog.json').read_text())
assert len(catalog['assets']) == 10
print('Validated 8 targets, 7 embedded extensions, local-media boundary, matching versions, plists and test pricing.')
