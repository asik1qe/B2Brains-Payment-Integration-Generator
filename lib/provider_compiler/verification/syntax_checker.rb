# frozen_string_literal: true

require "ripper"
require_relative "../core/diagnostic"
require_relative "../core/result"

module ProviderCompiler
  module Verification
    class SyntaxChecker
      def call(source, filename: "(generated)")
        if defined?(RubyVM::InstructionSequence)
          RubyVM::InstructionSequence.compile(source, filename)
        elsif Ripper.sexp(source).nil?
          raise SyntaxError, "Ruby parser rejected generated source"
        end

        ProviderCompiler::Core::Result.success({ "valid" => true })
      rescue SyntaxError => error
        metadata = { "exception_class" => error.class.name }
        line = error.message[/:(\d+):/, 1]
        metadata["line"] = line.to_i if line
        diagnostic = ProviderCompiler::Core::Diagnostic.new(
          severity: :error,
          code: :generated_ruby_syntax_error,
          message: "Generated Ruby has invalid syntax",
          stage: :verification,
          state: :unresolved,
          location: filename,
          metadata: metadata
        )
        ProviderCompiler::Core::Result.failure(nil, diagnostics: [diagnostic])
      end
    end
  end
end
