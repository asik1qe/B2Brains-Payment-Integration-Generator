# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Error do
  it "is the common application error" do
    expect(described_class).to be < StandardError
  end

  it "is the parent of configuration and CLI usage errors" do
    expect(ProviderCompiler::ConfigurationError).to be < described_class
    expect(ProviderCompiler::CliError).to be < described_class
  end
end
