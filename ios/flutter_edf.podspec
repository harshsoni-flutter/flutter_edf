#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_edf.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_edf'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter project.'
  s.description      = <<-DESC
A new Flutter project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*.{h,m,swift}', 'Classes/edflib.{c,h}' # <- Add your C files here
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Required for C/C++ libraries in FFI plugins
  s.compiler_flags = '-fembed-bitcode'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
   'OTHER_CFLAGS' => '$(inherited) -Wno-int-conversion -Wno-pointer-sign',
       'OTHER_LDFLAGS' => '$(inherited) -lsqlite3 -lz' # Add any required system libraries (like zlib if edflib uses it)}
  s.swift_version = '5.0'




  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'flutter_edf_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
