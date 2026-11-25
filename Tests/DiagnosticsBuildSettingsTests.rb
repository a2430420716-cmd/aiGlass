require_relative '../scripts/diagnostics-settings'

def check(value, message)
  raise message unless value
end

%w[app-store-connect enterprise debugging release-testing].each do |method|
  settings = {
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited) DEBUG AIGLASS_DIAGNOSTICS AIGLASS_PRODUCTION EXISTING_FEATURE',
    'GCC_PREPROCESSOR_DEFINITIONS' => ['$(inherited)', 'DEBUG=1', 'AIGLASS_DIAGNOSTICS=1', 'AIGLASS_PRODUCTION=1', 'OPUS_BUILD=1']
  }
  AIGlassDiagnosticsSettings.apply(settings, method)
  enabled = %w[debugging release-testing].include?(method)
  flag = enabled ? 'AIGLASS_DIAGNOSTICS' : 'AIGLASS_PRODUCTION'
  check(settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] == ['$(inherited)', 'EXISTING_FEATURE', flag], method)
  check(settings['GCC_PREPROCESSOR_DEFINITIONS'] == ['$(inherited)', 'OPUS_BUILD=1', "#{flag}=1"], method)
  check(settings['AIGlassDiagnosticsEnabled'] == (enabled ? 'YES' : 'NO'), method)
  snapshot = Marshal.load(Marshal.dump(settings))
  AIGlassDiagnosticsSettings.apply(settings, method)
  check(settings == snapshot, "Repeated configuration must be idempotent: #{method}")
end
begin
  AIGlassDiagnosticsSettings.apply({}, 'invalid')
  raise 'Unknown export type must fail'
rescue RuntimeError => error
  raise unless error.message.start_with?('Unknown export method:')
end
puts 'Diagnostics build settings: all export methods, stale flags, idempotence and unknown methods passed'
