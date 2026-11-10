#!/usr/bin/env python3
"""Sync current browser, local-media and plug-in files without replacing targets or signing settings."""
from pathlib import Path
import copy
import hashlib
import json
import re

root = Path(__file__).resolve().parents[1]
parser = root / 'Scripts/validate-project.py'
namespace = {'__file__': str(parser)}
exec(parser.read_text().split('assert len(targets)')[0], namespace)
project, objects = namespace['project'], namespace['objects']
original = copy.deepcopy(project)
main = objects[objects[project['rootObject']]['mainGroup']]
managed_folders = ('Browser/', 'Media/', 'Plugins/')

# Remove missing managed sources and their build entries. This script no longer
# adds a media downloader, native bridge, remote-media package, or URL scheme.
removed = {key for key, obj in objects.items()
           if obj.get('isa') == 'PBXFileReference'
           and obj.get('path', '').startswith(managed_folders)
           and not (root / obj['path']).exists()}
removed.update(key for key, obj in objects.items()
               if obj.get('isa') == 'PBXBuildFile' and obj.get('fileRef') in removed)
for key in removed:
    objects.pop(key)


def remove_references(value):
    if isinstance(value, dict):
        for key, item in value.items():
            value[key] = remove_references(item)
    elif isinstance(value, list):
        return [remove_references(item) for item in value
                if not isinstance(item, str) or item not in removed]
    return value


remove_references(project)


def add(label, obj):
    key = hashlib.sha1(('media-v2:' + label).encode()).hexdigest()[:24].upper()
    assert key not in objects or objects[key] == obj, 'Project identifier collision: ' + label
    objects[key] = obj
    return key


def file_reference(path, file_type):
    key = next((key for key, obj in objects.items()
                if obj.get('isa') == 'PBXFileReference'
                and obj.get('path') == path), None)
    if key is None:
        key = add(path, {'isa': 'PBXFileReference', 'lastKnownFileType': file_type,
                         'path': path, 'sourceTree': '<group>'})
        main['children'].append(key)
    return key


source_refs = [file_reference(file.relative_to(root).as_posix(), 'sourcecode.swift')
               for file in sorted([*root.glob('Browser/*.swift'),
                                   *root.glob('Media/*.swift'),
                                   *root.glob('Plugins/*.swift')])]
resource_refs = [file_reference('BrowserResources', 'folder')]
for target in namespace['targets']:
    if target.get('productType') != 'com.apple.product-type.application':
        continue
    for phase_id in target['buildPhases']:
        phase = objects[phase_id]
        refs = (source_refs if phase['isa'] == 'PBXSourcesBuildPhase' else
                resource_refs if phase['isa'] == 'PBXResourcesBuildPhase' else [])
        existing = {objects[key].get('fileRef') for key in phase.get('files', [])}
        for ref in refs:
            if ref not in existing:
                phase['files'].append(add(target['name'] + ':' + ref,
                                          {'isa': 'PBXBuildFile', 'fileRef': ref}))


def atom(value):
    return value if re.fullmatch(r'[A-Za-z0-9_.$/@+-]+', value) else json.dumps(value)


def emit(value, level=0):
    indent = '\t' * level
    if isinstance(value, dict):
        return '{\n' + ''.join('\t' * (level + 1) + atom(str(key)) + ' = ' +
                               emit(item, level + 1) + ';\n'
                               for key, item in value.items()) + indent + '}'
    if isinstance(value, list):
        return '(\n' + ''.join('\t' * (level + 1) + emit(item, level + 1) + ',\n'
                               for item in value) + indent + ')'
    return str(value) if isinstance(value, int) else atom(value)


if project != original:
    (root / 'DevTools.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n' + emit(project) + '\n')
    print('Synchronized browser, local-media and plug-in sources; retained all targets and signing settings.')
else:
    print('Project already matches current browser, local-media and plug-in sources.')
