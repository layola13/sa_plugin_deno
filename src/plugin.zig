const std = @import("std");
const plugin_api = @import("plugin_api");
const _api = @import("deno_saasm_api.zig");
// NOTE(Zig 0.17): usingnamespace removed.
pub const sa_deno_plugin_free_buffer = _api.sa_deno_plugin_free_buffer;
pub const sa_deno_plugin_hostname = _api.sa_deno_plugin_hostname;
pub const sa_deno_plugin_os_release = _api.sa_deno_plugin_os_release;
pub const sa_deno_plugin_os_uptime = _api.sa_deno_plugin_os_uptime;
pub const sa_deno_plugin_loadavg = _api.sa_deno_plugin_loadavg;
pub const sa_deno_plugin_system_memory_info = _api.sa_deno_plugin_system_memory_info;
pub const sa_deno_plugin_network_interfaces = _api.sa_deno_plugin_network_interfaces;
pub const sa_deno_plugin_pid = _api.sa_deno_plugin_pid;
pub const sa_deno_plugin_ppid = _api.sa_deno_plugin_ppid;
pub const sa_deno_plugin_uid = _api.sa_deno_plugin_uid;
pub const sa_deno_plugin_gid = _api.sa_deno_plugin_gid;
pub const sa_deno_plugin_exec_path = _api.sa_deno_plugin_exec_path;
pub const sa_deno_plugin_memory_usage = _api.sa_deno_plugin_memory_usage;
pub const sa_deno_plugin_env_get = _api.sa_deno_plugin_env_get;
pub const sa_deno_plugin_env_set = _api.sa_deno_plugin_env_set;
pub const sa_deno_plugin_env_delete = _api.sa_deno_plugin_env_delete;
pub const sa_deno_plugin_read_text_file = _api.sa_deno_plugin_read_text_file;
pub const sa_deno_plugin_read_file_base64 = _api.sa_deno_plugin_read_file_base64;
pub const sa_deno_plugin_write_text_file = _api.sa_deno_plugin_write_text_file;
pub const sa_deno_plugin_random_uuid = _api.sa_deno_plugin_random_uuid;
pub const sa_deno_plugin_args_json = _api.sa_deno_plugin_args_json;
pub const sa_deno_plugin_btoa = _api.sa_deno_plugin_btoa;
pub const sa_deno_plugin_atob = _api.sa_deno_plugin_atob;
pub const sa_deno_plugin_text_encode = _api.sa_deno_plugin_text_encode;
pub const sa_deno_plugin_text_decode = _api.sa_deno_plugin_text_decode;
pub const sa_deno_plugin_version_json = _api.sa_deno_plugin_version_json;
pub const sa_deno_plugin_build_json = _api.sa_deno_plugin_build_json;
pub const sa_deno_plugin_now_ms = _api.sa_deno_plugin_now_ms;
pub const sa_deno_plugin_now_ns = _api.sa_deno_plugin_now_ns;
pub const sa_deno_plugin_mkdir = _api.sa_deno_plugin_mkdir;
pub const sa_deno_plugin_remove = _api.sa_deno_plugin_remove;
pub const sa_deno_plugin_copy_file = _api.sa_deno_plugin_copy_file;
pub const sa_deno_plugin_read_dir_json = _api.sa_deno_plugin_read_dir_json;
pub const sa_deno_plugin_lstat_json = _api.sa_deno_plugin_lstat_json;
pub const sa_deno_plugin_write_file_base64 = _api.sa_deno_plugin_write_file_base64;
pub const sa_deno_plugin_command_exec = _api.sa_deno_plugin_command_exec;
pub const sa_deno_plugin_cwd = _api.sa_deno_plugin_cwd;
pub const sa_deno_plugin_chdir = _api.sa_deno_plugin_chdir;
pub const sa_deno_plugin_version_deno = _api.sa_deno_plugin_version_deno;
pub const sa_deno_plugin_build_os = _api.sa_deno_plugin_build_os;
pub const sa_deno_plugin_build_platform_family = _api.sa_deno_plugin_build_platform_family;
pub const sa_deno_plugin_date_now_iso = _api.sa_deno_plugin_date_now_iso;
pub const sa_deno_plugin_make_temp_dir = _api.sa_deno_plugin_make_temp_dir;
pub const sa_deno_plugin_make_temp_file = _api.sa_deno_plugin_make_temp_file;
pub const sa_deno_plugin_chat_sse_to_responses = _api.sa_deno_plugin_chat_sse_to_responses;
pub const sa_deno_plugin_chat_json_to_responses = _api.sa_deno_plugin_chat_json_to_responses;
pub const sa_deno_plugin_responses_sse_normalize = _api.sa_deno_plugin_responses_sse_normalize;
pub const sa_deno_plugin_responses_sse_normalize_with_request = _api.sa_deno_plugin_responses_sse_normalize_with_request;
pub const sa_deno_plugin_responses_json_normalize = _api.sa_deno_plugin_responses_json_normalize;
pub const sa_deno_plugin_responses_json_normalize_with_request = _api.sa_deno_plugin_responses_json_normalize_with_request;
pub const sa_deno_plugin_responses_request_normalize = _api.sa_deno_plugin_responses_request_normalize;
pub const sa_deno_plugin_responses_chat_fallback_request = _api.sa_deno_plugin_responses_chat_fallback_request;
pub const sa_deno_plugin_mcp_server_status_list = _api.sa_deno_plugin_mcp_server_status_list;
pub const sa_deno_plugin_mcp_tool_call = _api.sa_deno_plugin_mcp_tool_call;
pub const sa_deno_plugin_mcp_resource_read = _api.sa_deno_plugin_mcp_resource_read;
pub const sa_deno_plugin_infer_collaboration_mode = _api.sa_deno_plugin_infer_collaboration_mode;
pub const sa_deno_plugin_jsonrpc_params_string_literal = _api.sa_deno_plugin_jsonrpc_params_string_literal;

const skills = [_]plugin_api.SkillSection{
    .{
        .name = "deno-compat",
        .summary = "Deno API compatibility layer exposed via dynamically loaded dynamic library.",
        .items = &.{
            "deno hostname, osRelease, osUptime, loadavg",
            "deno systemMemoryInfo, networkInterfaces",
            "deno pid, ppid, uid, gid, execPath, memoryUsage",
            "deno env get, set, delete",
            "deno filesystem read/write text file, mkdir, remove, copy, readDir, lstat",
            "deno btoa, atob, TextEncoder/TextDecoder-compatible byte helpers",
            "deno args, version, build, now, command output",
            "public SA interface files: deno.sai and deno.sal",
        },
    },
};

pub const plugin = plugin_api.Plugin{
    .name = "deno",
    .skills = &skills,
};

pub const descriptor = plugin_api.PluginDescriptor{
    .abi_version = plugin_api.abi_version,
    .descriptor_size = @as(u32, @intCast(@sizeOf(plugin_api.PluginDescriptor))),
    .name = "deno",
    .init = null,
    .prebuild = null,
    .postbuild = null,
    .handle_command = null,
    .skills_ptr = skills[0..].ptr,
    .skills_len = skills.len,
};

pub export const saasm_plugin_descriptor_v1: plugin_api.PluginDescriptor = descriptor;

pub export fn saasm_plugin_descriptor_v1_fn(out: *plugin_api.PluginDescriptor) callconv(.c) void {
    out.* = descriptor;
}
