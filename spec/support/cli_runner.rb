# frozen_string_literal: true

require "stringio"
require "tmpdir"

module CliSpecRunner
  def run_cli(argv, answers: "", interactive: false)
    out = StringIO.new
    err = StringIO.new
    presenter = ProviderCompiler::CLI::Presenter.new(out: out, err: err)
    command = ProviderCompiler::CLI::Command.new(
      presenter: presenter,
      input: StringIO.new(answers),
      interactive: interactive
    )
    [command.run(argv), out.string, err.string]
  end

  def with_tmpdir
    Dir.mktmpdir("provider-compiler-spec") { |dir| yield dir }
  end
end

RSpec.configure do |config|
  config.include CliSpecRunner
end
