# frozen_string_literal: true

module SpecPaths
  ROOT = File.expand_path("..", __dir__).freeze
  PROJECT_ROOT = File.expand_path("..", ROOT).freeze

  module_function

  def fixture(*parts)
    File.join(ROOT, "fixtures", *parts)
  end

  def project(*parts)
    File.join(PROJECT_ROOT, *parts)
  end
end
