#!/usr/bin/env ruby
# Check that partitioning CI never drops a gate or hides a failed group.
require "yaml"
require "open3"
require "tmpdir"
require "fileutils"

module CIGates
  class Invalid < StandardError; end

  # Update deliberately when adding or removing checks. A deleted step must
  # not silently reduce the coverage while every remaining group is green.
  EXPECTED_CHECKS = 196
  PREFLIGHT = "tool_preflight (a gate that did not run is not a gate that passed)"
  FULL_TESTS = "Run tests (full, with the wasm toolchain present)"
  FIRST_RUN = "first_run_check (the README, executed)"
  PARITY = "parity (interp / C / LLVM / wasm agree)"
  FORMATTERS = {
    "fmt_comments_check (the formatter keeps column-1 comments)" => "fmt_comments_check.sh",
    "fmt_roundtrip_check (what fmt writes is still the same program)" => "fmt_roundtrip_check.sh"
  }.freeze
  RUNTIME_MOVES = {
    "examples_parity (the corpus prints the same on interp and C)" =>
      ["downstream", "sh scripts/examples_parity.sh\nsh scripts/examples_parity.sh --poison\n"],
    PARITY => ["compiler", "sh scripts/parity.sh"],
    "softfloat (a double's bits, on a target with no float)" =>
      ["web", "sh scripts/softfloat_check.sh"]
  }.freeze
  RISCV_BOUNDARIES = {
    "map_read_riscv (Map read boundaries against explicit results at both widths)" => "map_read_check.py",
    "buffer_boundary_riscv (the same buffer contracts at both widths)" => "buffer_boundary_check.py"
  }.freeze
  CHECKOUT = "Check out the dogfood repositories"
  CACHE = "Restore the downstream compile cache"
  PACKAGES = "Install package dependencies"
  CHECKOUT_GROUPS = %w[coroutines downstream riscv riscv-ownership].freeze
  RV_EXEC = {
    "rv_exec contracts (hosted boundaries at both widths)" => ["riscv", "--contracts"],
    "rv_exec corpus32 (the full corpus against C)" => ["coroutines", "--corpus32"],
    "rv_exec corpus64 (the full corpus against C)" => ["riscv-ownership", "--corpus64"]
  }.freeze
  RISCV_TOOLS = ["Install qemu-system-riscv32 (optional gate)",
                 "Install binutils-riscv64 (optional gate — oracle for mere -rvd)"].freeze

  def self.group_commands(workflow, group)
    assigned = check(workflow)
    require!(assigned.key?(group), "unknown gate group: #{group}")
    workflow.fetch("jobs").fetch("gate_shards").fetch("steps").map do |step|
      name = step["name"]
      next unless assigned.fetch(group).include?(name) || (group == "compiler" && name == FULL_TESTS)
      step["run"]
    end.compact.join("\n")
  end

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
    require!(!plan["continue-on-error"] && !plan.key?("if"), "gate assignment must be required")
    require!(plan.fetch("steps").any? { |s| s["run"] == "ruby scripts/ci_gate_check.rb --self-test" },
             "the assignment job must run the coverage and failure controls")
    shard = jobs.fetch("gate_shards")
    require!(shard["runs-on"] == "ubuntu-24.04", "integration checks must use the validated Ubuntu 24.04 image")
    require!(Array(shard["needs"]) == ["gate_plan"], "groups must wait for gate assignment")
    require!(!shard.key?("if") && !shard["continue-on-error"], "gate groups must be required")
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
    steps[0..start].each do |step|
      if RISCV_TOOLS.include?(step["name"])
        require!(step["if"] == "${{ matrix.group == 'riscv' }}", "RISC-V tools belong only to the RISC-V group")
        require!(!step["continue-on-error"], "required RISC-V oracle installation must fail visibly")
        require!(step["timeout-minutes"].is_a?(Integer) && (1..5).cover?(step["timeout-minutes"]),
                 "RISC-V package installation needs a bounded timeout")
      else
        require!(!step.key?("if"), "setup and required preflights must run in every group")
      end
      if step["name"].to_s.start_with?("Install ", "Set up ") || step["name"].to_s.start_with?("PostgreSQL")
        ceiling = step["name"] == "Set up OCaml" ? 30 : 15
        require!(step["timeout-minutes"].is_a?(Integer) && (1..ceiling).cover?(step["timeout-minutes"]),
                 "#{step['name']}: network setup needs a bounded timeout")
      end
    end
    require!(RISCV_TOOLS.all? { |name| steps[0..start].any? { |step| step["name"] == name } },
             "both independent RISC-V oracles must be installed")
    require!(steps[start]["env"] == {"MERE_CI_GROUP" => "${{ matrix.group }}"},
             "required tool preflight must inspect the active group's gates")
    checks = steps[(start + 1)..]
    require!(checks.map { |s| s["name"] }.uniq.length == checks.length, "check names must be unique")
    require!(RV_EXEC.keys.all? { |n| checks.count { |s| s["name"] == n } == 1 },
             "all three RISC-V execution partitions must run once")
    require!(checks.count { |s| s["name"] == FIRST_RUN } == 1, "the README execution gate must run once")
    require!(FORMATTERS.keys.all? { |name| checks.count { |s| s["name"] == name } == 1 },
             "both formatter gates must run once")
    require!(RUNTIME_MOVES.keys.all? { |name| checks.count { |s| s["name"] == name } == 1 },
             "all balanced runtime gates must run once")
    require!(RISCV_BOUNDARIES.keys.all? { |name| checks.count { |s| s["name"] == name } == 1 },
             "both balanced RISC-V boundary gates must run once")
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
      when "tool_preflight poison"
        require!(selected == ["riscv"] && !step["continue-on-error"],
                 "global tool preflight controls need the complete RISC-V toolchain")
        assigned.fetch("riscv") << name
      when FIRST_RUN
        require!(selected == ["runtime"], "the README gate belongs to runtime")
        require!(step["run"] == "opam exec -- sh scripts/first_run_check.sh",
                 "the README gate must retain the executed transcript and full test-count check")
        require!(!step["continue-on-error"], "README execution failures must fail runtime")
        assigned.fetch("runtime") << name
      when *FORMATTERS.keys
        require!(selected == ["downstream"], "formatter corpus gates belong to downstream")
        script = FORMATTERS.fetch(name)
        require!(step["run"] == "sh scripts/#{script}\nsh scripts/#{script} --poison\n",
                 "formatter gates must retain their full corpus and poison runs")
        require!(!step["continue-on-error"], "formatter failures must fail downstream")
        assigned.fetch("downstream") << name
      when *RUNTIME_MOVES.keys
        group, command = RUNTIME_MOVES.fetch(name)
        require!(selected == [group], "#{name}: retain its balanced execution group")
        require!(step["run"] == command && !step["continue-on-error"],
                 "#{name}: retain the complete corpus and controls")
        assigned.fetch(group) << name
      when *RISCV_BOUNDARIES.keys
        require!(selected == ["riscv"], "#{name}: retain its balanced execution group")
        script = RISCV_BOUNDARIES.fetch(name)
        require!(step["run"] == "MEMU=\"$RUNNER_TEMP/downstream/memu\" python3 scripts/#{script} --rv-only --poison" &&
                 !step["continue-on-error"], "#{name}: retain both widths, the memu oracle and poison controls")
        assigned.fetch("riscv") << name
      when CHECKOUT
        require!(selected.sort == CHECKOUT_GROUPS, "downstream and every RISC-V oracle group need checkouts")
        require!(!step["continue-on-error"], "missing required oracle checkouts must fail the group")
        require!(step["env"] == {"MERE_REQUIRE_MEMU" => "${{ matrix.group != 'downstream' }}"},
                 "every RISC-V oracle group must require memu")
      when CACHE
        require!(selected == ["downstream"], "only downstream may write the compile cache")
      when *RV_EXEC.keys
        group, mode = RV_EXEC.fetch(name)
        require!(selected == [group], "#{name}: wrong execution group")
        require!(!step["continue-on-error"], "#{name}: execution failures must fail the group")
        require!(step["run"] == "MEMU=\"$RUNNER_TEMP/downstream/memu\" sh scripts/rv_exec_check.sh #{mode}",
                 "#{name}: the assigned partition must execute")
        assigned.fetch(group) << name
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
    without_checkout = lambda do |c, group|
      selected = route(c[:checkout], c[:matrix]["group"]) - [group]
      terms = selected.map { |name| "matrix.group == '#{name}'" }.join(" || ")
      c[:checkout]["if"] = "${{ !cancelled() && (#{terms}) }}"
    end
    mutations = {
      "missing condition" => ->(c) { c[:poison].delete("if") },
      "boolean condition" => ->(c) { c[:poison]["if"] = false },
      "unknown group" => ->(c) { c[:poison]["if"] = "${{ !cancelled() && matrix.group == 'typo' }}" },
      "duplicated check" => ->(c) { c[:poison]["if"] = "${{ !cancelled() && (matrix.group == 'compiler' || matrix.group == 'runtime') }}" },
      "deleted check" => ->(c) { c[:steps].delete(c[:poison]) },
      "missing RV64 partition" => ->(c) { c[:steps].reject! { |s| s["name"] == RV_EXEC.keys.last } },
      "duplicate RV32 work" => ->(c) { c[:steps].find { |s| s["name"] == RV_EXEC.keys.last }["run"].sub!("--corpus64", "--corpus32") },
      "unpartitioned RV work" => ->(c) { c[:steps].find { |s| s["name"] == RV_EXEC.keys.first }["run"].sub!("--contracts", "--all") },
      "optional RV partition" => ->(c) { c[:steps].find { |s| s["name"] == RV_EXEC.keys.first }["continue-on-error"] = true },
      "RV corpus in wrong group" => ->(c) { c[:steps].find { |s| s["name"] == RV_EXEC.keys.last }["if"] = "${{ !cancelled() && matrix.group == 'riscv' }}" },
      "duplicate group" => ->(c) { c[:matrix]["group"] << "compiler" },
      "empty group" => ->(c) { c[:matrix]["group"] << "unused" },
      "excluded group" => ->(c) { c[:matrix]["exclude"] = [{"group" => "compiler"}] },
      "included group" => ->(c) { c[:matrix]["include"] = [{"group" => "compiler"}] },
      "fail fast" => ->(c) { c[:shard]["strategy"]["fail-fast"] = true },
      "unpinned runner" => ->(c) { c[:shard]["runs-on"] = "ubuntu-latest" },
      "optional groups" => ->(c) { c[:shard]["continue-on-error"] = true },
      "optional check" => ->(c) { c[:poison]["continue-on-error"] = true },
      "missing RISC-V checkout" => ->(c) { without_checkout.call(c, "riscv") },
      "missing coroutine checkout" => ->(c) { without_checkout.call(c, "coroutines") },
      "missing ownership checkout" => ->(c) { without_checkout.call(c, "riscv-ownership") },
      "missing downstream checkout" => ->(c) { without_checkout.call(c, "downstream") },
      "optional oracle checkout" => ->(c) { c[:checkout]["continue-on-error"] = true },
      "optional memu" => ->(c) { c[:checkout]["env"]["MERE_REQUIRE_MEMU"] = "false" },
      "shared writable cache" => ->(c) { c[:cache]["if"] = "${{ !cancelled() && (matrix.group == 'compiler' || matrix.group == 'downstream') }}" },
      "missing README gate" => ->(c) { c[:steps].reject! { |s| s["name"] == FIRST_RUN } },
      "renamed README gate" => ->(c) { c[:steps].find { |s| s["name"] == FIRST_RUN }["name"] = "README renamed" },
      "README in wrong group" => ->(c) { c[:steps].find { |s| s["name"] == FIRST_RUN }["if"] = "${{ !cancelled() && matrix.group == 'compiler' }}" },
      "README back in containers" => ->(c) { c[:steps].find { |s| s["name"] == FIRST_RUN }["if"] = "${{ !cancelled() && matrix.group == 'containers' }}" },
      "empty README gate" => ->(c) { c[:steps].find { |s| s["name"] == FIRST_RUN }["run"] = "true" },
      "optional README gate" => ->(c) { c[:steps].find { |s| s["name"] == FIRST_RUN }["continue-on-error"] = true },
      "missing parity gate" => ->(c) { c[:steps].reject! { |s| s["name"] == PARITY } },
      "renamed parity gate" => ->(c) { c[:steps].find { |s| s["name"] == PARITY }["name"] = "parity renamed" },
      "parity back in runtime" => ->(c) { c[:steps].find { |s| s["name"] == PARITY }["if"] = "${{ !cancelled() && matrix.group == 'runtime' }}" },
      "optional parity gate" => ->(c) { c[:steps].find { |s| s["name"] == PARITY }["continue-on-error"] = true },
      "parity bypassed" => ->(c) { c[:steps].find { |s| s["name"] == PARITY }["run"] = "true" },
      "missing formatter gate" => ->(c) { c[:steps].reject! { |s| s["name"] == FORMATTERS.keys.first } },
      "renamed formatter gate" => ->(c) { c[:steps].find { |s| s["name"] == FORMATTERS.keys.first }["name"] = "formatter renamed" },
      "formatter in wrong group" => ->(c) { c[:steps].find { |s| s["name"] == FORMATTERS.keys.first }["if"] = "${{ !cancelled() && matrix.group == 'compiler' }}" },
      "formatter poison removed" => ->(c) { c[:steps].find { |s| s["name"] == FORMATTERS.keys.first }["run"] = "sh scripts/fmt_comments_check.sh\n" },
      "formatter corpus removed" => ->(c) { c[:steps].find { |s| s["name"] == FORMATTERS.keys.last }["run"] = "sh scripts/fmt_roundtrip_check.sh --poison\n" },
      "optional formatter" => ->(c) { c[:steps].find { |s| s["name"] == FORMATTERS.keys.last }["continue-on-error"] = true },
      "examples back in runtime" => ->(c) { c[:steps].find { |s| s["name"] == RUNTIME_MOVES.keys.first }["if"] = "${{ !cancelled() && matrix.group == 'runtime' }}" },
      "renamed examples gate" => ->(c) { c[:steps].find { |s| s["name"] == RUNTIME_MOVES.keys.first }["name"] = "examples renamed" },
      "examples poison removed" => ->(c) { c[:steps].find { |s| s["name"] == RUNTIME_MOVES.keys.first }["run"] = "sh scripts/examples_parity.sh\n" },
      "softfloat back in runtime" => ->(c) { c[:steps].find { |s| s["name"] == RUNTIME_MOVES.keys.last }["if"] = "${{ !cancelled() && matrix.group == 'runtime' }}" },
      "renamed softfloat gate" => ->(c) { c[:steps].find { |s| s["name"] == RUNTIME_MOVES.keys.last }["name"] = "softfloat renamed" },
      "softfloat bypassed" => ->(c) { c[:steps].find { |s| s["name"] == RUNTIME_MOVES.keys.last }["run"] = "true" },
      "missing full suite" => ->(c) { c[:steps].delete(c[:full]) },
      "empty full suite" => ->(c) { c[:full]["run"] = "true" },
      "missing required preflight" => ->(c) { c[:steps].reject! { |s| s["name"] == PREFLIGHT } },
      "missing package preparation" => ->(c) { c[:steps].reject! { |s| s["name"] == PACKAGES } },
      "skipped setup" => ->(c) { c[:steps].find { |s| s["name"] == "Build" }["if"] = "false" },
      "unscoped RISC-V install" => ->(c) { c[:steps].find { |s| s["name"] == RISCV_TOOLS.first }.delete("if") },
      "missing RISC-V install" => ->(c) { c[:steps].reject! { |s| s["name"] == RISCV_TOOLS.first } },
      "optional RISC-V install" => ->(c) { c[:steps].find { |s| s["name"] == RISCV_TOOLS.first }["continue-on-error"] = true },
      "unbounded package install" => ->(c) { c[:steps].find { |s| s["name"] == RISCV_TOOLS.first }.delete("timeout-minutes") },
      "unbounded setup action" => ->(c) { c[:steps].find { |s| s["name"] == "Set up OCaml" }.delete("timeout-minutes") },
      "excessive compiler setup" => ->(c) { c[:steps].find { |s| s["name"] == "Set up OCaml" }["timeout-minutes"] = 31 },
      "global preflight in isolated group" => ->(c) { c[:steps].find { |s| s["name"] == PREFLIGHT }.delete("env") },
      "missing group dependency" => ->(c) { c[:final]["needs"] = ["gate_plan"] },
      "skipped final check" => ->(c) { c[:final].delete("if") },
      "ignored final failure" => ->(c) { c[:final]["continue-on-error"] = true },
      "always successful result" => ->(c) { c[:final]["steps"].first["run"] = "true" },
      "ignored assignment result" => ->(c) { c[:final]["steps"].first["run"] = '[ "$GATE_SHARDS_RESULT" = success ]' }
    }
    RISCV_BOUNDARIES.each_key do |name|
      mutations["missing #{name}"] = ->(c) { c[:steps].reject! { |s| s["name"] == name } }
      mutations["renamed #{name}"] = ->(c) { c[:steps].find { |s| s["name"] == name }["name"] = "boundary renamed" }
      mutations["previous group for #{name}"] = ->(c) { c[:steps].find { |s| s["name"] == name }["if"] = "${{ !cancelled() && matrix.group == 'riscv-ownership' }}" }
      mutations["optional #{name}"] = ->(c) { c[:steps].find { |s| s["name"] == name }["continue-on-error"] = true }
      mutations["no poison for #{name}"] = ->(c) { c[:steps].find { |s| s["name"] == name }["run"].sub!(" --poison", "") }
      mutations["no width filter for #{name}"] = ->(c) { c[:steps].find { |s| s["name"] == name }["run"].sub!(" --rv-only", "") }
      mutations["no memu oracle for #{name}"] = ->(c) { c[:steps].find { |s| s["name"] == name }["run"].sub!('MEMU="$RUNNER_TEMP/downstream/memu" ', "") }
    end
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
    check_oracle_checkout(workflow["jobs"]["gate_shards"]["steps"].find { |s| s["name"] == CHECKOUT })
    puts "ci_gates: #{mutations.length} negative controls caught; 36 result combinations checked"
  end

  def self.check_release_tools(workflows)
    tools = {
      ["ci.yml", "gate_shards", "Install the Wasm component toolchain"] => [
        "WASM_TOOLS=1.255.0", "WASMTIME=46.0.1", "BINARYEN=132",
        "--repo bytecodealliance/wasm-tools", "--repo bytecodealliance/wasmtime", "--repo WebAssembly/binaryen"],
      ["ci.yml", "gate_shards", "Install protoc (oracle for proto_parity)"] => [
        "PROTOC=27.3", "--repo protocolbuffers/protobuf", "--sha256 6dab2adab83f915126cab53540d48957c40e9e9023969c3e84d44bfb936c7741"],
      ["ci.yml", "gate_shards", "Install grpcurl (client for grpc_parity)"] => [
        "GRPCURL=1.8.8", "--repo fullstorydev/grpcurl", "--sha256 a47140caf9b9ef019d4e3b5f7138b16f54b7a0da117a3c8258dc50911737a68b"],
      ["pages.yml", "build", "Install binaryen (wasm-opt), pinned as in ci.yml"] => [
        "BINARYEN=132", "--repo WebAssembly/binaryen"]
    }
    tools.each do |(file, job, label), pins|
      step = workflows.fetch(file).fetch("jobs").fetch(job).fetch("steps").find { |s| s["name"] == label }
      require!(step && step["timeout-minutes"].is_a?(Integer) && (1..10).cover?(step["timeout-minutes"]) &&
               !step.key?("if") && !step["continue-on-error"] && step.fetch("env", {})["GH_TOKEN"] == "${{ github.token }}",
               "#{label}: verified release tool installation must remain bounded and required")
      run = step.fetch("run")
      require!(run.include?("python3 scripts/ci_release_asset.py") && pins.all? { |pin| run.include?(pin) } &&
               !run.include?("/releases/download/"), "#{label}: retain pinned release API downloads")
    end
  end

  def self.release_tools_self_test(workflows)
    checks = 0
    [["ci.yml", "gate_shards", "Install the Wasm component toolchain"],
     ["ci.yml", "gate_shards", "Install protoc (oracle for proto_parity)"],
     ["ci.yml", "gate_shards", "Install grpcurl (client for grpc_parity)"],
     ["pages.yml", "build", "Install binaryen (wasm-opt), pinned as in ci.yml"]].each do |file, job, label|
      %w[removed skipped optional timeout token helper pin].each do |poison|
        copy = Marshal.load(Marshal.dump(workflows))
        steps = copy.fetch(file).fetch("jobs").fetch(job).fetch("steps")
        step = steps.find { |s| s["name"] == label }
        case poison
        when "removed" then steps.delete(step)
        when "skipped" then step["if"] = false
        when "optional" then step["continue-on-error"] = true
        when "timeout" then step.delete("timeout-minutes")
        when "token" then step.delete("env")
        when "helper" then step["run"].gsub!("python3 scripts/ci_release_asset.py", "curl")
        when "pin" then step["run"].gsub!(/(?:WASM_TOOLS|PROTOC|GRPCURL|BINARYEN)=/, "UNPINNED=")
        end
        begin
          check_release_tools(copy)
        rescue Invalid
          checks += 1
          next
        end
        raise Invalid, "release tool control stayed green: #{label}/#{poison}"
      end
    end
    stdout, stderr, status = Open3.capture3("python3", File.join(__dir__, "ci_release_asset.py"), "--self-test")
    require!(status.success?, "release asset controls failed: #{stdout}#{stderr}")
    puts "ci_gates: #{checks} release tool routing controls caught; digest and atomic replacement controls passed"
  end

  def self.check_opam_setup(workflows)
    [["ci.yml", "build"], ["ci.yml", "gate_shards"],
     ["pages.yml", "build"], ["release-build.yml", "binary"]].each do |file, job|
      steps = workflows.fetch(file).fetch("jobs").fetch(job).fetch("steps")
      matches = steps.select { |step| step["name"] == "Cache verified opam" }
      require!(matches.length == 1, "#{file}/#{job}: signed opam bootstrap must run once")
      cache = matches.first
      setup = steps.find { |step| step["name"] == "Set up OCaml" }
      require!(setup && setup["uses"] == "ocaml/setup-ocaml@ff66428f72b64472e749b22e0ad4dded4b2ddca6",
               "opam bootstrap must match the audited setup-ocaml tool-cache contract")
      require!(steps.index(cache) < steps.index(setup), "verified opam must precede compiler setup")
      require!(cache["run"] == "python3 scripts/ci_opam_setup.py" && cache["timeout-minutes"] == 5 &&
               cache["env"] == {"GH_TOKEN" => "${{ github.token }}"} &&
               !cache.key?("if") && !cache["continue-on-error"],
               "signed opam bootstrap must remain bounded and required")
    end
  end

  def self.opam_setup_self_test(workflows)
    checks = 0
    [["ci.yml", "build"], ["ci.yml", "gate_shards"],
     ["pages.yml", "build"], ["release-build.yml", "binary"]].each do |file, job|
      %w[removed skipped optional timeout command token order contract].each do |poison|
        copy = Marshal.load(Marshal.dump(workflows))
        steps = copy.fetch(file).fetch("jobs").fetch(job).fetch("steps")
        cache = steps.find { |step| step["name"] == "Cache verified opam" }
        setup = steps.find { |step| step["name"] == "Set up OCaml" }
        case poison
        when "removed" then steps.delete(cache)
        when "skipped" then cache["if"] = false
        when "optional" then cache["continue-on-error"] = true
        when "timeout" then cache.delete("timeout-minutes")
        when "command" then cache["run"] = "true"
        when "token" then cache.delete("env")
        when "order" then steps.delete(cache); steps << cache
        when "contract" then setup["uses"] = "ocaml/setup-ocaml@v3"
        end
        begin
          check_opam_setup(copy)
        rescue Invalid
          checks += 1
          next
        end
        raise Invalid, "opam bootstrap control was not caught: #{file}/#{job}/#{poison}"
      end
    end
    _, error, status = Open3.capture3("python3", File.join(__dir__, "ci_opam_setup.py"), "--self-test")
    require!(status.success?, "signed opam bootstrap controls failed: #{error}")
    puts "ci_gates: #{checks} opam bootstrap routing controls caught; signature/digest/cache controls passed"
  end

  # Setup bounds also cover the matrix and publication workflows. Compiler
  # setup can take 26 minutes on a cold runner, so it has a separate ceiling
  # from the smaller tool downloads in the integration groups.
  def self.check_setup(workflows)
    jobs = {
      "ci.yml" => {"build" => 60, "gate_plan" => 10, "gate_shards" => 90, "gates" => 5},
      "pages.yml" => {"build" => 60, "deploy" => 10},
      "release-build.yml" => {"binary" => 60},
      "release.yml" => {"create-release" => 10, "checksums" => 20}
    }
    jobs.each do |file, names|
      workflow = workflows.fetch(file)
      names.each do |name, ceiling|
        job = workflow.fetch("jobs").fetch(name)
        timeout = job["timeout-minutes"]
        require!(timeout.is_a?(Integer) && (1..ceiling).cover?(timeout),
                 "#{file}/#{name}: job needs a bounded timeout")
        require!(!job["continue-on-error"], "#{file}/#{name}: setup failure must remain visible")
        require!(!job.key?("if") || (file == "ci.yml" && name == "gates" && job["if"] == "${{ always() }}"),
                 "#{file}/#{name}: required jobs must not be skipped")
        job.fetch("steps").each do |step|
          if step["uses"].to_s.start_with?("actions/checkout@", "actions/upload-", "actions/deploy-pages@")
            t = step["timeout-minutes"]
            require!(t.is_a?(Integer) && (1..5).cover?(t), "#{file}/#{name}: network action needs a bounded timeout")
            require!(!step["continue-on-error"], "#{file}/#{name}: required network action must report failure")
            if file == "release-build.yml" && step["uses"].to_s.start_with?("actions/upload-artifact@")
              require!(step["if"] == "${{ !inputs.publish-draft }}", "distribution inspection artifact must retain its condition")
            else
              require!(!step.key?("if"), "#{file}/#{name}: required network action must not be skipped")
            end
          end
        end
      end
    end
    [["ci.yml", "build", true], ["pages.yml", "build", false], ["release-build.yml", "binary", false]].each do |file, name, tests|
      job = workflows.fetch(file).fetch("jobs").fetch(name)
      require!(job.fetch("env")["OPAMRETRIES"] == "2", "#{file}: bound opam download attempts")
      [["Set up OCaml", 30], ["Install dependencies", 15]].each do |label, ceiling|
        matches = job.fetch("steps").select { |s| s["name"] == label }
        require!(matches.length == 1, "#{file}: required setup step is missing or duplicated")
        step = matches.first
        t = step["timeout-minutes"]
        require!(t.is_a?(Integer) && (1..ceiling).cover?(t), "#{file}/#{label}: setup needs a bounded timeout")
        require!(!step.key?("if") && !step["continue-on-error"], "#{file}/#{label}: setup must be required")
        if label == "Install dependencies"
          expected = "sh scripts/retry.sh opam install . --deps-only" + (tests ? " --with-test" : "")
          require!(step["run"] == expected, "#{file}: dependency installation must retain its bounded retry")
        end
      end
    end
    [["ci.yml", "build", true], ["ci.yml", "gate_shards", false],
     ["pages.yml", "build", false], ["release-build.yml", "binary", true]].each do |file, name, conditional|
      steps = workflows.fetch(file).fetch("jobs").fetch(name).fetch("steps")
      matches = steps.select { |s| s["name"] == "Configure Ubuntu package downloads" }
      require!(matches.length == 1, "#{file}/#{name}: Ubuntu package configuration must run once")
      apt = matches.first
      setup = steps.find { |s| s["name"] == "Set up OCaml" }
      require!(steps.index(apt) < steps.index(setup), "#{file}/#{name}: configure downloads before OCaml setup")
      require!(apt["run"] == "sudo python3 scripts/ci_apt_setup.py /etc/apt" &&
               apt["timeout-minutes"] == 1 && !apt["continue-on-error"],
               "#{file}/#{name}: require bounded Ubuntu package configuration")
      require!(conditional ? apt["if"] == "${{ runner.os == 'Linux' }}" : !apt.key?("if"),
               "#{file}/#{name}: Ubuntu package configuration must run on every Linux runner")
      require!(setup.fetch("with")["cache"] == true, "#{file}/#{name}: retain the opam compiler cache")
    end
    pages = workflows.fetch("pages.yml").fetch("jobs").fetch("build").fetch("steps")
    apt = pages.find { |s| s["name"] == "Install wabt (wat2wasm)" }
    curl = pages.find { |s| s["name"] == "Install binaryen (wasm-opt), pinned as in ci.yml" }
    [apt, curl].each do |step|
      require!(step && step["timeout-minutes"].is_a?(Integer) && (1..10).cover?(step["timeout-minutes"]),
               "Pages tool installation needs a bounded timeout")
      require!(!step.key?("if") && !step["continue-on-error"], "Pages tool installation must remain required")
    end
    apt_commands = apt.fetch("run").lines.select { |line| line.include?("sudo apt-get") }
    require!(apt_commands.length == 2 && apt_commands.all? { |line|
      %w[Acquire::Retries=2 Acquire::http::Timeout=30 Acquire::https::Timeout=30].all? { |flag| line.include?(flag) }
    }, "Pages apt requests need bounded retries and timeouts")
    require!(curl.fetch("run").include?("python3 scripts/ci_release_asset.py --repo WebAssembly/binaryen"),
             "Pages tool download must use the verified, bounded release API helper")
    [["release-build.yml", "binary", "Upload to draft release and verify the served bytes"],
     ["release.yml", "create-release", "Create (or reuse) the release"],
     ["release.yml", "checksums", "Publish checksums of the verified release assets"]].each do |file, job, label|
      step = workflows.fetch(file).fetch("jobs").fetch(job).fetch("steps").find { |s| s["name"] == label }
      require!(step && step["timeout-minutes"].is_a?(Integer) && (1..15).cover?(step["timeout-minutes"]),
               "#{file}/#{label}: release transfer needs a bounded timeout")
      require!(!step["continue-on-error"], "#{file}/#{label}: release transfer must report failure")
      expected_condition = file == "release-build.yml" ? "${{ inputs.publish-draft }}" : nil
      require!(expected_condition ? step["if"] == expected_condition : !step.key?("if"),
               "#{file}/#{label}: release transfer must retain its condition")
    end
  end

  def self.setup_self_test(workflows)
    checks = 0
    [["ci.yml", "build"], ["pages.yml", "build"], ["release-build.yml", "binary"]].each do |file, name|
      ["job", "compiler", "dependencies", "retry", "optional", "skipped", "downloads", "skipped-job", "optional-job", "boolean-step"].each do |poison|
        copy = Marshal.load(Marshal.dump(workflows))
        job = copy.fetch(file).fetch("jobs").fetch(name)
        setup = job.fetch("steps").find { |s| s["name"] == "Set up OCaml" }
        deps = job.fetch("steps").find { |s| s["name"] == "Install dependencies" }
        case poison
        when "job" then job.delete("timeout-minutes")
        when "compiler" then setup["timeout-minutes"] = 31
        when "dependencies" then deps.delete("timeout-minutes")
        when "retry" then deps["run"] = "opam install . --deps-only"
        when "optional" then setup["continue-on-error"] = true
        when "skipped" then setup["if"] = "false"
        when "downloads" then job.fetch("env").delete("OPAMRETRIES")
        when "skipped-job" then job["if"] = false
        when "optional-job" then job["continue-on-error"] = true
        when "boolean-step" then setup["if"] = false
        end
        begin
          check_setup(copy)
        rescue Invalid, KeyError
          checks += 1
          next
        end
        raise Invalid, "setup negative control stayed green: #{file}/#{poison}"
      end
    end
    %w[apt curl checkout transfer deployment artifact tool-optional tool-skipped transfer-optional artifact-optional].each do |poison|
      copy = Marshal.load(Marshal.dump(workflows))
      steps = copy["pages.yml"]["jobs"]["build"]["steps"]
      case poison
      when "apt" then steps.find { |s| s["name"] == "Install wabt (wat2wasm)" }["run"].gsub!("Acquire::Retries=2", "Acquire::Retries=0")
      when "curl" then steps.find { |s| s["name"] == "Install binaryen (wasm-opt), pinned as in ci.yml" }["run"].gsub!("python3 scripts/ci_release_asset.py", "curl")
      when "checkout" then steps.find { |s| s["uses"].to_s.start_with?("actions/checkout@") }.delete("timeout-minutes")
      when "transfer" then copy["release.yml"]["jobs"]["checksums"]["steps"].last.delete("timeout-minutes")
      when "deployment" then copy["pages.yml"]["jobs"]["deploy"]["steps"].first["if"] = false
      when "artifact" then copy["release-build.yml"]["jobs"]["binary"]["steps"].find { |s| s["uses"].to_s.start_with?("actions/upload-artifact@") }["if"] = false
      when "tool-optional" then steps.find { |s| s["name"] == "Install wabt (wat2wasm)" }["continue-on-error"] = true
      when "tool-skipped" then steps.find { |s| s["name"] == "Install binaryen (wasm-opt), pinned as in ci.yml" }["if"] = false
      when "transfer-optional" then copy["release.yml"]["jobs"]["checksums"]["steps"].last["continue-on-error"] = true
      when "artifact-optional" then copy["release-build.yml"]["jobs"]["binary"]["steps"].find { |s| s["uses"].to_s.start_with?("actions/upload-artifact@") }["continue-on-error"] = true
      end
      begin
        check_setup(copy)
      rescue Invalid, KeyError
        checks += 1
        next
      end
      raise Invalid, "setup negative control stayed green: #{poison}"
    end
    [["ci.yml", "build"], ["ci.yml", "gate_shards"],
     ["pages.yml", "build"], ["release-build.yml", "binary"]].each do |file, name|
      %w[missing late optional skipped timeout cache].each do |poison|
        copy = Marshal.load(Marshal.dump(workflows))
        steps = copy.fetch(file).fetch("jobs").fetch(name).fetch("steps")
        apt = steps.find { |s| s["name"] == "Configure Ubuntu package downloads" }
        case poison
        when "missing" then steps.delete(apt)
        when "late" then steps.delete(apt); steps.push(apt)
        when "optional" then apt["continue-on-error"] = true
        when "skipped" then apt["if"] = false
        when "timeout" then apt.delete("timeout-minutes")
        when "cache" then steps.find { |s| s["name"] == "Set up OCaml" }.fetch("with")["cache"] = false
        end
        begin
          check_setup(copy)
        rescue Invalid, KeyError
          checks += 1
          next
        end
        raise Invalid, "setup negative control stayed green: #{file}/#{name}/#{poison}"
      end
    end
    stdout, stderr, status = Open3.capture3("python3", File.expand_path("ci_apt_setup_test.py", __dir__))
    require!(status.success?, "Ubuntu package configuration tests failed: #{stdout}#{stderr}")
    check_retry
    puts "ci_gates: #{checks} setup negative controls caught; dependency retry behavior checked"
  end

  def self.check_retry
    script = File.expand_path("retry.sh", __dir__)
    Dir.mktmpdir("mere-network-retry-") do |tmp|
      FileUtils.mkdir_p("#{tmp}/bin")
      File.write("#{tmp}/bin/sleep", "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$RETRY_SLEEP\"\n")
      File.write("#{tmp}/command", <<~SH)
        #!/bin/sh
        [ "$#" = 1 ] && [ "$1" = 'argument with spaces' ] || exit 77
        n=0
        [ ! -f "$RETRY_COUNT" ] || n=$(cat "$RETRY_COUNT")
        n=$((n + 1)); echo "$n" > "$RETRY_COUNT"
        [ "$RETRY_MODE" != fail ] || exit 42
        [ "$RETRY_MODE" != cancel ] || exit 130
        [ "$RETRY_MODE" != missing ] || exit 127
        [ "$RETRY_MODE" != once ] || [ "$n" -gt 1 ] || exit 41
      SH
      File.chmod(0755, "#{tmp}/bin/sleep")
      File.chmod(0755, "#{tmp}/command")
      {"success" => [0, 1], "once" => [0, 2], "fail" => [42, 2], "cancel" => [130, 1], "missing" => [127, 1]}.each do |mode, (code, count)|
        env = {"PATH" => "#{tmp}/bin:#{ENV.fetch('PATH')}", "RETRY_MODE" => mode,
               "RETRY_COUNT" => "#{tmp}/count-#{mode}", "RETRY_SLEEP" => "#{tmp}/sleep-#{mode}"}
        _, _, status = Open3.capture3(env, "/bin/sh", script, "#{tmp}/command", "argument with spaces")
        require!(status.exitstatus == code && File.read(env["RETRY_COUNT"]).to_i == count,
                 "dependency retry #{mode}: wrong status or attempt count")
        sleeps = File.exist?(env["RETRY_SLEEP"]) ? File.readlines(env["RETRY_SLEEP"]).map(&:strip) : []
        require!(sleeps == (count == 1 ? [] : ["5"]), "dependency retry #{mode}: wrong backoff")
      end
      _, _, status = Open3.capture3("/bin/sh", script)
      require!(status.exitstatus == 2, "dependency retry must reject an empty command")
    end
  end

  # Execute the workflow's checkout body with a fake clone, so losing an
  # oracle cannot silently turn a newly isolated job into native-only coverage.
  def self.check_oracle_checkout(step)
    Dir.mktmpdir("mere-ci-checkout-") do |tmp|
      FileUtils.mkdir_p(["#{tmp}/bin", "#{tmp}/workspace/test/downstream"])
      File.write("#{tmp}/workspace/test/downstream/REPOS", "memu emulator compile\n")
      File.write("#{tmp}/bin/git", <<~SH)
        #!/bin/sh
        [ "$MERE_CHECKOUT_CASE" != clone-failure ] || exit 1
        for destination do :; done
        mkdir -p "$destination/riscv-runc"
        for width in 32 64; do
          [ "$MERE_CHECKOUT_CASE" != "missing-$width" ] || continue
          touch "$destination/riscv-runc/rv${width}i_run.mere"
        done
      SH
      File.chmod(0755, "#{tmp}/bin/git")
      %w[complete missing-32 missing-64 clone-failure].product(%w[true false]).each_with_index do |(state, required), i|
        _, _, status = Open3.capture3({
          "PATH" => "#{tmp}/bin:#{ENV.fetch('PATH')}",
          "GITHUB_WORKSPACE" => "#{tmp}/workspace",
          "RUNNER_TEMP" => "#{tmp}/run-#{i}",
          "MERE_REQUIRE_MEMU" => required,
          "MERE_CHECKOUT_CASE" => state
        }, "/bin/sh", "-e", "-c", step.fetch("run"))
        expected = state == "complete" || required == "false"
        require!(status.success? == expected, "oracle checkout #{state}, required=#{required}: unexpected status")
      end
    end
    puts "ci_gates: 8 oracle checkout cases checked"
  end
end

if $PROGRAM_NAME == __FILE__
  group = ARGV[0] == "--group" && ARGV.length == 2 ? ARGV[1] : nil
  abort "usage: ruby scripts/ci_gate_check.rb [--self-test | --group NAME]" unless group || (ARGV - ["--self-test"]).empty?
  begin
    path = File.expand_path("../.github/workflows/ci.yml", __dir__)
    workflow = YAML.safe_load(File.read(path), aliases: false)
    if group
      puts CIGates.group_commands(workflow, group)
      exit 0
    end
    assigned = CIGates.check(workflow)
    workflows = {"ci.yml" => workflow}
    %w[pages.yml release-build.yml release.yml].each do |name|
      workflows[name] = YAML.safe_load(File.read(File.join(File.dirname(path), name)), aliases: false)
    end
    CIGates.check_setup(workflows)
    CIGates.check_opam_setup(workflows)
    CIGates.check_release_tools(workflows)
    puts "ci_gates: #{assigned.values.sum(&:length)} checks assigned exactly once across #{assigned.length} groups"
    assigned.each { |group, checks| puts "  #{group}: #{checks.length}" }
    CIGates.self_test(workflow) if ARGV.include?("--self-test")
    CIGates.setup_self_test(workflows) if ARGV.include?("--self-test")
    CIGates.opam_setup_self_test(workflows) if ARGV.include?("--self-test")
    CIGates.release_tools_self_test(workflows) if ARGV.include?("--self-test")
  rescue CIGates::Invalid, KeyError, Psych::Exception => e
    warn "ci_gates: #{e.message}"
    exit 1
  end
end
