#!/usr/bin/env ruby
# Generates LumenBridge.xcodeproj with two application targets sharing the
# Shared/ source tree:
#   - LumenBridge   (macOS 14+, menu-bar SwiftUI)
#   - LumenBridgeTV (tvOS   17+, focus-based SwiftUI)
#
# Both targets point at the same bundle ID `com.lorislabapp.lumenbridge`
# (registered universal via App Store Connect API).
#
# Re-run this script whenever source files are added or moved — it rebuilds
# the project from the current disk layout.

require 'xcodeproj'
require 'fileutils'

ROOT = File.expand_path(File.dirname(__FILE__))
PROJECT_PATH = File.join(ROOT, 'LumenBridge.xcodeproj')

SHARED_DIR = File.join(ROOT, 'Shared')
MAC_DIR    = File.join(ROOT, 'LumenBridge')
TV_DIR     = File.join(ROOT, 'LumenBridgeTV')

# Nuke + regenerate for idempotency.
FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)

# Swift Package dependencies used by both targets.
MQTT_NIO_URL = 'https://github.com/adam-fowler/mqtt-nio'
MQTT_NIO_MIN = '2.13.0'

mqtt_nio_pkg = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
mqtt_nio_pkg.repositoryURL = MQTT_NIO_URL
mqtt_nio_pkg.requirement = {
  'kind' => 'upToNextMajorVersion',
  'minimumVersion' => MQTT_NIO_MIN
}
project.root_object.package_references << mqtt_nio_pkg

def add_package_product(project, target, package_ref, product_name)
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = package_ref
  dep.product_name = product_name
  target.package_product_dependencies << dep
  # Also add to the Frameworks build phase so it links.
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dep
  target.frameworks_build_phase.files << build_file
end

# Groups mirror the on-disk layout.
shared_group = project.new_group('Shared',         'Shared')
mac_group    = project.new_group('LumenBridge',    'LumenBridge')
tv_group     = project.new_group('LumenBridgeTV',  'LumenBridgeTV')

# Extensions that Xcode treats as opaque packages even though they are
# directories on disk — we add them as a single file reference, not a group.
PACKAGE_EXTS = %w[.xcassets .bundle .framework .app .xcframework].freeze

def add_files_recursive(project, parent_group, path_on_disk)
  Dir.glob("#{path_on_disk}/*").sort.each do |entry|
    basename = File.basename(entry)
    is_package = PACKAGE_EXTS.any? { |ext| basename.end_with?(ext) }
    if File.directory?(entry) && !is_package
      sub = parent_group.new_group(basename, basename)
      add_files_recursive(project, sub, entry)
    else
      parent_group.new_file(basename)
    end
  end
end

add_files_recursive(project, shared_group, SHARED_DIR)
add_files_recursive(project, mac_group,    MAC_DIR)
add_files_recursive(project, tv_group,     TV_DIR)

# Collect Swift files per group.
def swift_files_in(group)
  files = []
  group.recursive_children.each do |f|
    next unless f.is_a?(Xcodeproj::Project::Object::PBXFileReference)
    next unless f.path.end_with?('.swift')
    files << f
  end
  files
end

shared_swift = swift_files_in(shared_group)
mac_swift    = swift_files_in(mac_group)
tv_swift     = swift_files_in(tv_group)

# --- macOS target ---
mac_target = project.new_target(:application, 'LumenBridge', :osx, '14.0')
(shared_swift + mac_swift).each { |f| mac_target.source_build_phase.add_file_reference(f) }

# Asset catalog — macOS icon. The .xcassets folder is a "blue folder" in Xcode
# but for xcodebuild purposes we add the folder as a file reference with the
# .xcassets path and Xcode auto-picks it up as an asset catalog resource.
mac_xcassets = mac_group.recursive_children.find { |f|
  f.is_a?(Xcodeproj::Project::Object::PBXFileReference) && f.path == 'Assets.xcassets'
}
mac_target.resources_build_phase.add_file_reference(mac_xcassets) if mac_xcassets

add_package_product(project, mac_target, mqtt_nio_pkg, 'MQTTNIO')

mac_target.build_configurations.each do |config|
  config.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.lorislabapp.lumenbridge',
    'PRODUCT_NAME' => 'Lumen Bridge',
    'MARKETING_VERSION' => '0.1.0',
    'CURRENT_PROJECT_VERSION' => '1',
    'MACOSX_DEPLOYMENT_TARGET' => '14.0',
    'SWIFT_VERSION' => '6.0',
    'DEVELOPMENT_TEAM' => 'TDV6D5L785',
    'CODE_SIGN_STYLE' => 'Automatic',
    'CODE_SIGN_ENTITLEMENTS' => 'LumenBridge/Resources/LumenBridge.entitlements',
    'INFOPLIST_FILE' => 'LumenBridge/Resources/Info.plist',
    'ENABLE_HARDENED_RUNTIME' => 'YES',
    'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/../Frameworks',
    'COMBINE_HIDPI_IMAGES' => 'YES',
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
    'ENABLE_PREVIEWS' => 'YES',
    'INFOPLIST_KEY_NSHumanReadableCopyright' => 'Copyright © 2026 LorisLabs',
    'INFOPLIST_KEY_LSApplicationCategoryType' => 'public.app-category.utilities',
    'INFOPLIST_KEY_LSUIElement' => 'YES',
    'SDKROOT' => 'macosx',
    'SUPPORTED_PLATFORMS' => 'macosx'
  )
end

# --- tvOS target ---
tv_target = project.new_target(:application, 'LumenBridgeTV', :tvos, '17.0')
(shared_swift + tv_swift).each { |f| tv_target.source_build_phase.add_file_reference(f) }

add_package_product(project, tv_target, mqtt_nio_pkg, 'MQTTNIO')

tv_target.build_configurations.each do |config|
  config.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.lorislabapp.lumenbridge',
    'PRODUCT_NAME' => 'Lumen Bridge',
    'MARKETING_VERSION' => '0.1.0',
    'CURRENT_PROJECT_VERSION' => '1',
    'TVOS_DEPLOYMENT_TARGET' => '17.0',
    'SWIFT_VERSION' => '6.0',
    'DEVELOPMENT_TEAM' => 'TDV6D5L785',
    'CODE_SIGN_STYLE' => 'Automatic',
    'CODE_SIGN_ENTITLEMENTS' => 'LumenBridgeTV/Resources/LumenBridgeTV.entitlements',
    'INFOPLIST_FILE' => 'LumenBridgeTV/Resources/Info.plist',
    'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/Frameworks',
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
    'ENABLE_PREVIEWS' => 'YES',
    'INFOPLIST_KEY_NSHumanReadableCopyright' => 'Copyright © 2026 LorisLabs',
    'INFOPLIST_KEY_LSApplicationCategoryType' => 'public.app-category.utilities',
    'SDKROOT' => 'appletvos',
    'SUPPORTED_PLATFORMS' => 'appletvos appletvsimulator',
    'TARGETED_DEVICE_FAMILY' => '3'
  )
end

project.save

# Schemes — one per target so xcodebuild can build each independently.
[mac_target, tv_target].each do |target|
  scheme = Xcodeproj::XCScheme.new
  scheme.add_build_target(target)
  scheme.set_launch_target(target)
  scheme.save_as(PROJECT_PATH, target.name, true)
end

puts "Generated #{PROJECT_PATH}"
puts "Targets:"
puts "  - LumenBridge    (macOS 14+)   — #{(shared_swift + mac_swift).size} swift files"
puts "  - LumenBridgeTV  (tvOS 17+)   — #{(shared_swift + tv_swift).size} swift files"
