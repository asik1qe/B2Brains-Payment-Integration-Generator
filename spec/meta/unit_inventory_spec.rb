# frozen_string_literal: true

require "spec_helper"

RSpec.describe "unit specification inventory", suite: :unit, component: :coverage do
  it "has a direct unit spec for every production Ruby component" do
    missing = Dir[SpecPaths.project("lib", "provider_compiler", "**", "*.rb")].filter_map do |source|
      relative = source.delete_prefix(SpecPaths.project("lib", "provider_compiler") + File::SEPARATOR)
      parts = relative.split(File::SEPARATOR)
      filename = parts.pop.sub(/\.rb\z/, "_spec.rb")
      expected = if parts.empty?
                   SpecPaths.project("spec", "unit", "provider_compiler", filename)
                 else
                   SpecPaths.project("spec", "unit", *parts, filename)
                 end
      relative unless File.file?(expected)
    end

    expect(missing).to eq([]), "Missing direct unit specs for: #{missing.join(', ')}"
  end
end
