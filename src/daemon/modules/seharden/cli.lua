local log = require('runtime.log')
local engine = require('seharden.engine')
local profile = require('seharden.profile')
local cjson = require('cjson.safe')
local os = require('os')

local M = {}

local DEFAULT_CONFIG = "cis_alinux_3"
local DEFAULT_RULES_PATH = os.getenv("LOONGSHIELD_SEHARDEN_RULES_PATH")
    or "/etc/loongshield/seharden"

local USAGE = string.format([[
Usage: loongshield seharden [--scan|--reinforce] [options]

SEHarden Security Benchmark Scanning & OS Hardening

Modes:
  --scan              Audit the selected profile and report failing rules. (Default)
  --reinforce         Apply reinforce actions for failing rules.

Options:
  --config <ruleset>  Profile name or YAML path to load. (Default: %s)
  --level <level>     Limit execution to a profile level (for example: l1_server).
  --dry-run           Preview reinforce actions without changing the system.
  --format <format>   Output format: text or json. (Default: text)
  --verbose           Show rule-level evidence in a human-friendly format.
  --log-level <level> Set the logging level (trace, debug, info, warn, error).
  -h, --help          Show this help message.

Ruleset Search Path:
  $LOONGSHIELD_SEHARDEN_RULES_PATH
  Current default: %s

Notes:
  The default profile '%s' targets Alibaba Cloud Linux 3 / OpenAnolis-style hosts.
  Use --config to select a different profile on other RPM-based systems.
  If --level is omitted, seharden uses the profile default level when defined;
  otherwise it runs all rules in the selected profile.
  --dry-run only affects --reinforce mode.

Exit Codes:
  0 - Scan passed, or reinforce completed with no remaining failures
  1 - CLI error, profile load error, scan failures, or dry-run pending changes

Examples:
  loongshield seharden
  loongshield seharden --config agentos_baseline
  loongshield seharden --config cis_alinux_3 --level l1_server
  loongshield seharden --config agentos_baseline --verbose
  loongshield seharden --reinforce --config agentos_baseline --dry-run
  loongshield seharden --reinforce --config /etc/loongshield/seharden/dengbao_3.yml
]], DEFAULT_CONFIG, DEFAULT_RULES_PATH, DEFAULT_CONFIG)

local function print_usage()
    print(USAGE)
end

local function get_level_ids(profile_data)
    local level_ids = {}

    if type(profile_data) ~= "table" or type(profile_data.levels) ~= "table" then
        return level_ids
    end

    for _, level in ipairs(profile_data.levels) do
        if type(level) == "table" and type(level.id) == "string" and level.id ~= "" then
            table.insert(level_ids, level.id)
        end
    end

    table.sort(level_ids)
    return level_ids
end

local function format_level_ids(profile_data)
    local level_ids = get_level_ids(profile_data)
    if #level_ids == 0 then
        return nil
    end

    return table.concat(level_ids, ", ")
end

local function get_manual_review_items(profile_data, target_level)
    if type(profile.get_manual_review_items_for_level) ~= "function" then
        return {}
    end

    local items, err = profile.get_manual_review_items_for_level(profile_data, target_level)
    if items == nil then
        log.warn("Failed to resolve manual review items: %s", tostring(err))
        return {}
    end

    return items
end

local function format_manual_review_suffix(mode, count)
    if mode ~= "scan" or count <= 0 then
        return ""
    end

    return string.format(", %d manual-review item(s)", count)
end

local function emit_manual_review_summary(items)
    if #items == 0 then
        return
    end

    print(string.format(
        "Manual Review Summary: %d item(s) outside automated coverage",
        #items))
    for _, entry in ipairs(items) do
        print(string.format("  - [%s] %s", entry.area, entry.item))
        print(string.format("    reason: %s", entry.reason))
    end
end

local function build_json_report(base)
    local encoded, err = cjson.encode(base)
    if not encoded then
        return nil, err
    end
    return encoded
end

local function print_json_report(report)
    report.schema_version = report.schema_version or 1
    report.format = report.format or "json"

    local encoded, err = build_json_report(report)
    if encoded then
        print(encoded)
    else
        print('{"schema_version":1,"format":"json","exit_code":1,"error":"failed to encode JSON report"}')
    end
end

local function with_silent_logs(enabled, fn)
    if not enabled then
        return fn()
    end

    local saved_silent = log.silent
    log.silent = true
    local ok, a, b, c = pcall(fn)
    log.silent = saved_silent
    if not ok then
        error(a, 2)
    end
    return a, b, c
end

local function parse_args(argv)
    local opts = {}
    local i = 1

    while i <= #argv do
        local arg = argv[i]
        local inline_key, inline_value = arg:match("^%-%-([%w%-]+)=(.+)$")

        if inline_key == "config" or inline_key == "level" or inline_key == "log-level" or inline_key == "format" then
            opts[inline_key] = inline_value
            i = i + 1
        elseif arg == "--config" or arg == "--log-level" or arg == "--level" or arg == "--format" then
            if i >= #argv then
                return nil, string.format("Option '%s' requires a value.", arg)
            end

            local key = arg:sub(3)
            opts[key] = argv[i + 1]
            i = i + 2
        elseif arg == "--scan" or arg == "--reinforce" or arg == "--help" or arg == "--dry-run" then
            opts[arg:sub(3)] = true
            i = i + 1
        elseif arg == "--verbose" then
            opts.verbose = true
            i = i + 1
        elseif arg == "-h" then
            opts.help = true
            i = i + 1
        else
            return nil, string.format("Unknown option: %s", arg)
        end
    end

    return opts
end

local function requested_json_format(argv)
    for i = 1, #argv do
        if argv[i] == "--format" and argv[i + 1] == "json" then
            return true
        end
        local inline_value = argv[i]:match("^%-%-format=(.+)$")
        if inline_value == "json" then
            return true
        end
    end
    return false
end

function M.run(argv)
    local opts, err = parse_args(argv)
    if not opts then
        if requested_json_format(argv) then
            print_json_report({
                exit_code = 1,
                error = err,
            })
        else
            log.error(err)
            print("")
            print_usage()
        end
        return 1
    end

    if opts.help then
        print_usage()
        return 0
    end

    local output_format = opts.format or "text"
    if output_format ~= "text" and output_format ~= "json" then
        log.error("Unsupported output format '%s'. Expected 'text' or 'json'.", tostring(output_format))
        print("")
        print_usage()
        return 1
    end
    local json_output = output_format == "json"

    local log_level = opts['log-level'] or os.getenv("LOG_LEVEL")
    if log_level then
        with_silent_logs(json_output, function()
            log.setLevel(log_level)
        end)
    end

    if opts.scan and opts.reinforce then
        if json_output then
            print_json_report({
                exit_code = 1,
                error = "Options --scan and --reinforce are mutually exclusive.",
            })
        else
            log.error("Options --scan and --reinforce are mutually exclusive.")
            print("")
            print_usage()
        end
        return 1
    end

    local mode = opts.reinforce and "reinforce" or "scan"
    if opts["dry-run"] and mode ~= "reinforce" and not json_output then
        log.warn("Option '--dry-run' only affects --reinforce mode. Continuing with scan.")
    end

    local config_name = opts.config or DEFAULT_CONFIG
    local target_level = opts.level

    local profile_data = with_silent_logs(json_output, function()
        return profile.load(config_name)
    end)
    if not profile_data then
        if json_output then
            print_json_report({
                exit_code = 1,
                mode = mode,
                profile = config_name,
                level = target_level,
                error = string.format("Failed to load profile '%s'.", config_name),
            })
        end
        return 1
    end

    local effective_level = target_level
    if type(profile.resolve_target_level) == "function" then
        local resolved_level, level_err = with_silent_logs(json_output, function()
            return profile.resolve_target_level(profile_data, target_level)
        end)
        if resolved_level == nil and level_err ~= nil then
            if json_output then
                print_json_report({
                    exit_code = 1,
                    mode = mode,
                    profile = profile_data.id or config_name,
                    level = target_level,
                    error = tostring(level_err),
                })
            end
            return 1
        end
        effective_level = resolved_level
    end

    local rules_to_run, rules_err = with_silent_logs(json_output, function()
        return profile.get_rules_for_level(profile_data, effective_level)
    end)
    if not rules_to_run then
        local available_levels = format_level_ids(profile_data)
        if json_output then
            print_json_report({
                exit_code = 1,
                mode = mode,
                profile = profile_data.id or config_name,
                level = effective_level or "all",
                available_levels = get_level_ids(profile_data),
                error = rules_err or string.format(
                    "No rules available for level '%s'.",
                    tostring(effective_level or "all")),
            })
        elseif target_level and available_levels then
            log.info("Available levels for profile '%s': %s",
                profile_data.id or config_name, available_levels)
        end
        return 1
    end

    local manual_review_items = with_silent_logs(json_output, function()
        return get_manual_review_items(profile_data, effective_level)
    end)
    local manual_review_suffix = format_manual_review_suffix(mode, #manual_review_items)

    if opts.verbose and not json_output then
        print(string.format("%s: profile='%s', level='%s', %d rule(s)%s",
            log.style("SEHarden " .. mode, "bold", "cyan"),
            profile_data.id or config_name,
            effective_level or "all",
            #rules_to_run,
            manual_review_suffix))
    elseif not json_output then
        log.info("Running SEHarden %s with profile '%s' at level '%s' (%d rule(s)%s).",
            mode,
            profile_data.id or config_name,
            effective_level or "all",
            #rules_to_run,
            manual_review_suffix)
    end

    local exit_code, report = with_silent_logs(json_output, function()
        return engine.run(mode, rules_to_run, {
            dry_run = opts["dry-run"],
            verbose = opts.verbose or false,
            quiet = json_output,
        })
    end)

    if json_output then
        report.profile = profile_data.id or config_name
        report.level = effective_level or "all"
        report.manual_review = mode == "scan" and manual_review_items or {}
        print_json_report(report)
    elseif mode == "scan" then
        emit_manual_review_summary(manual_review_items)
    end

    return exit_code
end

return M
