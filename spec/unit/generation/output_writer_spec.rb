# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "tempfile"

RSpec.describe ProviderCompiler::Generation::OutputWriter do
  subject(:writer) { described_class.new }

  def integration(service_filename: "demo_service.rb")
    ProviderCompiler::Core::GeneratedIntegration.new(
      service_code: "service\n",
      integration_markdown: "docs\n",
      fixtures_json: "{}\n",
      service_filename: service_filename
    )
  end

  it "creates the directory, writes exactly three files, and returns absolute paths" do
    Dir.mktmpdir do |root|
      output = File.join(root, "nested")
      result = writer.write(integration, output_dir: output)

      expect(result).to be_success
      expect(result.value.keys).to contain_exactly("demo_service.rb", "INTEGRATION.md", "fixtures.json")
      expect(result.value.values).to all(satisfy { |path| Pathname.new(path).absolute? })
      expect(File.binread(File.join(output, "demo_service.rb"))).to eq("service\n")
      expect(Dir.children(output)).to contain_exactly("demo_service.rb", "INTEGRATION.md", "fixtures.json")
    end
  end

  it "rejects traversal and absolute filenames before creating the output directory" do
    Dir.mktmpdir do |root|
      output = File.join(root, "output")
      traversal = writer.write(integration(service_filename: "../escaped.rb"), output_dir: output)
      absolute = writer.write(integration(service_filename: File.join(root, "escaped.rb")), output_dir: output)

      expect(traversal).to be_failure
      expect(absolute).to be_failure
      expect(traversal.diagnostics.first.code).to eq("unsafe_output_filename")
      expect(File.exist?(File.join(root, "escaped.rb"))).to be(false)
      expect(Dir.exist?(output)).to be(false)
    end
  end

  it "converts ordinary I/O errors into diagnostics" do
    Tempfile.create("not-a-directory") do |file|
      result = writer.write(integration, output_dir: file.path)

      expect(result).to be_failure
      expect(result.diagnostics.first.code).to eq("output_write_error")
    end
  end
end
