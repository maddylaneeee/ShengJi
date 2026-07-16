#!/usr/bin/env ruby

require "xcodeproj"
require "fileutils"

root = File.expand_path(__dir__)
project_path = File.join(root, "LocalScribe.xcodeproj")
FileUtils.rm_rf(project_path)

project = Xcodeproj::Project.new(project_path)
project.root_object.attributes["LastSwiftUpdateCheck"] = "2660"
project.root_object.attributes["LastUpgradeCheck"] = "2660"
project.root_object.development_region = "zh-Hans"
project.root_object.known_regions = ["zh-Hans", "en", "Base"]

target = project.new_target(:application, "LocalScribe", :osx, "15.5")
target.product_reference.name = "声迹.app"

main_group = project.main_group.new_group("LocalScribe", "LocalScribe")
source_files = %w[
  LocalScribeApp.swift
  Models/TranscriptionModels.swift
  Services/LanguageCatalog.swift
  Services/Localization.swift
  Services/AudioPipeline.swift
  Services/AppStoragePaths.swift
  Services/AppInfo.swift
  Services/AppUpdateController.swift
  Services/LongTaskStorage.swift
  Services/SpeechModelStore.swift
  Services/WhisperModelManager.swift
  Services/WhisperEngine.swift
  Services/StreamingText.swift
  Services/SherpaOnnxEngine.swift
  Services/RecoveryStore.swift
  Services/ExportService.swift
  Services/TranscriptImport.swift
  Services/TranscriptionSessionModel.swift
  Services/CLIController.swift
  Services/AppleTranslation.swift
  Services/NLLBTranslation.swift
  Services/NLLBModelManager.swift
  Services/LiveCaptionController.swift
  Views/RootView.swift
  Views/StartView.swift
  Views/TranscriptionView.swift
  Views/TranscriptEditingView.swift
  Views/LiveCaptionPanelView.swift
  Views/SettingsView.swift
]

source_files.each do |relative_path|
  reference = main_group.new_file(relative_path)
  target.source_build_phase.add_file_reference(reference)
end

tests_group = project.main_group.new_group("LocalScribeTests", "LocalScribeTests")
test_target = project.new_target(:unit_test_bundle, "LocalScribeTests", :osx, "15.5")
test_target.add_dependency(target)
%w[
  TranslationStructureTests.swift
  LongTaskStorageTests.swift
  WhisperPipelineTests.swift
  TranscriptImportAndEditingTests.swift
  LocalizationTests.swift
].each do |relative_path|
  reference = tests_group.new_file(relative_path)
  test_target.source_build_phase.add_file_reference(reference)
end

test_target.build_configurations.each do |config|
  settings = config.build_settings
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "ca.lixinchen.localscribe.tests"
  settings["GENERATE_INFOPLIST_FILE"] = "YES"
  settings["SWIFT_VERSION"] = "5.0"
  settings["HEADER_SEARCH_PATHS"] = "$(inherited) $(PROJECT_DIR)/Vendor/WhisperMetal/include"
  settings["LIBRARY_SEARCH_PATHS"] = "$(inherited) $(PROJECT_DIR)/Vendor/WhisperMetal/lib"
  settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/LocalScribe.app/Contents/MacOS/LocalScribe"
  settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
  settings["CODE_SIGNING_ALLOWED"] = "NO"
end

resources_group = main_group.new_group("Resources", "Resources")
resources_group.new_file("Info.plist")
resources_group.new_file("LocalScribe.entitlements")

%w[Localizable.strings InfoPlist.strings].each do |resource_name|
  variant_group = resources_group.new_variant_group(resource_name)
  {
    "zh-Hans" => "zh-Hans.lproj/#{resource_name}",
    "en" => "en.lproj/#{resource_name}",
  }.each do |language, relative_path|
    reference = variant_group.new_file(relative_path)
    reference.name = language
  end
  target.resources_build_phase.add_file_reference(variant_group)
end

assets_path = File.join(root, "LocalScribe", "Resources", "Assets.xcassets")
if File.directory?(assets_path)
  assets_ref = resources_group.new_file("Assets.xcassets")
  target.resources_build_phase.add_file_reference(assets_ref)
end

%w[Speech AVFoundation CoreText Metal Accelerate ScreenCaptureKit Translation].each do |framework_name|
  reference = project.frameworks_group.new_file("System/Library/Frameworks/#{framework_name}.framework")
  reference.source_tree = "SDKROOT"
  target.frameworks_build_phase.add_file_reference(reference)
end

vendor_group = project.main_group.new_group("Vendor", "Vendor")
whisper_group = vendor_group.new_group("WhisperMetal", "WhisperMetal")
whisper_library = whisper_group.new_file("lib/libWhisperMetal.a")
target.frameworks_build_phase.add_file_reference(whisper_library)

whisper_vad_reference = vendor_group.new_file("WhisperVAD")
whisper_vad_reference.last_known_file_type = "folder"
target.resources_build_phase.add_file_reference(whisper_vad_reference)

sherpa_reference = vendor_group.new_file("SherpaOnnx")
sherpa_reference.last_known_file_type = "folder"
target.resources_build_phase.add_file_reference(sherpa_reference)

nllb_reference = vendor_group.new_file("NLLBTranslator")
nllb_reference.last_known_file_type = "folder"
target.resources_build_phase.add_file_reference(nllb_reference)

project.build_configurations.each do |config|
  config.build_settings["MACOSX_DEPLOYMENT_TARGET"] = "15.5"
  config.build_settings["SWIFT_VERSION"] = "5.0"
end

target.build_configurations.each do |config|
  settings = config.build_settings
  settings["ARCHS"] = "arm64"
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "ca.lixinchen.localscribe"
  settings["PRODUCT_NAME"] = "LocalScribe"
  settings["INFOPLIST_FILE"] = "LocalScribe/Resources/Info.plist"
  settings["CODE_SIGN_ENTITLEMENTS"] = "LocalScribe/Resources/LocalScribe.entitlements"
  settings["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"] = "NO"
  settings["CODE_SIGN_STYLE"] = "Automatic"
  settings["CODE_SIGN_IDENTITY"] = "-"
  settings["DEVELOPMENT_TEAM"] = ""
  settings["GENERATE_INFOPLIST_FILE"] = "NO"
  settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  settings["ENABLE_APP_SANDBOX"] = "NO"
  settings["ENABLE_USER_SELECTED_FILES"] = "readwrite"
  settings["ENABLE_HARDENED_RUNTIME"] = "YES"
  settings["SWIFT_EMIT_LOC_STRINGS"] = "YES"
  settings["SWIFT_STRICT_CONCURRENCY"] = "targeted"
  settings["HEADER_SEARCH_PATHS"] = "$(inherited) $(PROJECT_DIR)/Vendor/WhisperMetal/include"
  settings["LIBRARY_SEARCH_PATHS"] = "$(inherited) $(PROJECT_DIR)/Vendor/WhisperMetal/lib"
  settings["OTHER_LDFLAGS"] = "$(inherited) -lc++"
  settings["LD_RUNPATH_SEARCH_PATHS"] = "$(inherited) @executable_path/../Frameworks"
end

project.save
puts "Created #{project_path}"
