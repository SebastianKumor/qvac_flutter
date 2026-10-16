# qvac_flutter ships its iOS binaries as Swift Package Manager binary targets only.
Pod::Spec.new do |s|
  s.name     = 'qvac_flutter'
  s.version  = '0.1.0'
  s.summary  = 'Unofficial Flutter plugin for QVAC on-device speech to text.'
  s.homepage = 'https://github.com/SebastianKumor/qvac_flutter'
  s.license  = { :file => '../LICENSE' }
  s.author   = { 'Sebastian Kumor' => 'basty191120@gmail.com' }
  s.source   = { :path => '.' }
  s.platform = :ios, '15.0'

  raise 'qvac_flutter needs Swift Package Manager on iOS (Flutter 3.44 or newer). ' \
        'Turn it on with: flutter config --enable-swift-package-manager'
end
