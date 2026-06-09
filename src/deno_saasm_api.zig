const std = @import("std");
const builtin = @import("builtin");
const hubproxy_compat = @import("hubproxy_compat.zig");

// --- POSIX/C Signatures ---
extern fn getpid() c_int;
extern fn getppid() c_int;
extern fn getuid() c_uint;
extern fn getgid() c_uint;
extern fn getpagesize() c_int;
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;
extern fn getenv(name: [*:0]const u8) ?[*:0]u8;

const struct_sockaddr = extern struct {
    sa_family: u16,
    sa_data: [14]u8,
};
const struct_ifaddrs = extern struct {
    ifa_next: ?*struct_ifaddrs,
    ifa_name: [*:0]const u8,
    ifa_flags: c_uint,
    ifa_addr: ?*struct_sockaddr,
    ifa_netmask: ?*struct_sockaddr,
    ifa_ifu: extern union {
        ifu_broadaddr: ?*struct_sockaddr,
        ifu_dstaddr: ?*struct_sockaddr,
    },
    ifa_data: ?*anyopaque,
};
extern fn getifaddrs(ifap: *?*struct_ifaddrs) c_int;
extern fn freeifaddrs(ifa: ?*struct_ifaddrs) void;
extern fn inet_ntop(af: c_int, src: ?*const anyopaque, dst: [*]u8, size: c_uint) ?[*:0]const u8;

fn inputBytes(ptr: ?[*]const u8, len: u64) ?[]const u8 {
    if (len > @as(u64, @intCast(std.math.maxInt(usize)))) return null;
    const n: usize = @intCast(len);
    if (n == 0) return &.{};
    const p = ptr orelse return null;
    return p[0..n];
}

fn returnOwnedBuffer(bytes: []u8, out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const ptr_slot = out_ptr orelse {
        std.heap.page_allocator.free(bytes);
        return 2;
    };
    const len_slot = out_len orelse {
        std.heap.page_allocator.free(bytes);
        return 2;
    };
    ptr_slot.* = bytes.ptr;
    len_slot.* = bytes.len;
    return 0;
}

fn openFilePath(path: []const u8, flags: std.fs.File.OpenFlags) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openFileAbsolute(path, flags);
    }
    return std.fs.cwd().openFile(path, flags);
}

fn createFilePath(path: []const u8, flags: std.fs.File.CreateFlags) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.createFileAbsolute(path, flags);
    }
    return std.fs.cwd().createFile(path, flags);
}

// --- Helper: Free Buffer ---
pub export fn sa_deno_plugin_free_buffer(ptr: ?[*]const u8, len: u64) u32 {
    if (ptr) |p| {
        const slice = p[0..len];
        std.heap.page_allocator.free(slice);
    }
    return 0;
}

// --- 1. Hostname ---
pub export fn sa_deno_plugin_hostname(out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const uname = std.posix.uname();
    const nodename = std.mem.sliceTo(&uname.nodename, 0);
    const owned = std.heap.page_allocator.dupe(u8, nodename) catch return 2;
    out_ptr.?.* = owned.ptr;
    out_len.?.* = owned.len;
    return 0;
}

// --- 2. OS Release ---
pub export fn sa_deno_plugin_os_release(out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const uname = std.posix.uname();
    const release = std.mem.sliceTo(&uname.release, 0);
    const owned = std.heap.page_allocator.dupe(u8, release) catch return 2;
    out_ptr.?.* = owned.ptr;
    out_len.?.* = owned.len;
    return 0;
}

// --- 3. OS Uptime ---
pub export fn sa_deno_plugin_os_uptime(out_uptime: ?*f64) u32 {
    var file = std.fs.openFileAbsolute("/proc/uptime", .{}) catch return 2;
    defer file.close();
    var buf: [64]u8 = undefined;
    const n = file.readAll(&buf) catch return 2;
    const content = buf[0..n];
    const space_idx = std.mem.indexOfScalar(u8, content, ' ') orelse content.len;
    const uptime_str = std.mem.trim(u8, content[0..space_idx], " \t\r\n");
    out_uptime.?.* = std.fmt.parseFloat(f64, uptime_str) catch return 2;
    return 0;
}

// --- 4. Load Avg ---
pub export fn sa_deno_plugin_loadavg(out_load: ?*f64) u32 {
    var file = std.fs.openFileAbsolute("/proc/loadavg", .{}) catch return 2;
    defer file.close();
    var buf: [64]u8 = undefined;
    const n = file.readAll(&buf) catch return 2;
    const content = buf[0..n];
    var it = std.mem.tokenizeScalar(u8, content, ' ');
    const l1_str = it.next() orelse return 2;
    const l2_str = it.next() orelse return 2;
    const l3_str = it.next() orelse return 2;
    const l1 = std.fmt.parseFloat(f64, l1_str) catch return 2;
    const l2 = std.fmt.parseFloat(f64, l2_str) catch return 2;
    const l3 = std.fmt.parseFloat(f64, l3_str) catch return 2;

    const dest: [*]f64 = @ptrCast(out_load.?);
    dest[0] = l1;
    dest[1] = l2;
    dest[2] = l3;
    return 0;
}

// --- 5. System Memory Info ---
pub export fn sa_deno_plugin_system_memory_info(out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    var file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch return 2;
    defer file.close();
    var buf: [2048]u8 = undefined;
    const n = file.readAll(&buf) catch return 2;
    const content = buf[0..n];

    var total: u64 = 0;
    var free: u64 = 0;
    var available: u64 = 0;
    var buffers: u64 = 0;
    var cached: u64 = 0;
    var swapTotal: u64 = 0;
    var swapFree: u64 = 0;

    var it = std.mem.tokenizeScalar(u8, content, '\n');
    while (it.next()) |line| {
        var line_it = std.mem.tokenizeAny(u8, line, " \t:");
        const key = line_it.next() orelse continue;
        const val_str = line_it.next() orelse continue;
        const val = std.fmt.parseInt(u64, val_str, 10) catch continue;
        const bytes = val * 1024;
        if (std.mem.eql(u8, key, "MemTotal")) {
            total = bytes;
        } else if (std.mem.eql(u8, key, "MemFree")) {
            free = bytes;
        } else if (std.mem.eql(u8, key, "MemAvailable")) {
            available = bytes;
        } else if (std.mem.eql(u8, key, "Buffers")) {
            buffers = bytes;
        } else if (std.mem.eql(u8, key, "Cached")) {
            cached = bytes;
        } else if (std.mem.eql(u8, key, "SwapTotal")) {
            swapTotal = bytes;
        } else if (std.mem.eql(u8, key, "SwapFree")) {
            swapFree = bytes;
        }
    }

    var out_buf: [512]u8 = undefined;
    const json = std.fmt.bufPrint(&out_buf, "{{\"total\":{d},\"free\":{d},\"available\":{d},\"buffers\":{d},\"cached\":{d},\"swapTotal\":{d},\"swapFree\":{d}}}", .{ total, free, available, buffers, cached, swapTotal, swapFree }) catch return 2;

    const owned = std.heap.page_allocator.dupe(u8, json) catch return 2;
    out_ptr.?.* = owned.ptr;
    out_len.?.* = owned.len;
    return 0;
}

// --- 6. Network Interfaces ---
pub export fn sa_deno_plugin_network_interfaces(out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    var ifap: ?*struct_ifaddrs = null;
    if (getifaddrs(&ifap) != 0) return 2;
    defer {
        if (ifap) |ptr| freeifaddrs(ptr);
    }

    var list = std.ArrayList(u8).init(std.heap.page_allocator);
    errdefer list.deinit();
    list.append('[') catch return 2;

    var first = true;
    var current = ifap;
    while (current) |ifa| : (current = ifa.ifa_next) {
        const addr_ptr = ifa.ifa_addr orelse continue;
        const family = addr_ptr.sa_family;
        if (family != 2 and family != 10) continue;

        const name = std.mem.sliceTo(ifa.ifa_name, 0);

        var ip_buf: [46]u8 = undefined;
        const family_str = if (family == 2) "IPv4" else "IPv6";
        const af: c_int = if (family == 2) 2 else 10;

        const ip_src = if (family == 2)
            @as(?*const anyopaque, @ptrCast(&@as(*align(1) const extern struct {
                sa_family: u16,
                sin_port: u16,
                sin_addr: [4]u8,
            }, @ptrCast(addr_ptr)).sin_addr))
        else
            @as(?*const anyopaque, @ptrCast(&@as(*align(1) const extern struct {
                sa_family: u16,
                sin6_port: u16,
                sin6_flowinfo: u32,
                sin6_addr: [16]u8,
                sin6_scope_id: u32,
            }, @ptrCast(addr_ptr)).sin6_addr));

        const ip_z = inet_ntop(af, ip_src, &ip_buf, ip_buf.len) orelse continue;
        const ip_str = std.mem.sliceTo(ip_z, 0);

        var mask_buf: [46]u8 = undefined;
        var cidr: u32 = 0;
        var mask_str: []const u8 = "000.000.000.000";
        if (ifa.ifa_netmask) |mask_ptr| {
            const mask_src = if (family == 2)
                @as(?*const anyopaque, @ptrCast(&@as(*align(1) const extern struct {
                    sa_family: u16,
                    sin_port: u16,
                    sin_addr: [4]u8,
                }, @ptrCast(mask_ptr)).sin_addr))
            else
                @as(?*const anyopaque, @ptrCast(&@as(*align(1) const extern struct {
                    sa_family: u16,
                    sin6_port: u16,
                    sin6_flowinfo: u32,
                    sin6_addr: [16]u8,
                    sin6_scope_id: u32,
                }, @ptrCast(mask_ptr)).sin6_addr));
            if (inet_ntop(af, mask_src, &mask_buf, mask_buf.len)) |mask_z| {
                mask_str = std.mem.sliceTo(mask_z, 0);
            }

            if (family == 2) {
                const sin_addr = @as(*align(1) const extern struct {
                    sa_family: u16,
                    sin_port: u16,
                    sin_addr: [4]u8,
                }, @ptrCast(mask_ptr)).sin_addr;
                const mask_val = @as(u32, @bitCast(sin_addr));
                cidr = @popCount(mask_val);
            } else {
                const sin6_addr = @as(*align(1) const extern struct {
                    sa_family: u16,
                    sin6_port: u16,
                    sin6_flowinfo: u32,
                    sin6_addr: [16]u8,
                    sin6_scope_id: u32,
                }, @ptrCast(mask_ptr)).sin6_addr;
                for (sin6_addr) |b| {
                    cidr += @popCount(b);
                }
            }
        }

        var mac_buf: [32]u8 = undefined;
        var mac_path_buf: [128]u8 = undefined;
        const mac_path = std.fmt.bufPrint(&mac_path_buf, "/sys/class/net/{s}/address", .{name}) catch "";
        var mac_str: []const u8 = "00:00:00:00:00:00";
        if (mac_path.len != 0) {
            if (std.fs.openFileAbsolute(mac_path, .{})) |mac_file| {
                defer mac_file.close();
                if (mac_file.readAll(&mac_buf)) |mac_len| {
                    mac_str = std.mem.trim(u8, mac_buf[0..mac_len], " \t\r\n");
                } else |_| {}
            } else |_| {}
        }

        if (!first) {
            list.append(',') catch return 2;
        }
        first = false;

        var json_buf: [512]u8 = undefined;
        const entry = std.fmt.bufPrint(&json_buf, "{{\"name\":\"{s}\",\"family\":\"{s}\",\"address\":\"{s}\",\"netmask\":\"{s}\",\"scopeid\":null,\"cidr\":\"{s}/{d}\",\"mac\":\"{s}\"}}", .{ name, family_str, ip_str, mask_str, ip_str, cidr, mac_str }) catch return 2;

        list.appendSlice(entry) catch return 2;
    }

    list.append(']') catch return 2;
    const owned = list.toOwnedSlice() catch return 2;
    out_ptr.?.* = owned.ptr;
    out_len.?.* = owned.len;
    return 0;
}

// --- 7. PID ---
pub export fn sa_deno_plugin_pid(out_pid: ?*u32) u32 {
    out_pid.?.* = @intCast(getpid());
    return 0;
}

// --- 8. PPID ---
pub export fn sa_deno_plugin_ppid(out_ppid: ?*u32) u32 {
    out_ppid.?.* = @intCast(getppid());
    return 0;
}

// --- 9. UID ---
pub export fn sa_deno_plugin_uid(out_uid: ?*u32) u32 {
    out_uid.?.* = @intCast(getuid());
    return 0;
}

// --- 10. GID ---
pub export fn sa_deno_plugin_gid(out_gid: ?*u32) u32 {
    out_gid.?.* = @intCast(getgid());
    return 0;
}

// --- 11. Exec Path ---
pub export fn sa_deno_plugin_exec_path(out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const path = std.fs.selfExePathAlloc(std.heap.page_allocator) catch return 2;
    out_ptr.?.* = path.ptr;
    out_len.?.* = path.len;
    return 0;
}

// --- 12. Memory Usage ---
pub export fn sa_deno_plugin_memory_usage(out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    var file = std.fs.openFileAbsolute("/proc/self/statm", .{}) catch return 2;
    defer file.close();
    var buf: [64]u8 = undefined;
    const n = file.readAll(&buf) catch return 2;
    const content = buf[0..n];
    var it = std.mem.tokenizeScalar(u8, content, ' ');
    _ = it.next() orelse return 2;
    const rss_pages_str = it.next() orelse return 2;
    const rss_pages = std.fmt.parseInt(u64, rss_pages_str, 10) catch return 2;

    const page_size: u64 = @intCast(getpagesize());
    const rss = rss_pages * page_size;

    var out_buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&out_buf, "{{\"rss\":{d},\"heapTotal\":{d},\"heapUsed\":{d},\"external\":0}}", .{ rss, rss, rss }) catch return 2;

    const owned = std.heap.page_allocator.dupe(u8, json) catch return 2;
    out_ptr.?.* = owned.ptr;
    out_len.?.* = owned.len;
    return 0;
}

// --- 13. Env Get ---
pub export fn sa_deno_plugin_env_get(key_ptr: ?[*]const u8, key_len: u64, out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    if (key_ptr == null or key_len == 0) return 2;
    const key = key_ptr.?[0..key_len];
    const key_z = std.heap.page_allocator.dupeZ(u8, key) catch return 2;
    defer std.heap.page_allocator.free(key_z);

    const value = getenv(key_z.ptr) orelse return 1; // 1 means not found (null in Deno)
    const val_slice = std.mem.span(value);
    const owned = std.heap.page_allocator.dupe(u8, val_slice) catch return 2;
    out_ptr.?.* = owned.ptr;
    out_len.?.* = owned.len;
    return 0;
}

// --- 14. Env Set ---
pub export fn sa_deno_plugin_env_set(key_ptr: ?[*]const u8, key_len: u64, val_ptr: ?[*]const u8, val_len: u64) u32 {
    if (key_ptr == null or key_len == 0) return 2;
    const key = key_ptr.?[0..key_len];
    const value = if (val_ptr) |p| p[0..val_len] else &[_]u8{};

    const key_z = std.heap.page_allocator.dupeZ(u8, key) catch return 2;
    defer std.heap.page_allocator.free(key_z);
    const val_z = std.heap.page_allocator.dupeZ(u8, value) catch return 2;
    defer std.heap.page_allocator.free(val_z);

    if (setenv(key_z.ptr, val_z.ptr, 1) != 0) return 2;
    return 0;
}

// --- 15. Env Delete ---
pub export fn sa_deno_plugin_env_delete(key_ptr: ?[*]const u8, key_len: u64) u32 {
    if (key_ptr == null or key_len == 0) return 2;
    const key = key_ptr.?[0..key_len];
    const key_z = std.heap.page_allocator.dupeZ(u8, key) catch return 2;
    defer std.heap.page_allocator.free(key_z);

    if (unsetenv(key_z.ptr) != 0) return 2;
    return 0;
}

// --- 16. Read Text File ---
pub export fn sa_deno_plugin_read_text_file(path_ptr: ?[*]const u8, path_len: u64, out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    if (path_ptr == null or path_len == 0) return 2;
    const path = path_ptr.?[0..path_len];
    const path_z = std.heap.page_allocator.dupeZ(u8, path) catch return 2;
    defer std.heap.page_allocator.free(path_z);

    var file = openFilePath(path_z, .{}) catch return 2;
    defer file.close();

    const size = file.getEndPos() catch return 2;
    const content = std.heap.page_allocator.alloc(u8, size) catch return 2;
    errdefer std.heap.page_allocator.free(content);

    const read_bytes = file.readAll(content) catch return 2;
    out_ptr.?.* = content.ptr;
    out_len.?.* = read_bytes;
    return 0;
}

pub export fn sa_deno_plugin_read_file_base64(path_ptr: ?[*]const u8, path_len: u64, out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    if (path_ptr == null or path_len == 0) return 2;
    const path = path_ptr.?[0..path_len];
    const path_z = std.heap.page_allocator.dupeZ(u8, path) catch return 2;
    defer std.heap.page_allocator.free(path_z);

    var file = openFilePath(path_z, .{}) catch return 2;
    defer file.close();

    const size = file.getEndPos() catch return 2;
    const content = std.heap.page_allocator.alloc(u8, size) catch return 2;
    defer std.heap.page_allocator.free(content);

    const read_bytes = file.readAll(content) catch return 2;
    const encoded_len = std.base64.standard.Encoder.calcSize(read_bytes);
    const encoded = std.heap.page_allocator.alloc(u8, encoded_len) catch return 2;
    _ = std.base64.standard.Encoder.encode(encoded, content[0..read_bytes]);
    out_ptr.?.* = encoded.ptr;
    out_len.?.* = encoded.len;
    return 0;
}

// --- 17. Write Text File ---
pub export fn sa_deno_plugin_write_text_file(path_ptr: ?[*]const u8, path_len: u64, data_ptr: ?[*]const u8, data_len: u64) u32 {
    if (path_ptr == null or path_len == 0) return 2;
    const path = path_ptr.?[0..path_len];
    const path_z = std.heap.page_allocator.dupeZ(u8, path) catch return 2;
    defer std.heap.page_allocator.free(path_z);

    var file = createFilePath(path_z, .{}) catch return 2;
    defer file.close();

    const bytes = if (data_ptr) |p| p[0..data_len] else &[_]u8{};
    file.writeAll(bytes) catch return 2;
    return 0;
}

// --- 18. Random UUID ---
pub export fn sa_deno_plugin_random_uuid(out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const text = std.heap.page_allocator.alloc(u8, 36) catch return 2;
    _ = std.fmt.bufPrint(
        text,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        },
    ) catch return 2;
    out_ptr.?.* = text.ptr;
    out_len.?.* = text.len;
    return 0;
}

// --- 19. Args JSON ---
pub export fn sa_deno_plugin_args_json(out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    var args = std.process.argsAlloc(std.heap.page_allocator) catch return 2;
    defer std.process.argsFree(std.heap.page_allocator, args);

    const deno_args = if (args.len > 0) args[1..] else args[0..0];
    const json = std.json.stringifyAlloc(std.heap.page_allocator, deno_args, .{}) catch return 2;
    out_ptr.?.* = json.ptr;
    out_len.?.* = json.len;
    return 0;
}

// --- 20. Base64 Encode (btoa) ---
pub export fn sa_deno_plugin_btoa(data_ptr: ?[*]const u8, len: u64, out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const bytes = if (data_ptr) |p| p[0..len] else &[_]u8{};
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = std.heap.page_allocator.alloc(u8, encoded_len) catch return 2;
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    out_ptr.?.* = encoded.ptr;
    out_len.?.* = encoded.len;
    return 0;
}

// --- 21. Base64 Decode (atob) ---
pub export fn sa_deno_plugin_atob(data_ptr: ?[*]const u8, len: u64, out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const encoded = if (data_ptr) |p| p[0..len] else &[_]u8{};
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return 2;
    const decoded = std.heap.page_allocator.alloc(u8, decoded_len) catch return 2;
    std.base64.standard.Decoder.decode(decoded, encoded) catch {
        std.heap.page_allocator.free(decoded);
        return 2;
    };
    out_ptr.?.* = decoded.ptr;
    out_len.?.* = decoded.len;
    return 0;
}

// --- 22. Text Encode ---
pub export fn sa_deno_plugin_text_encode(data_ptr: ?[*]const u8, len: u64, out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const bytes = if (data_ptr) |p| p[0..len] else &[_]u8{};
    const owned = std.heap.page_allocator.dupe(u8, bytes) catch return 2;
    out_ptr.?.* = owned.ptr;
    out_len.?.* = owned.len;
    return 0;
}

// --- 23. Text Decode ---
pub export fn sa_deno_plugin_text_decode(data_ptr: ?[*]const u8, len: u64, out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const bytes = if (data_ptr) |p| p[0..len] else &[_]u8{};
    const owned = std.heap.page_allocator.dupe(u8, bytes) catch return 2;
    out_ptr.?.* = owned.ptr;
    out_len.?.* = owned.len;
    return 0;
}

// --- 24. Version JSON ---
pub export fn sa_deno_plugin_version_json(out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const json = std.fmt.allocPrint(
        std.heap.page_allocator,
        "{{\"deno\":\"sa-plugin-deno\",\"v8\":\"\",\"typescript\":\"\",\"sci\":\"{s}\"}}",
        .{builtin.zig_version_string},
    ) catch return 2;
    out_ptr.?.* = json.ptr;
    out_len.?.* = json.len;
    return 0;
}

// --- 25. Build JSON ---
pub export fn sa_deno_plugin_build_json(out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const os = @tagName(builtin.os.tag);
    const arch = @tagName(builtin.cpu.arch);
    const vendor = @tagName(builtin.abi);
    const json = std.fmt.allocPrint(
        std.heap.page_allocator,
        "{{\"os\":\"{s}\",\"arch\":\"{s}\",\"target\":\"{s}-{s}\"}}",
        .{ os, arch, arch, vendor },
    ) catch return 2;
    out_ptr.?.* = json.ptr;
    out_len.?.* = json.len;
    return 0;
}

// --- 26. Now Milliseconds ---
pub export fn sa_deno_plugin_now_ms(out_ms: ?*u64) u32 {
    out_ms.?.* = @intCast(std.time.milliTimestamp());
    return 0;
}

// --- 27. Now Nanoseconds ---
pub export fn sa_deno_plugin_now_ns(out_ns: ?*u64) u32 {
    out_ns.?.* = @intCast(std.time.nanoTimestamp());
    return 0;
}

// --- 28. Make Directory (mkdirSync) ---
pub export fn sa_deno_plugin_mkdir(path_ptr: ?[*]const u8, path_len: u64, recursive: u8) u32 {
    if (path_ptr == null or path_len == 0) return 2;
    const path = path_ptr.?[0..path_len];
    const path_z = std.heap.page_allocator.dupeZ(u8, path) catch return 2;
    defer std.heap.page_allocator.free(path_z);

    if (recursive != 0) {
        std.fs.cwd().makePath(path_z) catch return 2;
    } else {
        std.fs.cwd().makeDir(path_z) catch return 2;
    }
    return 0;
}

// --- 29. Remove (removeSync) ---
pub export fn sa_deno_plugin_remove(path_ptr: ?[*]const u8, path_len: u64, recursive: u8) u32 {
    if (path_ptr == null or path_len == 0) return 2;
    const path = path_ptr.?[0..path_len];
    const path_z = std.heap.page_allocator.dupeZ(u8, path) catch return 2;
    defer std.heap.page_allocator.free(path_z);

    if (recursive != 0) {
        std.fs.cwd().deleteTree(path_z) catch return 2;
    } else {
        std.fs.cwd().deleteFile(path_z) catch {
            std.fs.cwd().deleteDir(path_z) catch return 2;
        };
    }
    return 0;
}

// --- 30. Copy File (copyFileSync) ---
pub export fn sa_deno_plugin_copy_file(src_ptr: ?[*]const u8, src_len: u64, dst_ptr: ?[*]const u8, dst_len: u64) u32 {
    if (src_ptr == null or src_len == 0 or dst_ptr == null or dst_len == 0) return 2;
    const src = src_ptr.?[0..src_len];
    const dst = dst_ptr.?[0..dst_len];
    const src_z = std.heap.page_allocator.dupeZ(u8, src) catch return 2;
    defer std.heap.page_allocator.free(src_z);
    const dst_z = std.heap.page_allocator.dupeZ(u8, dst) catch return 2;
    defer std.heap.page_allocator.free(dst_z);

    std.fs.cwd().copyFile(src_z, std.fs.cwd(), dst_z, .{}) catch return 2;
    return 0;
}

// --- 31. Read Directory (readDirSync) ---
pub export fn sa_deno_plugin_read_dir_json(path_ptr: ?[*]const u8, path_len: u64, out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    if (path_ptr == null or path_len == 0) return 2;
    const path = path_ptr.?[0..path_len];
    const path_z = std.heap.page_allocator.dupeZ(u8, path) catch return 2;
    defer std.heap.page_allocator.free(path_z);

    var dir = std.fs.cwd().openDir(path_z, .{ .iterate = true }) catch return 2;
    defer dir.close();

    var list = std.ArrayList(u8).init(std.heap.page_allocator);
    errdefer list.deinit();
    list.append('[') catch return 2;

    var it = dir.iterate();
    var first = true;
    while (it.next() catch return 2) |entry| {
        if (!first) list.append(',') catch return 2;
        first = false;

        const is_dir = entry.kind == .directory;
        const is_file = entry.kind == .file;

        var entry_buf: [256]u8 = undefined;
        const entry_json = std.fmt.bufPrint(&entry_buf, "{{\"name\":\"{s}\",\"isDirectory\":{s},\"isFile\":{s}}}", .{ entry.name, if (is_dir) "true" else "false", if (is_file) "true" else "false" }) catch return 2;
        list.appendSlice(entry_json) catch return 2;
    }

    list.append(']') catch return 2;
    const owned = list.toOwnedSlice() catch return 2;
    out_ptr.?.* = owned.ptr;
    out_len.?.* = owned.len;
    return 0;
}

// --- 32. Lstat (lstatSync) ---
pub export fn sa_deno_plugin_lstat_json(path_ptr: ?[*]const u8, path_len: u64, out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    if (path_ptr == null or path_len == 0) return 2;
    const path = path_ptr.?[0..path_len];
    const path_z = std.heap.page_allocator.dupeZ(u8, path) catch return 2;
    defer std.heap.page_allocator.free(path_z);

    const stat = std.fs.cwd().statFile(path_z) catch return 2;

    const is_dir = stat.kind == .directory;
    const is_file = stat.kind == .file;
    const is_symlink = stat.kind == .sym_link;
    const mtime = @divTrunc(stat.mtime, 1_000_000); // ms
    const ctime = @divTrunc(stat.ctime, 1_000_000); // ms

    var out_buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&out_buf, "{{\"createdAtMs\":{d},\"isDirectory\":{s},\"isFile\":{s},\"isSymlink\":{s},\"modifiedAtMs\":{d}}}", .{ ctime, if (is_dir) "true" else "false", if (is_file) "true" else "false", if (is_symlink) "true" else "false", mtime }) catch return 2;

    const owned = std.heap.page_allocator.dupe(u8, json) catch return 2;
    out_ptr.?.* = owned.ptr;
    out_len.?.* = owned.len;
    return 0;
}

// --- 33. Write File Base64 (writeFileSync) ---
pub export fn sa_deno_plugin_write_file_base64(path_ptr: ?[*]const u8, path_len: u64, base64_ptr: ?[*]const u8, base64_len: u64) u32 {
    if (path_ptr == null or path_len == 0 or base64_ptr == null or base64_len == 0) return 2;
    const path = path_ptr.?[0..path_len];
    const base64 = base64_ptr.?[0..base64_len];
    const path_z = std.heap.page_allocator.dupeZ(u8, path) catch return 2;
    defer std.heap.page_allocator.free(path_z);

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(base64) catch return 2;
    const decoded = std.heap.page_allocator.alloc(u8, decoded_len) catch return 2;
    defer std.heap.page_allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, base64) catch return 2;

    var file = createFilePath(path_z, .{}) catch return 2;
    defer file.close();
    file.writeAll(decoded) catch return 2;
    return 0;
}

// --- 34. Command Exec (Deno.Command Sync Output) ---
pub export fn sa_deno_plugin_command_exec(
    argv_ptr: [*]const [*:0]const u8,
    argv_len: usize,
    cwd_ptr: ?[*]const u8,
    cwd_len: u64,
    out_code: *u32,
    out_stdout_ptr: ?*?[*]const u8,
    out_stdout_len: ?*u64,
    out_stderr_ptr: ?*?[*]const u8,
    out_stderr_len: ?*u64,
) u32 {
    const allocator = std.heap.page_allocator;

    // Parse argv
    var argv = allocator.alloc([]const u8, argv_len) catch return 2;
    defer allocator.free(argv);
    for (0..argv_len) |i| {
        argv[i] = std.mem.sliceTo(argv_ptr[i], 0);
    }

    // Parse cwd
    var cwd: ?[]const u8 = null;
    if (cwd_ptr) |ptr| {
        if (cwd_len > 0) {
            cwd = ptr[0..cwd_len];
        }
    }

    const run_res = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 10 * 1024 * 1024,
    }) catch return 2;

    switch (run_res.term) {
        .Exited => |code| out_code.* = code,
        else => out_code.* = 1,
    }

    out_stdout_ptr.?.* = run_res.stdout.ptr;
    out_stdout_len.?.* = run_res.stdout.len;
    out_stderr_ptr.?.* = run_res.stderr.ptr;
    out_stderr_len.?.* = run_res.stderr.len;

    return 0;
}

// --- 35. Get CWD (sa_deno_plugin_cwd) ---
pub export fn sa_deno_plugin_cwd(out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.process.getCwd(&buf) catch return 2;
    const owned = std.heap.page_allocator.dupe(u8, path) catch return 2;
    out_ptr.?.* = owned.ptr;
    out_len.?.* = owned.len;
    return 0;
}

// --- 36. Change Dir (sa_deno_plugin_chdir) ---
pub export fn sa_deno_plugin_chdir(path_ptr: ?[*]const u8, path_len: u64) u32 {
    if (path_ptr == null or path_len == 0) return 2;
    const path = path_ptr.?[0..path_len];
    const path_z = std.heap.page_allocator.dupeZ(u8, path) catch return 2;
    defer std.heap.page_allocator.free(path_z);
    std.process.changeCurDir(path_z) catch return 2;
    return 0;
}

// --- 37. Deno Version (sa_deno_plugin_version_deno) ---
pub export fn sa_deno_plugin_version_deno(out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const owned = std.heap.page_allocator.dupe(u8, "1.40.5") catch return 2;
    out_ptr.?.* = owned.ptr;
    out_len.?.* = owned.len;
    return 0;
}

// --- 38. Build OS (sa_deno_plugin_build_os) ---
pub export fn sa_deno_plugin_build_os(out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const os_name = @tagName(builtin.os.tag);
    const owned = std.heap.page_allocator.dupe(u8, os_name) catch return 2;
    out_ptr.?.* = owned.ptr;
    out_len.?.* = owned.len;
    return 0;
}

// --- 39. Build Platform Family (sa_deno_plugin_build_platform_family) ---
pub export fn sa_deno_plugin_build_platform_family(out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const family = if (builtin.os.tag != .windows) "unix" else "windows";
    const owned = std.heap.page_allocator.dupe(u8, family) catch return 2;
    out_ptr.?.* = owned.ptr;
    out_len.?.* = owned.len;
    return 0;
}

// --- 40. Date ISO (sa_deno_plugin_date_now_iso) ---
pub export fn sa_deno_plugin_date_now_iso(out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const ms = std.time.milliTimestamp();
    const secs = @divTrunc(ms, 1000);
    const msecs: u64 = @intCast(@mod(ms, 1000));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    var out_buf: [64]u8 = undefined;
    const iso = std.fmt.bufPrint(&out_buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
        msecs,
    }) catch return 2;

    const owned = std.heap.page_allocator.dupe(u8, iso) catch return 2;
    out_ptr.?.* = owned.ptr;
    out_len.?.* = owned.len;
    return 0;
}

// --- 41. Make Temp Dir (sa_deno_plugin_make_temp_dir) ---
pub export fn sa_deno_plugin_make_temp_dir(prefix_ptr: ?[*]const u8, prefix_len: u64, out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const prefix = if (prefix_ptr) |p| p[0..prefix_len] else &[_]u8{};
    var random_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    const tmp_dir_path = std.process.getEnvVarOwned(std.heap.page_allocator, "TMPDIR") catch std.process.getEnvVarOwned(std.heap.page_allocator, "TEMP") catch std.process.getEnvVarOwned(std.heap.page_allocator, "TMP") catch "/tmp";
    defer {
        if (!std.mem.eql(u8, tmp_dir_path, "/tmp")) {
            std.heap.page_allocator.free(tmp_dir_path);
        }
    }

    const name = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}{x}", .{ tmp_dir_path, prefix, std.mem.readInt(u64, &random_bytes, .big) }) catch return 2;
    errdefer std.heap.page_allocator.free(name);

    std.fs.makeDirAbsolute(name) catch return 2;
    out_ptr.?.* = name.ptr;
    out_len.?.* = name.len;
    return 0;
}

// --- 42. Make Temp File (sa_deno_plugin_make_temp_file) ---
pub export fn sa_deno_plugin_make_temp_file(
    prefix_ptr: ?[*]const u8,
    prefix_len: u64,
    suffix_ptr: ?[*]const u8,
    suffix_len: u64,
    out_ptr: ?*?[*]const u8,
    out_len: ?*u64,
) u32 {
    const prefix = if (prefix_ptr) |p| p[0..prefix_len] else &[_]u8{};
    const suffix = if (suffix_ptr) |p| p[0..suffix_len] else &[_]u8{};
    var random_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    const tmp_dir_path = std.process.getEnvVarOwned(std.heap.page_allocator, "TMPDIR") catch std.process.getEnvVarOwned(std.heap.page_allocator, "TEMP") catch std.process.getEnvVarOwned(std.heap.page_allocator, "TMP") catch "/tmp";
    defer {
        if (!std.mem.eql(u8, tmp_dir_path, "/tmp")) {
            std.heap.page_allocator.free(tmp_dir_path);
        }
    }

    const name = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}{x}{s}", .{ tmp_dir_path, prefix, std.mem.readInt(u64, &random_bytes, .big), suffix }) catch return 2;
    errdefer std.heap.page_allocator.free(name);

    var file = std.fs.createFileAbsolute(name, .{}) catch return 2;
    file.close();

    out_ptr.?.* = name.ptr;
    out_len.?.* = name.len;
    return 0;
}

// --- HubProxy Porting FFI Symbols ---
pub export fn sa_deno_plugin_chat_sse_to_responses(
    chat_body_ptr: ?[*]const u8,
    chat_body_len: u64,
    req_body_ptr: ?[*]const u8,
    req_body_len: u64,
    out_ptr: ?*?[*]const u8,
    out_len: ?*u64,
) u32 {
    const chat_body = inputBytes(chat_body_ptr, chat_body_len) orelse return 2;
    const req_body = inputBytes(req_body_ptr, req_body_len) orelse return 2;
    const converted = hubproxy_compat.chatSseToResponses(chat_body, req_body) catch return 2;
    return returnOwnedBuffer(converted, out_ptr, out_len);
}

pub export fn sa_deno_plugin_chat_json_to_responses(
    chat_body_ptr: ?[*]const u8,
    chat_body_len: u64,
    req_body_ptr: ?[*]const u8,
    req_body_len: u64,
    out_ptr: ?*?[*]const u8,
    out_len: ?*u64,
) u32 {
    const chat_body = inputBytes(chat_body_ptr, chat_body_len) orelse return 2;
    const req_body = inputBytes(req_body_ptr, req_body_len) orelse return 2;
    const converted = hubproxy_compat.chatJsonToResponses(chat_body, req_body) catch return 2;
    return returnOwnedBuffer(converted, out_ptr, out_len);
}

pub export fn sa_deno_plugin_responses_sse_normalize(
    sse_body_ptr: ?[*]const u8,
    sse_body_len: u64,
    out_ptr: ?*?[*]const u8,
    out_len: ?*u64,
) u32 {
    const sse_body = inputBytes(sse_body_ptr, sse_body_len) orelse return 2;
    const normalized = hubproxy_compat.responsesSseNormalize(sse_body) catch return 2;
    return returnOwnedBuffer(normalized, out_ptr, out_len);
}

pub export fn sa_deno_plugin_responses_sse_normalize_with_request(
    sse_body_ptr: ?[*]const u8,
    sse_body_len: u64,
    req_body_ptr: ?[*]const u8,
    req_body_len: u64,
    out_ptr: ?*?[*]const u8,
    out_len: ?*u64,
) u32 {
    const sse_body = inputBytes(sse_body_ptr, sse_body_len) orelse return 2;
    const req_body = inputBytes(req_body_ptr, req_body_len) orelse return 2;
    const normalized = hubproxy_compat.responsesSseNormalizeWithRequest(sse_body, req_body) catch return 2;
    return returnOwnedBuffer(normalized, out_ptr, out_len);
}

pub export fn sa_deno_plugin_responses_json_normalize(
    body_ptr: ?[*]const u8,
    body_len: u64,
    out_ptr: ?*?[*]const u8,
    out_len: ?*u64,
) u32 {
    const body = inputBytes(body_ptr, body_len) orelse return 2;
    const normalized = hubproxy_compat.responsesJsonNormalize(body) catch return 2;
    return returnOwnedBuffer(normalized, out_ptr, out_len);
}

pub export fn sa_deno_plugin_responses_json_normalize_with_request(
    body_ptr: ?[*]const u8,
    body_len: u64,
    req_body_ptr: ?[*]const u8,
    req_body_len: u64,
    out_ptr: ?*?[*]const u8,
    out_len: ?*u64,
) u32 {
    const body = inputBytes(body_ptr, body_len) orelse return 2;
    const req_body = inputBytes(req_body_ptr, req_body_len) orelse return 2;
    const normalized = hubproxy_compat.responsesJsonNormalizeWithRequest(body, req_body) catch return 2;
    return returnOwnedBuffer(normalized, out_ptr, out_len);
}

pub export fn sa_deno_plugin_responses_request_normalize(
    body_ptr: ?[*]const u8,
    body_len: u64,
    out_ptr: ?*?[*]const u8,
    out_len: ?*u64,
) u32 {
    const body = inputBytes(body_ptr, body_len) orelse return 2;
    const normalized = hubproxy_compat.responsesRequestNormalize(body) catch return 2;
    return returnOwnedBuffer(normalized, out_ptr, out_len);
}

pub export fn sa_deno_plugin_responses_chat_fallback_request(
    body_ptr: ?[*]const u8,
    body_len: u64,
    default_model_ptr: ?[*]const u8,
    default_model_len: u64,
    plan_mode_like: u8,
    out_ptr: ?*?[*]const u8,
    out_len: ?*u64,
) u32 {
    const body = inputBytes(body_ptr, body_len) orelse return 2;
    const default_model = inputBytes(default_model_ptr, default_model_len) orelse return 2;
    const converted = hubproxy_compat.responsesChatFallbackRequest(body, default_model, plan_mode_like != 0) catch return 2;
    const actual = converted orelse return 1;
    return returnOwnedBuffer(actual, out_ptr, out_len);
}

pub export fn sa_deno_plugin_mcp_server_status_list(
    body_ptr: ?[*]const u8,
    body_len: u64,
    out_ptr: ?*?[*]const u8,
    out_len: ?*u64,
) u32 {
    const body = inputBytes(body_ptr, body_len) orelse return 2;
    const status_list = hubproxy_compat.mcpServerStatusList(body) catch |err| switch (err) {
        error.InvalidMcpStatusParams => return 3,
        else => return 2,
    };
    return returnOwnedBuffer(status_list, out_ptr, out_len);
}

pub export fn sa_deno_plugin_mcp_tool_call(
    body_ptr: ?[*]const u8,
    body_len: u64,
    out_ptr: ?*?[*]const u8,
    out_len: ?*u64,
) u32 {
    const body = inputBytes(body_ptr, body_len) orelse return 2;
    if (!hubproxy_compat.mcpToolCallHasRequiredParams(body)) return 3;
    const result = hubproxy_compat.mcpToolCall(body) catch |err| switch (err) {
        error.McpToolExecutionFailed => return 4,
        else => return 2,
    };
    const actual = result orelse return 1;
    return returnOwnedBuffer(actual, out_ptr, out_len);
}

pub export fn sa_deno_plugin_mcp_resource_read(
    body_ptr: ?[*]const u8,
    body_len: u64,
    out_ptr: ?*?[*]const u8,
    out_len: ?*u64,
) u32 {
    const body = inputBytes(body_ptr, body_len) orelse return 2;
    if (!hubproxy_compat.mcpResourceReadHasRequiredParams(body)) return 3;
    const result = hubproxy_compat.mcpResourceRead(body) catch |err| switch (err) {
        error.McpToolExecutionFailed => return 4,
        else => return 2,
    };
    const actual = result orelse return 1;
    return returnOwnedBuffer(actual, out_ptr, out_len);
}

pub export fn sa_deno_plugin_infer_collaboration_mode(
    body_ptr: ?[*]const u8,
    body_len: u64,
    out_mode: ?*u32,
) u32 {
    const body = inputBytes(body_ptr, body_len) orelse return 2;
    const mode_slot = out_mode orelse return 2;
    mode_slot.* = hubproxy_compat.inferCollaborationModeCode(body);
    return 0;
}

pub export fn sa_deno_plugin_jsonrpc_params_string_literal(
    body_ptr: ?[*]const u8,
    body_len: u64,
    key_ptr: ?[*]const u8,
    key_len: u64,
    fallback_ptr: ?[*]const u8,
    fallback_len: u64,
    emit_null_if_missing: u8,
    out_ptr: ?*?[*]const u8,
    out_len: ?*u64,
) u32 {
    const body = inputBytes(body_ptr, body_len) orelse return 2;
    const key = inputBytes(key_ptr, key_len) orelse return 2;
    const fallback = inputBytes(fallback_ptr, fallback_len) orelse return 2;
    const literal = hubproxy_compat.jsonrpcParamsStringLiteral(body, key, fallback, emit_null_if_missing != 0) catch return 2;
    return returnOwnedBuffer(literal, out_ptr, out_len);
}
