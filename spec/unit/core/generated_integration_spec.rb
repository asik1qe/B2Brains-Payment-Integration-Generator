# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Core::GeneratedIntegration do
  let(:content) do
    {
      service_code: "class ProviderService\nend\n",
      integration_markdown: "# Integration\n",
      fixtures_json: "{}"
    }
  end

  it "preserves all three content fields and allows empty content" do
    integration = described_class.new(**content)
    empty = described_class.new(service_code: "", integration_markdown: "", fixtures_json: "")

    expect(integration.service_code).to eq(content[:service_code])
    expect(integration.integration_markdown).to eq(content[:integration_markdown])
    expect(integration.fixtures_json).to eq(content[:fixtures_json])
    expect(empty.fixtures_json).to eq("")
  end

  it "uses documentation and fixture filename defaults" do
    integration = described_class.new(**content)

    expect(integration.service_filename).to be_nil
    expect(integration.integration_filename).to eq("INTEGRATION.md")
    expect(integration.fixtures_filename).to eq("fixtures.json")
  end

  it "returns only files with known filenames" do
    integration = described_class.new(**content, service_filename: "provider_service.rb")

    expect(integration.files).to eq(
      "provider_service.rb" => content[:service_code],
      "INTEGRATION.md" => content[:integration_markdown],
      "fixtures.json" => content[:fixtures_json]
    )

    without_service = described_class.new(**content)
    expect(without_service.files).not_to include(nil)
    expect(without_service.files).not_to have_key("provider_service.rb")
  end

  it "looks files up by string or symbol" do
    integration = described_class.new(**content)

    expect(integration.file("INTEGRATION.md")).to eq(content[:integration_markdown])
    expect(integration.file(:"fixtures.json")).to eq(content[:fixtures_json])
    expect(integration.file("missing")).to be_nil
  end

  it "returns named file entries" do
    integration = described_class.new(**content, service_filename: "provider_service.rb")

    expect(integration.service_file).to eq(
      filename: "provider_service.rb", content: content[:service_code]
    )
    expect(integration.documentation_file).to eq(
      filename: "INTEGRATION.md", content: content[:integration_markdown]
    )
    expect(integration.fixtures_file).to eq(
      filename: "fixtures.json", content: content[:fixtures_json]
    )
    expect(described_class.new(**content).service_file).to be_nil
  end

  it "allows any filename to be omitted but rejects a specified empty filename" do
    integration = described_class.new(
      **content, integration_filename: nil, fixtures_filename: nil
    )

    expect(integration.files).to be_empty
    expect { described_class.new(**content, service_filename: "") }.to raise_error(ArgumentError)
    expect { described_class.new(**content, integration_filename: "") }.to raise_error(ArgumentError)
    expect { described_class.new(**content, fixtures_filename: "") }.to raise_error(ArgumentError)
  end

  it "validates content, filename, provider-name, and metadata types" do
    expect { described_class.new(**content, service_code: nil) }.to raise_error(ArgumentError)
    expect { described_class.new(**content, integration_markdown: :markdown) }.to raise_error(ArgumentError)
    expect { described_class.new(**content, fixtures_json: {}) }.to raise_error(ArgumentError)
    expect { described_class.new(**content, service_filename: :service) }.to raise_error(ArgumentError)
    expect { described_class.new(**content, provider_name: :provider) }.to raise_error(ArgumentError)
    expect { described_class.new(**content, metadata: []) }.to raise_error(ArgumentError)
  end

  it "isolates nested metadata from caller mutation" do
    metadata = { manifest: { verified: false }, files: ["service"] }
    integration = described_class.new(**content, metadata: metadata)
    metadata[:manifest][:verified] = true
    metadata[:files] << "docs"

    expect(integration.metadata).to eq(manifest: { verified: false }, files: ["service"])
  end

  it "has a stable representation and implements value equality" do
    attributes = content.merge(service_filename: "provider_service.rb", provider_name: "Provider")
    first = described_class.new(**attributes)
    second = described_class.new(**attributes)

    expect(first.to_h).to include(
      service_filename: "provider_service.rb", integration_filename: "INTEGRATION.md",
      fixtures_filename: "fixtures.json", provider_name: "Provider", metadata: {}
    )
    expect(first).to eql(second)
    expect(first.hash).to eq(second.hash)
    expect(first).not_to eq(first.to_h)
  end
end
