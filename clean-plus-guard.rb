#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"
require "pathname"

class CleanPlusGuard
  def initialize(rulebook_path:, profile_key: nil, verbose: false)
    log("[CleanPlusGuard::initialize]") if verbose
    @rulebook_path = rulebook_path
    @requested_profile_key = profile_key
    @verbose = verbose
    @workspace_root = Pathname.new(Dir.pwd)
  end

  def run
    log("[CleanPlusGuard::run]")
    rulebook = load_rulebook
    profile_key, profile = select_profile(rulebook)

    violations = []
    roots = profile.fetch("roots")

    module_root = @workspace_root.join(roots.fetch("module_root"))
    shared_contracts_root = @workspace_root.join(roots.fetch("shared_contracts_root"))

    unless module_root.exist?
      puts "CleanPlusGuard SKIPPED (profile=#{profile_key})"
      puts "  module_root not found: #{module_root}"
      return 0
    end

    # Validate module roots first (contracts purity is a major source of accidental coupling).
    violations.concat(scan_shared_contracts(shared_contracts_root, roots))
    violations.concat(scan_modules(module_root, roots))
    violations.concat(scan_routing_violations(rulebook, profile_key))

    report(profile_key, violations)
    violations.empty? ? 0 : 2
  rescue KeyError => e
    warn "Config error: #{e.message}"
    3
  rescue Psych::SyntaxError => e
    warn "YAML parse error: #{e.message}"
    3
  end

  private

  def log(message)
    puts message if ENV["CLEAN_PLUS_GUARD_LOG"] == "1" || @verbose
  end

  def load_rulebook
    log("[CleanPlusGuard::load_rulebook]")
    YAML.load_file(@rulebook_path).fetch("clean_plus")
  end

  def select_profile(rulebook)
    log("[CleanPlusGuard::select_profile]")
    profiles = rulebook.fetch("profiles")
    return [@requested_profile_key, profiles.fetch(@requested_profile_key)] if @requested_profile_key

    detected = []
    profiles.each do |key, profile|
      roots = profile.fetch("roots")
      module_root = @workspace_root.join(roots.fetch("module_root"))
      detected << [key, profile] if module_root.exist?
    end

    if detected.empty?
      raise KeyError, "No matching profile detected (no configured module_root exists)."
    end

    if detected.size > 1
      raise KeyError, "Multiple profiles detected; pass --profile (#{detected.map(&:first).join(", ")})."
    end

    detected.first
  end

  def scan_shared_contracts(shared_contracts_root, roots)
    log("[CleanPlusGuard::scan_shared_contracts]")
    return [] unless shared_contracts_root.exist?

    violations = []
    each_code_file(shared_contracts_root) do |file_path|
      source_module = :shared_contracts
      violations.concat(find_cross_module_violations(file_path, source_module, roots, strict_contracts: true))
    end
    violations
  end

  def scan_modules(module_root, roots)
    log("[CleanPlusGuard::scan_modules]")
    violations = []

    each_code_file(module_root) do |file_path|
      module_name = module_name_for_file(file_path, module_root)
      next if module_name.nil? || module_name.casecmp("shared").zero?

      strict_contracts = file_path.to_s.include?(File.join(module_root.to_s, module_name, "contracts") + File::SEPARATOR)
      violations.concat(find_cross_module_violations(file_path, module_name, roots, strict_contracts: strict_contracts))
    end

    violations
  end

  def scan_routing_violations(rulebook, profile_key)
    log("[CleanPlusGuard::scan_routing_violations]")
    violations = []
    violations.concat(scan_forbidden_route_definitions(rulebook, profile_key))
    violations.concat(scan_route_autodiscovery(rulebook, profile_key))
    violations
  end

  def scan_forbidden_route_definitions(rulebook, profile_key)
    log("[CleanPlusGuard::scan_forbidden_route_definitions]")
    routing = rulebook["routing"]
    return [] unless routing.is_a?(Hash)

    locations = routing["locations"]
    return [] unless locations.is_a?(Hash)

    location = locations[profile_key]
    return [] unless location.is_a?(Hash)

    globs = location["forbidden_route_definition_glob"]
    return [] unless globs.is_a?(Array) && !globs.empty?

    route_definition_re = /\bRoute::(get|post|put|patch|delete|options|any|match|resource|apiResource|view)\b/
    violations = []

    globs.each do |glob|
      Dir.glob(@workspace_root.join(glob).to_s).each do |path|
        next unless File.file?(path)
        next unless File.extname(path).downcase == ".php"

        File.read(path).each_line.with_index(1) do |line, line_no|
          next unless (m = line.match(route_definition_re))

          violations << violation(
            path,
            { line: line_no, target: m[0] },
            "Forbidden route definition in framework-level routes file. Move routes into a module (delivery/http/routes) and mount them from the composition root (explicit list)."
          )
        end
      end
    end

    violations
  end

  def scan_route_autodiscovery(rulebook, profile_key)
    log("[CleanPlusGuard::scan_route_autodiscovery]")
    routing = rulebook["routing"]
    return [] unless routing.is_a?(Hash)

    locations = routing["locations"]
    return [] unless locations.is_a?(Hash)

    location = locations[profile_key]
    return [] unless location.is_a?(Hash)

    registration_location = location["registration_location"]
    return [] unless registration_location.is_a?(String)
    return [] unless registration_location.end_with?(".php")

    registration_file = @workspace_root.join(registration_location)
    return [] unless registration_file.exist?

    auto_discovery_re =
      /\b(glob\s*\(|RecursiveDirectoryIterator|RecursiveIteratorIterator|FilesystemIterator|Finder\b|File::allFiles|File::files|File::glob)\b/

    violations = []
    File.read(registration_file).each_line.with_index(1) do |line, line_no|
      next unless (m = line.match(auto_discovery_re))

      violations << violation(
        registration_file.to_s,
        { line: line_no, target: m[0] },
        "Forbidden route auto-discovery. Clean Plus requires an explicit list of module route files in the composition root."
      )
    end

    violations
  end

  def module_name_for_file(file_path, module_root)
    log("[CleanPlusGuard::module_name_for_file]")
    relative = Pathname.new(file_path).relative_path_from(module_root).each_filename.to_a
    relative.first
  rescue ArgumentError
    nil
  end

  def each_code_file(root_path)
    log("[CleanPlusGuard::each_code_file]")
    root = Pathname.new(root_path)
    return enum_for(:each_code_file, root_path) unless block_given?

    Dir.glob(root.join("**", "*")).each do |path|
      next unless File.file?(path)
      next unless code_file?(path)
      next if excluded_path?(path)

      yield path
    end
  end

  def code_file?(path)
    log("[CleanPlusGuard::code_file?]")
    ext = File.extname(path).downcase
    %w[.php .js .jsx .ts .tsx .mjs .cjs].include?(ext)
  end

  def excluded_path?(path)
    log("[CleanPlusGuard::excluded_path?]")
    path.include?("/vendor/") ||
      path.include?("/node_modules/") ||
      path.include?("/storage/") ||
      path.include?("/bootstrap/cache/") ||
      path.include?("/dist/") ||
      path.include?("/build/") ||
      path.include?("/coverage/") ||
      path.include?("/.git/")
  end

  def find_cross_module_violations(file_path, source_module, roots, strict_contracts:)
    log("[CleanPlusGuard::find_cross_module_violations]")
    content = File.read(file_path)
    imports = extract_imports(file_path, content)

    violations = []
    imports.each do |imp|
      ref = classify_reference(imp.fetch(:target), roots)
      next if ref.nil?

      # Ignore self-references.
      next if ref.fetch(:module) == source_module

      # Shared contracts can never depend on modules; module contracts can only depend on shared contracts.
      if source_module == :shared_contracts
        violations << violation(file_path, imp, "Shared contracts must not import modules (found #{ref.fetch(:module)}).")
        next
      end

      if strict_contracts
        violations << violation(file_path, imp, "Module contracts must not import other modules (found #{ref.fetch(:module)}).")
        next
      end

      # General module code: only allow other module contracts, never internals.
      if ref.fetch(:kind) == :module_contracts
        next
      end

      violations << violation(
        file_path,
        imp,
        "Forbidden cross-module import: #{source_module} -> #{ref.fetch(:module)} (allowed: other module contracts only)."
      )
    end

    violations
  end

  def extract_imports(file_path, content)
    log("[CleanPlusGuard::extract_imports]")
    ext = File.extname(file_path).downcase

    case ext
    when ".php"
      extract_php_imports(content)
    else
      extract_js_imports(content)
    end
  end

  def extract_php_imports(content)
    log("[CleanPlusGuard::extract_php_imports]")
    imports = []
    content.each_line.with_index(1) do |line, line_no|
      stripped = line.strip
      next unless stripped.start_with?("use ")
      next if stripped.start_with?("use function ") || stripped.start_with?("use const ")

      # Supports: use Foo\Bar; and use Foo\{Bar,Baz};
      statement = stripped.sub(/\Ause\s+/, "").sub(/;\s*\z/, "")
      if statement.include?("{") && statement.include?("}")
        prefix, rest = statement.split("{", 2)
        names = rest.split("}", 2).first.to_s.split(",").map(&:strip)
        names.each do |name|
          imports << { target: (prefix + name).strip, line: line_no }
        end
      else
        imports << { target: statement.strip.split(/\s+as\s+/i).first, line: line_no }
      end
    end
    imports
  end

  def extract_js_imports(content)
    log("[CleanPlusGuard::extract_js_imports]")
    imports = []
    content.each_line.with_index(1) do |line, line_no|
      # import ... from "x"
      if (m = line.match(/\bfrom\s+["']([^"']+)["']/))
        imports << { target: m[1], line: line_no }
      end
      # import("x")
      if (m = line.match(/\bimport\s*\(\s*["']([^"']+)["']\s*\)/))
        imports << { target: m[1], line: line_no }
      end
      # require("x")
      if (m = line.match(/\brequire\s*\(\s*["']([^"']+)["']\s*\)/))
        imports << { target: m[1], line: line_no }
      end
    end
    imports
  end

  def classify_reference(target, roots)
    log("[CleanPlusGuard::classify_reference]")
    return nil if target.nil? || target.empty?

    # Allow shared contracts references explicitly.
    shared_root = roots.fetch("shared_contracts_root")
    if target.include?(shared_root) || target.include?("/shared/contracts/") || target.include?("\\Shared\\Contracts\\")
      return nil
    end

    # Path-style references (TS/JS relative imports, aliases that still contain /modules/<X>/...).
    if (ref = classify_path_reference(target, roots))
      return ref
    end

    # Namespace-style references (PHP).
    classify_namespace_reference(target, roots)
  end

  def classify_path_reference(target, roots)
    log("[CleanPlusGuard::classify_path_reference]")
    module_root = roots.fetch("module_root")
    normalized = target.tr("\\", "/")

    # Try to find /modules/<Module>/... or /Domains/<Module>/... even if module_root isn't present in the import.
    segments = normalized.split("/")
    marker_index =
      segments.index("modules") ||
      segments.index("Domains") ||
      segments.index("domains")

    return nil if marker_index.nil?

    module_name = segments[marker_index + 1]
    return nil if module_name.nil? || module_name.empty? || module_name == "shared"

    kind = normalized.include?("/contracts/") ? :module_contracts : :module_internals
    { module: module_name, kind: kind, via: :path, module_root: module_root }
  end

  def classify_namespace_reference(target, roots)
    log("[CleanPlusGuard::classify_namespace_reference]")
    # Heuristic: match common Laravel modular-monolith namespaces.
    # Examples:
    # - App\Domains\User\Domain\...
    # - Domains\User\Contracts\...
    patterns = [
      /(?:\A|\\)App\\Domains\\(?<mod>[A-Za-z0-9_]+)\\(?<rest>.+)\z/,
      /(?:\A|\\)Domains\\(?<mod>[A-Za-z0-9_]+)\\(?<rest>.+)\z/
    ]

    patterns.each do |re|
      m = target.match(re)
      next unless m

      module_name = m[:mod]
      return nil if module_name.nil? || module_name.empty? || module_name.casecmp("shared").zero?

      rest = m[:rest].to_s
      kind = rest.include?("\\Contracts\\") ? :module_contracts : :module_internals
      return { module: module_name, kind: kind, via: :namespace, module_root: roots.fetch("module_root") }
    end

    nil
  end

  def violation(file_path, imp, message)
    log("[CleanPlusGuard::violation]")
    {
      file: file_path.to_s,
      line: imp.fetch(:line),
      target: imp.fetch(:target),
      message: message
    }
  end

  def report(profile_key, violations)
    log("[CleanPlusGuard::report]")
    if violations.empty?
      puts "CleanPlusGuard OK (profile=#{profile_key})"
      return
    end

    puts "CleanPlusGuard FAILED (profile=#{profile_key})"
    violations.each do |v|
      puts "#{v.fetch(:file)}:#{v.fetch(:line)}: #{v.fetch(:message)}"
      puts "  target: #{v.fetch(:target)}"
    end
  end

  def fail_with(message)
    log("[CleanPlusGuard::fail_with]")
    warn message
    3
  end
end

def parse_args(argv)
  puts "[CleanPlusGuard::parse_args]" if ENV["CLEAN_PLUS_GUARD_LOG"] == "1"
  rulebook_path = "clean-plus.rules.yaml"
  profile_key = nil
  verbose = false

  i = 0
  while i < argv.length
    case argv[i]
    when "--rules"
      rulebook_path = argv[i + 1]
      i += 2
    when "--profile"
      profile_key = argv[i + 1]
      i += 2
    when "--verbose"
      verbose = true
      i += 1
    when "--help", "-h"
      puts "Usage:"
      puts "  ./clean-plus-guard.rb [--rules clean-plus.rules.yaml] [--profile <key>] [--verbose]"
      puts
      puts "Examples:"
      puts "  ./clean-plus-guard.rb --profile framework_agnostic_src"
      puts "  ./clean-plus-guard.rb --profile laravel_app_domains"
      exit 0
    else
      warn "Unknown arg: #{argv[i]}"
      exit 3
    end
  end

  [rulebook_path, profile_key, verbose]
end

rulebook_path, profile_key, verbose = parse_args(ARGV)
guard = CleanPlusGuard.new(rulebook_path: rulebook_path, profile_key: profile_key, verbose: verbose)
exit guard.run
