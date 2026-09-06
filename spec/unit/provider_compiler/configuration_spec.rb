# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe ProviderCompiler::Configuration do
  it "stores a valid immutable configuration with defaults" do
    config = described_class.new(spec_path: "api.yml", provider_name: "orbit")

    expect(config.to_h).to eq(
      spec_path: "api.yml", provider_name: "orbit", output_dir: "./output", overrides_path: nil
    )
    expect(config).to be_frozen
    expect(config.overrides?).to be(false)
  end

  it "stores output and overrides and exposes overrides?" do
    config = described_class.new(
      spec_path: "api.yml", provider_name: "orbit", output_dir: "build", overrides_path: "map.yml"
    )

    expect(config.output_dir).to eq("build")
    expect(config.overrides_path).to eq("map.yml")
    expect(config.overrides?).to be(true)
  end

  [nil, "", "  ", :api].each do |value|
    it "rejects invalid spec_path #{value.inspect}" do
      expect { described_class.new(spec_path: value, provider_name: "orbit") }
        .to raise_error(ProviderCompiler::ConfigurationError, /spec_path/)
    end
  end

  [nil, "", "  ", :orbit].each do |value|
    it "rejects invalid provider_name #{value.inspect}" do
      expect { described_class.new(spec_path: "api.yml", provider_name: value) }
        .to raise_error(ProviderCompiler::ConfigurationError, /provider_name/)
    end
  end

  it "rejects blank output_dir" do
    expect { described_class.new(spec_path: "api.yml", provider_name: "orbit", output_dir: "") }
      .to raise_error(ProviderCompiler::ConfigurationError, /output_dir/)
  end

  it "rejects blank overrides_path" do
    expect { described_class.new(spec_path: "api.yml", provider_name: "orbit", overrides_path: "") }
      .to raise_error(ProviderCompiler::ConfigurationError, /overrides_path/)
  end

  it "implements value equality and hash semantics" do
    first = described_class.new(spec_path: "api.yml", provider_name: "orbit")
    second = described_class.new(spec_path: "api.yml", provider_name: "orbit")
    different = described_class.new(spec_path: "other.yml", provider_name: "orbit")

    expect(first).to eql(second)
    expect(first.hash).to eq(second.hash)
    expect(first).not_to eq(different)
  end

  it "merges CLI over the default config file while leaving absent defaults unresolved" do
    Dir.mktmpdir do |root|
      File.write(File.join(root, "provider-compiler.yml"), <<~YAML)
        spec: from-config.yml
        provider: config_provider
        output: config-output
        debug: false
      YAML

      resolved = described_class.resolve({ provider_name: "cli_provider", debug: true }, cwd: root)

      expect(resolved).to include(
        spec_path: "from-config.yml", provider_name: "cli_provider",
        output_dir: "config-output", debug: true
      )
    end
  end

  it "loads an explicitly selected relative config from the supplied working directory" do
    Dir.mktmpdir do |root|
      File.write(File.join(root, "custom.yml"), "provider: orbit\n")

      expect(described_class.resolve({ config_path: "custom.yml" }, cwd: root)[:provider_name]).to eq("orbit")
    end
  end

  it "rejects a missing explicit config" do
    expect { described_class.resolve({ config_path: "missing.yml" }) }
      .to raise_error(ProviderCompiler::ConfigurationError, /not found/)
  end

  it "rejects malformed config YAML" do
    Dir.mktmpdir do |root|
      path = File.join(root, "bad.yml")
      File.write(path, "provider: [\n")

      expect { described_class.resolve({ config_path: path }) }
        .to raise_error(ProviderCompiler::ConfigurationError, /Unable to load config/)
    end
  end

  it "rejects wrong config value types" do
    Dir.mktmpdir do |root|
      path = File.join(root, "bad.yml")
      File.write(path, "debug: 1\n")

      expect { described_class.resolve({ config_path: path }) }
        .to raise_error(ProviderCompiler::ConfigurationError, /Invalid config value/)
    end
  end

  it "builds the deterministic default override path" do
    expect(described_class.default_overrides_path("Polaris Pay")).to eq(
      File.join(".provider-compiler", "polaris_pay.overrides.yml")
    )
  end
end
