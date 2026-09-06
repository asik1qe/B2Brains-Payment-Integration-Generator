# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec) do |task|
  task.pattern = "spec/**/*_spec.rb"
end

{
  "spec:unit" => "spec/{unit,meta}/**/*_spec.rb",
  "spec:pipeline" => "spec/pipeline/**/*_spec.rb",
  "spec:acceptance" => "spec/acceptance/**/*_spec.rb",
  "spec:real_world" => "spec/real_world/**/*_spec.rb"
}.each do |name, pattern|
  RSpec::Core::RakeTask.new(name) { |task| task.pattern = pattern }
end

desc "Run the complete Provider Compiler verification suite"
task test: :spec

desc "Run the external judge-case matrix"
task :judge do
  ruby File.expand_path("judge_cases/run_all.rb", __dir__)
end

task default: :spec
