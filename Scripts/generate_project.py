#!/usr/bin/env python3
"""Generate the Xcode project without third-party tooling. Run from any directory."""
from pathlib import Path
import hashlib, json, plistlib

root = Path(__file__).resolve().parent.parent
objects = {}
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def obj(key_name, isa, **fields):
    key = uid(key_name)
    objects[key] = dict(isa=isa, **fields)
    return key

def ref(path, kind='sourcecode.swift'):
    return obj('file:' + path, 'PBXFileReference', lastKnownFileType=kind, path=path, sourceTree='SOURCE_ROOT')

sources = sorted(str(p.relative_to(root)) for p in (root/'LLMUsage').rglob('*.swift') if 'Tests' not in p.parts)
sources += sorted(str(p.relative_to(root)) for p in (root/'Scripts/ManualReview').glob('*.swift'))
files = {p: ref(p) for p in sources}
tests = sorted(str(p.relative_to(root)) for p in (root/'LLMUsage/Tests').glob('*.swift'))
files.update({p: ref(p) for p in tests})
fixture = ref('LLMUsage/Tests/Fixtures', 'folder')
assets = ref('LLMUsage/Resources/Assets.xcassets', 'folder.assetcatalog')
providers = ref('LLMUsage/Resources/Providers', 'folder')
sparkle = ref('build/Dependencies/current/sparkle/Sparkle.framework', 'wrapper.framework')
config = ref('Configuration/Shared.xcconfig', 'text.xcconfig')
extras = [ref('README.md', 'net.daringfireball.markdown'), config, assets, providers, sparkle]
extras += [ref('LLMUsage/Resources/Brand/' + name, 'image.svg') for name in ['LLMUsageIcon.svg', 'LLMUsageIcon-dark.svg', 'LLMUsageSymbol.svg', 'LLMUsageSymbol-dark.svg']]
for p in ['App-Info.plist', 'Widget-Info.plist', 'App.entitlements', 'Widget.entitlements']:
    extras.append(ref('LLMUsage/Resources/' + p, 'text.plist.xml'))

products = {}
for target, product, kind in [('LLMUsage', 'LLM Usage.app', 'wrapper.application'),
                              ('LLMUsageWidget', 'LLMUsageWidget.appex', 'wrapper.app-extension'),
                              ('LLMUsageTests', 'LLMUsageTests.xctest', 'wrapper.cfbundle')]:
    products[target] = obj('product:' + target, 'PBXFileReference', explicitFileType=kind, includeInIndex='0', path=product, sourceTree='BUILT_PRODUCTS_DIR')
product_group = obj('products', 'PBXGroup', children=list(products.values()), name='Products', sourceTree='<group>')
source_groups = []
for directory in ['App','Dashboard','Sessions','Models','Settings','Data','Services','Shared','Widget','Tests','ManualReview']:
    children = [v for p,v in files.items() if f'/{directory}/' in p]
    if directory == 'Tests': children.append(fixture)
    source_groups.append(obj('group:'+directory, 'PBXGroup', children=children, name=directory, sourceTree='<group>'))
main_group = obj('main', 'PBXGroup', children=source_groups + extras + [product_group], sourceTree='<group>')

project_id = uid('project')
widget_id = uid('target:LLMUsageWidget')
app_id = uid('target:LLMUsage')
def dependency(target, target_id):
    proxy = obj('proxy:'+target, 'PBXContainerItemProxy', containerPortal=project_id, proxyType='1', remoteGlobalIDString=target_id, remoteInfo=target)
    return obj('dependency:'+target, 'PBXTargetDependency', target=target_id, targetProxy=proxy)
widget_dep = dependency('LLMUsageWidget', widget_id)
app_dep = dependency('LLMUsage', app_id)

def configs(name, settings):
    ids = []
    for mode in ['Debug','Release']:
        values = dict(settings)
        values.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if mode == 'Debug' else '-O',
                      DEBUG_INFORMATION_FORMAT='dwarf' if mode == 'Debug' else 'dwarf-with-dsym')
        if mode == 'Debug': values['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) DEBUG'; values['ENABLE_TESTABILITY'] = 'YES'
        ids.append(obj('config:'+name+mode, 'XCBuildConfiguration', baseConfigurationReference=config, buildSettings=values, name=mode))
    return obj('configlist:'+name, 'XCConfigurationList', buildConfigurations=ids, defaultConfigurationIsVisible='0', defaultConfigurationName='Release')

def build_file(target, path): return obj('build:'+target+path, 'PBXBuildFile', fileRef=files[path])
shared_widget = ['Shared/BrandGeometry.swift','Shared/UsageModels.swift','Shared/Localization.swift','Shared/UsageFormatting.swift','Shared/UsageRoute.swift','Shared/UsageHealth.swift','Shared/UsageHealthViews.swift',
                 'Shared/SnapshotStorage.swift','Shared/WidgetPresentation.swift','Shared/SampleData.swift','Shared/UsageStyle.swift',
                 'Shared/UsageHistory.swift','Shared/UsageHistoryViews.swift','Widget/UsageVariantViews.swift',
                 'Widget/UsageWidgetViews.swift','Widget/UsageTimelineProvider.swift','Widget/LLMUsageWidget.swift']
for target in ['LLMUsage','LLMUsageWidget','LLMUsageTests']:
    paths = tests if target.endswith('Tests') else [p for p in sources if not p.endswith('Widget/LLMUsageWidget.swift')]
    if target.endswith('Widget'): paths = ['LLMUsage/'+p for p in shared_widget]
    source_phase = obj('sources:'+target, 'PBXSourcesBuildPhase', buildActionMask='2147483647', files=[build_file(target,p) for p in paths], runOnlyForDeploymentPostprocessing='0')
    framework_phase = obj('frameworks:'+target, 'PBXFrameworksBuildPhase', buildActionMask='2147483647', files=[obj('sparkle-framework-build', 'PBXBuildFile', fileRef=sparkle)] if target == 'LLMUsage' else [], runOnlyForDeploymentPostprocessing='0')
    resource_files = []
    if target == 'LLMUsage':
        resource_files.append(obj('asset-build','PBXBuildFile',fileRef=assets))
        resource_files.append(obj('providers-build','PBXBuildFile',fileRef=providers))
    if target.endswith('Tests'): resource_files.append(obj('fixture-build','PBXBuildFile',fileRef=fixture))
    resource_phase = obj('resources:'+target, 'PBXResourcesBuildPhase', buildActionMask='2147483647', files=resource_files, runOnlyForDeploymentPostprocessing='0')
    phases = [source_phase, framework_phase, resource_phase]
    settings = dict(PRODUCT_NAME=target, PRODUCT_MODULE_NAME=target, PRODUCT_BUNDLE_IDENTIFIER='local.'+target,
                    CODE_SIGN_STYLE='Automatic', GENERATE_INFOPLIST_FILE='NO', SKIP_INSTALL='YES')
    dependencies = []
    if target == 'LLMUsage':
        prepare = obj('prepare-dependencies', 'PBXShellScriptBuildPhase', buildActionMask='2147483647',
                      files=[], inputPaths=[], outputPaths=[], runOnlyForDeploymentPostprocessing='0',
                      shellPath='/bin/bash', shellScript='set -euo pipefail\ncd "$SRCROOT"\npython3 Scripts/prepare-dependencies.py\n',
                      name='Prepare locked dependencies', alwaysOutOfDate='1')
        phases.insert(0, prepare)
        phases.append(obj('embed-dependencies', 'PBXShellScriptBuildPhase', buildActionMask='2147483647',
                          files=[], inputPaths=[], outputPaths=[], runOnlyForDeploymentPostprocessing='0',
                          shellPath='/bin/bash', shellScript='set -euo pipefail\ncd "$SRCROOT"\nLLM_CODESIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}" python3 Scripts/embed-dependencies.py "$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"\n',
                          name='Embed locked dependencies', alwaysOutOfDate='1'))
        settings.update(FRAMEWORK_SEARCH_PATHS=['$(inherited)', '$(SRCROOT)/build/Dependencies/current/sparkle'],
                        ENABLE_USER_SCRIPT_SANDBOXING='NO', PRODUCT_NAME='LLM Usage', PRODUCT_MODULE_NAME='LLMUsage',
                        PRODUCT_BUNDLE_IDENTIFIER='local.ClaudeUsage', INFOPLIST_FILE='$(DERIVED_FILE_DIR)/Versioned-App-Info.plist',
                        CODE_SIGN_ENTITLEMENTS='LLMUsage/Resources/App.entitlements', ENABLE_APP_SANDBOX='NO',
                        ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon',
                        ENABLE_HARDENED_RUNTIME='YES', SKIP_INSTALL='NO', LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/../Frameworks'])
        embed = obj('embed-widget-file', 'PBXBuildFile', fileRef=products['LLMUsageWidget'], settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
        phases.append(obj('embed-widget', 'PBXCopyFilesBuildPhase', buildActionMask='2147483647', dstPath='', dstSubfolderSpec='13', files=[embed], name='Embed App Extensions', runOnlyForDeploymentPostprocessing='0'))
        dependencies = [widget_dep]
        product_type = 'com.apple.product-type.application'
    elif target == 'LLMUsageWidget':
        settings.update(PRODUCT_BUNDLE_IDENTIFIER='local.ClaudeUsage.Widget', INFOPLIST_FILE='$(DERIVED_FILE_DIR)/Versioned-Widget-Info.plist',
                        CODE_SIGN_ENTITLEMENTS='LLMUsage/Resources/Widget.entitlements', ENABLE_APP_SANDBOX='YES',
                        APPLICATION_EXTENSION_API_ONLY='YES', LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/../Frameworks','@executable_path/../../../../Frameworks'])
        product_type = 'com.apple.product-type.app-extension'
    else:
        settings.update(FRAMEWORK_SEARCH_PATHS=['$(inherited)', '$(SRCROOT)/build/Dependencies/current/sparkle'], GENERATE_INFOPLIST_FILE='YES', PRODUCT_BUNDLE_IDENTIFIER='local.ClaudeUsage.Tests',
                        TEST_HOST='$(BUILT_PRODUCTS_DIR)/LLM Usage.app/Contents/MacOS/LLM Usage',
                        BUNDLE_LOADER='$(TEST_HOST)', LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/../Frameworks','@loader_path/../Frameworks'])
        dependencies = [app_dep]
        product_type = 'com.apple.product-type.bundle.unit-test'
    if target in ('LLMUsage', 'LLMUsageWidget'):
        settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
        stem = 'App' if target == 'LLMUsage' else 'Widget'
        phases.insert(0, obj('version:'+target, 'PBXShellScriptBuildPhase', buildActionMask='2147483647',
            files=[], inputPaths=['$(SRCROOT)/LLMUsage/Resources/'+stem+'-Info.plist', '$(SRCROOT)/.github/release.json'],
            outputPaths=['$(DERIVED_FILE_DIR)/Versioned-'+stem+'-Info.plist'],
            alwaysOutOfDate='1', name='Generate Info.plist from repository version', shellPath='/bin/bash',
            shellScript='set -euo pipefail\npython3 "$SRCROOT/Scripts/build_version.py" --write-template "$SCRIPT_INPUT_FILE_0" "$SCRIPT_OUTPUT_FILE_0"\n',
            runOnlyForDeploymentPostprocessing='0'))
        phases.append(obj('verify-version:'+target, 'PBXShellScriptBuildPhase', buildActionMask='2147483647',
            files=[], inputPaths=['$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)'], outputPaths=[], alwaysOutOfDate='1',
            name='Verify built version against repository', shellPath='/bin/bash',
            shellScript='set -euo pipefail\npython3 "$SRCROOT/Scripts/build_version.py" --verify-bundle "$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"'+(' --with-widget' if target == 'LLMUsage' else '')+'\n',
            runOnlyForDeploymentPostprocessing='0'))
    obj('target:'+target, 'PBXNativeTarget', buildConfigurationList=configs(target,settings), buildPhases=phases,
        buildRules=[], dependencies=dependencies, name=target, productName=target, productReference=products[target], productType=product_type)
project_settings = dict(SDKROOT='macosx', MACOSX_DEPLOYMENT_TARGET='26.0', SWIFT_VERSION='5.0',
                        CLANG_ENABLE_MODULES='YES', CLANG_ENABLE_OBJC_ARC='YES', SWIFT_STRICT_CONCURRENCY='targeted',
                        GCC_WARN_64_TO_32_BIT_CONVERSION='YES', GCC_WARN_UNDECLARED_SELECTOR='YES',
                        CLANG_WARN_DOCUMENTATION_COMMENTS='YES', COPY_PHASE_STRIP='NO')
obj('project','PBXProject', attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'2600',
    'TargetAttributes':{app_id:{'CreatedOnToolsVersion':'26.0'},widget_id:{'CreatedOnToolsVersion':'26.0'},uid('target:LLMUsageTests'):{'CreatedOnToolsVersion':'26.0','TestTargetID':app_id}}},
    buildConfigurationList=configs('project',project_settings), compatibilityVersion='Xcode 14.0', developmentRegion='ru',
    hasScannedForEncodings='0', knownRegions=['en','ru','Base'], mainGroup=main_group, productRefGroup=product_group,
    projectDirPath='', projectRoot='', targets=[app_id,widget_id,uid('target:LLMUsageTests')])

def serialize(value, level=0):
    if isinstance(value, dict):
        return '{\n' + ''.join('\t'*(level+1)+json.dumps(k)+' = '+serialize(v,level+1)+';\n' for k,v in value.items()) + '\t'*level+'}'
    if isinstance(value, list): return '(' + ', '.join(serialize(v,level+1) for v in value) + ')'
    return json.dumps(str(value))
project = root/'LLMUsage.xcodeproj'
project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n'+serialize(dict(archiveVersion='1',classes={},objectVersion='56',objects=objects,rootObject=project_id))+'\n')
schemes = project/'xcshareddata/xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
def buildable(name, product):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target:"+name)}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:LLMUsage.xcodeproj"/>'
app_ref=buildable('LLMUsage','LLM Usage.app')
test_ref=buildable('LLMUsageTests','LLMUsageTests.xctest')
(schemes/'LLMUsage.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Generated LLMUsage.xcodeproj (app, widget, tests)')
