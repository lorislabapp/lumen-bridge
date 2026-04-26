#!/usr/bin/env ruby
# BugReportKit onboarding — adopts the package into a new LorisLabs app in
# one command. Idempotent: safe to re-run.
#
# What it does, in order:
#   1. Copies Packages/BugReportKit into <app>/Packages/BugReportKit
#   2. Adds a local Swift Package reference to the app's .xcodeproj
#   3. Links the BugReportKit product to the app's main target
#   4. Generates <app>/<target>/Services/<App>BugReportContext.swift from
#      the template below (with the right protocol conformance)
#   5. Adds that new .swift file to the target's Sources build phase
#   6. Prints the snippet to add to the host app's SettingsView (one
#      NavigationLink — couldn't auto-edit the host's Settings file
#      because every app's Settings layout is different)
#
# Usage from any LorisLabs app dir:
#
#   ruby Packages/BugReportKit/scripts/onboard.rb \
#     --app-path /Users/kevin/GitHub/TypeMetrics \
#     --xcodeproj "TypeMetrics.xcodeproj" \
#     --target-name TypeMetrics \
#     --app-name "TypeMetrics" \
#     [--source /Users/kevin/GitHub/Lumen\ for\ Frigate/Packages/BugReportKit]
#
# If the target's source directory uses Xcode 16 file system synchronized
# groups (Lumen's pattern), step 5 is a no-op — Xcode picks up the new
# file automatically.

require 'xcodeproj'
require 'fileutils'
require 'optparse'

# ---------------------------------------------------------------------------
# Args

opts = {
  source: File.expand_path('..', __dir__),
}
OptionParser.new do |op|
  op.banner = "Usage: ruby onboard.rb --app-path <dir> --xcodeproj <file> --target-name <name> --app-name <pretty>"
  op.on('--app-path PATH', 'Absolute path to the host app repo root') { |v| opts[:app_path] = v }
  op.on('--xcodeproj NAME', 'Xcode project filename relative to app-path (e.g. "TypeMetrics.xcodeproj")') { |v| opts[:xcodeproj] = v }
  op.on('--target-name NAME', 'Xcode app target name (e.g. "TypeMetrics", "Clasp")') { |v| opts[:target_name] = v }
  op.on('--app-name NAME', 'Pretty app name for the generated context file (e.g. "TypeMetrics")') { |v| opts[:app_name] = v }
  op.on('--source PATH', "Source BugReportKit dir (default: #{opts[:source]})") { |v| opts[:source] = File.expand_path(v) }
  op.on('-h', '--help') { puts op; exit }
end.parse!

%i[app_path xcodeproj target_name app_name source].each do |k|
  abort "Missing --#{k.to_s.tr('_', '-')}" unless opts[k]
end

APP_PATH = File.expand_path(opts[:app_path])
PROJECT_PATH = File.join(APP_PATH, opts[:xcodeproj])
TARGET_NAME = opts[:target_name]
APP_NAME = opts[:app_name]
SOURCE_PACKAGE = File.expand_path(opts[:source])

abort "App dir not found: #{APP_PATH}" unless Dir.exist?(APP_PATH)
abort "xcodeproj not found: #{PROJECT_PATH}" unless Dir.exist?(PROJECT_PATH)
abort "Source package not found: #{SOURCE_PACKAGE}" unless Dir.exist?(File.join(SOURCE_PACKAGE, 'Sources'))

# ---------------------------------------------------------------------------
# Step 1 — copy the package

dest_package = File.join(APP_PATH, 'Packages', 'BugReportKit')
if Dir.exist?(dest_package)
  puts "  ↺  Packages/BugReportKit already present, refreshing source files (Package.swift / Sources / Tests)…"
  %w[Package.swift Sources Tests].each do |sub|
    FileUtils.rm_rf(File.join(dest_package, sub))
    src = File.join(SOURCE_PACKAGE, sub)
    if File.exist?(src)
      FileUtils.cp_r(src, File.join(dest_package, sub))
    end
  end
else
  FileUtils.mkdir_p(File.join(APP_PATH, 'Packages'))
  FileUtils.cp_r(SOURCE_PACKAGE, dest_package)
  puts "  +  Copied BugReportKit → #{dest_package}"
end

# Strip the package's build artifacts so the host doesn't carry them.
%w[.build .swiftpm].each do |dir|
  FileUtils.rm_rf(File.join(dest_package, dir))
end

# Also copy this onboard.rb into the dest so future re-runs work locally.
script_dest_dir = File.join(dest_package, 'scripts')
FileUtils.mkdir_p(script_dest_dir)
FileUtils.cp(__FILE__, File.join(script_dest_dir, 'onboard.rb'))

# ---------------------------------------------------------------------------
# Step 2 + 3 — register the local package + link to target

project = Xcodeproj::Project.open(PROJECT_PATH)
target = project.targets.find { |t| t.name == TARGET_NAME }
abort "Could not find target '#{TARGET_NAME}' in #{PROJECT_PATH}" unless target

pkg_relative = 'Packages/BugReportKit'
existing_pkg_ref = project.root_object.package_references.find do |ref|
  ref.respond_to?(:relative_path) && ref.relative_path == pkg_relative
end

if existing_pkg_ref
  puts "  ✓  Local SPM reference already present"
  pkg_ref = existing_pkg_ref
else
  pkg_ref = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  pkg_ref.relative_path = pkg_relative
  project.root_object.package_references << pkg_ref
  puts "  +  Added local SPM reference"
end

already_linked = target.package_product_dependencies.any? { |dep| dep.product_name == 'BugReportKit' }
if already_linked
  puts "  ✓  Target '#{TARGET_NAME}' already links BugReportKit"
else
  product_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product_dep.product_name = 'BugReportKit'
  product_dep.package = pkg_ref
  target.package_product_dependencies << product_dep

  fw_phase = target.frameworks_build_phase || target.new_frameworks_build_phase
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product_dep
  fw_phase.files << build_file
  puts "  +  Linked BugReportKit to target '#{TARGET_NAME}'"
end

# ---------------------------------------------------------------------------
# Step 4 — generate the context file

context_filename = "#{APP_NAME}BugReportContext.swift"
services_dir = File.join(APP_PATH, TARGET_NAME, 'Services')
FileUtils.mkdir_p(services_dir)
context_path = File.join(services_dir, context_filename)

template = <<~SWIFT
  import Foundation
  import BugReportKit
  import SwiftUI

  #if canImport(FoundationModels)
  import FoundationModels
  #endif

  /// #{APP_NAME}'s adoption of `BugReportKit`. Generated by `onboard.rb` on
  /// #{Time.now.utc.strftime('%Y-%m-%d')}. Customize freely after generation —
  /// re-running the onboarding script does NOT overwrite this file.
  ///
  /// Defaults:
  ///   • `connectionLog`: empty (no HTTP request log) — replace with a wrapper
  ///     over your own log if your app has one.
  ///   • `domainTools`:   empty — add app-specific Foundation Models tools
  ///     here as the bug-report flow accumulates real reports and you spot
  ///     patterns (e.g. GetCloudKitContextTool, GetSubscriptionStateTool).
  ///   • `theme`:         system Apple styling — replace with a wrapper over
  ///     your design tokens for a branded look.
  ///   • `generateBundle`: writes a minimal markdown summary to the temp
  ///     directory. Replace with your existing diagnostic bundle producer
  ///     once you have one.
  struct #{APP_NAME}BugReportContext: BugReportContextProvider {

      init() {}

      var connectionLog: any ConnectionLogProvider {
          // No HTTP request log on this app yet.
          // Swap for a real wrapper when you have one — see Lumen's
          // `LumenConnectionLogBridge` for the pattern.
          EmptyConnectionLogProvider()
      }

      var theme: any BugReportTheme {
          // Apple system styling. Replace with your design system if you have
          // one (e.g. Lumen passes a `VigilUIBugReportTheme` that maps onto
          // its dark-glass design tokens).
          DefaultBugReportTheme()
      }

      var domainSystemPromptAddendum: String {
          \"\"\"
          You are inside #{APP_NAME}. Edit this string to give the on-device
          model a short summary of what kind of app it is, what bug categories
          are common, and what concepts to use. Improving this prompt is the
          highest-leverage way to improve triage accuracy.
          \"\"\"
      }

      #if canImport(FoundationModels)
      // NOTE: fully qualify `FoundationModels.Tool` to avoid shadow collision
      // if your app has its own type named `Tool` (Clasp does — for snippet
      // templates).
      @available(iOS 26, macOS 26, visionOS 26, *)
      var domainTools: [any FoundationModels.Tool] {
          []
      }
      #endif

      func generateBundle(transcript: String?) async -> URL? {
          var lines: [String] = []
          lines.append("# #{APP_NAME} — Bug Report")
          lines.append("")
          lines.append("**Sent:** \\(ISO8601DateFormatter().string(from: Date()))")
          if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
             let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
              lines.append("**App:** \\(v) (\\(b))")
          }
          lines.append("")
          if let transcript {
              lines.append(transcript)
          }
          let content = lines.joined(separator: "\\n")
          let url = FileManager.default.temporaryDirectory
              .appendingPathComponent("#{APP_NAME.downcase}-bug-report-\\(Int(Date().timeIntervalSince1970)).md")
          do {
              try content.data(using: .utf8)?.write(to: url)
              return url
          } catch {
              return nil
          }
      }
  }
SWIFT

if File.exist?(context_path)
  puts "  ✓  #{context_filename} already exists, leaving as-is (re-running is safe)"
else
  File.write(context_path, template)
  puts "  +  Wrote #{context_path}"
end

# ---------------------------------------------------------------------------
# Step 5 — add the file to the target if it isn't picked up by a synchronized group

# Detect synchronized groups. If the target's source dir is synchronized,
# Xcode auto-includes new files and we don't need to touch project.pbxproj.
sync_paths = project.root_object.project_references.map { |_| nil }.compact
synchronized = project.main_group.recursive_children.any? do |obj|
  obj.is_a?(Xcodeproj::Project::Object::PBXFileSystemSynchronizedRootGroup) &&
    obj.path == TARGET_NAME
end

if synchronized
  puts "  ✓  Target '#{TARGET_NAME}' uses Xcode 16 synchronized groups — file auto-detected"
else
  rel_to_project_dir = "#{TARGET_NAME}/Services/#{context_filename}"
  sources_phase = target.source_build_phase
  already_added = sources_phase.files_references.any? { |ref| ref.respond_to?(:path) && ref.path&.end_with?(context_filename) }
  if already_added
    puts "  ✓  #{context_filename} already in '#{TARGET_NAME}' Sources"
  else
    target_group = project.main_group.find_subpath(TARGET_NAME, true)
    services_group = target_group.children.find { |g| g.respond_to?(:path) && g.path == 'Services' } \
      || target_group.new_group('Services', 'Services')
    file_ref = services_group.new_file(context_filename)
    target.add_file_references([file_ref])
    puts "  +  Added #{context_filename} to '#{TARGET_NAME}' Sources"
  end
end

project.save

# ---------------------------------------------------------------------------
# Step 6 — final instructions

puts ""
puts "─" * 70
puts "✓ #{APP_NAME} is now BugReportKit-ready."
puts "─" * 70
puts ""
puts "Last manual step — add the entry to your SettingsView. Drop this where"
puts "it fits (a Help section / tab is the conventional spot):"
puts ""
puts "    import BugReportKit"
puts ""
puts "    NavigationLink {"
puts "        BugReportView(provider: #{APP_NAME}BugReportContext())"
puts "    } label: {"
puts "        Label(\"Report a Bug\", systemImage: \"ant.fill\")"
puts "    }"
puts ""
puts "Then build the app target — should be clean."
puts ""
puts "When you accumulate real bug reports, edit"
puts "  #{TARGET_NAME}/Services/#{context_filename}"
puts "to:"
puts "  • improve domainSystemPromptAddendum (the AI's app-context briefing)"
puts "  • add app-specific @available(iOS 26+) Tool implementations"
puts "  • wire your real diagnostic bundle into generateBundle(transcript:)"
puts ""
