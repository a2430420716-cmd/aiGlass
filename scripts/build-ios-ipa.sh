#!/bin/bash
set -euo pipefail
umask 077

mkdir -p build/logs build/ipa
python3 - <<'PY'
import base64, os, pathlib
root = pathlib.Path(os.environ['RUNNER_TEMP'])
for name, filename in [('IOS_CERTIFICATE_BASE64', 'aiglass-certificate.p12'),
                       ('IOS_PROFILE_BASE64', 'aiglass-profile.mobileprovision')]:
    value = ''.join(os.environ[name].split())
    (root / filename).write_bytes(base64.b64decode(value, validate=True))
PY

keychain_path="$RUNNER_TEMP/aiglass-signing.keychain-db"
keychain_password=$(openssl rand -hex 24)
security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$RUNNER_TEMP/aiglass-certificate.p12" -P "$IOS_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$keychain_path" >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain_path" >/dev/null
security list-keychains -d user -s "$keychain_path" "$HOME/Library/Keychains/login.keychain-db"
security cms -D -i "$RUNNER_TEMP/aiglass-profile.mobileprovision" > "$RUNNER_TEMP/aiglass-profile.plist"

python3 - <<'PY'
import datetime, hashlib, os, pathlib, plistlib, re, shutil, subprocess
root = pathlib.Path(os.environ['RUNNER_TEMP'])
profile = plistlib.loads((root / 'aiglass-profile.plist').read_bytes())
bundle = 'uni.app.UNI03B27DD'
team = profile['TeamIdentifier'][0]
uuid = profile['UUID']
assert re.fullmatch(r'[0-9A-Fa-f-]{36}', uuid), 'Invalid profile UUID'
assert profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), '描述文件已过期'
entitlements = profile['Entitlements']
prefix = profile['ApplicationIdentifierPrefix'][0]
assert entitlements.get('application-identifier') == prefix + '.' + bundle, '描述文件不匹配 App Bundle ID'
required = plistlib.loads(pathlib.Path('AIGlass/AIGlass.entitlements').read_bytes())
for key, value in required.items():
    actual = entitlements.get(key)
    if isinstance(value, list):
        assert actual == '*' or (isinstance(actual, list) and ('*' in actual or set(value).issubset(actual))), '描述文件缺少权限: ' + key
    else:
        assert actual == value, '描述文件缺少权限: ' + key
method = os.environ['EXPORT_METHOD']
devices = bool(profile.get('ProvisionedDevices'))
debugging = bool(entitlements.get('get-task-allow'))
enterprise = bool(profile.get('ProvisionsAllDevices'))
if method == 'debugging':
    assert devices and debugging, '请选择开发描述文件'
elif method == 'release-testing':
    assert devices and not debugging and not enterprise, '请选择 Ad Hoc 描述文件'
elif method == 'enterprise':
    assert enterprise and not debugging, '请选择企业描述文件'
elif method == 'app-store-connect':
    assert not devices and not enterprise and not debugging, '请选择 App Store 描述文件'
else:
    raise ValueError('Unknown export method')
identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning',
    str(root / 'aiglass-signing.keychain-db')], text=True)
allowed = {hashlib.sha1(cert).hexdigest().upper() for cert in profile['DeveloperCertificates']}
identity = next((sha for sha in re.findall(r'\b[0-9A-F]{40}\b', identities) if sha in allowed), None)
assert identity, 'P12 中的有效证书/私钥与描述文件不匹配'
directory = pathlib.Path.home() / 'Library/MobileDevice/Provisioning Profiles'
directory.mkdir(parents=True, exist_ok=True)
installed = directory / (uuid + '.mobileprovision')
shutil.copyfile(root / 'aiglass-profile.mobileprovision', installed)
(root / 'aiglass-installed-profile-path').write_text(str(installed))
with open('build/ExportOptions.plist', 'wb') as stream:
    plistlib.dump({'method': method, 'teamID': team, 'signingStyle': 'manual',
                  'signingCertificate': identity, 'provisioningProfiles': {bundle: uuid},
                  'manageAppVersionAndBuildNumber': False}, stream)
with open(root / 'aiglass-signing-settings.plist', 'wb') as stream:
    plistlib.dump({'team': team, 'profile': uuid, 'identity': identity}, stream)
PY

# Apply signing to the app target only; CocoaPods frameworks must not inherit a profile.
ruby - <<'RUBY'
require 'xcodeproj'
settings = Xcodeproj::Plist.read_from_path(File.join(ENV.fetch('RUNNER_TEMP'), 'aiglass-signing-settings.plist'))
project = Xcodeproj::Project.open('AIGlass.xcodeproj')
target = project.targets.find { |item| item.name == 'AIGlass' }
raise 'AIGlass target missing' unless target
target.build_configurations.each do |config|
  config.build_settings.keys.grep(/\A(?:DEVELOPMENT_TEAM|CODE_SIGN_IDENTITY|PROVISIONING_PROFILE)/).each { |key| config.build_settings.delete(key) }
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1'
  config.build_settings['CODE_SIGN_STYLE'] = 'Manual'
  config.build_settings['DEVELOPMENT_TEAM'] = settings.fetch('team')
  config.build_settings['CODE_SIGN_IDENTITY'] = settings.fetch('identity')
  config.build_settings['PROVISIONING_PROFILE_SPECIFIER'] = settings.fetch('profile')
end
project.save
RUBY

xcodebuild -workspace AIGlass.xcworkspace -scheme AIGlass -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$PWD/build/AIGlass.xcarchive" \
  SWIFT_OPTIMIZATION_LEVEL=-Onone \
  archive 2>&1 | tee build/logs/archive.log
# Verify the archived app, not just the source settings, before exporting.
python3 - <<'PY'
import json, pathlib, plistlib, subprocess
app = pathlib.Path('build/AIGlass.xcarchive/Products/Applications/AIGlass.app')
info = plistlib.loads((app / 'Info.plist').read_bytes())
assert info.get('UIDeviceFamily') == [1], '归档 App 必须仅支持 iPhone'
keys = {
    'NSBluetoothAlwaysUsageDescription', 'NSBluetoothPeripheralUsageDescription',
    'NSCameraUsageDescription', 'NSMicrophoneUsageDescription',
    'NSPhotoLibraryUsageDescription', 'NSPhotoLibraryAddUsageDescription',
    'NSLocalNetworkUsageDescription', 'NSLocationWhenInUseUsageDescription'
}
for locale in ('en', 'zh-Hans'):
    path = app / (locale + '.lproj') / 'InfoPlist.strings'
    assert path.is_file(), '缺少权限本地化资源: ' + locale
    strings = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))
    assert keys.issubset(strings), '权限本地化不完整: ' + locale
    assert all(isinstance(strings[key], str) and strings[key].strip() for key in keys)
precise = info.get('NSLocationTemporaryUsageDescriptionDictionary', {})
assert precise.get('WiFiSSIDAutofill') and precise.get('WiFiSSIDAutofillChinese'), '缺少临时精确位置权限说明'
print('Archived app verified: iPhone only; English and Simplified Chinese permission descriptions present.')
PY

xcodebuild -exportArchive -archivePath "$PWD/build/AIGlass.xcarchive" \
  -exportOptionsPlist "$PWD/build/ExportOptions.plist" -exportPath "$PWD/build/ipa" \
  2>&1 | tee build/logs/export.log
