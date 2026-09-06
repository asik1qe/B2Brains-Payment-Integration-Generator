# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProviderCompiler::Mapping::Transformations::TypeCast do
  describe ".descriptor" do
    it "builds normalized descriptors only for supported target types" do
      expect(described_class.descriptor(to: :string)).to eq("type" => "type_cast", "to" => "string")
      expect(described_class.descriptor(to: "INTEGER")).to eq("type" => "type_cast", "to" => "integer")
      expect(described_class.descriptor(to: :number)).to eq("type" => "type_cast", "to" => "number")
    end

    it "rejects unsupported targets" do
      expect { described_class.descriptor(to: :boolean) }.to raise_error(ArgumentError, /unsupported cast target/)
    end
  end

  describe ".infer" do
    let(:string_schema) { ProviderCompiler::Core::API::Schema.new(type: "string") }
    let(:integer_schema) { ProviderCompiler::Core::API::Schema.new(type: "integer") }

    it "casts guaranteed operation identifiers to provider strings" do
      expect(described_class.infer(internal_path: "operation.id", schema: string_schema)).to eq(
        "type" => "type_cast", "to" => "string"
      )
      expect(described_class.infer(internal_path: "operation.provider_operation_key", schema: string_schema)).to eq(
        "type" => "type_cast", "to" => "string"
      )
    end

    it "does not invent casts for unrelated fields or incompatible schemas" do
      expect(described_class.infer(internal_path: "operation.amount", schema: string_schema)).to be_nil
      expect(described_class.infer(internal_path: "operation.id", schema: integer_schema)).to be_nil
      expect(described_class.infer(internal_path: "operation.id", schema: nil)).to be_nil
    end
  end
end
