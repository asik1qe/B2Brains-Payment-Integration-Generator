# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe ProviderCompiler::CLI::SourcePreview do
  it "falls back safely when no fragment can be found" do
    preview = described_class.new("definitely-missing-openapi.yml")

    expect(preview.fields("unknown.path")).to eq("Source fragment unavailable.")
    expect(preview.operations([])).to eq("Source fragment unavailable.")
  end
end
