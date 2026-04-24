#!/usr/bin/env ruby
# Generates the LumenBridge.xcodeproj from scratch.
# Layout matches what's on disk under ~/GitHub/lumen-bridge/LumenBridge/.

require 'xcodeproj'
require 'fileutils'

ROOT = File.expand_path('~/GitHub/lumen-bridge')
PROJECT_PATH = "#{ROOT}/LumenBridge.xcodeproj"
SRC_ROOT = "#{ROOT}/LumenBridge"

# Nuke any existing project (idempotent re-generation).
FileUtils.rm_rf(PROJECT_PATH)

project = Xcodeproj::Project.new(PROJECT_PATH)

# Top-level group for the source code on disk.
src_group = project.new_group('LumenBridge', 'LumenBridge')

# Recursively add all Swift/plist/entitlements files from disk into the project
# under the matching group hierarchy. Keeps folders on disk 1:1 with Xcode groups.
def add_files_recursive(project, parent_group, path_on_disk)
  Dir.glob("#{path_on_disk}/*").sort.each do |entry|
    basename = File.basename(entry)
    if File.directory?(entry)
      sub = parent_group.new_group(basename, basename)
      add_files_recursive(project, sub, entry)
    else
      parent_group.new_file(basename)
    end
  end
end

add_files_recursive(project, src_group, SRC_ROOT)

# macOS app target.
target = project.new_target(:application, 'LumenBridge', :osx, '14.0')

# Attach Swift source files to Sources build phase.
swift_files = []
src_group.recursive_children.each do |f|
  next unless f.is_a?(Xcodeproj::Project::Object::PBXFileReference)
  next unless f.path.end_with?('.swift')
  swift_files << f
end
swift_files.each { |f| target.source_build_phase.add_file_reference(f) }

# Resources (Info.plist is set via INFOPLIST_FILE, not as a resource file).
# Nothing else to add for now — assets come later.

# Build settings
target.build_configurations.each do |config|
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
    'INFOPLIST_KEY_LSUIElement' => 'YES'
  )
end

# Scheme so `xcodebuild -scheme LumenBridge` works.
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(PROJECT_PATH, 'LumenBridge', true)

puts "Generated #{PROJECT_PATH}"
puts "Targets: #{project.targets.map(&:name).join(', ')}"
puts "Sources: #{swift_files.size} Swift files"
