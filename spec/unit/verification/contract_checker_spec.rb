# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe ProviderCompiler::Verification::ContractChecker do
  subject(:checker) { described_class.new }

  it "accepts a service with the four required public methods" do
    expect(checker.call(generated_integration)).to be_success
  end

  it "rejects the wrong base class" do
    source = valid_service_source.sub("< Provider::BaseService", "< Object")
    result = checker.call(generated_integration(source: source))

    expect(result).to be_failure
    expect(result.diagnostics.map(&:code)).to include("generated_service_wrong_base_class")
  end

  it "rejects a BaseService subclass outside the Provider namespace" do
    source = valid_service_source.sub("class Provider::TestService", "class TestService")
    result = checker.call(generated_integration(source: source))

    expect(result).to be_failure
    expect(result.diagnostics.map(&:code)).to include("generated_service_wrong_namespace")
  end

  it "rejects a missing fetch_status method" do
    source = valid_service_source.sub(/\n  def fetch_status.*?\n  end\n/m, "\n")
    result = checker.call(generated_integration(source: source))

    expect(result.diagnostics.map(&:metadata)).to include("method_name" => "fetch_status")
  end

  it "reports every missing required method" do
    source = "class EmptyService < Provider::BaseService; end\n"
    result = checker.call(generated_integration(source: source))

    expect(result).to be_failure
    expect(result.diagnostics.count { |item| item.code == "generated_service_missing_method" }).to eq(4)
  end

  it "rejects a private required method" do
    source = valid_service_source.sub("  def fetch_status", "  private\n\n  def fetch_status")
    result = checker.call(generated_integration(source: source))

    expect(result).to be_failure
    expect(result.diagnostics.any? { |item| item.metadata["method_name"] == "fetch_status" }).to be(true)
  end

  it "rejects a method that cannot accept one positional argument" do
    source = valid_service_source.sub("def fetch_status(operation)", "def fetch_status")
    result = checker.call(generated_integration(source: source))

    expect(result).to be_failure
    expect(result.diagnostics.map(&:code)).to include("generated_service_invalid_method_signature")
  end

  it "allows optional and rest positional parameters" do
    source = valid_service_source
             .sub("def check_conditions(operation, request_method = nil)", "def check_conditions(operation = nil, *args)")
             .sub("def process_callback(payload)", "def process_callback(*payload)")

    expect(checker.call(generated_integration(source: source))).to be_success
  end

  it "rejects every generated failure code outside the platform whitelist" do
    source = valid_service_source.sub("success(result: operation)", "failure(:duplicate)")
    result = checker.call(generated_integration(source: source))

    expect(result).to be_failure
    expect(result.diagnostics.map(&:code)).to include("generated_service_unsupported_failure_code")
  end
end
