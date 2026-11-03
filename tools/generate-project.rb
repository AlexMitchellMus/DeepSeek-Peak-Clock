#!/usr/bin/env ruby
# Generates native/DeepSeekTracker.xcodeproj.
#
# Usage (needs the xcodeproj gem, installed into .tmp/gems by the repo setup):
#   export GEM_HOME=$PWD/.tmp/gems GEM_PATH=$PWD/.tmp/gems
#   ruby tools/generate-project.rb
#
# The project is intentionally dependency-free: DeepSeekCore sources are added
# as plain file references (no SwiftPM package), because SwiftPM's package
# resolution writes to ~/Library and is blocked in this environment.

require 'xcodeproj'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
NATIVE = File.join(ROOT, 'native')
PROJECT_PATH = File.join(NATIVE, 'DeepSeekTracker.xcodeproj')

APP_NAME = 'DeepSeekTracker'
APP_BUNDLE = 'com.deepseektracker.app'
WIDGET_NAME = 'DeepSeekTrackerWidget'
WIDGET_BUNDLE = 'com.deepseektracker.app.widget'
DEPLOYMENT = '14.0'
SWIFT_VERSION = '5.0'

def glob(dir)
  Dir.glob(File.join(dir, '**', '*.swift')).sort
end

def rel(path)
  path.sub("#{NATIVE}/", '')
end

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes['LastSwiftUpdateCheck'] = '2700'
project.root_object.attributes['LastUpgradeCheck'] = '2700'

app_group = project.main_group.new_group('App')
widget_group = project.main_group.new_group('Widget')
shared_group = project.main_group.new_group('Shared')
core_group = project.main_group.new_group('Core')

app_files = glob(File.join(NATIVE, 'App')).map { |p| app_group.new_reference(rel(p)) }
widget_files = glob(File.join(NATIVE, 'Widget')).map do |p|
  # Info.plist is referenced but not compiled
  widget_group.new_reference(rel(p))
end
shared_files = glob(File.join(NATIVE, 'Shared')).map { |p| shared_group.new_reference(rel(p)) }
core_files = glob(File.join(NATIVE, 'DeepSeekCore', 'Sources', 'DeepSeekCore')).map do |p|
  core_group.new_reference(rel(p))
end


def settings(target, extra = {})
  target.build_configurations.each do |config|
    config.build_settings.merge!(extra)
  end
end

def base_settings
  {
    'SWIFT_VERSION' => SWIFT_VERSION,
    'MACOSX_DEPLOYMENT_TARGET' => DEPLOYMENT,
    'SDKROOT' => 'macosx',
    'SUPPORTED_PLATFORMS' => 'macosx',
    # Left at Xcode defaults (automatic signing / "Sign to Run Locally") so
    # opening the project and pressing Run just works with a personal team.
    'ENABLE_HARDENED_RUNTIME' => 'NO',
    'SWIFT_EMIT_LOC_STRINGS' => 'NO',
    'SWIFT_STRICT_CONCURRENCY' => 'minimal',
    # The Swift macro plugin server cannot nest a sandbox inside this environment;
    # same reason SwiftPM needs --disable-sandbox here.
    'OTHER_SWIFT_FLAGS' => '-disable-sandbox ' \
      '-file-prefix-map $(SRCROOT)=/repo -file-prefix-map $(OBJROOT)=/build ' \
      '-debug-prefix-map $(SRCROOT)=/repo -debug-prefix-map $(OBJROOT)=/build',
    'CLANG_ENABLE_MODULES' => 'YES',
    'ALWAYS_SEARCH_USER_PATHS' => 'NO',
    'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO',
    'DEAD_CODE_STRIPPING' => 'YES',
    'ONLY_ACTIVE_ARCH' => 'YES',
    'ARCHS' => '$(ARCHS_STANDARD)',
  }
end

# ---------------------------------------------------------------- app target
app = project.new_target(:application, APP_NAME, :osx, DEPLOYMENT)
app.build_configurations.each do |config|
  config.build_settings.merge!(base_settings)
  config.build_settings.merge!(
    'PRODUCT_NAME' => APP_NAME,
    'PRODUCT_BUNDLE_IDENTIFIER' => APP_BUNDLE,
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'INFOPLIST_FILE' => 'App/Info.plist',
    'ASSETCATALOG_COMPILER_APPICON_NAME' => '',
    'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/../Frameworks',
    'COMBINE_HIDPI_IMAGES' => 'YES',
    'MARKETING_VERSION' => '1.0',
    'CURRENT_PROJECT_VERSION' => '7',
  )
  if config.name == 'Debug'
    config.build_settings['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone'
    config.build_settings['GCC_OPTIMIZATION_LEVEL'] = '0'
  end
end
(app_files + shared_files + core_files).each { |f| app.add_file_references([f]) }

# --------------------------------------------------------------- widget target
widget = project.new_target(:app_extension, WIDGET_NAME, :osx, DEPLOYMENT)
widget.build_configurations.each do |config|
  config.build_settings.merge!(base_settings)
  config.build_settings.merge!(
    'PRODUCT_NAME' => WIDGET_NAME,
    'PRODUCT_BUNDLE_IDENTIFIER' => WIDGET_BUNDLE,
    'INFOPLIST_FILE' => 'Widget/Info.plist',
    'APPLICATION_EXTENSION_API_ONLY' => 'YES',
    'SKIP_INSTALL' => 'YES',
    'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/../../../../Frameworks @executable_path/../Frameworks',
    'MARKETING_VERSION' => '1.0',
    'CURRENT_PROJECT_VERSION' => '7',
    'CODE_SIGN_ENTITLEMENTS' => 'Widget/DeepSeekTrackerWidget.entitlements',
  )
end
(widget_files.select { |f| f.path.to_s.end_with?('.swift') } + shared_files + core_files).each do |f|
  widget.add_file_references([f])
end
# Keep plists in the project tree for editing, but never in a build phase.
widget_files.select { |f| f.path.to_s.end_with?('.plist') }.each { |f| f.include_in_index = '0' }

app.add_dependency(widget)

# Embed the extension in PlugIns/.
embed = app.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = '13' # PlugIns
embed.dst_path = ''
embed.add_file_reference(widget.product_reference)

# ----------------------------------------------------------------- schemes
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_build_target(widget)
scheme.set_launch_target(app)
scheme.save_as(project.path, APP_NAME, true)

project.save

puts "wrote #{PROJECT_PATH}"
puts "  app sources:    #{app_files.size + shared_files.size + core_files.size}"
puts "  widget sources: #{widget_files.select { |f| f.path.to_s.end_with?('.swift') }.size + shared_files.size + core_files.size}"
puts "  core files:     #{core_files.map { |f| rel(f.real_path) }.join(', ')}"
