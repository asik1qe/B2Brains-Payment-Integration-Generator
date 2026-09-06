# frozen_string_literal: true

require "spec_helper"
require_relative "../support"

RSpec.describe ProviderCompiler::Mapping::Transformations::DateTime do
  it "infers only the OpenAPI date-time format" do
    expect(described_class.infer(api_schema(type: "string", format: "date-time"))).to eq(
      "type" => "date_time", "format" => "date-time"
    )
    expect(described_class.infer(api_schema(type: "string", format: "date"))).to be_nil
  end
end
