#!/usr/bin/env python3
"""Add native media sources without replacing the user's nine-target Xcode project."""
from pathlib import Path
import hashlib
import json
import plistlib
import re

root = Path(__file__).resolve().parents[1]
parser = root / 'Scripts/validate-project.py'
ns = {'__file__': str(parser)}
exec(parser.read_text().split('assert len(targets)')[0], ns)
project, objects = ns['project'], ns['objects']

def oid(label):
    return hashlib.sha1(('media-v2:' + label).encode()).hexdigest()[:24].upper()

def add(label, obj):
    key = oid(label)
    objects[key] = obj
    return key

main = objects[objects[project['rootObject']]['mainGroup']]
files = sorted([*root.glob('Browser/*.swift'), *root.glob('Media/*.swift'), *root.glob('Plugins/*.swift'), root / 'Media/MediaRemux.c'])
source_ids = []
for file in files:
    path = file.relative_to(root).as_posix()
    key = add(path, {'isa': 'PBXFileReference', 'lastKnownFileType': 'sourcecode.c.c' if file.suffix == '.c' else 'sourcecode.swift', 'path': path, 'sourceTree': '<group>'})
    if key not in main['children']:
        main['children'].append(key)
    source_ids.append(key)
resources = []
for path in ['BrowserResources', 'Licenses/FFmpegBuild']:
    key = add(path, {'isa': 'PBXFileReference', 'lastKnownFileType': 'folder', 'path': path, 'sourceTree': '<group>'})
    if key not in main['children']:
        main['children'].append(key)
    resources.append(key)
package = add('ffmpeg-package', {'isa': 'XCRemoteSwiftPackageReference', 'repositoryURL': 'https://github.com/superuser404notfound/FFmpegBuild', 'requirement': {'kind': 'revision', 'revision': 'f93e7788796eeede40bf866ed2f802b4dbfbef50'}})
pbxproject = objects[project['rootObject']]
if package not in pbxproject.setdefault('packageReferences', []):
    pbxproject['packageReferences'].append(package)
for target in ns['targets']:
    if target.get('productType') != 'com.apple.product-type.application':
        continue
    name = target['name']
    # Old project exports contained package products as PBXTargetDependency objects.
    # Xcode expects package products in packageProductDependencies/frameworks instead.
    target['dependencies'] = [key for key in target.get('dependencies', [])
                              if 'target' in objects[key] or 'targetProxy' in objects[key]]
    for phaseid in target['buildPhases']:
        phase = objects[phaseid]
        refs = source_ids if phase['isa'] == 'PBXSourcesBuildPhase' else resources if phase['isa'] == 'PBXResourcesBuildPhase' else []
        for ref in refs:
            build = add(name + ':' + ref, {'isa': 'PBXBuildFile', 'fileRef': ref})
            if build not in phase['files']:
                phase['files'].append(build)
    product = add(name + ':ffmpeg', {'isa': 'XCSwiftPackageProductDependency', 'package': package, 'productName': 'AetherFFmpegBuild'})
    if product not in target.setdefault('packageProductDependencies', []):
        target['packageProductDependencies'].append(product)
    framework = next(objects[k] for k in target['buildPhases'] if objects[k]['isa'] == 'PBXFrameworksBuildPhase')
    build = add(name + ':ffmpeg-link', {'isa': 'PBXBuildFile', 'productRef': product})
    if build not in framework['files']:
        framework['files'].append(build)
    extension_builds = []
    for extension_id, extension in list(objects.items()):
        if extension.get('isa') != 'PBXNativeTarget' or extension.get('productType') != 'com.apple.product-type.app-extension':
            continue
        proxy = add(name + ':proxy:' + extension_id, {
            'isa': 'PBXContainerItemProxy', 'containerPortal': project['rootObject'],
            'proxyType': 1, 'remoteGlobalIDString': extension_id, 'remoteInfo': extension['name']})
        dependency = add(name + ':dependency:' + extension_id, {
            'isa': 'PBXTargetDependency', 'target': extension_id, 'targetProxy': proxy})
        if dependency not in target.setdefault('dependencies', []):
            target['dependencies'].append(dependency)
        extension_builds.append(add(name + ':embed:' + extension_id, {
            'isa': 'PBXBuildFile', 'fileRef': extension['productReference'],
            'settings': {'ATTRIBUTES': ['RemoveHeadersOnCopy']}}))
    embed = add(name + ':embed-extensions', {'isa': 'PBXCopyFilesBuildPhase',
        'buildActionMask': 2147483647, 'dstPath': '', 'dstSubfolderSpec': 13,
        'files': extension_builds, 'name': 'Embed App Extensions', 'runOnlyForDeploymentPostprocessing': 0})
    if embed not in target['buildPhases']:
        target['buildPhases'].append(embed)
    for configuration in objects[target['buildConfigurationList']]['buildConfigurations']:
        settings = objects[configuration]['buildSettings']
        settings['SWIFT_OBJC_BRIDGING_HEADER'] = 'Configuration/DevTools-Bridging-Header.h'
        info = root / settings['INFOPLIST_FILE']
        plist = plistlib.loads(info.read_bytes())
        plist.update({
            'CFBundleURLTypes': [{'CFBundleURLName': 'DevTools media', 'CFBundleURLSchemes': ['devtools']}],
            'NSCameraUsageDescription': 'Use your camera on websites after you grant site permission.',
            'NSMicrophoneUsageDescription': 'Use your microphone on websites after you grant site permission.',
            'NSPhotoLibraryAddUsageDescription': 'Save downloaded media to your Photos library.',
            'UIFileSharingEnabled': True,
            'LSSupportsOpeningDocumentsInPlace': True,
        })
        info.write_bytes(plistlib.dumps(plist, sort_keys=False))
# Repair an absolute reference to the user's local copy of an otherwise included plist.
for obj in objects.values():
    if obj.get('isa') == 'PBXFileReference' and str(obj.get('path', '')).endswith('/DevTools copy-Info.plist'):
        obj['path'] = 'DevTools copy-Info.plist'
        obj['sourceTree'] = '<group>'

def atom(value):
    return value if re.fullmatch(r"[A-Za-z0-9_.$/@+-]+", value) else json.dumps(value)

def emit(value, level=0):
    indent = '\t' * level
    if isinstance(value, dict):
        return '{\n' + ''.join('\t' * (level + 1) + atom(str(k)) + ' = ' + emit(v, level + 1) + ';\n' for k, v in value.items()) + indent + '}'
    if isinstance(value, list):
        return '(\n' + ''.join('\t' * (level + 1) + emit(v, level + 1) + ',\n' for v in value) + indent + ')'
    return str(value) if isinstance(value, int) else atom(value)
(root / 'DevTools.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n' + emit(project) + '\n')
print('Updated both app targets; retained', len(ns['targets']), 'targets and existing signing settings.')
