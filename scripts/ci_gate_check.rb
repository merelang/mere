#!/usr/bin/env ruby
# Check that partitioning CI never drops a gate or hides a failed group.
require "yaml"
require "open3"

module CIGates
  class Invalid < StandardError; end

  # Update deliberately when adding or removing checks. A deleted step must
  # not silently reduce the coverage while every remaining group is green.
  EXPECTED_CHECKS = 166
  PREFLIGHT = "tool_preflight (a gate that did not run is not a gate that passed)"
  FULL_TESTS = "Run tests (full, with the wasm toolchain present)"
  CHECKOUT = "Check out the dogfood repositories"
  CACHE = "Restore the downstream compile cache"
  PACKAGES = "Install package dependencies"

  def self.require!(condition, message)
    raise Invalid, message unless condition
  end

  def self.route(step, groups)
    condition = step.fetch("if", "")
    prefix = "${{ !cancelled() && "
    require!(condition.is_a?(String) && condition.start_with?(prefix) && condition.end_with?(" }}"),
             "#{step['name']}: must run after earlier failures and select a group")
    expression = condition.delete_prefix(prefix).delete_suffix(" }}")
    expression = expression[1...-1] if expression.start_with?("(") && expression.end_with?(")")
    selected = expression.split(" || ").map do |part|
      match = /\Amatrix\.group == '([a-z][a-z0-9_-]*)'\z/.match(part)
      require!(match, "#{step['name']}: unrecognized group condition")
      match[1]
    end
    require!(selected.uniq == selected && (selected - groups).empty?,
             "#{step['name']}: duplicate or unknown group")
    selected
  end

  def self.check_results(step)
    states = %w[success failure cancelled skipped unknown] + [""]
    states.product(states).each do |plan, shards|
      _, _, status = Open3.capture3(
        {"GATE_PLAN_RESULT" => plan, "GATE_SHARDS_RESULT" => shards},
        "/bin/sh", "-e", "-c", step.fetch("run")
      )
      require!(status.success? == (plan == "success" && shards == "success"),
               "final check must reject failed, cancelled, skipped or missing results")
    end
  end

  def self.check(workflow)
    jobs = workflow.fetch("jobs")
    plan = jobs.fetch("gate_plan")
    require!(!plan["continue-on-error"] && !plan["if"], "gate assignment must be required")
    require!(plan.fetch("steps").any? { |s| s["run"] == "ruby scripts/ci_gate_check.rb --self-test" },
             "the assignment job must run the coverage and failure controls")
    shard = jobs.fetch("gate_shards")
    require!(shard["runs-on"] == "ubuntu-24.04", "integration checks must use the validated Ubuntu 24.04 image")
    require!(Array(shard["needs"]) == ["gate_plan"], "groups must wait for gate assignment")
    require!(!shard["if"] && !shard["continue-on-error"], "gate groups must be required")
    require!(shard.fetch("strategy")["fail-fast"] == false, "one failed group must not cancel the rest")
    matrix = shard.fetch("strategy").fetch("matrix")
    require!(matrix.keys == ["group"], "matrix include/exclude must not add or remove gate groups")
    groups = matrix.fetch("group")
    require!(groups.is_a?(Array) && !groups.empty? && groups.uniq == groups &&
             groups.all? { |g| g.is_a?(String) && /\A[a-z][a-z0-9_-]*\z/.match?(g) },
             "matrix groups must be unique nonempty names")
    steps = shard.fetch("steps")
    start = steps.index { |s| s["name"] == PREFLIGHT }
    require!(start, "every group needs the required tool preflight")
    build = steps.index { |s| s["name"] == "Build" }
    packages = steps.index { |s| s["name"] == PACKAGES }
    require!(build && packages && build < packages && packages < start,
             "declared packages must be installed after building and before preflights")
    require!(steps[packages]["run"] == "opam exec -- _build/default/bin/mere.exe install",
             "package preparation must use the compiler being tested")
    require!(steps[0..start].all? { |s| !s["if"] }, "setup and required preflights must run in every group")
    checks = steps[(start + 1)..]
    require!(checks.map { |s| s["name"] }.uniq.length == checks.length, "check names must be unique")
    require!(checks.count { |s| s["name"] == FULL_TESTS } == 1, "the full toolchain unit suite must run once")
    require!(checks.count { |s| s["name"] == CHECKOUT } == 1, "downstream checkouts must be present")
    require!(checks.count { |s| s["name"] == CACHE } == 1, "the downstream compile cache must be present")
    assigned = groups.to_h { |g| [g, []] }
    checks.each do |step|
      name = step.fetch("name")
      if name == FULL_TESTS
        require!(step["if"] == "${{ matrix.group == 'compiler' }}", "the full unit suite belongs to compiler")
        require!(step["run"] == "opam exec -- dune runtest", "the full toolchain unit suite must execute")
        selected = ["compiler"]
      else
        selected = route(step, groups)
      end
      case name
      when CHECKOUT
        require!(selected.sort == %w[downstream riscv], "both downstream and RISC-V need checkouts")
      when CACHE
        require!(selected == ["downstream"], "only downstream may write the compile cache")
      else
        require!(selected.length == 1, "#{name}: each check must run in exactly one group")
        require!(!step["continue-on-error"] && !step.fetch("run", "").empty?, "#{name}: check failures must fail the group")
        assigned.fetch(selected.first) << name
      end
    end
    require!(assigned.values.sum(&:length) == EXPECTED_CHECKS, "expected #{EXPECTED_CHECKS} checks; update the count deliberately")
    require!(assigned.values.none?(&:empty?), "a group has no checks")
    final = jobs.fetch("gates")
    require!(final["name"] == "Gates (cross-backend and differential)", "keep the existing required-check name")
    require!(Array(final["needs"]).sort == %w[gate_plan gate_shards], "final check must wait for the plan and all groups")
    require!(final["if"] == "${{ always() }}" && !final["continue-on-error"], "final check must run and fail when groups fail or skip")
    require!(final.fetch("steps").length == 1, "final check must have a single result check")
    result = final.fetch("steps").first
    require!(result["env"] == {
      "GATE_PLAN_RESULT" => "${{ needs.gate_plan.result }}",
      "GATE_SHARDS_RESULT" => "${{ needs.gate_shards.result }}"
    }, "final check must read both dependency results")
    require!(!result["if"] && !result["continue-on-error"], "the result check must not skip or ignore failure")
    check_results(result)
    assigned
  end

  def self.self_test(workflow)
    mutations = {
      "missing condition" => ->(c) { c[:poison].delete("if") },
      "boolean condition" => ->(c) { c[:poison]["if"] = false },
      "unknown group" => ->(c) { c[:poison]["if"] = "${{ !cancelled() && matrix.group == 'typo' }}" },
      "duplicated check" => ->(c) { c[:poison]["if"] = "${{ !cancelled() && (matrix.group == 'compiler' || matrix.group == 'runtime') }}" },
      "deleted check" => ->(c) { c[:steps].delete(c[:poison]) },
      "duplicate group" => ->(c) { c[:matrix]["group"] << "compiler" },
      "empty group" => ->(c) { c[:matrix]["group"] << "unused" },
      "excluded group" => ->(c) { c[:matrix]["exclude"] = [{"group" => "compiler"}] },
      "included group" => ->(c) { c[:matrix]["include"] = [{"group" => "compiler"}] },
      "fail fast" => ->(c) { c[:shard]["strategy"]["fail-fast"] = true },
      "unpinned runner" => ->(c) { c[:shard]["runs-on"] = "ubuntu-latest" },
      "optional groups" => ->(c) { c[:shard]["continue-on-error"] = true },
      "optional check" => ->(c) { c[:poison]["continue-on-error"] = true },
      "missing RISC-V checkout" => ->(c) { c[:checkout]["if"] = "${{ !cancelled() && matrix.group == 'downstream' }}" },
      "shared writable cache" => ->(c) { c[:cache]["if"] = "${{ !cancelled() && (matrix.group == 'compiler' || matrix.group == 'downstream') }}" },
      "missing full suite" => ->(c) { c[:steps].delete(c[:full]) },
      "empty full suite" => ->(c) { c[:full]["run"] = "true" },
      "missing required preflight" => ->(c) { c[:steps].reject! { |s| s["name"] == PREFLIGHT } },
      "missing package preparation" => ->(c) { c[:steps].reject! { |s| s["name"] == PACKAGES } },
      "skipped setup" => ->(c) { c[:steps].find { |s| s["name"] == "Build" }["if"] = "false" },
      "missing group dependency" => ->(c) { c[:final]["needs"] = ["gate_plan"] },
      "skipped final check" => ->(c) { c[:final].delete("if") },
      "ignored final failure" => ->(c) { c[:final]["continue-on-error"] = true },
      "always successful result" => ->(c) { c[:final]["steps"].first["run"] = "true" },
      "ignored assignment result" => ->(c) { c[:final]["steps"].first["run"] = '[ "$GATE_SHARDS_RESULT" = success ]' }
    }
    mutations.each do |label, change|
      copy = Marshal.load(Marshal.dump(workflow))
      shard = copy["jobs"]["gate_shards"]
      steps = shard["steps"]
      change.call({
        shard: shard, steps: steps, matrix: shard["strategy"]["matrix"],
        poison: steps.find { |s| s["name"] == "tool_preflight poison" },
        checkout: steps.find { |s| s["name"] == CHECKOUT },
        cache: steps.find { |s| s["name"] == CACHE },
        full: steps.find { |s| s["name"] == FULL_TESTS },
        final: copy["jobs"]["gates"]
      })
      begin
        check(copy)
      rescue Invalid
        next
      end
      raise Invalid, "negative control was not caught: #{label}"
    end
    puts "ci_gates: #{mutations.length} negative controls caught; 36 result combinations checked"
  end
end

if $PROGRAM_NAME == __FILE__
  abort "usage: ruby scripts/ci_gate_check.rb [--self-test]" unless (ARGV - ["--self-test"]).empty?
  begin
    path = File.expand_path("../.github/workflows/ci.yml", __dir__)
    workflow = YAML.safe_load(File.read(path), aliases: false)
    assigned = CIGates.check(workflow)
    puts "ci_gates: #{assigned.values.sum(&:length)} checks assigned exactly once across #{assigned.length} groups"
    assigned.each { |group, checks| puts "  #{group}: #{checks.length}" }
    CIGates.self_test(workflow) if ARGV.include?("--self-test")
  rescue CIGates::Invalid, KeyError, Psych::Exception => e
    warn "ci_gates: #{e.message}"
    exit 1
  end
end
