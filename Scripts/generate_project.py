#!/usr/bin/env python3
"""Generate the tiny Xcode project using stdlib only; no XcodeGen installation."""
import pathlib, hashlib
root=pathlib.Path(__file__).resolve().parents[1]
project=root/'Peoplemaps.xcodeproj'; project.mkdir(exist_ok=True)
objects=[]
def ref(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def obj(name,body):
    key=ref(name);objects.append(f'\t\t{key} = {{ {body} }};');return key
def files(folder):
    refs=[];builds=[];resources=[]
    for p in sorted((root/folder).glob('*')):
        if p.suffix not in {'.swift','.json','.md'}:continue
        kind={'swift':'sourcecode.swift','json':'text.json','md':'net.daringfireball.markdown'}[p.suffix[1:]]
        key=obj(str(p.relative_to(root)),f'isa = PBXFileReference; lastKnownFileType = {kind}; path = "{p.name}"; sourceTree = "<group>";')
        build=obj('build:'+str(p.relative_to(root)),f'isa = PBXBuildFile; fileRef = {key};')
        refs.append(key);(builds if p.suffix=='.swift' else resources).append(build)
    obj(folder,f'isa = PBXGroup; children = ({",".join(refs)}); path = {folder}; sourceTree = "<group>";')
    return builds,resources
app_sources,app_resources=files('App'); test_sources,test_resources=files('UITests')
app_product=obj('app-product','isa = PBXFileReference; explicitFileType = wrapper.application; path = Peoplemaps.app; sourceTree = BUILT_PRODUCTS_DIR;')
test_product=obj('test-product','isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = PeoplemapsUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
obj('products',f'isa = PBXGroup; children = ({app_product},{test_product}); name = Products; sourceTree = "<group>";')
obj('root',f'isa = PBXGroup; children = ({ref("App")},{ref("UITests")},{ref("products")}); sourceTree = "<group>";')
obj('core-package','isa = XCLocalSwiftPackageReference; relativePath = .;')
obj('map-package','isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/maplibre/maplibre-gl-native-distribution"; requirement = {kind = exactVersion; version = 6.31.0;};')
obj('core-product',f'isa = XCSwiftPackageProductDependency; package = {ref("core-package")}; productName = PeoplemapsCore;')
obj('map-product',f'isa = XCSwiftPackageProductDependency; package = {ref("map-package")}; productName = MapLibre;')
obj('core-link',f'isa = PBXBuildFile; productRef = {ref("core-product")};')
obj('map-link',f'isa = PBXBuildFile; productRef = {ref("map-product")};')
for name,sources,resources in [('app',app_sources,app_resources),('test',test_sources,test_resources)]:
    obj(name+'-sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(sources)}); runOnlyForDeploymentPostprocessing = 0;')
    obj(name+'-resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(resources)}); runOnlyForDeploymentPostprocessing = 0;')
    frameworks=','.join([ref('core-link'),ref('map-link')]) if name=='app' else ''
    obj(name+'-frameworks',f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({frameworks}); runOnlyForDeploymentPostprocessing = 0;')
    for config in ['Debug','Release']:
        settings={'SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'17.0','SWIFT_VERSION':'6.0','TARGETED_DEVICE_FAMILY':'"1,2"',
                  'GENERATE_INFOPLIST_FILE':'YES','CODE_SIGNING_ALLOWED':'NO','PRODUCT_NAME':'"$(TARGET_NAME)"',
                  'ONLY_ACTIVE_ARCH':'YES' if config=='Debug' else 'NO',
                  'SWIFT_OPTIMIZATION_LEVEL':'"-Onone"' if config=='Debug' else '"-O"',
                  'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'"DEBUG $(inherited)"' if config=='Debug' else '"$(inherited)"',
                  'PRODUCT_BUNDLE_IDENTIFIER':'org.peoplemaps.prototype' if name=='app' else 'org.peoplemaps.prototype.uitests',
                  'LD_RUNPATH_SEARCH_PATHS':'"$(inherited) @executable_path/Frameworks"'}
        if name=='app':settings.update({'INFOPLIST_KEY_UILaunchScreen_Generation':'YES','INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES','INFOPLIST_KEY_UISupportedInterfaceOrientations':'UIInterfaceOrientationPortrait','INFOPLIST_KEY_CFBundleDisplayName':'Peoplemaps','MARKETING_VERSION':'0.1.0','CURRENT_PROJECT_VERSION':'1'})
        else:settings['TEST_TARGET_NAME']='Peoplemaps'
        obj(name+'-'+config,f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{'+''.join(f'{k} = {v};' for k,v in settings.items())+'};')
    obj(name+'-config',f'isa = XCConfigurationList; buildConfigurations = ({ref(name+"-Debug")},{ref(name+"-Release")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('proxy',f'isa = PBXContainerItemProxy; containerPortal = {ref("project")}; proxyType = 1; remoteGlobalIDString = {ref("app-target")}; remoteInfo = Peoplemaps;')
obj('test-dependency',f'isa = PBXTargetDependency; target = {ref("app-target")}; targetProxy = {ref("proxy")};')
for name,title,product,type_ in [('app','Peoplemaps',app_product,'com.apple.product-type.application'),('test','PeoplemapsUITests',test_product,'com.apple.product-type.bundle.ui-testing')]:
    obj(name+'-target',f'isa = PBXNativeTarget; buildConfigurationList = {ref(name+"-config")}; buildPhases = ({ref(name+"-sources")},{ref(name+"-frameworks")},{ref(name+"-resources")}); buildRules = (); dependencies = ({ref("test-dependency") if name=="test" else ""}); name = {title}; productName = {title}; productReference = {product}; productType = "{type_}"; packageProductDependencies = ({",".join([ref("core-product"),ref("map-product")]) if name=="app" else ""});')
for config in ['Debug','Release']:
    obj('project-'+config,f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; ALWAYS_SEARCH_USER_PATHS = NO;}};')
obj('project-config',f'isa = XCConfigurationList; buildConfigurations = ({ref("project-Debug")},{ref("project-Release")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('project',f'isa = PBXProject; attributes = {{LastUpgradeCheck = 2700; TargetAttributes = {{{ref("test-target")} = {{TestTargetID = {ref("app-target")};}};}};}}; buildConfigurationList = {ref("project-config")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {ref("root")}; productRefGroup = {ref("products")}; projectDirPath = ""; projectRoot = ""; targets = ({ref("app-target")},{ref("test-target")}); packageReferences = ({ref("core-package")},{ref("map-package")});')
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {ref("project")}; }}\n')
schemes=project/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
def buildable(name,title):return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref(name+"-target")}" BuildableName="{title}{".app" if name=="app" else ".xctest"}" BlueprintName="{title}" ReferencedContainer="container:Peoplemaps.xcodeproj"/>'
(schemes/'Peoplemaps.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable('app','Peoplemaps')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO" parallelizable="NO">{buildable('test','PeoplemapsUITests')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{buildable('app','Peoplemaps')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable('app','Peoplemaps')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(project)
