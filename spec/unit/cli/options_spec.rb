# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::CLI::Options do
  subject(:options) { described_class.new }

  it "parses supplied flags without applying configuration defaults" do
    config = options.parse(%w[--spec api.yml --provider orbit])

    expect(config.spec_path).to eq("api.yml")
    expect(config.provider_name).to eq("orbit")
    expect(config.output_dir).to be_nil
    expect(config.overrides_path).to be_nil
  end

  it "parses output and overrides" do
    config = options.parse(%w[--spec api.yml --provider orbit --output build --overrides mapping.yml])

    expect(config.output_dir).to eq("build")
    expect(config.overrides_path).to eq("mapping.yml")
  end

  it "does not mutate argv" do
    argv = %w[--spec api.yml --provider orbit]

    options.parse(argv)

    expect(argv).to eq(%w[--spec api.yml --provider orbit])
  end

  it "leaves missing values available for config or interactive input" do
    parsed = options.parse([])

    expect(parsed.spec_path).to be_nil
    expect(parsed.provider_name).to be_nil
  end

  it "parses config and execution mode flags" do
    parsed = options.parse(%w[--config run.yml --debug --non-interactive --force])

    expect(parsed.config_path).to eq("run.yml")
    expect(parsed.debug).to be(true)
    expect(parsed.non_interactive).to be(true)
    expect(parsed.force).to be(true)
  end

  it "lets OptionParser report unknown flags" do
    expect { options.parse(%w[--unknown]) }.to raise_error(OptionParser::InvalidOption)
  end

  ["-h", "--help"].each do |flag|
    it "handles #{flag} without mandatory options" do
      expect(options.parse([flag])).to be_nil
      expect(options).to be_help
      expect(options.help_text).to include("Usage:", "--spec", "--provider", "Examples:")
      expect(options.help_text.scan("integrate --spec").size).to be >= 2
    end
  end
end
