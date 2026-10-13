platform :ios, '15.0'
use_frameworks!

target 'AIGlass' do
  pod 'WechatOpenSDK-XCFramework'
end

# Xcode 27 no longer builds the SDK's declared iOS 12 target.
# Keep dependencies at the app's existing iOS 15 minimum.
post_install do |installer|
  minimum = Gem::Version.new('15.0')
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      deployment = config.build_settings['IPHONEOS_DEPLOYMENT_TARGET']
      if deployment && Gem::Version.new(deployment) < minimum
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = minimum.to_s
      end
    end
  end
end
