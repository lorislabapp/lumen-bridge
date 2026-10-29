#!/usr/bin/env ruby
# Generates LumenBridge.xcodeproj with three application targets sharing the
# Shared/ source tree:
#   - LumenBridge   (macOS 15+, menu-bar SwiftUI) — Mac App Store build
#   - LumenHub      (macOS 15+, same sources, LUMEN_HUB) — Developer ID build;
#                   the only target that links LumenHearing / FluidAudio
#   - LumenBridgeTV (tvOS   18+, focus-based SwiftUI)
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

# Bouke/HAP — Swift HomeKit Accessory Protocol implementation. Used by
# the Phase 5 HomeKit bridge (macOS only — tvOS doesn't expose HAP-server
# capability and gets its accessory list via the macOS Bridge).
HAP_URL = 'https://github.com/Bouke/HAP'
HAP_REVISION = '51e3505a' # last commit on master, 2022-12-31 — tracked by SHA so we know exactly what code we're shipping

hap_pkg = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
hap_pkg.repositoryURL = HAP_URL
hap_pkg.requirement = {
  'kind' => 'revision',
  'revision' => HAP_REVISION
}
project.root_object.package_references << hap_pkg

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

# LorisReports — vendored as a product of Packages/LorisLabsKit. Keep the
# generator aligned with the checked-in project so regeneration cannot undo
# the migration away from the former BugReportKit package.
LORIS_LABS_KIT_DIR = 'Packages/LorisLabsKit'

def add_local_package(project, dir)
  pkg = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  pkg.relative_path = dir
  project.root_object.package_references << pkg
  pkg
end

loris_labs_kit_pkg = add_local_package(project, LORIS_LABS_KIT_DIR) if File.exist?(File.join(LORIS_LABS_KIT_DIR, 'Package.swift'))

# Same exact Foundation version already resolved by LorisLabsKit. Explicit product owner.
foundation_pkg = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
foundation_pkg.repositoryURL = 'https://github.com/lowrisk75/LorisFoundation.git'
foundation_pkg.requirement = { 'kind' => 'exactVersion', 'version' => '0.2.0' }
project.root_object.package_references << foundation_pkg

# FrigateKit — shared with the Lumen app (symlink to the Lumen checkout).
# The Hub reuses its MQTT transition model and MailboxVisitSequence engine
# instead of keeping a second copy. Requires tvOS 18 / macOS 15.
FRIGATE_KIT_DIR = 'Packages/FrigateKit'
frigate_kit_pkg = add_local_package(project, FRIGATE_KIT_DIR)

# LumenHearing — Lumen Hub speech transcription and voices (Parakeet v3,
# pyannote community-1 diarization via FluidAudio, SQLite). Linked ONLY into
# the LumenHub target, never into the App Store LumenBridge app (it would ship
# FluidAudio code and an unused resource bundle). See
# Packages/LumenHearing/README.md and THIRD_PARTY_NOTICES.md.
LUMEN_HEARING_DIR = 'Packages/LumenHearing'
lumen_hearing_pkg = add_local_package(project, LUMEN_HEARING_DIR)

# LumenAssistant — Lumen Hub hands-free assistant (camera mics → rules/LLM →
# safety policy → Home Assistant). Hub only, like LumenHearing.
# See Packages/LumenAssistant/README.md.
LUMEN_ASSISTANT_DIR = 'Packages/LumenAssistant'
lumen_assistant_pkg = add_local_package(project, LUMEN_ASSISTANT_DIR)

# LumenLook — Lumen Hub "Look": after the assistant acts, check the device's
# real state on a camera (area per device, pixel test, vision model fallback).
# Hub only. See Packages/LumenLook/Package.swift.
LUMEN_LOOK_DIR = 'Packages/LumenLook'
lumen_look_pkg = add_local_package(project, LUMEN_LOOK_DIR)

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

# Hub unit tests (XCTest). Kept apart from Tests/, which holds the
# swiftc-only automation fixture harness run by Scripts/.
HUB_TESTS_DIR = File.join(ROOT, 'HubTests')
hub_tests_group = project.new_group('HubTests', 'HubTests')
add_files_recursive(project, hub_tests_group, HUB_TESTS_DIR) if File.directory?(HUB_TESTS_DIR)

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

# --- macOS targets ---
# macOS 15+ because LorisReports requires it. Bridge has
# no users yet so the bump is free.
#
# LumenBridge (App Store) and LumenHub (Developer ID) compile the same
# sources. They are separate targets, not just configurations, because an
# Xcode target cannot link a Swift package product in one configuration only:
# LumenHearing (FluidAudio) must never reach the App Store binary.
def add_bundle_resource(group, target, basename)
  ref = group.recursive_children.find { |f|
    f.is_a?(Xcodeproj::Project::Object::PBXFileReference) && f.path == basename
  }
  target.resources_build_phase.add_file_reference(ref) if ref
end

def mac_app_settings(config_name)
  {
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.lorislabapp.lumenbridge',
    'PRODUCT_NAME' => 'Lumen Bridge',
    'MARKETING_VERSION' => '1.1',
    'CURRENT_PROJECT_VERSION' => '20',
    'MACOSX_DEPLOYMENT_TARGET' => '15.0',
    'SWIFT_VERSION' => '6.0',
    'DEVELOPMENT_TEAM' => 'TDV6D5L785',
    'CODE_SIGN_STYLE' => 'Automatic',
    'CODE_SIGN_ENTITLEMENTS' => 'LumenBridge/Resources/LumenBridge.entitlements',
    'INFOPLIST_FILE' => 'LumenBridge/Resources/Info.plist',
    'LORIS_REPORTS_APNS_ENVIRONMENT' => config_name == 'Debug' ? 'sandbox' : 'production',
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
  }
end

# Lumen Hub: Developer ID / local, no sandbox (LumenHub.entitlements drops the
# App Sandbox so the HomeKit accessory server and sidecars can run). Same
# bundle ID; distinct app name so it never overwrites the App Store app.
def hub_app_settings
  {
    'CODE_SIGN_ENTITLEMENTS' => 'LumenBridge/Resources/LumenHub.entitlements',
    'PRODUCT_NAME' => 'Lumen Hub',
    # Hub keeps its own pilot version track (Developer ID DMG).
    'MARKETING_VERSION' => '0.1.0',
    'CURRENT_PROJECT_VERSION' => '15',
    'PRODUCT_MODULE_NAME' => 'Lumen_Bridge',
    # Homebridge/Node/ffmpeg and hearing code compile only here.
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited) LUMEN_HUB'
  }
end

def add_mac_app(project, name, sources, mac_group)
  target = project.new_target(:application, name, :osx, '15.0')
  sources.each { |f| target.source_build_phase.add_file_reference(f) }
  # Asset catalog — macOS icon. The .xcassets folder is added as a file
  # reference and Xcode picks it up as an asset catalog resource.
  xcassets = mac_group.recursive_children.find { |f|
    f.is_a?(Xcodeproj::Project::Object::PBXFileReference) && f.path == 'Assets.xcassets'
  }
  target.resources_build_phase.add_file_reference(xcassets) if xcassets
  # Bundle resources required by Apple's Asset Validation:
  #   - Localizable.xcstrings — string catalog (compiled to .strings at build)
  #   - PrivacyInfo.xcprivacy — privacy manifest, mandatory since Spring 2024
  add_bundle_resource(mac_group, target, 'Localizable.xcstrings')
  add_bundle_resource(mac_group, target, 'PrivacyInfo.xcprivacy')
  target
end

mac_target = add_mac_app(project, 'LumenBridge', shared_swift + mac_swift, mac_group)
hub_target = add_mac_app(project, 'LumenHub', shared_swift + mac_swift, mac_group)
# Assistant strings: Hub-only table, kept out of Localizable.xcstrings.
add_bundle_resource(mac_group, hub_target, 'Assistant.xcstrings')
add_bundle_resource(mac_group, hub_target, 'Look.xcstrings')

[mac_target, hub_target].each do |target|
  add_package_product(project, target, mqtt_nio_pkg, 'MQTTNIO')
  add_package_product(project, target, hap_pkg, 'HAP')
  add_package_product(project, target, frigate_kit_pkg, 'FrigateKit')
  add_package_product(project, target, lumen_hearing_pkg, 'LumenHearing') if target == hub_target
  add_package_product(project, target, lumen_assistant_pkg, 'LumenAssistant') if target == hub_target
  add_package_product(project, target, lumen_look_pkg, 'LumenLook') if target == hub_target
  add_package_product(project, target, foundation_pkg, 'LorisSecurity')
  add_package_product(project, target, loris_labs_kit_pkg, 'LorisReports') if loris_labs_kit_pkg
  add_package_product(project, target, loris_labs_kit_pkg, 'LorisLabsKit') if loris_labs_kit_pkg
end

mac_target.build_configurations.each { |config| config.build_settings.merge!(mac_app_settings(config.name)) }
hub_target.build_configurations.each do |config|
  config.build_settings.merge!(mac_app_settings(config.name)).merge!(hub_app_settings)
end

# --- tvOS target ---
tv_target = project.new_target(:application, 'LumenBridgeTV', :tvos, '18.0')
(shared_swift + tv_swift).each { |f| tv_target.source_build_phase.add_file_reference(f) }

add_package_product(project, tv_target, mqtt_nio_pkg, 'MQTTNIO')
add_package_product(project, tv_target, frigate_kit_pkg, 'FrigateKit')

# tvOS asset catalog — Brand Assets stack (App Icon layered, App Store
# icon, Top Shelf 1920x720, Top Shelf Wide 2320x720). Required for
# upload — Apple rejects tvOS .ipa without TVTopShelfImage.
tv_xcassets = tv_group.recursive_children.find { |f|
  f.is_a?(Xcodeproj::Project::Object::PBXFileReference) && f.path == 'Assets.xcassets'
}
tv_target.resources_build_phase.add_file_reference(tv_xcassets) if tv_xcassets

add_bundle_resource(tv_group, tv_target, 'Localizable.xcstrings')
add_bundle_resource(tv_group, tv_target, 'PrivacyInfo.xcprivacy')

tv_target.build_configurations.each do |config|
  config.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.lorislabapp.lumenbridge',
    'PRODUCT_NAME' => 'Lumen Bridge',
    'MARKETING_VERSION' => '0.1.0',
    'CURRENT_PROJECT_VERSION' => '15',
    'TVOS_DEPLOYMENT_TARGET' => '18.0',
    'SWIFT_VERSION' => '6.0',
    'DEVELOPMENT_TEAM' => 'TDV6D5L785',
    'CODE_SIGN_STYLE' => 'Automatic',
    'CODE_SIGN_ENTITLEMENTS' => 'LumenBridgeTV/Resources/LumenBridgeTV.entitlements',
    'INFOPLIST_FILE' => 'LumenBridgeTV/Resources/Info.plist',
    'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/Frameworks',
    # tvOS uses a Brand Assets stack as the app icon source. The compiler
    # key takes the name of the brand-asset stack (without the
    # `.brandassets` suffix) — NOT the name of an inner imagestack like
    # "App Icon". Pointing at "App Icon" silently skips Assets.car
    # production, which causes ASC error 90471 ("Missing App Store Icon")
    # at upload time.
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'Brand Assets',
    'ENABLE_PREVIEWS' => 'YES',
    'INFOPLIST_KEY_NSHumanReadableCopyright' => 'Copyright © 2026 LorisLabs',
    'INFOPLIST_KEY_LSApplicationCategoryType' => 'public.app-category.utilities',
    'SDKROOT' => 'appletvos',
    'SUPPORTED_PLATFORMS' => 'appletvos appletvsimulator',
    'TARGETED_DEVICE_FAMILY' => '3'
  )
end

project.save

# --- Unit tests (hosted by the macOS apps) ---
# LumenBridgeTests runs in the App Store app, LumenHubTests in Lumen Hub
# (same files; LUMEN_HUB-only tests compile only in the latter).
# FrigateKit / MQTTNIO are static: the host app already links them and
# BUNDLE_LOADER exposes their symbols, so linking again would duplicate them.
hub_tests_swift = swift_files_in(hub_tests_group)
hub_tests_json = hub_tests_group.recursive_children.select { |f|
  f.is_a?(Xcodeproj::Project::Object::PBXFileReference) && f.path.end_with?('.json')
}
def add_test_target(project, name, host, app_name, files, resources, hub)
  t = project.new_target(:unit_test_bundle, name, :osx, '15.0')
  files.each { |f| t.source_build_phase.add_file_reference(f) }
  resources.each { |f| t.resources_build_phase.add_file_reference(f) }
  t.add_dependency(host)
  t.build_configurations.each do |config|
    config.build_settings.merge!(
      'PRODUCT_BUNDLE_IDENTIFIER' => 'com.lorislabapp.lumenbridge.tests',
      'MACOSX_DEPLOYMENT_TARGET' => '15.0',
      'SWIFT_VERSION' => '6.0',
      'DEVELOPMENT_TEAM' => 'TDV6D5L785',
      'CODE_SIGN_STYLE' => 'Automatic',
      'GENERATE_INFOPLIST_FILE' => 'YES',
      'TEST_HOST' => "$(BUILT_PRODUCTS_DIR)/#{app_name}.app/Contents/MacOS/#{app_name}",
      'BUNDLE_LOADER' => '$(TEST_HOST)',
      'SDKROOT' => 'macosx'
    )
    config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) LUMEN_HUB' if hub
  end
  t
end
hub_tests_target = add_test_target(project, 'LumenBridgeTests', mac_target, 'Lumen Bridge', hub_tests_swift, hub_tests_json, false)
lumen_hub_tests_target = add_test_target(project, 'LumenHubTests', hub_target, 'Lumen Hub', hub_tests_swift, hub_tests_json, true)

# --- "Hub" configuration ---
# Kept so `-configuration Hub` keeps working: on the LumenHub target it is the
# Developer ID release build; on the other targets it equals Release.
project.add_build_configuration('Hub', :release)
[mac_target, hub_target, tv_target, hub_tests_target, lumen_hub_tests_target].each do |target|
  release = target.build_configurations.find { |c| c.name == 'Release' }
  hub = target.build_configurations.find { |c| c.name == 'Hub' }
  hub ||= target.add_build_configuration('Hub', :release)
  hub.build_settings = release.build_settings.dup
end
[mac_target, hub_target].each do |target|
  target.build_configurations.find { |c| c.name == 'Debug' }.build_settings['ENABLE_TESTABILITY'] = 'YES'
end
project.save

# Schemes — one per target so xcodebuild can build each independently.
[mac_target, tv_target].each do |target|
  scheme = Xcodeproj::XCScheme.new
  scheme.add_build_target(target)
  scheme.set_launch_target(target)
  scheme.add_test_target(hub_tests_target) if target == mac_target
  scheme.save_as(PROJECT_PATH, target.name, true)
end

# Lumen Hub scheme: the LumenHub target, "Hub" configuration (no sandbox).
hub_scheme = Xcodeproj::XCScheme.new
hub_scheme.add_build_target(hub_target)
hub_scheme.set_launch_target(hub_target)
hub_scheme.add_test_target(lumen_hub_tests_target)
hub_scheme.launch_action.build_configuration = 'Hub'
hub_scheme.profile_action.build_configuration = 'Hub'
hub_scheme.archive_action.build_configuration = 'Hub'
hub_scheme.save_as(PROJECT_PATH, 'LumenHub', true)

puts "Generated #{PROJECT_PATH}"
puts "Targets:"
puts "  - LumenBridge    (macOS 15+)  — #{(shared_swift + mac_swift).size} swift files (App Store, no LumenHearing)"
puts "  - LumenHub       (macOS 15+)  — #{(shared_swift + mac_swift).size} swift files (Developer ID, LUMEN_HUB + LumenHearing)"
puts "  - LumenBridgeTV  (tvOS 17+)   — #{(shared_swift + tv_swift).size} swift files"
