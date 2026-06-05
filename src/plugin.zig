const std = @import("std");
const plugin_api = @import("plugin_api");
pub usingnamespace @import("deno_saasm_api.zig");

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
