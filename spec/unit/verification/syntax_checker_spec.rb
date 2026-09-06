# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe ProviderCompiler::Verification::SyntaxChecker do
  subject(:checker) { described_class.new }

  it "accepts valid Ruby" do
    result = checker.call("value = 1\n")

    expect(result).to be_success
    expect(result.value).to eq("valid" => true)
  end

  it "reports invalid Ruby without raising" do
    result = checker.call("class Broken\n", filename: "broken.rb")

    expect(result).to be_failure
    expect(result.diagnostics.first.code).to eq("generated_ruby_syntax_error")
    expect(result.diagnostics.first.stage).to eq("verification")
    expect(result.diagnostics.first.location).to eq("broken.rb")
  end

  it "does not execute the source" do
    $verification_syntax_side_effect = nil
    result = checker.call("$verification_syntax_side_effect = true\n")

    expect(result).to be_success
    expect($verification_syntax_side_effect).to be_nil
  ensure
    $verification_syntax_side_effect = nil
  end

  it "accepts required generated class syntax" do
    expect(checker.call(valid_service_source)).to be_success
  end
end
