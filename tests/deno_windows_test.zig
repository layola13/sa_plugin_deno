const std = @import("std");
const plugin = @import("deno");
const plugin_api = @import("plugin_api");

fn readOwned(comptime function: anytype) ![]const u8 {
    var ptr: ?[*]const u8 = null;
    var len: u64 = 0;
    try std.testing.expectEqual(@as(u32, 0), function(&ptr, &len));
    const bytes = (ptr orelse return error.NullBuffer)[0..@intCast(len)];
    const copy = try std.testing.allocator.dupe(u8, bytes);
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_deno_plugin_free_buffer(ptr, len));
    return copy;
}

test "deno Windows descriptor and build identity" {
    try std.testing.expectEqualStrings("deno", std.mem.span(plugin.saasm_plugin_descriptor_v1.name));
    try std.testing.expectEqual(plugin_api.abi_version, plugin.saasm_plugin_descriptor_v1.abi_version);
    const os_release = try readOwned(plugin.sa_deno_plugin_os_release);
    defer std.testing.allocator.free(os_release);
    try std.testing.expectEqualStrings("Windows", os_release);
    const family = try readOwned(plugin.sa_deno_plugin_build_platform_family);
    defer std.testing.allocator.free(family);
    try std.testing.expectEqualStrings("windows", family);
}

test "deno Windows process and environment APIs return owned data" {
    var pid: u32 = 0;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_deno_plugin_pid(&pid));
    try std.testing.expect(pid > 0);
    const hostname = try readOwned(plugin.sa_deno_plugin_hostname);
    defer std.testing.allocator.free(hostname);
    try std.testing.expect(hostname.len > 0);
    const cwd = try readOwned(plugin.sa_deno_plugin_cwd);
    defer std.testing.allocator.free(cwd);
    try std.testing.expect(cwd.len > 0);
    const key = "TEMP";
    var value_ptr: ?[*]const u8 = null;
    var value_len: u64 = 0;
    const status = plugin.sa_deno_plugin_env_get(key.ptr, key.len, &value_ptr, &value_len);
    if (status == 0) {
        try std.testing.expect(value_ptr != null);
        try std.testing.expect(value_len > 0);
        try std.testing.expectEqual(@as(u32, 0), plugin.sa_deno_plugin_free_buffer(value_ptr, value_len));
    } else {
        try std.testing.expectEqual(@as(u32, 1), status);
    }
}

test "deno Windows compatibility identity APIs" {
    var ppid: u32 = 0;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_deno_plugin_ppid(&ppid));
    var uid: u32 = 99;
    var gid: u32 = 99;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_deno_plugin_uid(&uid));
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_deno_plugin_gid(&gid));
    try std.testing.expectEqual(@as(u32, 0), uid);
    try std.testing.expectEqual(@as(u32, 0), gid);
}
