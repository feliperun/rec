//! The Objective-C runtime entry points rec uses to drive Apple frameworks
//! that only have Objective-C APIs (CoreBluetooth, see src/ble.zig).
//! Hand-declared like m4a.zig's AudioToolbox externs: translate-c over
//! Apple framework headers is brittle. macOS only.

const std = @import("std");

pub const Id = ?*anyopaque;
pub const Sel = ?*anyopaque;

extern "c" fn objc_getClass(name: [*:0]const u8) Id;
extern "c" fn sel_registerName(name: [*:0]const u8) Sel;
extern "c" fn objc_allocateClassPair(superclass: Id, name: [*:0]const u8, extra_bytes: usize) Id;
extern "c" fn objc_registerClassPair(cls: Id) void;
extern "c" fn class_addMethod(cls: Id, name: Sel, imp: *const anyopaque, types: [*:0]const u8) u8;
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;
/// Never called through this signature: `send` casts it to the exact
/// signature of each message, as the runtime requires on arm64.
extern "c" fn objc_msgSend() void;

pub fn class(name: [*:0]const u8) Id {
    return objc_getClass(name);
}

/// Sends `sel` to `target` with `args` (a tuple of C-ABI values) and
/// returns `R`. Struct returns are not supported (they need
/// objc_msgSend_stret on x86_64), and no caller needs one.
pub fn send(comptime R: type, target: Id, comptime sel: [:0]const u8, args: anytype) R {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    const F = switch (fields.len) {
        0 => *const fn (Id, Sel) callconv(.c) R,
        1 => *const fn (Id, Sel, fields[0].type) callconv(.c) R,
        2 => *const fn (Id, Sel, fields[0].type, fields[1].type) callconv(.c) R,
        3 => *const fn (Id, Sel, fields[0].type, fields[1].type, fields[2].type) callconv(.c) R,
        else => @compileError("objc.send: add an arity"),
    };
    const f: F = @ptrCast(&objc_msgSend);
    return @call(.auto, f, .{ target, sel_registerName(sel) } ++ args);
}

pub const Method = struct {
    sel: [:0]const u8,
    imp: *const anyopaque,
    /// Objective-C type encoding, e.g. "v@:@" for `- (void)m:(id)a`.
    types: [:0]const u8,
};

/// Registers an NSObject subclass implementing `methods`, or returns the
/// class registered earlier under `name`.
pub fn defineClass(name: [*:0]const u8, methods: []const Method) Id {
    if (objc_getClass(name)) |existing| return existing;
    const cls = objc_allocateClassPair(objc_getClass("NSObject"), name, 0);
    for (methods) |m| _ = class_addMethod(cls, sel_registerName(m.sel), m.imp, m.types);
    objc_registerClassPair(cls);
    return cls;
}

/// An autoreleased NSString copy of `text`.
pub fn string(text: [*:0]const u8) Id {
    return send(Id, class("NSString"), "stringWithUTF8String:", .{text});
}

pub fn retain(obj: Id) Id {
    return send(Id, obj, "retain", .{});
}

pub fn release(obj: Id) void {
    send(void, obj, "release", .{});
}

/// Autoreleased objects created between `push` and `pop` are freed by `pop`.
pub fn push() ?*anyopaque {
    return objc_autoreleasePoolPush();
}

pub fn pop(pool: ?*anyopaque) void {
    objc_autoreleasePoolPop(pool);
}

test "messages reach Foundation objects" {
    const pool = push();
    defer pop(pool);
    const s = string("AF43");
    try std.testing.expectEqual(@as(usize, 4), send(usize, s, "length", .{}));
    const utf8 = send([*:0]const u8, s, "UTF8String", .{});
    try std.testing.expectEqualStrings("AF43", std.mem.span(utf8));
}
