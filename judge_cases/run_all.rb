#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "yaml"

ROOT = File.expand_path("..", __dir__)
CASES_ROOT = __dir__
MANIFEST = YAML.safe_load_file(File.join(CASES_ROOT, "manifest.yml"), aliases: false)
OUTPUT_ROOT = File.join(ROOT, "tmp", "judge_cases")

FileUtils.rm_rf(OUTPUT_ROOT)
FileUtils.mkdir_p(OUTPUT_ROOT)

results = []

puts "=" * 92
puts "PROVIDER COMPILER - JUDGE CASES"
puts "=" * 92

MANIFEST.fetch("cases").each_with_index do |item, index|
  output = File.join(OUTPUT_ROOT, item.fetch("id"))
  command = [
    RbConfig.ruby,
    File.join(ROOT, "bin", "integrate"),
    "--spec", File.join(CASES_ROOT, item.fetch("spec")),
    "--provider", item.fetch("provider"),
    "--output", output,
    "--non-interactive",
    "--force"
  ]
  if item["overrides"]
    command += ["--overrides", File.join(CASES_ROOT, item.fetch("overrides"))]
  end

  stdout, stderr, process = Open3.capture3(*command, chdir: ROOT)
  combined = [stdout, stderr].join("\n")
  actual_status = combined[/Status:\s+(SUCCESS|FAILED|NEEDS REVIEW)/, 1]
  artifact_count = Dir.exist?(output) ? Dir.children(output).count { |name| File.file?(File.join(output, name)) } : 0

  checks = []
  checks << ["exit", process.exitstatus == item.fetch("expected_exit")]
  checks << ["status", actual_status == item.fetch("expected_status")]
  checks << ["artifacts", artifact_count == item.fetch("expected_artifacts")]
  Array(item["expect_output"]).each do |fragment|
    checks << ["output: #{fragment}", combined.include?(fragment)]
  end

  passed = checks.all?(&:last)
  results << { item: item, passed: passed, exit: process.exitstatus, status: actual_status, artifacts: artifact_count, checks: checks }

  marker = passed ? "PASS" : "FAIL"
  puts format(
    "%2d. %-5s %-58s exit=%d status=%-12s files=%d",
    index + 1,
    marker,
    item.fetch("label"),
    process.exitstatus,
    actual_status || "(none)",
    artifact_count
  )

  next if passed

  checks.reject(&:last).each { |name, _| puts "      failed check: #{name}" }
  puts "      stdout: #{stdout.lines.first(8).join.strip}" unless stdout.empty?
  puts "      stderr: #{stderr.lines.first(8).join.strip}" unless stderr.empty?
end

passed = results.count { |result| result[:passed] }
failed = results.length - passed

puts "-" * 92
puts "Judge cases: #{passed}/#{results.length} passed | #{failed} failed"
puts "Artifacts:   #{OUTPUT_ROOT}"
puts "=" * 92

exit(failed.zero? ? 0 : 1)
