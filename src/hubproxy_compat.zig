const std = @import("std");

fn longestSuffixPrefix(text: []const u8, prefix: []const u8) usize {
    if (text.len == 0 or prefix.len == 0) return 0;
    const max_len = @min(text.len, prefix.len - 1);
    var len = max_len;
    while (len > 0) : (len -= 1) {
        if (std.mem.eql(u8, text[text.len - len ..], prefix[0..len])) return len;
    }
    return 0;
}

const ThoughtStreamSplitter = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayList(u8),
    in_thought: bool = false,

    fn init(allocator: std.mem.Allocator) ThoughtStreamSplitter {
        return .{
            .allocator = allocator,
            .pending = std.ArrayList(u8).init(allocator),
            .in_thought = false,
        };
    }

    fn deinit(self: *ThoughtStreamSplitter) void {
        self.pending.deinit();
    }

    fn consume(self: *ThoughtStreamSplitter, chunk: []const u8, visible: *std.ArrayList(u8), reasoning: *std.ArrayList(u8)) !void {
        const open_tag = "<thought>";
        const close_tag = "</thought>";
        try self.pending.appendSlice(chunk);

        while (self.pending.items.len != 0) {
            if (!self.in_thought) {
                if (std.mem.indexOf(u8, self.pending.items, open_tag)) |open_index| {
                    if (open_index > 0) try visible.appendSlice(self.pending.items[0..open_index]);
                    try self.pending.replaceRange(0, open_index + open_tag.len, &.{});
                    self.in_thought = true;
                    continue;
                }

                const keep = longestSuffixPrefix(self.pending.items, open_tag);
                const emit_len = self.pending.items.len - keep;
                if (emit_len > 0) try visible.appendSlice(self.pending.items[0..emit_len]);
                try self.pending.replaceRange(0, emit_len, &.{});
                break;
            }

            if (std.mem.indexOf(u8, self.pending.items, close_tag)) |close_index| {
                if (close_index > 0) try reasoning.appendSlice(self.pending.items[0..close_index]);
                try self.pending.replaceRange(0, close_index + close_tag.len, &.{});
                self.in_thought = false;
                continue;
            }

            const keep = longestSuffixPrefix(self.pending.items, close_tag);
            const emit_len = self.pending.items.len - keep;
            if (emit_len > 0) try reasoning.appendSlice(self.pending.items[0..emit_len]);
            try self.pending.replaceRange(0, emit_len, &.{});
            break;
        }
    }

    fn flush(self: *ThoughtStreamSplitter, visible: *std.ArrayList(u8), reasoning: *std.ArrayList(u8)) !void {
        if (self.pending.items.len != 0) {
            if (self.in_thought) {
                try reasoning.appendSlice(self.pending.items);
            } else {
                try visible.appendSlice(self.pending.items);
            }
            self.pending.clearRetainingCapacity();
        }
        self.in_thought = false;
    }
};

fn appendJsonString(writer: anytype, text: []const u8) !void {
    try std.json.stringify(text, .{}, writer);
}

fn jsonStringLiteralAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try appendJsonString(out.writer(), text);
    return try out.toOwnedSlice();
}

fn jsonTextSlice(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        .number_string => |text| text,
        else => null,
    };
}

fn jsonRpcParamLookupKey(key: []const u8) []const u8 {
    if (key.len > 2 and key[0] == '"') {
        if (std.mem.indexOfScalar(u8, key[1..], '"')) |end| {
            if (end > 0) return key[1 .. 1 + end];
        }
    }
    return key;
}

fn jsonRpcParamsStringLiteralAlloc(body: []const u8, key: []const u8, fallback: []const u8, emit_null_if_missing: bool) ![]u8 {
    const lookup_key = jsonRpcParamLookupKey(key);
    if (lookup_key.len != 0) {
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch null;
        if (parsed) |*document| {
            defer document.deinit();
            if (jsonObjectGetValue(document.value, "params")) |params| {
                if (jsonObjectGetValue(params, lookup_key)) |value| {
                    if (jsonTextSlice(value)) |text| {
                        return try jsonStringLiteralAlloc(std.heap.page_allocator, text);
                    }
                }
            }
        }
    }

    if (emit_null_if_missing) return try std.heap.page_allocator.dupe(u8, "null");
    return try jsonStringLiteralAlloc(std.heap.page_allocator, fallback);
}

fn eqlAsciiIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

fn indexOfAsciiIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eqlAsciiIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn normalizedModeCode(raw: []const u8) u32 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (eqlAsciiIgnoreCase(trimmed, "plan")) return 1;
    if (eqlAsciiIgnoreCase(trimmed, "goal")) return 2;
    if (eqlAsciiIgnoreCase(trimmed, "code")) return 3;
    return 0;
}

fn modeCodeFromExplicitContainer(value: std.json.Value) u32 {
    const object = switch (value) {
        .object => |object| object,
        else => return 0,
    };
    if (jsonTextSlice(object.get("mode") orelse .null)) |text| {
        const mode = normalizedModeCode(text);
        if (mode != 0) return mode;
    }
    if (jsonTextSlice(object.get("kind") orelse .null)) |text| {
        const mode = normalizedModeCode(text);
        if (mode != 0) return mode;
    }
    if (jsonTextSlice(object.get("collaborationModeKind") orelse .null)) |text| {
        const mode = normalizedModeCode(text);
        if (mode != 0) return mode;
    }
    return 0;
}

fn modeCodeFromExplicitFields(root: std.json.ObjectMap) u32 {
    if (root.get("collaborationMode")) |value| {
        const mode = modeCodeFromExplicitContainer(value);
        if (mode != 0) return mode;
    }
    if (root.get("collaboration_mode")) |value| {
        const mode = modeCodeFromExplicitContainer(value);
        if (mode != 0) return mode;
    }
    if (root.get("client_metadata")) |value| {
        const mode = modeCodeFromExplicitContainer(value);
        if (mode != 0) return mode;
    }
    return 0;
}

fn instructionModeFromText(latest: u32, text: []const u8) u32 {
    var mode = latest;
    var search_start: usize = 0;
    while (search_start < text.len) {
        const remaining = text[search_start..];
        const plan_index = indexOfAsciiIgnoreCase(remaining, "# Plan Mode (Conversational)");
        const plan_alt_index = indexOfAsciiIgnoreCase(remaining, "You are in **Plan Mode**");
        const collab_plan_index = indexOfAsciiIgnoreCase(remaining, "<collaboration_mode># Plan Mode");
        const code_index = indexOfAsciiIgnoreCase(remaining, "# Collaboration Mode: Code");
        const default_index = indexOfAsciiIgnoreCase(remaining, "# Collaboration Mode: Default");

        var best_index: ?usize = null;
        var best_mode: u32 = 0;
        const candidates = [_]struct { idx: ?usize, mode: u32 }{
            .{ .idx = plan_index, .mode = 1 },
            .{ .idx = plan_alt_index, .mode = 1 },
            .{ .idx = collab_plan_index, .mode = 1 },
            .{ .idx = code_index, .mode = 3 },
            .{ .idx = default_index, .mode = 3 },
        };
        for (candidates) |candidate| {
            if (candidate.idx) |idx| {
                if (best_index == null or idx < best_index.?) {
                    best_index = idx;
                    best_mode = candidate.mode;
                }
            }
        }
        const idx = best_index orelse break;
        mode = best_mode;
        search_start += idx + 1;
    }
    return mode;
}

fn collectModeCodeFromContent(content: std.json.Value, instruction: bool, instruction_mode: *u32, has_goal: *bool) void {
    if (jsonTextSlice(content)) |text| {
        if (indexOfAsciiIgnoreCase(text, "<goal_context>") != null or
            indexOfAsciiIgnoreCase(text, "Continue working toward the active thread goal") != null)
        {
            has_goal.* = true;
        }
        if (instruction) instruction_mode.* = instructionModeFromText(instruction_mode.*, text);
        return;
    }

    switch (content) {
        .array => |items| {
            for (items.items) |part| {
                const object = switch (part) {
                    .object => |object| object,
                    else => continue,
                };
                if (jsonTextSlice(object.get("text") orelse .null)) |text| {
                    if (indexOfAsciiIgnoreCase(text, "<goal_context>") != null or
                        indexOfAsciiIgnoreCase(text, "Continue working toward the active thread goal") != null)
                    {
                        has_goal.* = true;
                    }
                    if (instruction) instruction_mode.* = instructionModeFromText(instruction_mode.*, text);
                }
            }
        },
        else => {},
    }
}

pub fn inferCollaborationModeCode(body: []const u8) u32 {
    if (body.len == 0) return 0;
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch return 0;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return 0,
    };

    const explicit = modeCodeFromExplicitFields(root);
    if (explicit != 0) return explicit;

    var instruction_mode: u32 = 0;
    var has_goal = false;
    if (jsonTextSlice(root.get("instructions") orelse .null)) |text| {
        instruction_mode = instructionModeFromText(instruction_mode, text);
        if (indexOfAsciiIgnoreCase(text, "<goal_context>") != null or
            indexOfAsciiIgnoreCase(text, "Continue working toward the active thread goal") != null)
        {
            has_goal = true;
        }
    }
    if (jsonTextSlice(root.get("system") orelse .null)) |text| {
        instruction_mode = instructionModeFromText(instruction_mode, text);
        if (indexOfAsciiIgnoreCase(text, "<goal_context>") != null or
            indexOfAsciiIgnoreCase(text, "Continue working toward the active thread goal") != null)
        {
            has_goal = true;
        }
    }

    if (root.get("input")) |input| {
        switch (input) {
            .array => |items| {
                for (items.items) |item| {
                    const object = switch (item) {
                        .object => |object| object,
                        else => continue,
                    };
                    const role = jsonStringValue(object.get("role"));
                    const instruction = eqlAsciiIgnoreCase(role, "developer") or eqlAsciiIgnoreCase(role, "system");
                    if (object.get("content")) |content| {
                        collectModeCodeFromContent(content, instruction, &instruction_mode, &has_goal);
                    }
                    if (jsonTextSlice(object.get("text") orelse .null)) |text| {
                        if (indexOfAsciiIgnoreCase(text, "<goal_context>") != null or
                            indexOfAsciiIgnoreCase(text, "Continue working toward the active thread goal") != null)
                        {
                            has_goal = true;
                        }
                        if (instruction) instruction_mode = instructionModeFromText(instruction_mode, text);
                    }
                }
            },
            else => {},
        }
    }

    if (has_goal) return 2;
    return instruction_mode;
}

fn jsonU64Value(value: ?std.json.Value) u64 {
    const actual = value orelse return 0;
    return switch (actual) {
        .integer => |inner| if (inner >= 0) @as(u64, @intCast(inner)) else 0,
        .float => |inner| if (inner >= 0 and inner <= @as(f64, @floatFromInt(std.math.maxInt(u64)))) @as(u64, @intFromFloat(inner)) else 0,
        else => 0,
    };
}

fn appendResponseCreated(out: *std.ArrayList(u8)) !void {
    try out.appendSlice("event: response.created\n");
    try out.appendSlice("data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_chat_fb\"}}\n\n");
}

fn appendReasoningDelta(
    out: *std.ArrayList(u8),
    reasoning_started: *bool,
    reasoning_done: *bool,
    reasoning_output_index: *u64,
    next_output_index: *u64,
    text: []const u8,
) !void {
    if (text.len == 0) return;
    const writer = out.writer();
    if (reasoning_done.*) {
        reasoning_started.* = false;
        reasoning_done.* = false;
    }
    if (!reasoning_started.*) {
        reasoning_output_index.* = next_output_index.*;
        next_output_index.* += 1;
        try out.appendSlice("event: response.output_item.added\n");
        try out.appendSlice("data: {\"type\":\"response.output_item.added\",\"output_index\":");
        try writer.print("{}", .{reasoning_output_index.*});
        try out.appendSlice(",\"item\":{\"id\":\"think_chat_fb\",\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"\"}]}}\n\n");
        try out.appendSlice("event: response.reasoning_summary_part.added\n");
        try out.appendSlice("data: {\"type\":\"response.reasoning_summary_part.added\",\"item_id\":\"think_chat_fb\",\"output_index\":");
        try writer.print("{}", .{reasoning_output_index.*});
        try out.appendSlice(",\"summary_index\":0}\n\n");
        reasoning_started.* = true;
    }
    try out.appendSlice("event: response.reasoning_summary_text.delta\n");
    try out.appendSlice("data: {\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"think_chat_fb\",\"output_index\":");
    try writer.print("{}", .{reasoning_output_index.*});
    try out.appendSlice(",\"summary_index\":0,\"delta\":");
    try appendJsonString(writer, text);
    try out.appendSlice("}\n\n");
}

fn appendReasoningDone(
    out: *std.ArrayList(u8),
    reasoning_started: bool,
    reasoning_done: *bool,
    reasoning_output_index: u64,
    reasoning_text: []const u8,
) !void {
    if (!reasoning_started) return;
    if (reasoning_done.*) return;
    const writer = out.writer();
    try out.appendSlice("event: response.output_item.done\n");
    try out.appendSlice("data: {\"type\":\"response.output_item.done\",\"output_index\":");
    try writer.print("{}", .{reasoning_output_index});
    try out.appendSlice(",\"item\":{\"id\":\"think_chat_fb\",\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":");
    try appendJsonString(writer, reasoning_text);
    try out.appendSlice("}],\"encrypted_content\":null,\"content\":[{\"type\":\"reasoning_text\",\"text\":");
    try appendJsonString(writer, reasoning_text);
    try out.appendSlice("}]}}\n\n");
    reasoning_done.* = true;
}

fn appendMessageDelta(
    out: *std.ArrayList(u8),
    message_started: *bool,
    message_output_index: *u64,
    next_output_index: *u64,
    message_text: *std.ArrayList(u8),
    text: []const u8,
) !void {
    if (text.len == 0) return;
    const writer = out.writer();
    if (!message_started.*) {
        message_output_index.* = next_output_index.*;
        next_output_index.* += 1;
        try out.appendSlice("event: response.output_item.added\n");
        try out.appendSlice("data: {\"type\":\"response.output_item.added\",\"output_index\":");
        try writer.print("{}", .{message_output_index.*});
        try out.appendSlice(",\"item\":{\"id\":\"msg_chat_fb\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"\"}]}}\n\n");
        message_started.* = true;
    }
    try message_text.appendSlice(text);
    try out.appendSlice("event: response.output_text.delta\n");
    try out.appendSlice("data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_chat_fb\",\"output_index\":");
    try writer.print("{}", .{message_output_index.*});
    try out.appendSlice(",\"content_index\":0,\"delta\":");
    try appendJsonString(writer, text);
    try out.appendSlice("}\n\n");
}

fn appendMessageDone(out: *std.ArrayList(u8), message_started: bool, message_output_index: u64, message_text: []const u8) !void {
    if (!message_started) return;
    const writer = out.writer();
    try out.appendSlice("event: response.output_item.done\n");
    try out.appendSlice("data: {\"type\":\"response.output_item.done\",\"output_index\":");
    try writer.print("{}", .{message_output_index});
    try out.appendSlice(",\"item\":{\"id\":\"msg_chat_fb\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
    try appendJsonString(writer, message_text);
    try out.appendSlice("}]}}\n\n");
}

fn requestAllowsContinuation(req_body: []const u8) bool {
    if (std.mem.indexOf(u8, req_body, "\"name\":\"exec_command\"") == null) return false;
    if (std.mem.indexOf(u8, req_body, "<goal_context>") != null) return true;
    if (std.mem.indexOf(u8, req_body, "\"mode\":\"goal\"") != null) return true;
    if (std.mem.indexOf(u8, req_body, "\"kind\":\"goal\"") != null) return true;
    if (std.mem.indexOf(u8, req_body, "\"collaborationModeKind\":\"goal\"") != null) return true;
    if (std.mem.indexOf(u8, req_body, "\"mode\":\"code\"") != null) return true;
    if (std.mem.indexOf(u8, req_body, "\"kind\":\"code\"") != null) return true;
    if (std.mem.indexOf(u8, req_body, "\"collaborationModeKind\":\"code\"") != null) return true;
    if (std.mem.indexOf(u8, req_body, "# Collaboration Mode: Default") != null) return true;
    return false;
}

fn isProgressOnlyText(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.mem.indexOf(u8, trimmed, "<proposed_plan>") != null or
        std.mem.indexOf(u8, trimmed, "</proposed_plan>") != null or
        std.mem.indexOf(u8, trimmed, "我已完成") != null or
        std.mem.indexOf(u8, trimmed, "结论") != null or
        std.mem.indexOf(u8, trimmed, "总结") != null or
        std.mem.indexOf(u8, trimmed, "summary") != null or
        std.mem.indexOf(u8, trimmed, "conclusion") != null or
        std.mem.indexOf(u8, trimmed, "completed") != null)
    {
        return false;
    }
    if (std.mem.indexOf(u8, trimmed, "Let me ") != null or
        std.mem.indexOf(u8, trimmed, "let me ") != null or
        std.mem.indexOf(u8, trimmed, "I'll ") != null or
        std.mem.indexOf(u8, trimmed, "I will ") != null or
        std.mem.indexOf(u8, trimmed, "我先") != null or
        std.mem.indexOf(u8, trimmed, "我会") != null or
        std.mem.indexOf(u8, trimmed, "接下来") != null)
    {
        return std.mem.indexOf(u8, trimmed, "check") != null or
            std.mem.indexOf(u8, trimmed, "inspect") != null or
            std.mem.indexOf(u8, trimmed, "read") != null or
            std.mem.indexOf(u8, trimmed, "run") != null or
            std.mem.indexOf(u8, trimmed, "verify") != null or
            std.mem.indexOf(u8, trimmed, "review") != null or
            std.mem.indexOf(u8, trimmed, "analyze") != null or
            std.mem.indexOf(u8, trimmed, "analyse") != null or
            std.mem.indexOf(u8, trimmed, "查看") != null or
            std.mem.indexOf(u8, trimmed, "检查") != null or
            std.mem.indexOf(u8, trimmed, "读取") != null or
            std.mem.indexOf(u8, trimmed, "运行") != null or
            std.mem.indexOf(u8, trimmed, "执行") != null or
            std.mem.indexOf(u8, trimmed, "评估") != null or
            std.mem.indexOf(u8, trimmed, "分析") != null;
    }
    return false;
}

fn appendContinuationTool(out: *std.ArrayList(u8)) !void {
    try out.appendSlice("event: response.output_item.done\n");
    try out.appendSlice("data: {\"type\":\"response.output_item.done\",\"item\":{\"id\":\"tc_chat_continue\",\"type\":\"function_call\",\"call_id\":\"call_chat_continue\",\"name\":\"exec_command\",\"arguments\":\"{\\\"cmd\\\":\\\"printf '%s\\\\n' 'Progress-only message received in chat fallback. Continue now: call a read-only tool if more evidence is needed, otherwise provide the final answer.'\\\"}\"}}\n\n");
}

fn appendContinuationToolJson(out: *std.ArrayList(u8)) !void {
    try out.appendSlice("{\"type\":\"function_call\",\"id\":\"tc_chat_continue\",\"call_id\":\"call_chat_continue\",\"name\":\"exec_command\",\"arguments\":\"{\\\"cmd\\\":\\\"printf '%s\\\\n' 'Progress-only message received in chat fallback. Continue now: call a read-only tool if more evidence is needed, otherwise provide the final answer.'\\\"}\"}");
}

const ChatToolCallState = struct {
    allocator: std.mem.Allocator,
    index: usize,
    call_id: std.ArrayList(u8),
    name: std.ArrayList(u8),
    arguments: std.ArrayList(u8),

    fn init(allocator: std.mem.Allocator, index: usize) ChatToolCallState {
        return .{
            .allocator = allocator,
            .index = index,
            .call_id = std.ArrayList(u8).init(allocator),
            .name = std.ArrayList(u8).init(allocator),
            .arguments = std.ArrayList(u8).init(allocator),
        };
    }

    fn deinit(self: *ChatToolCallState) void {
        self.call_id.deinit();
        self.name.deinit();
        self.arguments.deinit();
    }
};

fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.append('\'');
    for (value) |ch| {
        if (ch == '\'') {
            try out.appendSlice("'\\''");
        } else {
            try out.append(ch);
        }
    }
    try out.append('\'');
    return try out.toOwnedSlice();
}

fn isSensitiveEnvPath(path: []const u8) bool {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse std.math.maxInt(usize);
    const base = if (slash == std.math.maxInt(usize)) path else path[slash + 1 ..];
    if (base.len < 4) return false;
    if (!std.ascii.eqlIgnoreCase(base[0..4], ".env")) return false;
    return base.len == 4 or base[4] == '.';
}

fn appendCommandArguments(out_arguments: *std.ArrayList(u8), command: []const u8) !void {
    try out_arguments.appendSlice("{\"cmd\":");
    try appendJsonString(out_arguments.writer(), command);
    try out_arguments.append('}');
}

fn appendReadCommand(allocator: std.mem.Allocator, path: []const u8, out_arguments: *std.ArrayList(u8)) !void {
    const quoted = try shellQuote(allocator, path);
    defer allocator.free(quoted);
    var command = std.ArrayList(u8).init(allocator);
    defer command.deinit();
    if (isSensitiveEnvPath(path)) {
        try command.appendSlice("sed -E 's/(OPENAI_API_KEY|AUTH|TOKEN|KEY|SECRET)=.*/\\\\1=<redacted>/I' ");
    } else {
        try command.appendSlice("cat ");
    }
    try command.appendSlice(quoted);
    try appendCommandArguments(out_arguments, command.items);
}

const McpNamespaceSplit = struct { namespace: []const u8, tool: []const u8 };

fn splitMcpNamespace(name: []const u8) ?McpNamespaceSplit {
    if (!std.mem.startsWith(u8, name, "mcp__")) return null;
    const rest_start: usize = 5;
    const rel_end = std.mem.indexOf(u8, name[rest_start..], "__") orelse return null;
    const ns_len = rest_start + rel_end + 2;
    if (name.len <= ns_len) return null;
    const tool_start = if (name[ns_len] == '.') ns_len + 1 else ns_len;
    if (tool_start >= name.len) return null;
    return .{ .namespace = name[0..ns_len], .tool = name[tool_start..] };
}

fn denormalizeMcpServerNameAlloc(allocator: std.mem.Allocator, server: []const u8) ![]u8 {
    var source = server;
    if (std.mem.startsWith(u8, source, "mcp__") and std.mem.endsWith(u8, source, "__") and source.len > 7) {
        source = source[5 .. source.len - 2];
    }
    var out = try allocator.alloc(u8, source.len);
    for (source, 0..) |ch, idx| {
        out[idx] = switch (ch) {
            '_', ' ' => '-',
            else => std.ascii.toLower(ch),
        };
    }
    return out;
}

fn normalizeMcpServerNameAlloc(allocator: std.mem.Allocator, server: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, server, "mcp__mcp_") and std.mem.endsWith(u8, server, "___") and server.len > 11) {
        const inner = server[9 .. server.len - 3];
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        try out.appendSlice("mcp__");
        try out.appendSlice(inner);
        try out.appendSlice("__");
        return try out.toOwnedSlice();
    }
    if (std.mem.startsWith(u8, server, "mcp__") and std.mem.endsWith(u8, server, "__") and server.len > 7) {
        return allocator.dupe(u8, server);
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice("mcp__");
    var last_sep = false;
    for (server) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            try out.append(std.ascii.toLower(ch));
            last_sep = false;
        } else if (!last_sep) {
            try out.append('_');
            last_sep = true;
        }
    }
    while (out.items.len > 5 and out.items[out.items.len - 1] == '_') _ = out.pop();
    try out.appendSlice("__");
    return try out.toOwnedSlice();
}

fn requestMentionsTool(req_body: []const u8, name: []const u8) bool {
    return name.len != 0 and std.mem.indexOf(u8, req_body, name) != null;
}

fn toolValueDeclaresNamespace(tool: std.json.Value, namespace: []const u8) bool {
    const object = switch (tool) {
        .object => |object| object,
        else => return false,
    };

    const tool_type = jsonStringValue(object.get("type") orelse .null);
    const name = jsonStringValue(object.get("name") orelse .null);
    if (std.mem.eql(u8, tool_type, "namespace") and std.mem.eql(u8, name, namespace)) return true;
    if (splitMcpNamespace(name)) |split| {
        if (std.mem.eql(u8, split.namespace, namespace)) return true;
    }

    if (jsonObjectGetValue(tool, "function")) |function_value| {
        const function_name = jsonStringValue(jsonObjectGetValue(function_value, "name"));
        if (splitMcpNamespace(function_name)) |split| {
            if (std.mem.eql(u8, split.namespace, namespace)) return true;
        }
    }

    if (jsonObjectGetValue(tool, "tools")) |nested_tools| {
        if (toolListDeclaresNamespace(nested_tools, namespace)) return true;
    }

    return false;
}

fn toolListDeclaresNamespace(tools: std.json.Value, namespace: []const u8) bool {
    const array = switch (tools) {
        .array => |array| array,
        else => return false,
    };
    for (array.items) |tool| {
        if (toolValueDeclaresNamespace(tool, namespace)) return true;
    }
    return false;
}

fn requestHasNamespaceTool(req_body: []const u8, namespace: []const u8) bool {
    if (namespace.len == 0) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, req_body, .{}) catch {
        return std.mem.indexOf(u8, req_body, namespace) != null;
    };
    defer parsed.deinit();
    if (jsonObjectGetValue(parsed.value, "tools")) |tools| {
        if (toolListDeclaresNamespace(tools, namespace)) return true;
    }
    return false;
}

fn requestHasExplicitTopLevelNamespaceTool(req_body: []const u8, namespace: []const u8) bool {
    if (namespace.len == 0) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, req_body, .{}) catch return false;
    defer parsed.deinit();
    const tools = jsonObjectGetValue(parsed.value, "tools") orelse return false;
    const array = switch (tools) {
        .array => |array| array,
        else => return false,
    };
    for (array.items) |tool| {
        const tool_type = jsonStringValue(jsonObjectGetValue(tool, "type"));
        if (!std.mem.eql(u8, tool_type, "namespace")) continue;
        const name = jsonStringValue(jsonObjectGetValue(tool, "name"));
        if (std.mem.eql(u8, name, namespace)) return true;
    }
    return false;
}

fn normalizeMcpDotToolNameAlloc(allocator: std.mem.Allocator, req_body: []const u8, name: []const u8) !?[]u8 {
    const dot_index = std.mem.indexOfScalar(u8, name, '.') orelse return null;
    if (dot_index == 0 or dot_index + 1 >= name.len) return null;
    const prefix = name[0..dot_index];
    const rest = name[dot_index + 1 ..];
    const normalized_prefix = try normalizeMcpServerNameAlloc(allocator, prefix);
    defer allocator.free(normalized_prefix);
    if (!requestHasNamespaceTool(req_body, normalized_prefix)) return null;

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice(normalized_prefix);
    try out.appendSlice(rest);
    return try out.toOwnedSlice();
}

fn appendArgumentsWithDenormalizedMcpServer(
    allocator: std.mem.Allocator,
    arguments: []const u8,
    out_arguments: *std.ArrayList(u8),
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    if (try normalizeResponsesArgumentsString(arena.allocator(), arguments)) |normalized| {
        try out_arguments.appendSlice(normalized);
        return;
    }
    try out_arguments.appendSlice(arguments);
}

fn normalizeChatToolArguments(
    allocator: std.mem.Allocator,
    req_body: []const u8,
    name: []const u8,
    arguments: []const u8,
    out_namespace: *std.ArrayList(u8),
    out_name: *std.ArrayList(u8),
    out_arguments: *std.ArrayList(u8),
) !bool {
    const normalized_dot_name: ?[]u8 = try normalizeMcpDotToolNameAlloc(allocator, req_body, name);
    defer if (normalized_dot_name) |owned| allocator.free(owned);
    const effective_name = normalized_dot_name orelse name;

    if (std.mem.eql(u8, effective_name, "exec_command")) {
        if (!requestMentionsTool(req_body, "exec_command")) return false;
        try out_name.appendSlice("exec_command");
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments, .{}) catch {
            try out_arguments.appendSlice(arguments);
            return true;
        };
        defer parsed.deinit();
        const command = jsonStringValue(jsonObjectGetValue(parsed.value, "command"));
        if (command.len != 0) {
            try appendCommandArguments(out_arguments, command);
            return true;
        }
        try out_arguments.appendSlice(arguments);
        return true;
    }

    if (std.mem.eql(u8, effective_name, "read")) {
        if (!requestMentionsTool(req_body, "exec_command")) return false;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments, .{}) catch return false;
        defer parsed.deinit();
        var path = jsonStringValue(jsonObjectGetValue(parsed.value, "filePath"));
        if (path.len == 0) path = jsonStringValue(jsonObjectGetValue(parsed.value, "path"));
        if (path.len == 0) return false;
        try out_name.appendSlice("exec_command");
        try appendReadCommand(allocator, path, out_arguments);
        return true;
    }

    if (splitMcpNamespace(effective_name)) |split| {
        if (!requestHasNamespaceTool(req_body, split.namespace)) {
            if (!requestMentionsTool(req_body, effective_name)) return false;
            try out_name.appendSlice(effective_name);
            try appendArgumentsWithDenormalizedMcpServer(allocator, arguments, out_arguments);
            return true;
        }
        try out_namespace.appendSlice(split.namespace);
        try out_name.appendSlice(split.tool);
        try appendArgumentsWithDenormalizedMcpServer(allocator, arguments, out_arguments);
        return true;
    }

    if (!requestMentionsTool(req_body, effective_name)) {
        if (!requestMentionsTool(req_body, "exec_command")) return false;
        try out_name.appendSlice("exec_command");
        var message = std.ArrayList(u8).init(allocator);
        defer message.deinit();
        try message.appendSlice("Tool ");
        if (effective_name.len != 0) {
            try message.appendSlice(effective_name);
        } else {
            try message.appendSlice("unknown");
        }
        try message.appendSlice(" is unavailable in chat fallback; continue with exec_command/MCP tools or provide the final answer.");
        const quoted = try shellQuote(allocator, message.items);
        defer allocator.free(quoted);
        var command = std.ArrayList(u8).init(allocator);
        defer command.deinit();
        try command.appendSlice("printf '%s\\n' ");
        try command.appendSlice(quoted);
        try appendCommandArguments(out_arguments, command.items);
        return true;
    }

    try out_name.appendSlice(effective_name);
    try appendArgumentsWithDenormalizedMcpServer(allocator, arguments, out_arguments);
    return effective_name.len != 0;
}

fn appendNormalizedToolCall(out: *std.ArrayList(u8), req_body: []const u8, call: *const ChatToolCallState) !void {
    var normalized_namespace = std.ArrayList(u8).init(std.heap.page_allocator);
    defer normalized_namespace.deinit();
    var normalized_name = std.ArrayList(u8).init(std.heap.page_allocator);
    defer normalized_name.deinit();
    var normalized_args = std.ArrayList(u8).init(std.heap.page_allocator);
    defer normalized_args.deinit();
    const ok_norm = try normalizeChatToolArguments(
        std.heap.page_allocator,
        req_body,
        call.name.items,
        call.arguments.items,
        &normalized_namespace,
        &normalized_name,
        &normalized_args,
    );
    if (!ok_norm) return;

    const writer = out.writer();
    try out.appendSlice("event: response.output_item.done\n");
    try out.appendSlice("data: {\"type\":\"response.output_item.done\",\"item\":{\"id\":\"tc_chat_fb_");
    try writer.print("{}", .{call.index});
    try out.appendSlice("\",\"type\":\"function_call\",\"call_id\":");
    if (call.call_id.items.len != 0) {
        try appendJsonString(writer, call.call_id.items);
    } else {
        try appendJsonString(writer, normalized_name.items);
    }
    try out.appendSlice(",\"name\":");
    try appendJsonString(writer, normalized_name.items);
    try out.appendSlice(",\"arguments\":");
    try appendJsonString(writer, normalized_args.items);
    if (normalized_namespace.items.len != 0) {
        try out.appendSlice(",\"namespace\":");
        try appendJsonString(writer, normalized_namespace.items);
        try out.appendSlice(",\"output_kind\":\"function_call_output\"");
    }
    try out.appendSlice("}}\n\n");
}

fn appendNormalizedToolCallJson(out: *std.ArrayList(u8), req_body: []const u8, call: *const ChatToolCallState) !bool {
    var normalized_namespace = std.ArrayList(u8).init(std.heap.page_allocator);
    defer normalized_namespace.deinit();
    var normalized_name = std.ArrayList(u8).init(std.heap.page_allocator);
    defer normalized_name.deinit();
    var normalized_args = std.ArrayList(u8).init(std.heap.page_allocator);
    defer normalized_args.deinit();
    const ok_norm = try normalizeChatToolArguments(
        std.heap.page_allocator,
        req_body,
        call.name.items,
        call.arguments.items,
        &normalized_namespace,
        &normalized_name,
        &normalized_args,
    );
    if (!ok_norm) return false;

    const writer = out.writer();
    try out.appendSlice("{\"id\":\"tc_chat_fb_");
    try writer.print("{}", .{call.index});
    try out.appendSlice("\",\"type\":\"function_call\",\"call_id\":");
    if (call.call_id.items.len != 0) {
        try appendJsonString(writer, call.call_id.items);
    } else {
        try appendJsonString(writer, normalized_name.items);
    }
    try out.appendSlice(",\"name\":");
    try appendJsonString(writer, normalized_name.items);
    try out.appendSlice(",\"arguments\":");
    try appendJsonString(writer, normalized_args.items);
    if (normalized_namespace.items.len != 0) {
        try out.appendSlice(",\"namespace\":");
        try appendJsonString(writer, normalized_namespace.items);
        try out.appendSlice(",\"output_kind\":\"function_call_output\"");
    }
    try out.append('}');
    return true;
}

fn findToolCallState(calls: *std.ArrayList(ChatToolCallState), index: usize) !*ChatToolCallState {
    for (calls.items) |*call| {
        if (call.index == index) return call;
    }
    try calls.append(ChatToolCallState.init(std.heap.page_allocator, index));
    return &calls.items[calls.items.len - 1];
}

fn parseToolCallIndex(value: std.json.Value) usize {
    return switch (value) {
        .integer => |inner| if (inner >= 0) @as(usize, @intCast(inner)) else 0,
        .float => |inner| if (inner >= 0 and inner <= @as(f64, @floatFromInt(std.math.maxInt(usize)))) @as(usize, @intFromFloat(inner)) else 0,
        else => 0,
    };
}

fn appendResponseDone(out: *std.ArrayList(u8)) !void {
    try out.appendSlice("event: response.done\n");
    try out.appendSlice("data: {\"type\":\"response.done\",\"response\":{\"id\":\"resp_chat_fb\",\"status\":\"completed\"}}\n\n");
    try out.appendSlice("event: response.completed\n");
    try out.appendSlice("data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_chat_fb\",\"status\":\"completed\"}}\n\n");
}

fn appendChatUsageJson(out: *std.ArrayList(u8), usage: ?std.json.Value) !void {
    const prompt_tokens = if (usage) |u| blk: {
        const prompt = jsonU64Value(jsonObjectGetValue(u, "prompt_tokens"));
        break :blk if (prompt != 0) prompt else jsonU64Value(jsonObjectGetValue(u, "input_tokens"));
    } else 0;
    const completion_tokens = if (usage) |u| blk: {
        const completion = jsonU64Value(jsonObjectGetValue(u, "completion_tokens"));
        break :blk if (completion != 0) completion else jsonU64Value(jsonObjectGetValue(u, "output_tokens"));
    } else 0;
    const total_tokens = if (usage) |u| blk: {
        const total = jsonU64Value(jsonObjectGetValue(u, "total_tokens"));
        break :blk if (total != 0) total else prompt_tokens + completion_tokens;
    } else prompt_tokens + completion_tokens;
    const cached_tokens = if (usage) |u| jsonU64Value(jsonObjectGetValue(jsonObjectGetValue(u, "prompt_tokens_details") orelse .null, "cached_tokens")) else 0;
    const reasoning_tokens = if (usage) |u| jsonU64Value(jsonObjectGetValue(jsonObjectGetValue(u, "completion_tokens_details") orelse .null, "reasoning_tokens")) else 0;
    try out.writer().print(
        "\"usage\":{{\"input_tokens\":{},\"input_tokens_details\":{{\"cached_tokens\":{}}},\"output_tokens\":{},\"output_tokens_details\":{{\"reasoning_tokens\":{}}},\"total_tokens\":{}}}",
        .{ prompt_tokens, cached_tokens, completion_tokens, reasoning_tokens, total_tokens },
    );
}

fn appendChatJsonReasoningItem(out: *std.ArrayList(u8), text: []const u8) !void {
    const writer = out.writer();
    try out.appendSlice("{\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":");
    try appendJsonString(writer, text);
    try out.appendSlice("}],\"encrypted_content\":null,\"content\":[{\"type\":\"reasoning_text\",\"text\":");
    try appendJsonString(writer, text);
    try out.appendSlice("}]}");
}

fn appendChatJsonMessageItem(out: *std.ArrayList(u8), text: []const u8) !void {
    const writer = out.writer();
    try out.appendSlice("{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
    try appendJsonString(writer, text);
    try out.appendSlice("}]}");
}

fn appendOutputComma(out: *std.ArrayList(u8), count: *usize) !void {
    if (count.* != 0) try out.append(',');
    count.* += 1;
}

fn denoChatJsonToResponses(chat_body: []const u8, req_body: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, chat_body, .{}) catch {
        return std.heap.page_allocator.dupe(u8, chat_body);
    };
    defer parsed.deinit();

    const first_choice = jsonArrayFirst(jsonObjectGetValue(parsed.value, "choices") orelse .null);
    const message = if (first_choice) |choice| jsonObjectGetValue(choice, "message") else null;
    const content = if (message) |msg| jsonStringValue(jsonObjectGetValue(msg, "content")) else "";
    const message_reasoning = if (message) |msg| jsonStringValue(jsonObjectGetValue(msg, "reasoning_content")) else "";

    var splitter = ThoughtStreamSplitter.init(std.heap.page_allocator);
    defer splitter.deinit();
    var visible = std.ArrayList(u8).init(std.heap.page_allocator);
    defer visible.deinit();
    var thought = std.ArrayList(u8).init(std.heap.page_allocator);
    defer thought.deinit();
    try splitter.consume(content, &visible, &thought);
    try splitter.flush(&visible, &thought);

    const trimmed_message_reasoning = std.mem.trim(u8, message_reasoning, " \t\r\n");
    const trimmed_thought = std.mem.trim(u8, thought.items, " \t\r\n");
    const trimmed_visible = std.mem.trim(u8, visible.items, " \t\r\n");

    var reasoning = std.ArrayList(u8).init(std.heap.page_allocator);
    defer reasoning.deinit();
    if (trimmed_message_reasoning.len != 0) try reasoning.appendSlice(trimmed_message_reasoning);
    if (trimmed_thought.len != 0 and !std.mem.eql(u8, trimmed_thought, trimmed_message_reasoning)) {
        if (reasoning.items.len != 0) try reasoning.append('\n');
        try reasoning.appendSlice(trimmed_thought);
    }

    var out = std.ArrayList(u8).init(std.heap.page_allocator);
    errdefer out.deinit();
    const writer = out.writer();
    try out.appendSlice("{\"id\":\"resp_chat_fb\",\"object\":\"response\",\"output\":[");
    var output_count: usize = 0;
    if (reasoning.items.len != 0) {
        try appendOutputComma(&out, &output_count);
        try appendChatJsonReasoningItem(&out, reasoning.items);
    }
    if (trimmed_visible.len != 0) {
        try appendOutputComma(&out, &output_count);
        try appendChatJsonMessageItem(&out, trimmed_visible);
    }

    var tool_count: usize = 0;
    if (message) |msg| {
        if (jsonObjectGetValue(msg, "tool_calls")) |tool_calls_value| {
            switch (tool_calls_value) {
                .array => |array| {
                    for (array.items, 0..) |entry, idx| {
                        const fn_value = jsonObjectGetValue(entry, "function") orelse .null;
                        const call_id = jsonStringValue(jsonObjectGetValue(entry, "id"));
                        const name = jsonStringValue(jsonObjectGetValue(fn_value, "name"));
                        const args = jsonStringValue(jsonObjectGetValue(fn_value, "arguments"));
                        var call = ChatToolCallState.init(std.heap.page_allocator, idx);
                        defer call.deinit();
                        try call.call_id.appendSlice(call_id);
                        try call.name.appendSlice(name);
                        try call.arguments.appendSlice(args);
                        var item = std.ArrayList(u8).init(std.heap.page_allocator);
                        defer item.deinit();
                        if (try appendNormalizedToolCallJson(&item, req_body, &call)) {
                            try appendOutputComma(&out, &output_count);
                            try out.appendSlice(item.items);
                            tool_count += 1;
                        }
                    }
                },
                else => {},
            }
        }
    }

    if (tool_count == 0 and trimmed_visible.len != 0 and requestAllowsContinuation(req_body) and isProgressOnlyText(trimmed_visible)) {
        try appendOutputComma(&out, &output_count);
        try appendContinuationToolJson(&out);
    }

    try out.appendSlice("],\"output_text\":");
    try appendJsonString(writer, trimmed_visible);
    try out.append(',');
    try appendChatUsageJson(&out, if (jsonObjectGetValue(parsed.value, "usage")) |usage| usage else null);
    try out.appendSlice(",\"status\":\"completed\"}");
    return try out.toOwnedSlice();
}

const ThoughtSplit = struct {
    visible: []u8,
    reasoning: []u8,
};

fn splitThoughtTextAlloc(allocator: std.mem.Allocator, text: []const u8) !ThoughtSplit {
    var splitter = ThoughtStreamSplitter.init(allocator);
    defer splitter.deinit();
    var visible = std.ArrayList(u8).init(allocator);
    errdefer visible.deinit();
    var reasoning = std.ArrayList(u8).init(allocator);
    errdefer reasoning.deinit();
    try splitter.consume(text, &visible, &reasoning);
    try splitter.flush(&visible, &reasoning);
    const trimmed_visible = std.mem.trim(u8, visible.items, " \t\r\n");
    const trimmed_reasoning = std.mem.trim(u8, reasoning.items, " \t\r\n");
    const owned_visible = try allocator.dupe(u8, trimmed_visible);
    const owned_reasoning = try allocator.dupe(u8, trimmed_reasoning);
    visible.deinit();
    reasoning.deinit();
    return .{ .visible = owned_visible, .reasoning = owned_reasoning };
}

fn appendMergedReasoningText(out: *std.ArrayList(u8), text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return;
    if (std.mem.indexOf(u8, out.items, trimmed) != null) return;
    if (out.items.len != 0) try out.append('\n');
    try out.appendSlice(trimmed);
}

fn appendReasoningFields(value: std.json.Value, out: *std.ArrayList(u8)) !void {
    const fields = [_][]const u8{ "reasoning", "reasoning_content", "thinking", "thought", "reason", "text" };
    inline for (fields) |field| {
        try appendMergedReasoningText(out, jsonStringValue(jsonObjectGetValue(value, field)));
    }
    if (jsonObjectGetValue(value, "summary")) |summary| {
        switch (summary) {
            .string => |text| try appendMergedReasoningText(out, text),
            .array => |array| {
                for (array.items) |part| {
                    switch (part) {
                        .string => |text| try appendMergedReasoningText(out, text),
                        .object => try appendMergedReasoningText(out, jsonStringValue(jsonObjectGetValue(part, "text"))),
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    if (jsonObjectGetValue(value, "content")) |content| {
        switch (content) {
            .array => |array| {
                for (array.items) |part| {
                    const part_type = jsonStringValue(jsonObjectGetValue(part, "type"));
                    if (std.mem.eql(u8, part_type, "reasoning_text") or std.mem.eql(u8, part_type, "summary_text")) {
                        try appendMergedReasoningText(out, jsonStringValue(jsonObjectGetValue(part, "text")));
                    }
                }
            },
            else => {},
        }
    }
}

fn isNativeReasoningType(item_type: []const u8) bool {
    return std.mem.eql(u8, item_type, "reasoning") or
        std.mem.eql(u8, item_type, "thinking") or
        std.mem.eql(u8, item_type, "thought") or
        std.mem.eql(u8, item_type, "reason");
}

fn appendNativeReasoningItem(out: *std.ArrayList(u8), id: []const u8, text: []const u8) !void {
    const writer = out.writer();
    try out.appendSlice("{\"id\":");
    if (id.len != 0) {
        try appendJsonString(writer, id);
    } else {
        try appendJsonString(writer, "rs_native_json");
    }
    try out.appendSlice(",\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":");
    try appendJsonString(writer, text);
    try out.appendSlice("}],\"encrypted_content\":null,\"content\":[{\"type\":\"reasoning_text\",\"text\":");
    try appendJsonString(writer, text);
    try out.appendSlice("}]}");
}

fn appendNativeMessageItem(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    item: std.json.Value,
    output_count: *usize,
    has_reasoning: *bool,
) !void {
    var item_reasoning = std.ArrayList(u8).init(allocator);
    defer item_reasoning.deinit();
    const reason_fields = [_][]const u8{ "reasoning", "reasoning_content", "thinking", "thought", "reason" };
    inline for (reason_fields) |field| {
        try appendMergedReasoningText(&item_reasoning, jsonStringValue(jsonObjectGetValue(item, field)));
    }

    var visible_content = std.ArrayList(u8).init(allocator);
    defer visible_content.deinit();
    var content_count: usize = 0;
    if (jsonObjectGetValue(item, "content")) |content| {
        switch (content) {
            .array => |array| {
                for (array.items) |part| {
                    const part_type = jsonStringValue(jsonObjectGetValue(part, "type"));
                    const text = jsonStringValue(jsonObjectGetValue(part, "text"));
                    if ((std.mem.eql(u8, part_type, "output_text") or std.mem.eql(u8, part_type, "text")) and text.len != 0) {
                        const split = try splitThoughtTextAlloc(allocator, text);
                        defer allocator.free(split.visible);
                        defer allocator.free(split.reasoning);
                        try appendMergedReasoningText(&item_reasoning, split.reasoning);
                        if (split.visible.len != 0) {
                            if (content_count != 0) try visible_content.append(',');
                            try visible_content.appendSlice("{\"type\":\"output_text\",\"text\":");
                            try appendJsonString(visible_content.writer(), split.visible);
                            try visible_content.append('}');
                            content_count += 1;
                        }
                    } else {
                        if (content_count != 0) try visible_content.append(',');
                        try std.json.stringify(part, .{}, visible_content.writer());
                        content_count += 1;
                    }
                }
            },
            else => {},
        }
    }

    if (item_reasoning.items.len != 0) {
        try appendOutputComma(out, output_count);
        try appendNativeReasoningItem(out, "", item_reasoning.items);
        has_reasoning.* = true;
    }

    try appendOutputComma(out, output_count);
    const writer = out.writer();
    try out.appendSlice("{\"type\":\"message\",\"role\":");
    const role = jsonStringValue(jsonObjectGetValue(item, "role"));
    try appendJsonString(writer, if (role.len != 0) role else "assistant");
    if (jsonStringValue(jsonObjectGetValue(item, "id")).len != 0) {
        try out.appendSlice(",\"id\":");
        try appendJsonString(writer, jsonStringValue(jsonObjectGetValue(item, "id")));
    }
    try out.appendSlice(",\"content\":[");
    try out.appendSlice(visible_content.items);
    try out.appendSlice("]}");
}

fn appendNativeNormalizedOutput(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    output: ?std.json.Value,
    output_text_reasoning: []const u8,
    req_body: []const u8,
) !void {
    try out.appendSlice("\"output\":[");
    var output_count: usize = 0;
    var has_reasoning = false;
    if (output) |output_value| {
        switch (output_value) {
            .array => |array| {
                for (array.items) |item| {
                    const item_type = jsonStringValue(jsonObjectGetValue(item, "type"));
                    if (isNativeReasoningType(item_type)) {
                        var text = std.ArrayList(u8).init(allocator);
                        defer text.deinit();
                        try appendReasoningFields(item, &text);
                        if (text.items.len != 0) {
                            try appendOutputComma(out, &output_count);
                            try appendNativeReasoningItem(out, jsonStringValue(jsonObjectGetValue(item, "id")), text.items);
                            has_reasoning = true;
                        }
                        continue;
                    }
                    if (std.mem.eql(u8, item_type, "message")) {
                        try appendNativeMessageItem(allocator, out, item, &output_count, &has_reasoning);
                        continue;
                    }
                    if (nativeFunctionCallNeedsNamespaceNormalize(item, req_body)) {
                        try appendOutputComma(out, &output_count);
                        const name = jsonStringValue(jsonObjectGetValue(item, "name"));
                        try appendNativeFunctionCallWithNamespace(allocator, out, item, splitMcpNamespace(name).?);
                        continue;
                    }
                    if (outputKindForResponsesToolCallType(item_type)) |output_kind| {
                        try appendOutputComma(out, &output_count);
                        try appendNativeToolCallWithOutputKind(allocator, out, item, output_kind);
                        continue;
                    }
                    try appendOutputComma(out, &output_count);
                    try std.json.stringify(item, .{}, out.writer());
                }
            },
            else => {},
        }
    }
    if (!has_reasoning and output_text_reasoning.len != 0) {
        try appendOutputComma(out, &output_count);
        try appendNativeReasoningItem(out, "", output_text_reasoning);
    }
    try out.append(']');
}

fn nativeFunctionCallNeedsNamespaceNormalize(item: std.json.Value, req_body: []const u8) bool {
    const item_type = jsonStringValue(jsonObjectGetValue(item, "type"));
    if (!std.mem.eql(u8, item_type, "function_call")) return false;
    const name = jsonStringValue(jsonObjectGetValue(item, "name"));
    const split = splitMcpNamespace(name) orelse return false;
    if (req_body.len == 0) return true;
    return requestHasExplicitTopLevelNamespaceTool(req_body, split.namespace);
}

fn outputKindForResponsesToolCallType(item_type: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, item_type, "function_call")) return "function_call_output";
    if (std.mem.eql(u8, item_type, "custom_tool_call")) return "custom_tool_call_output";
    if (std.mem.eql(u8, item_type, "tool_search_call")) return "tool_search_output";
    if (std.mem.eql(u8, item_type, "mcp_tool_call")) return "mcp_tool_call_output";
    return null;
}

fn appendNativeFunctionCallWithNamespace(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    item: std.json.Value,
    split: McpNamespaceSplit,
) !void {
    const object = switch (item) {
        .object => |object| object,
        else => return std.json.stringify(item, .{}, out.writer()),
    };
    try out.append('{');
    var field_count: usize = 0;
    var it = object.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "name") or
            std.mem.eql(u8, entry.key_ptr.*, "namespace") or
            std.mem.eql(u8, entry.key_ptr.*, "output_kind"))
        {
            continue;
        }
        if (field_count != 0) try out.append(',');
        try appendJsonString(out.writer(), entry.key_ptr.*);
        try out.append(':');
        if (std.mem.eql(u8, entry.key_ptr.*, "arguments")) {
            const arguments = jsonStringValue(entry.value_ptr.*);
            if (arguments.len != 0) {
                if (try normalizeResponsesArgumentsString(allocator, arguments)) |normalized_arguments| {
                    try std.json.stringify(normalized_arguments, .{}, out.writer());
                } else {
                    try std.json.stringify(entry.value_ptr.*, .{}, out.writer());
                }
            } else {
                try std.json.stringify(entry.value_ptr.*, .{}, out.writer());
            }
        } else {
            try std.json.stringify(entry.value_ptr.*, .{}, out.writer());
        }
        field_count += 1;
    }
    if (field_count != 0) try out.append(',');
    try out.appendSlice("\"name\":");
    try appendJsonString(out.writer(), split.tool);
    try out.appendSlice(",\"namespace\":");
    try appendJsonString(out.writer(), split.namespace);
    try out.appendSlice(",\"output_kind\":\"function_call_output\"}");
}

fn appendNativeToolCallWithOutputKind(allocator: std.mem.Allocator, out: *std.ArrayList(u8), item: std.json.Value, output_kind: []const u8) !void {
    const object = switch (item) {
        .object => |object| object,
        else => return std.json.stringify(item, .{}, out.writer()),
    };
    try out.append('{');
    var field_count: usize = 0;
    var it = object.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "output_kind")) continue;
        if (field_count != 0) try out.append(',');
        try appendJsonString(out.writer(), entry.key_ptr.*);
        try out.append(':');
        if (std.mem.eql(u8, entry.key_ptr.*, "arguments")) {
            const arguments = jsonStringValue(entry.value_ptr.*);
            if (arguments.len != 0) {
                if (try normalizeResponsesArgumentsString(allocator, arguments)) |normalized_arguments| {
                    try std.json.stringify(normalized_arguments, .{}, out.writer());
                } else {
                    try std.json.stringify(entry.value_ptr.*, .{}, out.writer());
                }
            } else {
                try std.json.stringify(entry.value_ptr.*, .{}, out.writer());
            }
        } else {
            try std.json.stringify(entry.value_ptr.*, .{}, out.writer());
        }
        field_count += 1;
    }
    if (field_count != 0) try out.append(',');
    try out.appendSlice("\"output_kind\":");
    try appendJsonString(out.writer(), output_kind);
    try out.append('}');
}

fn nativeResponsesJsonNeedsNormalize(root: std.json.ObjectMap, output_text_reasoning: []const u8, req_body: []const u8) bool {
    if (output_text_reasoning.len != 0) return true;
    const output = root.get("output") orelse return false;
    return switch (output) {
        .array => |array| {
            for (array.items) |item| {
                const item_type = jsonStringValue(jsonObjectGetValue(item, "type"));
                if (isNativeReasoningType(item_type)) return true;
                if (nativeFunctionCallNeedsNamespaceNormalize(item, req_body)) return true;
                if (outputKindForResponsesToolCallType(item_type) != null) return true;
                if (std.mem.eql(u8, item_type, "message")) {
                    const reason_fields = [_][]const u8{ "reasoning", "reasoning_content", "thinking", "thought", "reason" };
                    inline for (reason_fields) |field| {
                        if (std.mem.trim(u8, jsonStringValue(jsonObjectGetValue(item, field)), " \t\r\n").len != 0) return true;
                    }
                    if (jsonObjectGetValue(item, "content")) |content| {
                        switch (content) {
                            .array => |content_array| {
                                for (content_array.items) |part| {
                                    const part_type = jsonStringValue(jsonObjectGetValue(part, "type"));
                                    const text = jsonStringValue(jsonObjectGetValue(part, "text"));
                                    if (std.mem.eql(u8, part_type, "text")) return true;
                                    if (std.mem.eql(u8, part_type, "output_text") and
                                        (std.mem.indexOf(u8, text, "<thought>") != null or
                                            std.mem.indexOf(u8, text, "</thought>") != null))
                                    {
                                        return true;
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                }
            }
            return false;
        },
        else => false,
    };
}

fn denoResponsesJsonNormalizeWithRequest(body: []const u8, req_body: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch {
        return std.heap.page_allocator.dupe(u8, body);
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return std.heap.page_allocator.dupe(u8, body),
    };

    const output_text = jsonStringValue(root.get("output_text"));
    const output_text_split = try splitThoughtTextAlloc(std.heap.page_allocator, output_text);
    defer std.heap.page_allocator.free(output_text_split.visible);
    defer std.heap.page_allocator.free(output_text_split.reasoning);
    if (!nativeResponsesJsonNeedsNormalize(root, output_text_split.reasoning, req_body)) {
        return std.heap.page_allocator.dupe(u8, body);
    }

    var out = std.ArrayList(u8).init(std.heap.page_allocator);
    errdefer out.deinit();
    try out.append('{');
    var field_count: usize = 0;
    var it = root.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "output") or std.mem.eql(u8, entry.key_ptr.*, "output_text")) continue;
        if (field_count != 0) try out.append(',');
        try appendJsonString(out.writer(), entry.key_ptr.*);
        try out.append(':');
        try std.json.stringify(entry.value_ptr.*, .{}, out.writer());
        field_count += 1;
    }
    if (field_count != 0) try out.append(',');
    try appendNativeNormalizedOutput(std.heap.page_allocator, &out, root.get("output"), output_text_split.reasoning, req_body);
    try out.appendSlice(",\"output_text\":");
    try appendJsonString(out.writer(), output_text_split.visible);
    try out.append('}');
    return try out.toOwnedSlice();
}

fn denoResponsesJsonNormalize(body: []const u8) ![]u8 {
    return denoResponsesJsonNormalizeWithRequest(body, "");
}

fn jsonObjectGetValue(value: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(key),
        else => null,
    };
}

fn jsonArrayFirst(value: std.json.Value) ?std.json.Value {
    return switch (value) {
        .array => |array| if (array.items.len > 0) array.items[0] else null,
        else => null,
    };
}

fn jsonStringValue(value: ?std.json.Value) []const u8 {
    const actual = value orelse return "";
    return switch (actual) {
        .string => |text| text,
        else => "",
    };
}

fn jsonBoolValue(value: ?std.json.Value, default_value: bool) bool {
    const actual = value orelse return default_value;
    return switch (actual) {
        .bool => |inner| inner,
        else => default_value,
    };
}

fn appendJsonFieldName(out: *std.ArrayList(u8), field_count: *usize, name: []const u8) !void {
    if (field_count.* != 0) try out.append(',');
    try appendJsonString(out.writer(), name);
    try out.append(':');
    field_count.* += 1;
}

fn appendSystemText(system_texts: *std.ArrayList(u8), text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return;
    if (system_texts.items.len != 0) try system_texts.appendSlice("\n\n");
    try system_texts.appendSlice(trimmed);
}

fn responseContentTextOnlyAlloc(allocator: std.mem.Allocator, content: std.json.Value) !?[]u8 {
    switch (content) {
        .string => |text| return try allocator.dupe(u8, text),
        .array => |array| {
            var has_non_text = false;
            for (array.items) |part| {
                const part_type = jsonStringValue(jsonObjectGetValue(part, "type"));
                if (!std.mem.eql(u8, part_type, "input_text") and
                    !std.mem.eql(u8, part_type, "text") and
                    !std.mem.eql(u8, part_type, "output_text"))
                {
                    has_non_text = true;
                    break;
                }
            }
            if (has_non_text) return null;
            var out = std.ArrayList(u8).init(allocator);
            errdefer out.deinit();
            for (array.items) |part| {
                try out.appendSlice(jsonStringValue(jsonObjectGetValue(part, "text")));
            }
            return try out.toOwnedSlice();
        },
        else => return null,
    }
}

fn appendMappedResponseContentPart(out: *std.ArrayList(u8), part: std.json.Value) !void {
    const writer = out.writer();
    const part_type = jsonStringValue(jsonObjectGetValue(part, "type"));
    if (std.mem.eql(u8, part_type, "input_text") or
        std.mem.eql(u8, part_type, "text") or
        std.mem.eql(u8, part_type, "output_text"))
    {
        try out.appendSlice("{\"type\":\"text\",\"text\":");
        try appendJsonString(writer, jsonStringValue(jsonObjectGetValue(part, "text")));
        try out.append('}');
        return;
    }
    if (std.mem.eql(u8, part_type, "input_image")) {
        try out.appendSlice("{\"type\":\"image_url\",\"image_url\":{\"url\":");
        try appendJsonString(writer, jsonStringValue(jsonObjectGetValue(part, "image_url")));
        try out.appendSlice("}}");
        return;
    }
    if (std.mem.eql(u8, part_type, "image_url")) {
        try out.appendSlice("{\"type\":\"image_url\",\"image_url\":");
        const image_url = jsonObjectGetValue(part, "image_url") orelse .null;
        switch (image_url) {
            .object => try std.json.stringify(image_url, .{}, writer),
            .string => |url| {
                try out.appendSlice("{\"url\":");
                try appendJsonString(writer, url);
                try out.append('}');
            },
            else => try out.appendSlice("{\"url\":\"\"}"),
        }
        try out.append('}');
        return;
    }
    try std.json.stringify(part, .{}, writer);
}

fn appendResponseContentAsChat(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    content: std.json.Value,
) !bool {
    if (try responseContentTextOnlyAlloc(allocator, content)) |text| {
        try appendJsonString(out.writer(), text);
        return text.len != 0;
    }

    const array = switch (content) {
        .array => |items| items,
        else => return false,
    };
    if (array.items.len == 0) return false;
    try out.append('[');
    var count: usize = 0;
    for (array.items) |part| {
        switch (part) {
            .object => {},
            else => continue,
        }
        if (count != 0) try out.append(',');
        try appendMappedResponseContentPart(out, part);
        count += 1;
    }
    try out.append(']');
    return count != 0;
}

fn isResponsesToolCallType(item_type: []const u8) bool {
    return std.mem.eql(u8, item_type, "function_call") or
        std.mem.eql(u8, item_type, "custom_tool_call") or
        std.mem.eql(u8, item_type, "tool_search_call") or
        std.mem.eql(u8, item_type, "mcp_tool_call");
}

fn isResponsesToolOutputType(item_type: []const u8) bool {
    return std.mem.eql(u8, item_type, "function_call_output") or
        std.mem.eql(u8, item_type, "custom_tool_call_output") or
        std.mem.eql(u8, item_type, "tool_search_output") or
        std.mem.eql(u8, item_type, "mcp_tool_call_output");
}

fn responseToolCallNameForChat(allocator: std.mem.Allocator, item: std.json.Value) ![]const u8 {
    const raw_name = std.mem.trim(u8, jsonStringValue(jsonObjectGetValue(item, "name")), " \t\r\n");
    const item_type = jsonStringValue(jsonObjectGetValue(item, "type"));
    if (std.mem.eql(u8, item_type, "mcp_tool_call")) {
        const server = jsonStringValue(jsonObjectGetValue(item, "server"));
        if (server.len != 0 and !std.mem.startsWith(u8, raw_name, server)) {
            var out = std.ArrayList(u8).init(allocator);
            errdefer out.deinit();
            try out.appendSlice(server);
            try out.appendSlice(raw_name);
            return try out.toOwnedSlice();
        }
    }
    return raw_name;
}

fn responseToolCallArgumentsForChat(allocator: std.mem.Allocator, item_type: []const u8, arguments: []const u8) ![]const u8 {
    if (arguments.len == 0) return "{}";
    if (std.mem.eql(u8, item_type, "function_call")) {
        if (try normalizeResponsesRequestArgumentsString(allocator, arguments)) |normalized| return normalized;
    }
    return arguments;
}

fn collectResponseToolCallNames(
    allocator: std.mem.Allocator,
    input_items: []const std.json.Value,
) !std.StringHashMap([]const u8) {
    var call_names = std.StringHashMap([]const u8).init(allocator);
    errdefer call_names.deinit();
    for (input_items) |item| {
        const item_type = jsonStringValue(jsonObjectGetValue(item, "type"));
        if (!isResponsesToolCallType(item_type)) continue;
        const call_id = jsonStringValue(jsonObjectGetValue(item, "call_id"));
        if (call_id.len == 0) continue;
        const name = try responseToolCallNameForChat(allocator, item);
        if (name.len == 0) continue;
        try call_names.put(call_id, name);
    }
    return call_names;
}

fn appendChatMessagePrefix(out: *std.ArrayList(u8), message_count: *usize, role: []const u8) !void {
    if (message_count.* != 0) try out.append(',');
    try out.appendSlice("{\"role\":");
    try appendJsonString(out.writer(), role);
    try out.appendSlice(",\"content\":");
    message_count.* += 1;
}

fn appendResponseMessageAsChat(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(u8),
    message_count: *usize,
    system_texts: *std.ArrayList(u8),
    item: std.json.Value,
) !void {
    const item_type = jsonStringValue(jsonObjectGetValue(item, "type"));
    if (!std.mem.eql(u8, item_type, "message") and !std.mem.eql(u8, item_type, "assistant_message")) return;
    const raw_role = blk: {
        const role = jsonStringValue(jsonObjectGetValue(item, "role"));
        if (role.len != 0) break :blk role;
        break :blk if (std.mem.eql(u8, item_type, "message")) "user" else "assistant";
    };
    const role = if (std.mem.eql(u8, raw_role, "developer")) "system" else raw_role;
    const content = jsonObjectGetValue(item, "content") orelse .null;
    if (std.mem.eql(u8, role, "system")) {
        if (try responseContentTextOnlyAlloc(allocator, content)) |text| try appendSystemText(system_texts, text);
        return;
    }

    var content_buf = std.ArrayList(u8).init(allocator);
    errdefer content_buf.deinit();
    if (!try appendResponseContentAsChat(allocator, &content_buf, content)) {
        content_buf.deinit();
        return;
    }
    try appendChatMessagePrefix(messages, message_count, role);
    try messages.appendSlice(content_buf.items);
    try messages.append('}');
}

fn appendResponseToolCallAsChat(
    allocator: std.mem.Allocator,
    input_items: []const std.json.Value,
    index: *usize,
    messages: *std.ArrayList(u8),
    message_count: *usize,
) !void {
    const start_len = messages.items.len;
    if (message_count.* != 0) try messages.append(',');
    try messages.appendSlice("{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[");
    var call_count: usize = 0;
    while (index.* < input_items.len) : (index.* += 1) {
        const item = input_items[index.*];
        const item_type = jsonStringValue(jsonObjectGetValue(item, "type"));
        if (!isResponsesToolCallType(item_type)) break;
        const call_id = jsonStringValue(jsonObjectGetValue(item, "call_id"));
        const arguments = jsonStringValue(jsonObjectGetValue(item, "arguments"));
        const chat_arguments = try responseToolCallArgumentsForChat(allocator, item_type, arguments);
        const chat_name = try responseToolCallNameForChat(allocator, item);
        if (chat_name.len == 0) continue;
        if (call_count != 0) try messages.append(',');
        try messages.appendSlice("{\"id\":");
        if (call_id.len != 0) {
            try appendJsonString(messages.writer(), call_id);
        } else {
            try messages.writer().print("\"call_{}\"", .{index.*});
        }
        try messages.appendSlice(",\"type\":\"function\",\"function\":{\"name\":");
        try appendJsonString(messages.writer(), chat_name);
        try messages.appendSlice(",\"arguments\":");
        try appendJsonString(messages.writer(), chat_arguments);
        try messages.appendSlice("}}");
        call_count += 1;
    }
    try messages.appendSlice("]}");
    if (call_count == 0) {
        messages.shrinkRetainingCapacity(start_len);
        if (index.* != 0) index.* -= 1;
        return;
    }
    message_count.* += 1;
    if (index.* != 0) index.* -= 1;
}

fn appendResponseToolOutputAsChat(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(u8),
    message_count: *usize,
    call_names: *const std.StringHashMap([]const u8),
    item: std.json.Value,
) !void {
    const item_type = jsonStringValue(jsonObjectGetValue(item, "type"));
    if (!isResponsesToolOutputType(item_type)) return;
    var output_text = jsonStringValue(jsonObjectGetValue(item, "output"));
    if (output_text.len == 0) {
        if (jsonObjectGetValue(item, "output")) |output| {
            const owned_output = try std.json.stringifyAlloc(allocator, output, .{});
            output_text = owned_output;
        } else {
            output_text = jsonStringValue(jsonObjectGetValue(item, "content"));
        }
    }
    if (output_text.len == 0) return;
    try appendChatMessagePrefix(messages, message_count, "tool");
    try appendJsonString(messages.writer(), output_text);
    const call_id = jsonStringValue(jsonObjectGetValue(item, "call_id"));
    if (call_id.len != 0) {
        try messages.appendSlice(",\"tool_call_id\":");
        try appendJsonString(messages.writer(), call_id);
    }
    const explicit_name = std.mem.trim(u8, jsonStringValue(jsonObjectGetValue(item, "name")), " \t\r\n");
    const name = if (explicit_name.len != 0) explicit_name else blk: {
        if (call_id.len == 0) break :blk "";
        break :blk call_names.get(call_id) orelse "";
    };
    if (name.len != 0) {
        try messages.appendSlice(",\"name\":");
        try appendJsonString(messages.writer(), name);
    }
    try messages.append('}');
}

fn appendNormalizedChatTool(
    out: *std.ArrayList(u8),
    tool: std.json.Value,
    namespace_prefix: []const u8,
    tool_count: *usize,
) !void {
    const tool_type = jsonStringValue(jsonObjectGetValue(tool, "type"));
    if (std.mem.eql(u8, tool_type, "namespace")) {
        const nested_prefix = jsonStringValue(jsonObjectGetValue(tool, "name"));
        const nested_tools = jsonObjectGetValue(tool, "tools") orelse .null;
        switch (nested_tools) {
            .array => |array| {
                for (array.items) |nested| try appendNormalizedChatTool(out, nested, nested_prefix, tool_count);
            },
            else => {},
        }
        return;
    }
    if (tool_type.len != 0 and !std.mem.eql(u8, tool_type, "function")) return;

    const fn_value = jsonObjectGetValue(tool, "function") orelse .null;
    const source = switch (fn_value) {
        .object => fn_value,
        else => tool,
    };
    const raw_name = blk: {
        const fn_name = jsonStringValue(jsonObjectGetValue(source, "name"));
        if (fn_name.len != 0) break :blk fn_name;
        break :blk jsonStringValue(jsonObjectGetValue(tool, "name"));
    };
    if (raw_name.len == 0) return;
    if (tool_count.* != 0) try out.append(',');
    try out.appendSlice("{\"type\":\"function\",\"function\":{\"name\":");
    if (namespace_prefix.len != 0 and !std.mem.startsWith(u8, raw_name, namespace_prefix)) {
        var prefixed = std.ArrayList(u8).init(std.heap.page_allocator);
        defer prefixed.deinit();
        try prefixed.appendSlice(namespace_prefix);
        try prefixed.appendSlice(raw_name);
        try appendJsonString(out.writer(), prefixed.items);
    } else {
        try appendJsonString(out.writer(), raw_name);
    }

    const description = blk: {
        const fn_desc = jsonStringValue(jsonObjectGetValue(source, "description"));
        if (fn_desc.len != 0) break :blk fn_desc;
        break :blk jsonStringValue(jsonObjectGetValue(tool, "description"));
    };
    if (description.len != 0) {
        try out.appendSlice(",\"description\":");
        try appendJsonString(out.writer(), description);
    }
    if (jsonObjectGetValue(source, "parameters")) |parameters| {
        try out.appendSlice(",\"parameters\":");
        try std.json.stringify(parameters, .{}, out.writer());
    } else if (jsonObjectGetValue(tool, "parameters")) |parameters| {
        try out.appendSlice(",\"parameters\":");
        try std.json.stringify(parameters, .{}, out.writer());
    }
    const has_strict = jsonObjectGetValue(source, "strict") != null or jsonObjectGetValue(tool, "strict") != null;
    if (has_strict) {
        try out.appendSlice(",\"strict\":");
        try out.appendSlice(if (jsonBoolValue(jsonObjectGetValue(source, "strict"), jsonBoolValue(jsonObjectGetValue(tool, "strict"), false))) "true" else "false");
    }
    try out.appendSlice("}}");
    tool_count.* += 1;
}

fn appendNormalizedChatToolsField(out: *std.ArrayList(u8), field_count: *usize, tools: std.json.Value) !void {
    const array = switch (tools) {
        .array => |items| items,
        else => return,
    };
    var tools_json = std.ArrayList(u8).init(std.heap.page_allocator);
    defer tools_json.deinit();
    var tool_count: usize = 0;
    for (array.items) |tool| try appendNormalizedChatTool(&tools_json, tool, "", &tool_count);
    if (tool_count == 0) return;
    try appendJsonFieldName(out, field_count, "tools");
    try out.append('[');
    try out.appendSlice(tools_json.items);
    try out.append(']');
}

fn appendResponseFormatFromText(out: *std.ArrayList(u8), field_count: *usize, text_value: ?std.json.Value) !void {
    const text = text_value orelse return;
    const format = jsonObjectGetValue(text, "format") orelse return;
    const format_type = jsonStringValue(jsonObjectGetValue(format, "type"));
    if (format_type.len == 0) return;
    try appendJsonFieldName(out, field_count, "response_format");
    if (std.mem.eql(u8, format_type, "json_schema")) {
        try out.appendSlice("{\"type\":\"json_schema\",\"json_schema\":{\"name\":");
        const name = jsonStringValue(jsonObjectGetValue(format, "name"));
        try appendJsonString(out.writer(), if (name.len != 0) name else "codex_output_schema");
        if (jsonObjectGetValue(format, "schema")) |schema| {
            try out.appendSlice(",\"schema\":");
            try std.json.stringify(schema, .{}, out.writer());
        }
        try out.appendSlice(",\"strict\":");
        try out.appendSlice(if (jsonBoolValue(jsonObjectGetValue(format, "strict"), false)) "true" else "false");
        try out.appendSlice("}}");
        return;
    }
    try std.json.stringify(format, .{}, out.writer());
}

fn shouldSkipResponsesFallbackField(key: []const u8) bool {
    return std.mem.eql(u8, key, "input") or
        std.mem.eql(u8, key, "instructions") or
        std.mem.eql(u8, key, "reasoning") or
        std.mem.eql(u8, key, "stream") or
        std.mem.eql(u8, key, "tools") or
        std.mem.eql(u8, key, "content") or
        std.mem.eql(u8, key, "text") or
        std.mem.eql(u8, key, "store") or
        std.mem.eql(u8, key, "prompt_cache_key") or
        std.mem.eql(u8, key, "include") or
        std.mem.eql(u8, key, "model") or
        std.mem.eql(u8, key, "messages") or
        std.mem.eql(u8, key, "response_format");
}

fn denoResponsesChatFallbackRequest(body: []const u8, default_model: []const u8, plan_mode_like: bool) !?[]u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch return null;
    const root = switch (parsed) {
        .object => |object| object,
        else => return null,
    };
    const model = blk: {
        const body_model = jsonStringValue(root.get("model"));
        break :blk if (body_model.len != 0) body_model else default_model;
    };

    var system_texts = std.ArrayList(u8).init(allocator);
    var messages = std.ArrayList(u8).init(allocator);
    var message_count: usize = 0;
    if (plan_mode_like) {
        try appendSystemText(&system_texts, "Compatibility note: you are using Chat Completions as a Responses API fallback. Do not stop after only a progress update or plan. If you say you will inspect or run something, call an available tool in the same response; otherwise provide the final answer.");
    }
    try appendSystemText(&system_texts, jsonStringValue(root.get("instructions")));

    const input = root.get("input") orelse .null;
    switch (input) {
        .array => |input_array| {
            var call_names = try collectResponseToolCallNames(allocator, input_array.items);
            defer call_names.deinit();
            var index: usize = 0;
            while (index < input_array.items.len) : (index += 1) {
                const item = input_array.items[index];
                const item_type = jsonStringValue(jsonObjectGetValue(item, "type"));
                if (isResponsesToolCallType(item_type)) {
                    try appendResponseToolCallAsChat(allocator, input_array.items, &index, &messages, &message_count);
                    continue;
                }
                if (std.mem.eql(u8, item_type, "message") or std.mem.eql(u8, item_type, "assistant_message")) {
                    try appendResponseMessageAsChat(allocator, &messages, &message_count, &system_texts, item);
                    continue;
                }
                if (std.mem.eql(u8, item_type, "reasoning")) continue;
                if (isResponsesToolOutputType(item_type)) {
                    try appendResponseToolOutputAsChat(allocator, &messages, &message_count, &call_names, item);
                }
            }
        },
        else => {},
    }
    if (message_count == 0) {
        const top_text = blk: {
            const input_text = jsonStringValue(root.get("input"));
            if (input_text.len != 0) break :blk input_text;
            const content_text = jsonStringValue(root.get("content"));
            if (content_text.len != 0) break :blk content_text;
            break :blk jsonStringValue(root.get("text"));
        };
        if (top_text.len != 0) {
            try appendChatMessagePrefix(&messages, &message_count, "user");
            try appendJsonString(messages.writer(), top_text);
            try messages.append('}');
        }
    }
    if (system_texts.items.len != 0) {
        var with_system = std.ArrayList(u8).init(allocator);
        var system_count: usize = 0;
        try appendChatMessagePrefix(&with_system, &system_count, "system");
        try appendJsonString(with_system.writer(), system_texts.items);
        try with_system.append('}');
        if (messages.items.len != 0) try with_system.append(',');
        try with_system.appendSlice(messages.items);
        messages = with_system;
        message_count += 1;
    }
    var out = std.ArrayList(u8).init(std.heap.page_allocator);
    errdefer out.deinit();
    try out.append('{');
    var field_count: usize = 0;
    var it = root.iterator();
    while (it.next()) |entry| {
        if (shouldSkipResponsesFallbackField(entry.key_ptr.*)) continue;
        try appendJsonFieldName(&out, &field_count, entry.key_ptr.*);
        try std.json.stringify(entry.value_ptr.*, .{}, out.writer());
    }
    try appendResponseFormatFromText(&out, &field_count, root.get("text"));
    try appendJsonFieldName(&out, &field_count, "model");
    try appendJsonString(out.writer(), model);
    try appendJsonFieldName(&out, &field_count, "messages");
    try out.append('[');
    try out.appendSlice(messages.items);
    try out.append(']');
    if (root.get("tools")) |tools| try appendNormalizedChatToolsField(&out, &field_count, tools);
    const stream = jsonBoolValue(root.get("stream"), true);
    try appendJsonFieldName(&out, &field_count, "stream");
    try out.appendSlice(if (stream) "true" else "false");
    if (stream) {
        try appendJsonFieldName(&out, &field_count, "stream_options");
        try out.appendSlice("{\"include_usage\":true}");
    }
    try out.append('}');
    return try out.toOwnedSlice();
}

fn normalizeResponsesArgumentsString(allocator: std.mem.Allocator, arguments: []const u8) !?[]u8 {
    var args_value = std.json.parseFromSliceLeaky(std.json.Value, allocator, arguments, .{}) catch return null;
    const args_object = switch (args_value) {
        .object => |*object| object,
        else => return null,
    };
    const server_ptr = args_object.getPtr("server") orelse return null;
    const server = jsonStringValue(server_ptr.*);
    if (server.len == 0) return null;
    const denormalized = try denormalizeMcpServerNameAlloc(allocator, server);
    server_ptr.* = .{ .string = denormalized };
    return try std.json.stringifyAlloc(allocator, args_value, .{});
}

fn normalizeResponsesRequestArgumentsString(allocator: std.mem.Allocator, arguments: []const u8) !?[]u8 {
    var args_value = std.json.parseFromSliceLeaky(std.json.Value, allocator, arguments, .{}) catch return null;
    const args_object = switch (args_value) {
        .object => |*object| object,
        else => return null,
    };
    const server_ptr = args_object.getPtr("server") orelse return null;
    const server = jsonStringValue(server_ptr.*);
    if (server.len == 0) return null;
    const normalized = try normalizeMcpServerNameAlloc(allocator, server);
    if (std.mem.eql(u8, normalized, server)) return null;
    server_ptr.* = .{ .string = normalized };
    return try std.json.stringifyAlloc(allocator, args_value, .{});
}

fn normalizeResponsesRequestValue(
    allocator: std.mem.Allocator,
    value: *std.json.Value,
    call_names: ?*const std.StringHashMap([]const u8),
) !bool {
    switch (value.*) {
        .object => |*object| {
            var changed = false;
            const item_type = jsonStringValue(object.get("type"));
            if (std.mem.eql(u8, item_type, "mcp_tool_call")) {
                const server = jsonStringValue(object.get("server"));
                if (server.len != 0) {
                    const raw_name = std.mem.trim(u8, jsonStringValue(object.get("name")), " \t\r\n");
                    if (!std.mem.startsWith(u8, raw_name, server)) {
                        const full_name = try std.mem.concat(allocator, u8, &.{ server, raw_name });
                        try object.put("name", .{ .string = full_name });
                    }
                    try object.put("type", .{ .string = "function_call" });
                    changed = true;
                }
            }
            if (std.mem.eql(u8, item_type, "reasoning")) {
                if (object.getPtr("content")) |_| {
                    _ = object.swapRemove("content");
                    changed = true;
                }
            }
            if (std.mem.eql(u8, item_type, "function_call")) {
                const namespace = jsonStringValue(object.get("namespace"));
                if (namespace.len != 0) {
                    if (object.getPtr("name")) |name_ptr| {
                        const name = jsonStringValue(name_ptr.*);
                        if (name.len != 0 and !std.mem.startsWith(u8, name, namespace)) {
                            const full_name = try std.mem.concat(allocator, u8, &.{ namespace, name });
                            name_ptr.* = .{ .string = full_name };
                            _ = object.swapRemove("namespace");
                            _ = object.swapRemove("output_kind");
                            changed = true;
                        }
                    }
                }
                if (object.getPtr("arguments")) |arguments_ptr| {
                    const arguments = jsonStringValue(arguments_ptr.*);
                    if (arguments.len != 0) {
                        if (try normalizeResponsesRequestArgumentsString(allocator, arguments)) |normalized_arguments| {
                            arguments_ptr.* = .{ .string = normalized_arguments };
                            changed = true;
                        }
                    }
                }
            }
            if (isResponsesToolOutputType(item_type)) {
                const call_id = jsonStringValue(object.get("call_id"));
                const explicit_name = std.mem.trim(u8, jsonStringValue(object.get("name")), " \t\r\n");
                const name = if (explicit_name.len != 0) explicit_name else blk: {
                    if (call_id.len == 0) break :blk "";
                    const map = call_names orelse break :blk "";
                    break :blk map.get(call_id) orelse "";
                };
                if (name.len != 0) {
                    try object.put("name", .{ .string = name });
                    changed = true;
                }
            }
            return changed;
        },
        .array => |*array| {
            var changed = false;
            for (array.items) |*item| {
                if (try normalizeResponsesRequestValue(allocator, item, call_names)) changed = true;
            }
            return changed;
        },
        else => return false,
    }
}

fn denoResponsesRequestNormalize(body: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{}) catch {
        return std.heap.page_allocator.dupe(u8, body);
    };
    const allocator = arena.allocator();
    var call_names = std.StringHashMap([]const u8).init(allocator);
    defer call_names.deinit();
    var changed = false;
    switch (value) {
        .object => |object| {
            const input = object.get("input") orelse .null;
            switch (input) {
                .array => |input_array| {
                    call_names = try collectResponseToolCallNames(allocator, input_array.items);
                    const input_ptr = object.getPtr("input").?;
                    if (try normalizeResponsesRequestValue(allocator, input_ptr, &call_names)) changed = true;
                },
                else => {},
            }
        },
        else => {},
    }
    if (!changed) return std.heap.page_allocator.dupe(u8, body);
    return try std.json.stringifyAlloc(std.heap.page_allocator, value, .{});
}

fn normalizeResponsesEventData(allocator: std.mem.Allocator, data: []const u8, req_body: []const u8) !?[]u8 {
    var value = std.json.parseFromSliceLeaky(std.json.Value, allocator, data, .{}) catch return null;
    const root = switch (value) {
        .object => |*object| object,
        else => return null,
    };
    const item_ptr = root.getPtr("item") orelse return null;
    const item = switch (item_ptr.*) {
        .object => |*object| object,
        else => return null,
    };

    var changed = false;
    const item_type = jsonStringValue(item.get("type"));
    if (isNativeReasoningType(item_type)) {
        var text = std.ArrayList(u8).init(allocator);
        defer text.deinit();
        try appendReasoningFields(item_ptr.*, &text);
        if (text.items.len != 0) {
            var out = std.ArrayList(u8).init(allocator);
            errdefer out.deinit();
            const writer = out.writer();
            try out.appendSlice("{\"type\":");
            try appendJsonString(writer, jsonStringValue(root.get("type")));
            try out.appendSlice(",\"item\":");
            try appendNativeReasoningItem(&out, jsonStringValue(item.get("id")), text.items);
            try out.append('}');
            return try out.toOwnedSlice();
        }
    }

    const output_kind = outputKindForResponsesToolCallType(item_type) orelse return null;

    if (item.getPtr("arguments")) |arguments_ptr| {
        const arguments = jsonStringValue(arguments_ptr.*);
        if (arguments.len != 0) {
            if (try normalizeResponsesArgumentsString(allocator, arguments)) |normalized_arguments| {
                arguments_ptr.* = .{ .string = normalized_arguments };
                changed = true;
            }
        }
    }

    if (nativeFunctionCallNeedsNamespaceNormalize(item_ptr.*, req_body)) {
        const name = jsonStringValue(item.get("name"));
        const split = splitMcpNamespace(name).?;
        item.put("name", .{ .string = split.tool }) catch return null;
        item.put("namespace", .{ .string = split.namespace }) catch return null;
        item.put("output_kind", .{ .string = "function_call_output" }) catch return null;
        changed = true;
    } else {
        const existing_output_kind = jsonStringValue(item.get("output_kind"));
        if (!std.mem.eql(u8, existing_output_kind, output_kind)) {
            item.put("output_kind", .{ .string = output_kind }) catch return null;
            changed = true;
        }
    }

    if (!changed) return null;
    return try std.json.stringifyAlloc(allocator, value, .{});
}

fn appendNormalizedResponsesSseBlock(out: *std.ArrayList(u8), event_line: ?[]const u8, data: []const u8, req_body: []const u8) !void {
    if (event_line) |line| {
        try out.appendSlice(line);
        try out.append('\n');
    }
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const normalized = try normalizeResponsesEventData(arena.allocator(), data, req_body) orelse data;
    try out.appendSlice("data: ");
    try out.appendSlice(normalized);
    try out.appendSlice("\n\n");
}

fn denoResponsesSseNormalizeWithRequest(sse_body: []const u8, req_body: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(std.heap.page_allocator);
    errdefer out.deinit();
    var data_buffer = std.ArrayList(u8).init(std.heap.page_allocator);
    defer data_buffer.deinit();
    var event_line: ?[]const u8 = null;

    var line_it = std.mem.splitScalar(u8, sse_body, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "event:")) {
            if (data_buffer.items.len != 0) {
                try appendNormalizedResponsesSseBlock(&out, event_line, data_buffer.items, req_body);
                data_buffer.clearRetainingCapacity();
            } else if (event_line) |pending_event| {
                try out.appendSlice(pending_event);
                try out.append('\n');
            }
            event_line = line;
            continue;
        }
        if (std.mem.startsWith(u8, line, "data:")) {
            const data = std.mem.trimLeft(u8, line[5..], " \t");
            try data_buffer.appendSlice(data);
            continue;
        }
        if (std.mem.trim(u8, line, " \t\r").len == 0) {
            if (data_buffer.items.len != 0) {
                try appendNormalizedResponsesSseBlock(&out, event_line, data_buffer.items, req_body);
                data_buffer.clearRetainingCapacity();
                event_line = null;
            } else if (event_line) |pending_event| {
                try out.appendSlice(pending_event);
                try out.appendSlice("\n\n");
                event_line = null;
            } else {
                try out.append('\n');
            }
            continue;
        }
        if (event_line) |pending_event| {
            try out.appendSlice(pending_event);
            try out.append('\n');
            event_line = null;
        }
        try out.appendSlice(line);
        try out.append('\n');
    }
    if (data_buffer.items.len != 0) {
        try appendNormalizedResponsesSseBlock(&out, event_line, data_buffer.items, req_body);
    } else if (event_line) |pending_event| {
        try out.appendSlice(pending_event);
        try out.append('\n');
    }
    return try out.toOwnedSlice();
}

fn denoResponsesSseNormalize(sse_body: []const u8) ![]u8 {
    return denoResponsesSseNormalizeWithRequest(sse_body, "");
}

fn appendChatSseDataChunk(
    out: *std.ArrayList(u8),
    data: []const u8,
    splitter: *ThoughtStreamSplitter,
    reasoning_started: *bool,
    reasoning_done: *bool,
    reasoning_output_index: *u64,
    reasoning_text: *std.ArrayList(u8),
    message_started: *bool,
    message_output_index: *u64,
    next_output_index: *u64,
    message_text: *std.ArrayList(u8),
    tool_calls: *std.ArrayList(ChatToolCallState),
    saw_stop_without_tool: *bool,
    req_body: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{}) catch return;
    defer parsed.deinit();
    const first_choice = jsonArrayFirst(jsonObjectGetValue(parsed.value, "choices") orelse return) orelse return;
    const delta = jsonObjectGetValue(first_choice, "delta");
    if (delta) |delta_value| {
        const reason = jsonStringValue(jsonObjectGetValue(delta_value, "reasoning_content"));
        if (reason.len != 0) {
            if (!message_started.*) {
                try appendReasoningDelta(out, reasoning_started, reasoning_done, reasoning_output_index, next_output_index, reason);
            }
            try reasoning_text.appendSlice(reason);
        }
        const thinking = jsonStringValue(jsonObjectGetValue(delta_value, "thinking"));
        if (thinking.len != 0) {
            if (!message_started.*) {
                try appendReasoningDelta(out, reasoning_started, reasoning_done, reasoning_output_index, next_output_index, thinking);
            }
            try reasoning_text.appendSlice(thinking);
        }
        const content = jsonStringValue(jsonObjectGetValue(delta_value, "content"));
        if (content.len != 0) {
            var visible = std.ArrayList(u8).init(std.heap.page_allocator);
            defer visible.deinit();
            var thought = std.ArrayList(u8).init(std.heap.page_allocator);
            defer thought.deinit();
            try splitter.consume(content, &visible, &thought);
            if (thought.items.len != 0) {
                if (!message_started.*) {
                    try appendReasoningDelta(out, reasoning_started, reasoning_done, reasoning_output_index, next_output_index, thought.items);
                }
                try reasoning_text.appendSlice(thought.items);
            }
            if (visible.items.len != 0) {
                if (!message_started.*) {
                    try appendReasoningDone(out, reasoning_started.*, reasoning_done, reasoning_output_index.*, reasoning_text.items);
                }
                try appendMessageDelta(out, message_started, message_output_index, next_output_index, message_text, visible.items);
            }
        }
        if (jsonObjectGetValue(delta_value, "tool_calls")) |tool_calls_value| {
            switch (tool_calls_value) {
                .array => |array| {
                    for (array.items) |entry| {
                        const index = if (jsonObjectGetValue(entry, "index")) |idx_value| parseToolCallIndex(idx_value) else 0;
                        const state = try findToolCallState(tool_calls, index);
                        const call_id = jsonStringValue(jsonObjectGetValue(entry, "id"));
                        if (call_id.len != 0) {
                            state.call_id.clearRetainingCapacity();
                            try state.call_id.appendSlice(call_id);
                        }
                        if (jsonObjectGetValue(entry, "function")) |fn_value| {
                            const name = jsonStringValue(jsonObjectGetValue(fn_value, "name"));
                            if (name.len != 0) {
                                state.name.clearRetainingCapacity();
                                try state.name.appendSlice(name);
                            }
                            const args_part = jsonStringValue(jsonObjectGetValue(fn_value, "arguments"));
                            if (args_part.len != 0) try state.arguments.appendSlice(args_part);
                        }
                    }
                },
                else => {},
            }
        }
    }
    const finish_reason = jsonStringValue(jsonObjectGetValue(first_choice, "finish_reason"));
    if (std.mem.eql(u8, finish_reason, "stop")) saw_stop_without_tool.* = tool_calls.items.len == 0;
    if (std.mem.eql(u8, finish_reason, "tool_calls") or std.mem.eql(u8, finish_reason, "stop")) {
        std.mem.sort(ChatToolCallState, tool_calls.items, {}, struct {
            fn lessThan(_: void, lhs: ChatToolCallState, rhs: ChatToolCallState) bool {
                return lhs.index < rhs.index;
            }
        }.lessThan);
        for (tool_calls.items) |*call| try appendNormalizedToolCall(out, req_body, call);
        for (tool_calls.items) |*call| call.deinit();
        tool_calls.clearRetainingCapacity();
    }
}

fn denoChatSseToResponses(chat_body: []const u8, req_body: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(std.heap.page_allocator);
    errdefer out.deinit();
    var splitter = ThoughtStreamSplitter.init(std.heap.page_allocator);
    defer splitter.deinit();
    var reasoning_text = std.ArrayList(u8).init(std.heap.page_allocator);
    defer reasoning_text.deinit();
    var message_text = std.ArrayList(u8).init(std.heap.page_allocator);
    defer message_text.deinit();
    var reasoning_started = false;
    var reasoning_done = false;
    var reasoning_output_index: u64 = 0;
    var message_started = false;
    var message_output_index: u64 = 0;
    var next_output_index: u64 = 0;
    var saw_stop_without_tool = false;
    var tool_calls = std.ArrayList(ChatToolCallState).init(std.heap.page_allocator);
    defer {
        for (tool_calls.items) |*call| call.deinit();
        tool_calls.deinit();
    }
    var data_buffer = std.ArrayList(u8).init(std.heap.page_allocator);
    defer data_buffer.deinit();

    try appendResponseCreated(&out);

    var line_it = std.mem.splitScalar(u8, chat_body, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "data:")) {
            const data = std.mem.trimLeft(u8, line[5..], " \t");
            if (!std.mem.eql(u8, data, "[DONE]")) {
                try data_buffer.appendSlice(data);
            }
            continue;
        }
        if (std.mem.trim(u8, line, " \t\r").len != 0 or data_buffer.items.len == 0) continue;
        try appendChatSseDataChunk(
            &out,
            data_buffer.items,
            &splitter,
            &reasoning_started,
            &reasoning_done,
            &reasoning_output_index,
            &reasoning_text,
            &message_started,
            &message_output_index,
            &next_output_index,
            &message_text,
            &tool_calls,
            &saw_stop_without_tool,
            req_body,
        );
        data_buffer.clearRetainingCapacity();
    }
    if (data_buffer.items.len != 0) {
        try appendChatSseDataChunk(
            &out,
            data_buffer.items,
            &splitter,
            &reasoning_started,
            &reasoning_done,
            &reasoning_output_index,
            &reasoning_text,
            &message_started,
            &message_output_index,
            &next_output_index,
            &message_text,
            &tool_calls,
            &saw_stop_without_tool,
            req_body,
        );
    }

    var tail_visible = std.ArrayList(u8).init(std.heap.page_allocator);
    defer tail_visible.deinit();
    var tail_reasoning = std.ArrayList(u8).init(std.heap.page_allocator);
    defer tail_reasoning.deinit();
    try splitter.flush(&tail_visible, &tail_reasoning);
    if (tail_reasoning.items.len != 0) {
        try appendReasoningDelta(&out, &reasoning_started, &reasoning_done, &reasoning_output_index, &next_output_index, tail_reasoning.items);
        try reasoning_text.appendSlice(tail_reasoning.items);
    }
    if (tail_visible.items.len != 0) {
        try appendReasoningDone(&out, reasoning_started, &reasoning_done, reasoning_output_index, reasoning_text.items);
        try appendMessageDelta(&out, &message_started, &message_output_index, &next_output_index, &message_text, tail_visible.items);
    }
    try appendReasoningDone(&out, reasoning_started, &reasoning_done, reasoning_output_index, reasoning_text.items);
    try appendMessageDone(&out, message_started, message_output_index, message_text.items);
    if (saw_stop_without_tool and requestAllowsContinuation(req_body) and isProgressOnlyText(message_text.items)) {
        try appendContinuationTool(&out);
    }
    try appendResponseDone(&out);
    return try out.toOwnedSlice();
}

pub fn chatSseToResponses(chat_body: []const u8, req_body: []const u8) ![]u8 {
    return denoChatSseToResponses(chat_body, req_body);
}

pub fn chatJsonToResponses(chat_body: []const u8, req_body: []const u8) ![]u8 {
    return denoChatJsonToResponses(chat_body, req_body);
}

pub fn responsesSseNormalize(sse_body: []const u8) ![]u8 {
    return denoResponsesSseNormalize(sse_body);
}

pub fn responsesSseNormalizeWithRequest(sse_body: []const u8, req_body: []const u8) ![]u8 {
    return denoResponsesSseNormalizeWithRequest(sse_body, req_body);
}

pub fn responsesJsonNormalize(body: []const u8) ![]u8 {
    return denoResponsesJsonNormalize(body);
}

pub fn responsesJsonNormalizeWithRequest(body: []const u8, req_body: []const u8) ![]u8 {
    return denoResponsesJsonNormalizeWithRequest(body, req_body);
}

pub fn responsesRequestNormalize(body: []const u8) ![]u8 {
    return denoResponsesRequestNormalize(body);
}

pub fn responsesChatFallbackRequest(body: []const u8, default_model: []const u8, plan_mode_like: bool) !?[]u8 {
    return denoResponsesChatFallbackRequest(body, default_model, plan_mode_like);
}

pub fn jsonrpcParamsStringLiteral(body: []const u8, key: []const u8, fallback: []const u8, emit_null_if_missing: bool) ![]u8 {
    return jsonRpcParamsStringLiteralAlloc(body, key, fallback, emit_null_if_missing);
}

fn appendMcpJsonLine(out: *std.ArrayList(u8), payload: []const u8) !void {
    try out.appendSlice(payload);
    try out.append('\n');
}

fn jsonNumberMatchesId(value: std.json.Value, expected: i64) bool {
    return switch (value) {
        .integer => |actual| actual == expected,
        .float => |actual| actual == @as(f64, @floatFromInt(expected)),
        .number_string => |text| blk: {
            const parsed = std.fmt.parseInt(i64, text, 10) catch break :blk false;
            break :blk parsed == expected;
        },
        else => false,
    };
}

fn nextMcpJsonMessage(output: []const u8, cursor: *usize) ?[]const u8 {
    while (cursor.* < output.len and std.ascii.isWhitespace(output[cursor.*])) cursor.* += 1;
    if (cursor.* >= output.len) return null;

    if (std.mem.startsWith(u8, output[cursor.*..], "Content-Length:")) {
        const header_end_rel = std.mem.indexOf(u8, output[cursor.*..], "\r\n\r\n") orelse
            std.mem.indexOf(u8, output[cursor.*..], "\n\n") orelse return null;
        const header_end = cursor.* + header_end_rel;
        const separator_len: usize = if (header_end + 3 < output.len and output[header_end] == '\r') 4 else 2;
        const header = output[cursor.*..header_end];
        const colon = std.mem.indexOfScalar(u8, header, ':') orelse return null;
        const len_text = std.mem.trim(u8, header[colon + 1 ..], " \t\r\n");
        const body_len = std.fmt.parseInt(usize, len_text, 10) catch return null;
        const body_start = header_end + separator_len;
        const body_end = body_start + body_len;
        if (body_end > output.len) return null;
        cursor.* = body_end;
        return output[body_start..body_end];
    }

    const line_end = std.mem.indexOfScalarPos(u8, output, cursor.*, '\n') orelse output.len;
    const line = std.mem.trim(u8, output[cursor.*..line_end], " \t\r\n");
    cursor.* = if (line_end < output.len) line_end + 1 else line_end;
    if (line.len == 0 or line[0] != '{') return nextMcpJsonMessage(output, cursor);
    return line;
}

fn mcpResultFieldJsonAlloc(allocator: std.mem.Allocator, output: []const u8, expected_id: i64, field_name: ?[]const u8) !?[]u8 {
    var cursor: usize = 0;
    while (nextMcpJsonMessage(output, &cursor)) |message| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, message, .{}) catch continue;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => continue,
        };
        if (!jsonNumberMatchesId(object.get("id") orelse .null, expected_id)) continue;
        const result = object.get("result") orelse return null;
        const selected = if (field_name) |name| jsonObjectGetValue(result, name) orelse .null else result;
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        try std.json.stringify(selected, .{}, out.writer());
        return try out.toOwnedSlice();
    }
    return null;
}

fn mcpOutputHasResultId(allocator: std.mem.Allocator, output: []const u8, expected_id: i64) !bool {
    var cursor: usize = 0;
    while (nextMcpJsonMessage(output, &cursor)) |message| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, message, .{}) catch continue;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => continue,
        };
        if (!jsonNumberMatchesId(object.get("id") orelse .null, expected_id)) continue;
        if (object.get("result") != null or object.get("error") != null) return true;
    }
    return false;
}

fn mcpOutputHasAllResultIds(allocator: std.mem.Allocator, output: []const u8, expected_ids: []const i64) !bool {
    for (expected_ids) |expected_id| {
        if (!(try mcpOutputHasResultId(allocator, output, expected_id))) return false;
    }
    return true;
}

fn readMcpOutputUntilResults(allocator: std.mem.Allocator, stdout_file: std.fs.File, expected_ids: []const i64) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const deadline_ms = std.time.milliTimestamp() + 10_000;
    var buf: [8192]u8 = undefined;

    while (true) {
        if (try mcpOutputHasAllResultIds(allocator, out.items, expected_ids)) return try out.toOwnedSlice();
        if (std.time.milliTimestamp() >= deadline_ms) return error.McpReadTimeout;

        var fds = [_]std.posix.pollfd{.{
            .fd = stdout_file.handle,
            .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&fds, 250);
        if (ready == 0) continue;
        if ((fds[0].revents & std.posix.POLL.IN) != 0) {
            const n = try stdout_file.read(&buf);
            if (n == 0) break;
            try out.appendSlice(buf[0..n]);
            continue;
        }
        if ((fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
            break;
        }
    }

    return try out.toOwnedSlice();
}

fn closeMcpChild(child: *std.process.Child) void {
    if (child.stdin) |stdin_file| {
        stdin_file.close();
        child.stdin = null;
    }
    if (child.stdout) |stdout_file| {
        stdout_file.close();
        child.stdout = null;
    }
    _ = child.kill() catch {};
    _ = child.wait() catch {};
}

fn mcpToolsMapJsonAlloc(allocator: std.mem.Allocator, tools_result_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, tools_result_json, .{});
    defer parsed.deinit();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.append('{');

    var first = true;
    const tools = jsonObjectGetValue(parsed.value, "tools") orelse .null;
    switch (tools) {
        .array => |array| {
            for (array.items) |tool| {
                const name = jsonStringValue(jsonObjectGetValue(tool, "name"));
                if (name.len == 0) continue;
                if (!first) try out.append(',');
                first = false;
                try appendJsonString(out.writer(), name);
                try out.append(':');
                try std.json.stringify(tool, .{}, out.writer());
            }
        },
        else => {},
    }

    try out.append('}');
    return try out.toOwnedSlice();
}

const McpServerPieces = struct {
    server_info_json: ?[]u8,
    tools_map_json: []u8,
    resources_json: []u8,
    resource_templates_json: []u8,

    fn deinit(self: McpServerPieces, allocator: std.mem.Allocator) void {
        if (self.server_info_json) |server_info| allocator.free(server_info);
        allocator.free(self.tools_map_json);
        allocator.free(self.resources_json);
        allocator.free(self.resource_templates_json);
    }
};

fn mcpResultArrayFieldJsonAlloc(allocator: std.mem.Allocator, output: []const u8, expected_id: i64, camel_field: []const u8, snake_field: []const u8) ![]u8 {
    if (try mcpResultFieldJsonAlloc(allocator, output, expected_id, camel_field)) |json| return json;
    if (snake_field.len != 0) {
        if (try mcpResultFieldJsonAlloc(allocator, output, expected_id, snake_field)) |json| return json;
    }
    return try allocator.dupe(u8, "[]");
}

const McpStatusPage = struct {
    start: usize,
    limit: usize,
    include_inventory: bool = true,
    seen: usize = 0,
    emitted: usize = 0,
    has_more: bool = false,
    invalid: bool = false,
};

fn jsonCursorUsizeValue(value: std.json.Value) ?usize {
    return switch (value) {
        .string => |text| std.fmt.parseInt(usize, text, 10) catch null,
        else => null,
    };
}

fn jsonLimitUsizeValue(value: std.json.Value) ?usize {
    return switch (value) {
        .integer => |inner| if (inner >= 0) @as(usize, @intCast(inner)) else null,
        else => null,
    };
}

fn mcpStatusPageFromBody(body: []const u8) McpStatusPage {
    var page = McpStatusPage{ .start = 0, .limit = std.math.maxInt(usize) };
    if (body.len == 0) return page;
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch return page;
    defer parsed.deinit();
    const params = jsonObjectGetValue(parsed.value, "params") orelse return page;
    if (jsonObjectGetValue(params, "detail")) |detail_value| {
        const detail = jsonStringValue(detail_value);
        if (std.mem.eql(u8, detail, "full")) {
            page.include_inventory = true;
        } else if (std.mem.eql(u8, detail, "toolsAndAuthOnly")) {
            page.include_inventory = false;
        } else {
            page.invalid = true;
            return page;
        }
    }
    if (jsonObjectGetValue(params, "cursor")) |cursor_value| {
        page.start = jsonCursorUsizeValue(cursor_value) orelse {
            page.invalid = true;
            return page;
        };
    }
    if (jsonObjectGetValue(params, "limit")) |limit_value| {
        const raw_limit = jsonLimitUsizeValue(limit_value) orelse {
            page.invalid = true;
            return page;
        };
        page.limit = if (raw_limit == 0) 1 else raw_limit;
    }
    return page;
}

fn mcpStatusPageShouldEmit(page: *McpStatusPage) bool {
    const idx = page.seen;
    page.seen += 1;
    if (idx < page.start) return false;
    if (page.emitted >= page.limit) {
        page.has_more = true;
        return false;
    }
    page.emitted += 1;
    return true;
}

fn queryMcpStdioServer(allocator: std.mem.Allocator, name: []const u8, command: []const u8, args: []const []const u8, cwd: []const u8, include_inventory: bool) !McpServerPieces {
    _ = name;
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(command);
    try argv.appendSlice(args);

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    defer closeMcpChild(&child);

    var input = std.ArrayList(u8).init(allocator);
    defer input.deinit();
    try appendMcpJsonLine(&input,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"sa-hubproxy","version":"0.1.0"}}}
    );
    try appendMcpJsonLine(&input,
        \\{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
    );
    try appendMcpJsonLine(&input,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
    );
    if (include_inventory) {
        try appendMcpJsonLine(&input,
            \\{"jsonrpc":"2.0","id":3,"method":"resources/list","params":{}}
        );
        try appendMcpJsonLine(&input,
            \\{"jsonrpc":"2.0","id":4,"method":"resources/templates/list","params":{}}
        );
    }

    if (child.stdin) |stdin_file| {
        try stdin_file.writeAll(input.items);
    }

    const stdout_file = child.stdout orelse return error.McpMissingStdout;
    const status_ids = [_]i64{ 2, 3, 4 };
    const tools_only_ids = [_]i64{2};
    const stdout = try readMcpOutputUntilResults(allocator, stdout_file, if (include_inventory) status_ids[0..] else tools_only_ids[0..]);
    defer allocator.free(stdout);

    const server_info = try mcpResultFieldJsonAlloc(allocator, stdout, 1, "serverInfo");
    const tools_result = (try mcpResultFieldJsonAlloc(allocator, stdout, 2, null)) orelse return error.McpMissingToolsResult;
    defer allocator.free(tools_result);
    const tools_map = try mcpToolsMapJsonAlloc(allocator, tools_result);
    const resources = if (include_inventory) try mcpResultArrayFieldJsonAlloc(allocator, stdout, 3, "resources", "") else try allocator.dupe(u8, "[]");
    const resource_templates = if (include_inventory) try mcpResultArrayFieldJsonAlloc(allocator, stdout, 4, "resourceTemplates", "resource_templates") else try allocator.dupe(u8, "[]");
    return .{
        .server_info_json = server_info,
        .tools_map_json = tools_map,
        .resources_json = resources,
        .resource_templates_json = resource_templates,
    };
}

fn queryMcpStdioToolCall(allocator: std.mem.Allocator, command: []const u8, args: []const []const u8, cwd: []const u8, tool_name: []const u8, arguments_json: []const u8, meta_json: []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(command);
    try argv.appendSlice(args);

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    defer closeMcpChild(&child);

    var input = std.ArrayList(u8).init(allocator);
    defer input.deinit();
    try appendMcpJsonLine(&input,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"sa-hubproxy","version":"0.1.0"}}}
    );
    try appendMcpJsonLine(&input,
        \\{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
    );
    var call_payload = std.ArrayList(u8).init(allocator);
    defer call_payload.deinit();
    try call_payload.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":");
    try appendJsonString(call_payload.writer(), tool_name);
    try call_payload.appendSlice(",\"arguments\":");
    try call_payload.appendSlice(arguments_json);
    if (meta_json.len != 0) {
        try call_payload.appendSlice(",\"_meta\":");
        try call_payload.appendSlice(meta_json);
    }
    try call_payload.appendSlice("}}");
    try appendMcpJsonLine(&input, call_payload.items);

    if (child.stdin) |stdin_file| {
        try stdin_file.writeAll(input.items);
    }

    const stdout_file = child.stdout orelse return error.McpMissingStdout;
    const expected_ids = [_]i64{2};
    const stdout = try readMcpOutputUntilResults(allocator, stdout_file, expected_ids[0..]);
    defer allocator.free(stdout);

    return (try mcpResultFieldJsonAlloc(allocator, stdout, 2, null)) orelse error.McpMissingToolCallResult;
}

fn queryMcpStdioResourceRead(allocator: std.mem.Allocator, command: []const u8, args: []const []const u8, cwd: []const u8, uri: []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(command);
    try argv.appendSlice(args);

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    defer closeMcpChild(&child);

    var input = std.ArrayList(u8).init(allocator);
    defer input.deinit();
    try appendMcpJsonLine(&input,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"sa-hubproxy","version":"0.1.0"}}}
    );
    try appendMcpJsonLine(&input,
        \\{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
    );
    var read_payload = std.ArrayList(u8).init(allocator);
    defer read_payload.deinit();
    try read_payload.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"resources/read\",\"params\":{\"uri\":");
    try appendJsonString(read_payload.writer(), uri);
    try read_payload.appendSlice("}}");
    try appendMcpJsonLine(&input, read_payload.items);

    if (child.stdin) |stdin_file| {
        try stdin_file.writeAll(input.items);
    }

    const stdout_file = child.stdout orelse return error.McpMissingStdout;
    const expected_ids = [_]i64{2};
    const stdout = try readMcpOutputUntilResults(allocator, stdout_file, expected_ids[0..]);
    defer allocator.free(stdout);

    return (try mcpResultFieldJsonAlloc(allocator, stdout, 2, null)) orelse error.McpMissingResourceReadResult;
}

fn resolveMcpCwdAlloc(allocator: std.mem.Allocator, plugin_root: []const u8, cwd: []const u8) ![]u8 {
    if (cwd.len == 0 or std.mem.eql(u8, cwd, ".")) return try allocator.dupe(u8, plugin_root);
    if (std.fs.path.isAbsolute(cwd)) return try allocator.dupe(u8, cwd);
    return try std.fs.path.join(allocator, &.{ plugin_root, cwd });
}

fn mcpAuthStatusProtocolValue(raw: []const u8) []const u8 {
    if (raw.len == 0) return "unsupported";
    if (eqlAsciiIgnoreCase(raw, "unsupported")) return "unsupported";
    if (eqlAsciiIgnoreCase(raw, "not_logged_in") or eqlAsciiIgnoreCase(raw, "notLoggedIn")) return "notLoggedIn";
    if (eqlAsciiIgnoreCase(raw, "bearer_token") or eqlAsciiIgnoreCase(raw, "bearerToken")) return "bearerToken";
    if (eqlAsciiIgnoreCase(raw, "oauth") or eqlAsciiIgnoreCase(raw, "OAuth")) return "oauth";
    return "unsupported";
}

fn appendMcpStatusEntry(out: *std.ArrayList(u8), first: *bool, name: []const u8, pieces: McpServerPieces, auth_status: []const u8) !void {
    if (!first.*) try out.append(',');
    first.* = false;
    try out.appendSlice("{\"name\":");
    try appendJsonString(out.writer(), name);
    try out.appendSlice(",\"serverInfo\":");
    if (pieces.server_info_json) |server_info| {
        try out.appendSlice(server_info);
    } else {
        try out.appendSlice("null");
    }
    try out.appendSlice(",\"tools\":");
    try out.appendSlice(pieces.tools_map_json);
    try out.appendSlice(",\"resources\":");
    try out.appendSlice(pieces.resources_json);
    try out.appendSlice(",\"resourceTemplates\":");
    try out.appendSlice(pieces.resource_templates_json);
    try out.appendSlice(",\"authStatus\":");
    try appendJsonString(out.writer(), mcpAuthStatusProtocolValue(auth_status));
    try out.append('}');
}

fn appendMcpStatusesFromConfig(out: *std.ArrayList(u8), first: *bool, config_path: []const u8, include_inventory: bool, page: *McpStatusPage) !void {
    const allocator = std.heap.page_allocator;
    const plugin_root = std.fs.path.dirname(config_path) orelse return;
    const bytes = std.fs.cwd().readFileAlloc(allocator, config_path, 512 * 1024) catch return;
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return;
    defer parsed.deinit();
    const servers = jsonObjectGetValue(parsed.value, "mcpServers") orelse return;
    const server_map = switch (servers) {
        .object => |object| object,
        else => return,
    };

    var it = server_map.iterator();
    while (it.next()) |entry| {
        const server_object = switch (entry.value_ptr.*) {
            .object => |object| object,
            else => continue,
        };
        const server_type = jsonStringValue(server_object.get("type") orelse .null);
        if (server_type.len != 0 and !std.mem.eql(u8, server_type, "stdio")) continue;
        const command = jsonStringValue(server_object.get("command") orelse .null);
        if (command.len == 0) continue;
        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();
        switch (server_object.get("args") orelse .null) {
            .array => |array| for (array.items) |arg_value| {
                const arg = jsonStringValue(arg_value);
                if (arg.len != 0) try args.append(arg);
            },
            else => {},
        }
        const cwd_value = jsonStringValue(server_object.get("cwd") orelse .null);
        const cwd = try resolveMcpCwdAlloc(allocator, plugin_root, cwd_value);
        defer allocator.free(cwd);
        const pieces = queryMcpStdioServer(allocator, entry.key_ptr.*, command, args.items, cwd, include_inventory) catch continue;
        defer pieces.deinit(allocator);
        if (mcpStatusPageShouldEmit(page)) {
            try appendMcpStatusEntry(out, first, entry.key_ptr.*, pieces, "unsupported");
        }
    }
}

fn appendMcpStatusFromConfigObject(out: *std.ArrayList(u8), first: *bool, item: std.json.Value, include_inventory: bool, page: *McpStatusPage) !bool {
    const object = switch (item) {
        .object => |object| object,
        else => return false,
    };
    const enabled = if (object.get("enabled")) |value| switch (value) {
        .bool => |actual| actual,
        else => true,
    } else true;
    if (!enabled) return false;
    const name = jsonStringValue(object.get("name") orelse .null);
    if (name.len == 0) return false;
    const transport = jsonObjectGetValue(item, "transport") orelse return false;
    const transport_type = jsonStringValue(jsonObjectGetValue(transport, "type"));
    if (!std.mem.eql(u8, transport_type, "stdio")) return false;
    const command = jsonStringValue(jsonObjectGetValue(transport, "command"));
    const cwd = jsonStringValue(jsonObjectGetValue(transport, "cwd"));
    if (command.len == 0 or cwd.len == 0) return false;

    const allocator = std.heap.page_allocator;
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    switch (jsonObjectGetValue(transport, "args") orelse .null) {
        .array => |array| for (array.items) |arg_value| {
            const arg = jsonStringValue(arg_value);
            if (arg.len != 0) try args.append(arg);
        },
        else => {},
    }
    const pieces = queryMcpStdioServer(allocator, name, command, args.items, cwd, include_inventory) catch return false;
    defer pieces.deinit(allocator);
    if (mcpStatusPageShouldEmit(page)) {
        const auth_status_value = if (object.get("auth_status")) |value| value else if (object.get("authStatus")) |value| value else .null;
        const auth_status = jsonStringValue(auth_status_value);
        try appendMcpStatusEntry(out, first, name, pieces, auth_status);
    }
    return true;
}

fn mcpConfigObjectName(value: std.json.Value) []const u8 {
    const object = switch (value) {
        .object => |object| object,
        else => return "",
    };
    return jsonStringValue(object.get("name") orelse .null);
}

fn mcpConfigObjectNameLessThan(_: void, left: std.json.Value, right: std.json.Value) bool {
    return std.mem.lessThan(u8, mcpConfigObjectName(left), mcpConfigObjectName(right));
}

fn appendMcpStatusesFromCodexCli(out: *std.ArrayList(u8), first: *bool, include_inventory: bool, page: *McpStatusPage) !u64 {
    const allocator = std.heap.page_allocator;
    const argv = [_][]const u8{ "codex", "mcp", "list", "--json" };
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .max_output_bytes = 2 * 1024 * 1024,
    }) catch return 0;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return 0,
        else => return 0,
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch return 0;
    defer parsed.deinit();
    const array = switch (parsed.value) {
        .array => |array| array,
        else => return 0,
    };
    std.mem.sort(std.json.Value, array.items, {}, mcpConfigObjectNameLessThan);
    var count: u64 = 0;
    for (array.items) |item| {
        if (try appendMcpStatusFromConfigObject(out, first, item, include_inventory, page)) count += 1;
    }
    return count;
}

fn mcpServerNameMatches(allocator: std.mem.Allocator, requested: []const u8, configured: []const u8) !bool {
    if (std.mem.eql(u8, requested, configured)) return true;
    const requested_norm = try normalizeMcpServerNameAlloc(allocator, requested);
    defer allocator.free(requested_norm);
    const configured_norm = try normalizeMcpServerNameAlloc(allocator, configured);
    defer allocator.free(configured_norm);
    if (std.mem.eql(u8, requested_norm, configured_norm)) return true;
    const requested_denorm = try denormalizeMcpServerNameAlloc(allocator, requested);
    defer allocator.free(requested_denorm);
    return std.mem.eql(u8, requested_denorm, configured);
}

fn mcpIdentifierMatchAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var last_sep = false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            try out.append(std.ascii.toLower(ch));
            last_sep = false;
        } else if (!last_sep) {
            try out.append('_');
            last_sep = true;
        }
    }
    while (out.items.len != 0 and out.items[out.items.len - 1] == '_') _ = out.pop();
    return try out.toOwnedSlice();
}

fn resolveMcpToolNameAlloc(allocator: std.mem.Allocator, tools_map_json: []const u8, requested: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, tools_map_json, .{}) catch return try allocator.dupe(u8, requested);
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return try allocator.dupe(u8, requested),
    };

    var it = object.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, requested, entry.key_ptr.*)) {
            return try allocator.dupe(u8, entry.key_ptr.*);
        }
    }

    const requested_norm = try mcpIdentifierMatchAlloc(allocator, requested);
    defer allocator.free(requested_norm);
    var normalized_match: ?[]const u8 = null;
    var norm_it = object.iterator();
    while (norm_it.next()) |entry| {
        const actual_norm = try mcpIdentifierMatchAlloc(allocator, entry.key_ptr.*);
        defer allocator.free(actual_norm);
        if (!std.mem.eql(u8, requested_norm, actual_norm)) continue;
        if (normalized_match) |existing| {
            if (!std.mem.eql(u8, existing, entry.key_ptr.*)) return try allocator.dupe(u8, requested);
        }
        normalized_match = entry.key_ptr.*;
    }
    if (normalized_match) |actual| return try allocator.dupe(u8, actual);
    return try allocator.dupe(u8, requested);
}

fn mcpCallArgumentsJsonAlloc(allocator: std.mem.Allocator, params: std.json.Value) ![]u8 {
    const arguments = jsonObjectGetValue(params, "arguments") orelse .null;
    switch (arguments) {
        .object => {},
        .array => {},
        .null => return try allocator.dupe(u8, "{}"),
        .string => |text| {
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return try allocator.dupe(u8, "{}");
            defer parsed.deinit();
            switch (parsed.value) {
                .object, .array => {
                    var out = std.ArrayList(u8).init(allocator);
                    errdefer out.deinit();
                    try std.json.stringify(parsed.value, .{}, out.writer());
                    return try out.toOwnedSlice();
                },
                else => return try allocator.dupe(u8, "{}"),
            }
        },
        else => return try allocator.dupe(u8, "{}"),
    }
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try std.json.stringify(arguments, .{}, out.writer());
    return try out.toOwnedSlice();
}

fn mcpCallMetaJsonAlloc(allocator: std.mem.Allocator, params: std.json.Value) ![]u8 {
    const thread_id = jsonStringValue(jsonObjectGetValue(params, "threadId"));
    const meta = jsonObjectGetValue(params, "_meta") orelse .null;
    if (thread_id.len == 0) {
        switch (meta) {
            .null => return try allocator.dupe(u8, ""),
            else => {},
        }
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        try std.json.stringify(meta, .{}, out.writer());
        return try out.toOwnedSlice();
    }

    switch (meta) {
        .object => |object| {
            var out = std.ArrayList(u8).init(allocator);
            errdefer out.deinit();
            try out.append('{');
            var first = true;
            var it = object.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "threadId")) continue;
                if (!first) try out.append(',');
                first = false;
                try appendJsonString(out.writer(), entry.key_ptr.*);
                try out.append(':');
                try std.json.stringify(entry.value_ptr.*, .{}, out.writer());
            }
            if (!first) try out.append(',');
            try appendJsonString(out.writer(), "threadId");
            try out.append(':');
            try appendJsonString(out.writer(), thread_id);
            try out.append('}');
            return try out.toOwnedSlice();
        },
        .null => {
            var out = std.ArrayList(u8).init(allocator);
            errdefer out.deinit();
            try out.appendSlice("{\"threadId\":");
            try appendJsonString(out.writer(), thread_id);
            try out.append('}');
            return try out.toOwnedSlice();
        },
        else => {
            var out = std.ArrayList(u8).init(allocator);
            errdefer out.deinit();
            try std.json.stringify(meta, .{}, out.writer());
            return try out.toOwnedSlice();
        },
    }
}

pub fn mcpToolCallHasRequiredParams(body: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch return false;
    defer parsed.deinit();
    const params = jsonObjectGetValue(parsed.value, "params") orelse return false;
    const server = jsonStringValue(jsonObjectGetValue(params, "server"));
    const tool = jsonStringValue(jsonObjectGetValue(params, "tool"));
    const thread_id = jsonStringValue(jsonObjectGetValue(params, "threadId"));
    return server.len != 0 and tool.len != 0 and thread_id.len != 0;
}

pub fn mcpResourceReadHasRequiredParams(body: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch return false;
    defer parsed.deinit();
    const params = jsonObjectGetValue(parsed.value, "params") orelse return false;
    const server = jsonStringValue(jsonObjectGetValue(params, "server"));
    const uri = jsonStringValue(jsonObjectGetValue(params, "uri"));
    return server.len != 0 and uri.len != 0;
}

fn mcpToolCallFromConfig(allocator: std.mem.Allocator, config_path: []const u8, requested_server: []const u8, tool_name: []const u8, arguments_json: []const u8, meta_json: []const u8) !?[]u8 {
    const plugin_root = std.fs.path.dirname(config_path) orelse return null;
    const bytes = std.fs.cwd().readFileAlloc(allocator, config_path, 512 * 1024) catch return null;
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return null;
    defer parsed.deinit();
    const servers = jsonObjectGetValue(parsed.value, "mcpServers") orelse return null;
    const server_map = switch (servers) {
        .object => |object| object,
        else => return null,
    };

    var it = server_map.iterator();
    while (it.next()) |entry| {
        if (!(try mcpServerNameMatches(allocator, requested_server, entry.key_ptr.*))) continue;
        const server_object = switch (entry.value_ptr.*) {
            .object => |object| object,
            else => continue,
        };
        const server_type = jsonStringValue(server_object.get("type") orelse .null);
        if (server_type.len != 0 and !std.mem.eql(u8, server_type, "stdio")) continue;
        const command = jsonStringValue(server_object.get("command") orelse .null);
        if (command.len == 0) continue;
        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();
        switch (server_object.get("args") orelse .null) {
            .array => |array| for (array.items) |arg_value| {
                const arg = jsonStringValue(arg_value);
                if (arg.len != 0) try args.append(arg);
            },
            else => {},
        }
        const cwd_value = jsonStringValue(server_object.get("cwd") orelse .null);
        const cwd = try resolveMcpCwdAlloc(allocator, plugin_root, cwd_value);
        defer allocator.free(cwd);
        const pieces = queryMcpStdioServer(allocator, entry.key_ptr.*, command, args.items, cwd, false) catch return error.McpToolExecutionFailed;
        defer pieces.deinit(allocator);
        const resolved_tool = try resolveMcpToolNameAlloc(allocator, pieces.tools_map_json, tool_name);
        defer allocator.free(resolved_tool);
        return queryMcpStdioToolCall(allocator, command, args.items, cwd, resolved_tool, arguments_json, meta_json) catch return error.McpToolExecutionFailed;
    }
    return null;
}

fn mcpResourceReadFromConfig(allocator: std.mem.Allocator, config_path: []const u8, requested_server: []const u8, uri: []const u8) !?[]u8 {
    const plugin_root = std.fs.path.dirname(config_path) orelse return null;
    const bytes = std.fs.cwd().readFileAlloc(allocator, config_path, 512 * 1024) catch return null;
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return null;
    defer parsed.deinit();
    const servers = jsonObjectGetValue(parsed.value, "mcpServers") orelse return null;
    const server_map = switch (servers) {
        .object => |object| object,
        else => return null,
    };

    var it = server_map.iterator();
    while (it.next()) |entry| {
        if (requested_server.len != 0 and !(try mcpServerNameMatches(allocator, requested_server, entry.key_ptr.*))) continue;
        const server_object = switch (entry.value_ptr.*) {
            .object => |object| object,
            else => continue,
        };
        const server_type = jsonStringValue(server_object.get("type") orelse .null);
        if (server_type.len != 0 and !std.mem.eql(u8, server_type, "stdio")) continue;
        const command = jsonStringValue(server_object.get("command") orelse .null);
        if (command.len == 0) continue;
        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();
        switch (server_object.get("args") orelse .null) {
            .array => |array| for (array.items) |arg_value| {
                const arg = jsonStringValue(arg_value);
                if (arg.len != 0) try args.append(arg);
            },
            else => {},
        }
        const cwd_value = jsonStringValue(server_object.get("cwd") orelse .null);
        const cwd = try resolveMcpCwdAlloc(allocator, plugin_root, cwd_value);
        defer allocator.free(cwd);
        return queryMcpStdioResourceRead(allocator, command, args.items, cwd, uri) catch return error.McpToolExecutionFailed;
    }
    return null;
}

fn mcpToolCallFromCodexItem(allocator: std.mem.Allocator, item: std.json.Value, requested_server: []const u8, tool_name: []const u8, arguments_json: []const u8, meta_json: []const u8) !?[]u8 {
    const object = switch (item) {
        .object => |object| object,
        else => return null,
    };
    const enabled = if (object.get("enabled")) |value| switch (value) {
        .bool => |actual| actual,
        else => true,
    } else true;
    if (!enabled) return null;
    const name = jsonStringValue(object.get("name") orelse .null);
    if (name.len == 0 or !(try mcpServerNameMatches(allocator, requested_server, name))) return null;
    const transport = jsonObjectGetValue(item, "transport") orelse return null;
    const transport_type = jsonStringValue(jsonObjectGetValue(transport, "type"));
    if (!std.mem.eql(u8, transport_type, "stdio")) return null;
    const command = jsonStringValue(jsonObjectGetValue(transport, "command"));
    const cwd = jsonStringValue(jsonObjectGetValue(transport, "cwd"));
    if (command.len == 0 or cwd.len == 0) return null;
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    switch (jsonObjectGetValue(transport, "args") orelse .null) {
        .array => |array| for (array.items) |arg_value| {
            const arg = jsonStringValue(arg_value);
            if (arg.len != 0) try args.append(arg);
        },
        else => {},
    }
    const pieces = queryMcpStdioServer(allocator, name, command, args.items, cwd, false) catch return error.McpToolExecutionFailed;
    defer pieces.deinit(allocator);
    const resolved_tool = try resolveMcpToolNameAlloc(allocator, pieces.tools_map_json, tool_name);
    defer allocator.free(resolved_tool);
    return queryMcpStdioToolCall(allocator, command, args.items, cwd, resolved_tool, arguments_json, meta_json) catch return error.McpToolExecutionFailed;
}

fn mcpToolCallFromCodexCli(allocator: std.mem.Allocator, requested_server: []const u8, tool_name: []const u8, arguments_json: []const u8, meta_json: []const u8) !?[]u8 {
    const argv = [_][]const u8{ "codex", "mcp", "list", "--json" };
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .max_output_bytes = 2 * 1024 * 1024,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch return null;
    defer parsed.deinit();
    const array = switch (parsed.value) {
        .array => |array| array,
        else => return null,
    };
    for (array.items) |item| {
        if (try mcpToolCallFromCodexItem(allocator, item, requested_server, tool_name, arguments_json, meta_json)) |result_json| return result_json;
    }
    return null;
}

fn mcpResourceReadFromCodexItem(allocator: std.mem.Allocator, item: std.json.Value, requested_server: []const u8, uri: []const u8) !?[]u8 {
    const object = switch (item) {
        .object => |object| object,
        else => return null,
    };
    const enabled = if (object.get("enabled")) |value| switch (value) {
        .bool => |actual| actual,
        else => true,
    } else true;
    if (!enabled) return null;
    const name = jsonStringValue(object.get("name") orelse .null);
    if (name.len == 0) return null;
    if (requested_server.len != 0 and !(try mcpServerNameMatches(allocator, requested_server, name))) return null;
    const transport = jsonObjectGetValue(item, "transport") orelse return null;
    const transport_type = jsonStringValue(jsonObjectGetValue(transport, "type"));
    if (!std.mem.eql(u8, transport_type, "stdio")) return null;
    const command = jsonStringValue(jsonObjectGetValue(transport, "command"));
    const cwd = jsonStringValue(jsonObjectGetValue(transport, "cwd"));
    if (command.len == 0 or cwd.len == 0) return null;
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    switch (jsonObjectGetValue(transport, "args") orelse .null) {
        .array => |array| for (array.items) |arg_value| {
            const arg = jsonStringValue(arg_value);
            if (arg.len != 0) try args.append(arg);
        },
        else => {},
    }
    return queryMcpStdioResourceRead(allocator, command, args.items, cwd, uri) catch return error.McpToolExecutionFailed;
}

fn mcpResourceReadFromCodexCli(allocator: std.mem.Allocator, requested_server: []const u8, uri: []const u8) !?[]u8 {
    const argv = [_][]const u8{ "codex", "mcp", "list", "--json" };
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .max_output_bytes = 2 * 1024 * 1024,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch return null;
    defer parsed.deinit();
    const array = switch (parsed.value) {
        .array => |array| array,
        else => return null,
    };
    for (array.items) |item| {
        if (try mcpResourceReadFromCodexItem(allocator, item, requested_server, uri)) |result_json| return result_json;
    }
    return null;
}

pub fn mcpToolCall(body: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch return null;
    defer parsed.deinit();
    const params = jsonObjectGetValue(parsed.value, "params") orelse return null;
    const server = jsonStringValue(jsonObjectGetValue(params, "server"));
    const tool = jsonStringValue(jsonObjectGetValue(params, "tool"));
    const thread_id = jsonStringValue(jsonObjectGetValue(params, "threadId"));
    if (server.len == 0 or tool.len == 0 or thread_id.len == 0) return null;
    const arguments_json = try mcpCallArgumentsJsonAlloc(std.heap.page_allocator, params);
    defer std.heap.page_allocator.free(arguments_json);
    const meta_json = try mcpCallMetaJsonAlloc(std.heap.page_allocator, params);
    defer std.heap.page_allocator.free(meta_json);

    const allocator = std.heap.page_allocator;
    if (try mcpToolCallFromCodexCli(allocator, server, tool, arguments_json, meta_json)) |result| return result;

    const codex_home = std.process.getEnvVarOwned(allocator, "CODEX_HOME") catch blk: {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
        defer allocator.free(home);
        break :blk try std.fs.path.join(allocator, &.{ home, ".codex" });
    };
    defer allocator.free(codex_home);
    const plugin_cache = try std.fs.path.join(allocator, &.{ codex_home, "plugins", "cache", "local-projects" });
    defer allocator.free(plugin_cache);
    var dir = std.fs.openDirAbsolute(plugin_cache, .{ .iterate = true }) catch return null;
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(entry.path), ".mcp.json")) continue;
        const config_path = try std.fs.path.join(allocator, &.{ plugin_cache, entry.path });
        defer allocator.free(config_path);
        if (try mcpToolCallFromConfig(allocator, config_path, server, tool, arguments_json, meta_json)) |result| return result;
    }
    return null;
}

pub fn mcpResourceRead(body: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch return null;
    defer parsed.deinit();
    const params = jsonObjectGetValue(parsed.value, "params") orelse return null;
    const uri = jsonStringValue(jsonObjectGetValue(params, "uri"));
    if (uri.len == 0) return null;
    const server = jsonStringValue(jsonObjectGetValue(params, "server"));
    const allocator = std.heap.page_allocator;
    if (try mcpResourceReadFromCodexCli(allocator, server, uri)) |result| return result;

    const codex_home = std.process.getEnvVarOwned(allocator, "CODEX_HOME") catch blk: {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
        defer allocator.free(home);
        break :blk try std.fs.path.join(allocator, &.{ home, ".codex" });
    };
    defer allocator.free(codex_home);
    const plugin_cache = try std.fs.path.join(allocator, &.{ codex_home, "plugins", "cache", "local-projects" });
    defer allocator.free(plugin_cache);
    var dir = std.fs.openDirAbsolute(plugin_cache, .{ .iterate = true }) catch return null;
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(entry.path), ".mcp.json")) continue;
        const config_path = try std.fs.path.join(allocator, &.{ plugin_cache, entry.path });
        defer allocator.free(config_path);
        if (try mcpResourceReadFromConfig(allocator, config_path, server, uri)) |result| return result;
    }
    return null;
}

fn appendDiscoveredMcpStatuses(out: *std.ArrayList(u8), first: *bool, include_inventory: bool, page: *McpStatusPage) !void {
    const allocator = std.heap.page_allocator;
    const codex_count = try appendMcpStatusesFromCodexCli(out, first, include_inventory, page);
    if (codex_count != 0) return;

    const codex_home = std.process.getEnvVarOwned(allocator, "CODEX_HOME") catch blk: {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch return;
        defer allocator.free(home);
        break :blk try std.fs.path.join(allocator, &.{ home, ".codex" });
    };
    defer allocator.free(codex_home);

    const plugin_cache = try std.fs.path.join(allocator, &.{ codex_home, "plugins", "cache", "local-projects" });
    defer allocator.free(plugin_cache);
    var dir = std.fs.openDirAbsolute(plugin_cache, .{ .iterate = true }) catch return;
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(entry.path), ".mcp.json")) continue;
        const config_path = try std.fs.path.join(allocator, &.{ plugin_cache, entry.path });
        defer allocator.free(config_path);
        appendMcpStatusesFromConfig(out, first, config_path, include_inventory, page) catch continue;
    }
}

pub fn mcpServerStatusList(body: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(std.heap.page_allocator);
    errdefer out.deinit();
    try out.appendSlice("{\"data\":[");
    var first = true;
    var page = mcpStatusPageFromBody(body);
    if (page.invalid) return error.InvalidMcpStatusParams;
    try appendDiscoveredMcpStatuses(&out, &first, page.include_inventory, &page);
    if (page.start > page.seen) return error.InvalidMcpStatusParams;
    try out.appendSlice("],\"nextCursor\":");
    if (page.has_more) {
        const next_cursor = try std.fmt.allocPrint(std.heap.page_allocator, "{}", .{page.start + page.emitted});
        defer std.heap.page_allocator.free(next_cursor);
        try appendJsonString(out.writer(), next_cursor);
    } else {
        try out.appendSlice("null");
    }
    try out.append('}');
    return try out.toOwnedSlice();
}

test "collaboration mode inference matches Deno request context rules" {
    try std.testing.expectEqual(@as(u32, 3), inferCollaborationModeCode(
        \\{"client_metadata":{"mode":"code"}}
    ));
    try std.testing.expectEqual(@as(u32, 2), inferCollaborationModeCode(
        \\{"collaboration_mode":{"kind":" goal "}}
    ));
    try std.testing.expectEqual(@as(u32, 1), inferCollaborationModeCode(
        \\{"instructions":"# Plan Mode (Conversational)\nYou are in **Plan Mode**.","input":[{"role":"user","content":[{"text":"hi"}]}]}
    ));
    try std.testing.expectEqual(@as(u32, 2), inferCollaborationModeCode(
        \\{"input":[{"role":"developer","content":[{"text":"<goal_context>Continue working toward the active thread goal.</goal_context>"}]}]}
    ));
    try std.testing.expectEqual(@as(u32, 3), inferCollaborationModeCode(
        \\{"input":[{"role":"developer","content":[{"text":"<collaboration_mode># Plan Mode (Conversational)</collaboration_mode>"}]},{"role":"assistant","content":[{"text":"PLAN_OK"}]},{"role":"developer","content":[{"text":"<collaboration_mode># Collaboration Mode: Default</collaboration_mode>"}]}]}
    ));
}

test "chat SSE MCP dot-notation tool calls are normalized" {
    const req_body =
        \\{"tools":[{"type":"namespace","name":"mcp__code_index__","tools":[{"type":"function","name":"read_mcp_resource"}]}]}
    ;
    const chat_body =
        \\data: {"choices":[{"delta":{"tool_calls":[{"id":"call_raw_underscore","type":"function","function":{"name":"code_index.read_mcp_resource","arguments":"{\"server\":\"code_index\",\"uri\":\"file:///tmp/one\"}"},"index":0},{"id":"call_raw_hyphen","type":"function","function":{"name":"code-index.read_mcp_resource","arguments":"{\"server\":\"code-index\",\"uri\":\"file:///tmp/two\"}"},"index":1},{"id":"call_normalized_dot","type":"function","function":{"name":"mcp__code_index__.read_mcp_resource","arguments":"{\"server\":\"mcp__code_index__\",\"uri\":\"file:///tmp/three\"}"},"index":2}]},"finish_reason":null}]}
        \\
        \\data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}
        \\
        \\data: [DONE]
        \\
    ;
    const out = try chatSseToResponses(chat_body, req_body);
    defer std.heap.page_allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"namespace\":\"mcp__code_index__\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"read_mcp_resource\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\"server\\\":\\\"code-index\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "code_index.read_mcp_resource") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "code-index.read_mcp_resource") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "mcp__code_index__.read_mcp_resource") == null);
}

test "chat JSON MCP dot-notation tool calls are normalized" {
    const req_body =
        \\{"tools":[{"type":"namespace","name":"mcp__code_index__","tools":[{"type":"function","name":"read_mcp_resource"}]}]}
    ;
    const chat_body =
        \\{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_json_mcp","type":"function","function":{"name":"code-index.read_mcp_resource","arguments":"{\"server\":\"mcp__code_index__\",\"uri\":\"file:///tmp/json\"}"}}]}}]}
    ;
    const out = try chatJsonToResponses(chat_body, req_body);
    defer std.heap.page_allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"namespace\":\"mcp__code_index__\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"read_mcp_resource\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\"server\\\":\\\"code-index\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "code-index.read_mcp_resource") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "mcp__code_index__.read_mcp_resource") == null);
}

test "chat JSON MCP namespace detection parses formatted request tools" {
    const req_body =
        \\{
        \\  "tools": [
        \\    {
        \\      "type": "namespace",
        \\      "name": "mcp__demo_server__",
        \\      "tools": [{ "type": "function", "name": "rebuild" }]
        \\    }
        \\  ]
        \\}
    ;
    const chat_body =
        \\{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_demo","type":"function","function":{"name":"demo-server.rebuild","arguments":"{}"}}]}}]}
    ;
    const out = try chatJsonToResponses(chat_body, req_body);
    defer std.heap.page_allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"namespace\":\"mcp__demo_server__\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"rebuild\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "demo-server.rebuild") == null);
}

test "chat JSON MCP namespace detection accepts flat request tools" {
    const req_body =
        \\{"tools":[{"type":"function","name":"mcp__demo_server__rebuild","parameters":{"type":"object"}}]}
    ;
    const chat_body =
        \\{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_demo_flat","type":"function","function":{"name":"demo-server.rebuild","arguments":"{}"}}]}}]}
    ;
    const out = try chatJsonToResponses(chat_body, req_body);
    defer std.heap.page_allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"namespace\":\"mcp__demo_server__\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"rebuild\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "demo-server.rebuild") == null);
}

test "responses chat fallback request normalizes MCP server arguments in history" {
    const body =
        \\{"model":"models/mimo-v2.5-pro","stream":false,"input":[{"type":"function_call","call_id":"call-1","name":"read_mcp_resource","arguments":"{\"server\":\"Code Index\",\"uri\":\"file:///tmp/one\"}"},{"type":"function_call","call_id":"call-2","name":"read_mcp_resource","arguments":"{\"server\":\"mcp__mcp_code_index___\",\"uri\":\"file:///tmp/two\"}"},{"type":"function_call","call_id":"call-3","name":"read_mcp_resource","arguments":"{\"server\":\"Custom Tool\",\"uri\":\"file:///tmp/three\"}"}]}
    ;
    const out_opt = try responsesChatFallbackRequest(body, "fallback-model", false);
    const out = out_opt orelse return error.TestUnexpectedResult;
    defer std.heap.page_allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\\\"server\\\":\\\"mcp__code_index__\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\"server\\\":\\\"mcp__custom_tool__\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Code Index") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "mcp__mcp_code_index___") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Custom Tool") == null);
}

test "mcp server namespace normalization is generic" {
    const spaced = try normalizeMcpServerNameAlloc(std.testing.allocator, "Workspace Tools V2");
    defer std.testing.allocator.free(spaced);
    try std.testing.expectEqualStrings("mcp__workspace_tools_v2__", spaced);

    const dashed = try normalizeMcpServerNameAlloc(std.testing.allocator, "secure-coder.server");
    defer std.testing.allocator.free(dashed);
    try std.testing.expectEqualStrings("mcp__secure_coder_server__", dashed);

    const already = try normalizeMcpServerNameAlloc(std.testing.allocator, "mcp__custom_tool__");
    defer std.testing.allocator.free(already);
    try std.testing.expectEqualStrings("mcp__custom_tool__", already);

    const double_wrapped = try normalizeMcpServerNameAlloc(std.testing.allocator, "mcp__mcp_custom_tool___");
    defer std.testing.allocator.free(double_wrapped);
    try std.testing.expectEqualStrings("mcp__custom_tool__", double_wrapped);
}

test "responses request normalize strips reasoning content" {
    const body =
        \\{"model":"gpt-5.5","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]},{"type":"reasoning","summary":[],"content":[{"type":"reasoning_text","text":"internal"}],"encrypted_content":"enc"}]}
    ;
    const out = try responsesRequestNormalize(body);
    defer std.heap.page_allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"type\":\"reasoning\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"encrypted_content\":\"enc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "reasoning_text") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"content\"") != null);
}

test "responses request normalize flattens namespace history calls" {
    const body =
        \\{"input":[{"type":"function_call","name":"build_index","namespace":"mcp__code_index__","output_kind":"function_call_output","arguments":"{}","call_id":"call-1"}]}
    ;
    const out = try responsesRequestNormalize(body);
    defer std.heap.page_allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"mcp__code_index__build_index\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"namespace\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"output_kind\"") == null);
}

test "native responses json splits flat mcp tool names" {
    const body =
        \\{"output":[{"id":"tool-1","type":"function_call","call_id":"call-1","name":"mcp__code_index__build_index","arguments":"{}"}]}
    ;
    const out = try responsesJsonNormalize(body);
    defer std.heap.page_allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"build_index\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"namespace\":\"mcp__code_index__\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"output_kind\":\"function_call_output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"mcp__code_index__build_index\"") == null);
}

test "native responses json splits mcp names only for declared namespace request tools" {
    const body =
        \\{"output":[{"id":"tool-1","type":"function_call","call_id":"call-1","name":"mcp__code_index__build_index","arguments":"{}"}]}
    ;
    const flat_req =
        \\{"tools":[{"type":"function","name":"mcp__code_index__build_index","parameters":{"type":"object"}}]}
    ;
    const namespace_req =
        \\{"tools":[{"type":"namespace","name":"mcp__code_index__","tools":[{"type":"function","name":"build_index"}]}]}
    ;

    const flat_out = try responsesJsonNormalizeWithRequest(body, flat_req);
    defer std.heap.page_allocator.free(flat_out);
    try std.testing.expect(std.mem.indexOf(u8, flat_out, "\"name\":\"mcp__code_index__build_index\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, flat_out, "\"namespace\":\"mcp__code_index__\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, flat_out, "\"output_kind\":\"function_call_output\"") != null);

    const namespace_out = try responsesJsonNormalizeWithRequest(body, namespace_req);
    defer std.heap.page_allocator.free(namespace_out);
    try std.testing.expect(std.mem.indexOf(u8, namespace_out, "\"name\":\"build_index\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, namespace_out, "\"namespace\":\"mcp__code_index__\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, namespace_out, "\"name\":\"mcp__code_index__build_index\"") == null);
}

test "native responses json denormalizes mcp arguments when flat names are preserved" {
    const body =
        \\{"output":[{"id":"tool-args","type":"function_call","call_id":"call-args","name":"mcp__code_index__read_mcp_resource","arguments":"{\"server\":\"mcp__code_index__\",\"uri\":\"file:///foo\"}"}]}
    ;
    const flat_req =
        \\{"tools":[{"type":"function","name":"mcp__code_index__read_mcp_resource","parameters":{"type":"object"}}]}
    ;

    const out = try responsesJsonNormalizeWithRequest(body, flat_req);
    defer std.heap.page_allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"mcp__code_index__read_mcp_resource\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"namespace\":\"mcp__code_index__\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\"server\\\":\\\"code-index\\\"") != null);
}

test "native responses json adds output kind for all tool call types" {
    const body =
        \\{"output":[{"id":"fn-1","type":"function_call","call_id":"call-fn","name":"exec_command","arguments":"{}"},{"id":"custom-1","type":"custom_tool_call","call_id":"call-custom","name":"custom"},{"id":"search-1","type":"tool_search_call","call_id":"call-search","name":"search"},{"id":"mcp-1","type":"mcp_tool_call","call_id":"call-mcp","name":"tool"}]}
    ;
    const out = try responsesJsonNormalize(body);
    defer std.heap.page_allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"output_kind\":\"function_call_output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"output_kind\":\"custom_tool_call_output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"output_kind\":\"tool_search_output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"output_kind\":\"mcp_tool_call_output\"") != null);
}

test "native responses sse splits flat mcp tool names on added and done" {
    const body =
        \\event: response.output_item.added
        \\data: {"type":"response.output_item.added","item":{"id":"tool-added","type":"function_call","call_id":"call-a","name":"mcp__code_index__search","arguments":"{}"}}
        \\
        \\
        \\event: response.output_item.done
        \\data: {"type":"response.output_item.done","item":{"id":"tool-done","type":"function_call","call_id":"call-b","name":"mcp__code_index__build_index","arguments":"{}"}}
        \\
        \\
    ;
    const out = try responsesSseNormalize(body);
    defer std.heap.page_allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"build_index\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"namespace\":\"mcp__code_index__\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"output_kind\":\"function_call_output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"mcp__code_index__search\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"mcp__code_index__build_index\"") == null);
}

test "native responses sse adds output kind for non mcp namespace tool calls" {
    const body =
        \\event: response.output_item.done
        \\data: {"type":"response.output_item.done","item":{"id":"tool-plain","type":"function_call","call_id":"call-fn","name":"exec_command","arguments":"{}"}}
        \\
        \\
        \\event: response.output_item.done
        \\data: {"type":"response.output_item.done","item":{"id":"tool-custom","type":"custom_tool_call","call_id":"call-custom","name":"custom"}}
        \\
        \\
    ;
    const out = try responsesSseNormalize(body);
    defer std.heap.page_allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"output_kind\":\"function_call_output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"output_kind\":\"custom_tool_call_output\"") != null);
}

test "mcp status detail controls inventory probing" {
    try std.testing.expect(mcpStatusPageFromBody("").include_inventory);
    try std.testing.expect(mcpStatusPageFromBody(
        \\{"jsonrpc":"2.0","id":1,"method":"mcpServerStatus/list","params":{}}
    ).include_inventory);
    try std.testing.expect(mcpStatusPageFromBody(
        \\{"jsonrpc":"2.0","id":1,"method":"mcpServerStatus/list","params":{"detail":"full"}}
    ).include_inventory);
    try std.testing.expect(!mcpStatusPageFromBody(
        \\{"jsonrpc":"2.0","id":1,"method":"mcpServerStatus/list","params":{"detail":"toolsAndAuthOnly"}}
    ).include_inventory);
    try std.testing.expect(mcpStatusPageFromBody(
        \\{"jsonrpc":"2.0","id":1,"method":"mcpServerStatus/list","params":{"detail":"unknown"}}
    ).invalid);
}

test "mcp status pagination parses cursor and limit" {
    var page = mcpStatusPageFromBody(
        \\{"jsonrpc":"2.0","id":1,"method":"mcpServerStatus/list","params":{"cursor":"2","limit":0}}
    );
    try std.testing.expectEqual(@as(usize, 2), page.start);
    try std.testing.expectEqual(@as(usize, 1), page.limit);
    try std.testing.expect(!mcpStatusPageShouldEmit(&page));
    try std.testing.expect(!mcpStatusPageShouldEmit(&page));
    try std.testing.expect(mcpStatusPageShouldEmit(&page));
    try std.testing.expect(!mcpStatusPageShouldEmit(&page));
    try std.testing.expect(page.has_more);
    try std.testing.expectEqual(@as(usize, 1), page.emitted);
}

test "mcp status pagination rejects invalid cursor and limit types" {
    const bad_cursor = mcpStatusPageFromBody(
        \\{"jsonrpc":"2.0","id":1,"method":"mcpServerStatus/list","params":{"cursor":"not-a-number","limit":1}}
    );
    try std.testing.expect(bad_cursor.invalid);

    const numeric_cursor = mcpStatusPageFromBody(
        \\{"jsonrpc":"2.0","id":1,"method":"mcpServerStatus/list","params":{"cursor":1,"limit":1}}
    );
    try std.testing.expect(numeric_cursor.invalid);

    const bad_limit = mcpStatusPageFromBody(
        \\{"jsonrpc":"2.0","id":1,"method":"mcpServerStatus/list","params":{"cursor":"0","limit":"1"}}
    );
    try std.testing.expect(bad_limit.invalid);
}

test "mcp auth status values normalize to Codex protocol casing" {
    try std.testing.expectEqualStrings("unsupported", mcpAuthStatusProtocolValue("unsupported"));
    try std.testing.expectEqualStrings("notLoggedIn", mcpAuthStatusProtocolValue("not_logged_in"));
    try std.testing.expectEqualStrings("notLoggedIn", mcpAuthStatusProtocolValue("notLoggedIn"));
    try std.testing.expectEqualStrings("bearerToken", mcpAuthStatusProtocolValue("bearer_token"));
    try std.testing.expectEqualStrings("bearerToken", mcpAuthStatusProtocolValue("bearerToken"));
    try std.testing.expectEqualStrings("oauth", mcpAuthStatusProtocolValue("OAuth"));
    try std.testing.expectEqualStrings("unsupported", mcpAuthStatusProtocolValue("unknown"));
}

test "mcp tool call meta injects thread id like Codex" {
    var parsed_object = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"threadId":"thread-new","_meta":{"existing":true,"threadId":"old"}}
    , .{});
    defer parsed_object.deinit();
    const merged = try mcpCallMetaJsonAlloc(std.testing.allocator, parsed_object.value);
    defer std.testing.allocator.free(merged);
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"existing\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"threadId\":\"thread-new\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "old") == null);

    var parsed_missing = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"threadId":"thread-only"}
    , .{});
    defer parsed_missing.deinit();
    const created = try mcpCallMetaJsonAlloc(std.testing.allocator, parsed_missing.value);
    defer std.testing.allocator.free(created);
    try std.testing.expect(std.mem.indexOf(u8, created, "\"threadId\":\"thread-only\"") != null);

    var parsed_non_object = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"threadId":"thread-new","_meta":"raw"}
    , .{});
    defer parsed_non_object.deinit();
    const kept = try mcpCallMetaJsonAlloc(std.testing.allocator, parsed_non_object.value);
    defer std.testing.allocator.free(kept);
    try std.testing.expect(std.mem.eql(u8, kept, "\"raw\""));
}

test "mcp tool name resolver maps safe function names to advertised MCP names" {
    const tools_map =
        \\{"build-index":{"name":"build-index"},"read_mcp_resource":{"name":"read_mcp_resource"}}
    ;
    const dashed = try resolveMcpToolNameAlloc(std.testing.allocator, tools_map, "build_index");
    defer std.testing.allocator.free(dashed);
    try std.testing.expectEqualStrings("build-index", dashed);

    const exact = try resolveMcpToolNameAlloc(std.testing.allocator, tools_map, "read_mcp_resource");
    defer std.testing.allocator.free(exact);
    try std.testing.expectEqualStrings("read_mcp_resource", exact);
}

test "mcp tool name resolver leaves ambiguous safe names unresolved" {
    const tools_map =
        \\{"build-index":{"name":"build-index"},"build_index":{"name":"build_index"},"read":{"name":"read"}}
    ;
    const exact = try resolveMcpToolNameAlloc(std.testing.allocator, tools_map, "build_index");
    defer std.testing.allocator.free(exact);
    try std.testing.expectEqualStrings("build_index", exact);

    const ambiguous = try resolveMcpToolNameAlloc(std.testing.allocator, tools_map, "build index");
    defer std.testing.allocator.free(ambiguous);
    try std.testing.expectEqualStrings("build index", ambiguous);
}

test "mcp tool call reports matched server execution failure" {
    const item =
        \\{"name":"broken-server","enabled":true,"transport":{"type":"stdio","command":"false","args":[],"cwd":"/tmp"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, item, .{});
    defer parsed.deinit();
    const result = mcpToolCallFromCodexItem(std.testing.allocator, parsed.value, "broken-server", "any_tool", "{}", "") catch |err| {
        try std.testing.expectEqual(error.McpToolExecutionFailed, err);
        return;
    };
    if (result) |payload| std.testing.allocator.free(payload);
    return error.TestExpectedExecutionFailure;
}

test "mcp resource read reports matched server execution failure" {
    const item =
        \\{"name":"broken-server","enabled":true,"transport":{"type":"stdio","command":"false","args":[],"cwd":"/tmp"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, item, .{});
    defer parsed.deinit();
    const result = mcpResourceReadFromCodexItem(std.testing.allocator, parsed.value, "broken-server", "file:///tmp/demo") catch |err| {
        try std.testing.expectEqual(error.McpToolExecutionFailed, err);
        return;
    };
    if (result) |payload| std.testing.allocator.free(payload);
    return error.TestExpectedExecutionFailure;
}

test "mcp tool call required params require thread id with JSON parsing" {
    try std.testing.expect(mcpToolCallHasRequiredParams(
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "mcpServer/tool/call",
        \\  "params": {
        \\    "threadId": "thread-1",
        \\    "server": "code-index",
        \\    "tool": "describe-index"
        \\  }
        \\}
    ));
    try std.testing.expect(!mcpToolCallHasRequiredParams(
        \\{"jsonrpc":"2.0","id":1,"method":"mcpServer/tool/call","params":{"server":"code-index","tool":"describe-index"}}
    ));
}

test "mcp resource read required params require server and uri" {
    try std.testing.expect(mcpResourceReadHasRequiredParams(
        \\{"jsonrpc":"2.0","id":1,"method":"mcpServer/resource/read","params":{"server":"code-index","uri":"file:///tmp/demo"}}
    ));
    try std.testing.expect(!mcpResourceReadHasRequiredParams(
        \\{"jsonrpc":"2.0","id":1,"method":"mcpServer/resource/read","params":{"uri":"file:///tmp/demo"}}
    ));
    try std.testing.expect(!mcpResourceReadHasRequiredParams(
        \\{"jsonrpc":"2.0","id":1,"method":"mcpServer/resource/read","params":{"server":"code-index"}}
    ));
}

test "mcp resources read result extraction supports text and blob contents" {
    const stdout =
        \\{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"fixture"}}}
        \\{"jsonrpc":"2.0","id":2,"result":{"contents":[{"uri":"file:///a.md","mimeType":"text/markdown","text":"hello"},{"uri":"file:///b.bin","mimeType":"application/octet-stream","blob":"AAEC"}]}}
    ;
    const out = (try mcpResultFieldJsonAlloc(std.testing.allocator, stdout, 2, null)) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"contents\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"text\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"blob\":\"AAEC\"") != null);
}

test "mcp status result extraction includes resources and templates" {
    const stdout =
        \\{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"fixture"}}}
        \\{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}
        \\{"jsonrpc":"2.0","id":3,"result":{"resources":[{"uri":"file:///a.md","name":"A"}]}}
        \\{"jsonrpc":"2.0","id":4,"result":{"resourceTemplates":[{"uriTemplate":"file:///{name}","name":"template"}]}}
    ;
    const resources = try mcpResultArrayFieldJsonAlloc(std.testing.allocator, stdout, 3, "resources", "");
    defer std.testing.allocator.free(resources);
    const templates = try mcpResultArrayFieldJsonAlloc(std.testing.allocator, stdout, 4, "resourceTemplates", "resource_templates");
    defer std.testing.allocator.free(templates);

    try std.testing.expect(std.mem.indexOf(u8, resources, "file:///a.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, templates, "uriTemplate") != null);
}
