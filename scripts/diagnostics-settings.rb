# Keep testing diagnostics independent of the Release archive configuration.
module AIGlassDiagnosticsSettings
  TEST_METHODS = %w[debugging release-testing].freeze
  STORE_METHODS = %w[app-store-connect enterprise].freeze
  FLAGS = %w[DEBUG AIGLASS_DIAGNOSTICS AIGLASS_PRODUCTION].freeze

  def self.apply(settings, export_method)
    raise "Unknown export method: #{export_method}" unless (TEST_METHODS + STORE_METHODS).include?(export_method)

    enabled = TEST_METHODS.include?(export_method)
    flag = enabled ? 'AIGLASS_DIAGNOSTICS' : 'AIGLASS_PRODUCTION'
    conditions = tokens(settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'])
    conditions.reject! { |value| FLAGS.include?(value) }
    settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = (['$(inherited)'] + conditions + [flag]).uniq

    definitions = tokens(settings['GCC_PREPROCESSOR_DEFINITIONS'])
    definitions.reject! { |value| FLAGS.include?(value.split('=').first) }
    settings['GCC_PREPROCESSOR_DEFINITIONS'] = (['$(inherited)'] + definitions + ["#{flag}=1"]).uniq
    # The project supplies an explicit Info.plist, so INFOPLIST_KEY_* is not
    # emitted by Xcode. Expand this setting through the plist source instead.
    settings['AIGlassDiagnosticsEnabled'] = enabled ? 'YES' : 'NO'
  end

  def self.tokens(value)
    value.is_a?(Array) ? value.dup : value.to_s.split
  end
end
