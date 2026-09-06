# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::API::Server do
  it "requires a non-empty URL" do
    expect { described_class.new(url: nil) }.to raise_error(ArgumentError)
    expect { described_class.new(url: "") }.to raise_error(ArgumentError)
  end

  it "normalizes variable keys and looks variables up by strings or symbols" do
    server = described_class.new(url: "https://{region}.example.com", variables: { region: { default: "eu" } })

    expect(server.variable("region")).to eq(default: "eu")
    expect(server.variable(:region)).to eq(default: "eu")
  end

  it "copies collections and implements value equality" do
    variables = { region: { default: "eu" } }
    first = described_class.new(url: "https://example.com", variables: variables, extensions: { x: [] })
    second = described_class.new(url: "https://example.com", variables: variables, extensions: { x: [] })
    variables[:later] = true

    expect(first.variables).to eq("region" => { default: "eu" })
    expect(first.to_h).to include(url: "https://example.com", variables: { "region" => { default: "eu" } },
                                   extensions: { "x" => [] })
    expect(first).to eql(second)
    expect(first.hash).to eq(second.hash)
  end
end
