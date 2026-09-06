# frozen_string_literal: true

require_relative "../mapping/support"

module GenerationSpecSupport
  def novapay_provider_spec
    path = SpecPaths.fixture("official", "novapay_provider_api.yaml")
    loaded = ProviderCompiler::OpenAPI::Loader.new.call(path)
    ProviderCompiler::OpenAPI::Parser.new.call(loaded.value).value
  end

  def novapay_mapping_plan
    overrides = SpecPaths.fixture("overrides", "novapay_overrides.yml")
    ProviderCompiler::Mapping::Mapper.new.call(novapay_provider_spec, overrides: overrides).value
  end

  def orbit_mapping_plan
    ProviderCompiler::Mapping::Mapper.new.call(synthetic_provider_spec).value
  end
end

RSpec.configure do |config|
  config.include GenerationSpecSupport
end
