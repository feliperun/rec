//! A Bluetooth LE central for one GATT service: find a peripheral by the
//! service UUID it advertises, connect, subscribe to every characteristic
//! that notifies, write commands, and receive notifications. Device
//! protocols live elsewhere (src/devices/); this layer knows only UUIDs.
//!
//! On macOS it drives CoreBluetooth through the Objective-C runtime
//! (src/objc.zig, docs/adr/0022). CoreBluetooth calls its delegate on the
//! main run loop, which only advances while `Link` is waiting, so a process
//! holds one link at a time. Other platforms report `error.Unsupported`.

const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag == .macos;

pub const Error = error{
    Unsupported,
    Unauthorized,
    BluetoothOff,
    NotFound,
    ConnectFailed,
    ServiceMissing,
    Disconnected,
    OutOfMemory,
};

pub const Spec = struct {
    /// Service UUID the peripheral advertises (16-bit or 128-bit form).
    advertised: [:0]const u8,
    /// GATT service holding `characteristics`.
    service: [:0]const u8,
    /// Characteristic UUIDs; notifications and writes refer to them by index.
    characteristics: []const [:0]const u8,
};

pub const Notification = struct {
    index: usize,
    /// Valid until the next `next` call.
    bytes: []const u8,
};

pub const Link = if (supported) MacLink else struct {
    pub const Error = ble_error;
    pub fn connect(io: std.Io, gpa: std.mem.Allocator, spec: Spec, timeout_s: ?f64) ble_error!@This() {
        _ = io;
        _ = gpa;
        _ = spec;
        _ = timeout_s;
        return error.Unsupported;
    }
    pub fn write(self: *@This(), index: usize, bytes: []const u8) ble_error!void {
        _ = self;
        _ = index;
        _ = bytes;
        return error.Unsupported;
    }
    pub fn next(self: *@This(), timeout_ms: u32) ble_error!?Notification {
        _ = self;
        _ = timeout_ms;
        return error.Unsupported;
    }
    pub fn close(self: *@This()) void {
        _ = self;
    }
};

const ble_error = Error;

// --- macOS: CoreBluetooth ----------------------------------------------------

const objc = if (supported) @import("objc.zig") else struct {
    pub const Id = ?*anyopaque;
};
const Id = objc.Id;
const Sel = ?*anyopaque;

extern "c" fn CFRunLoopRunInMode(mode: ?*const anyopaque, seconds: f64, return_after_source_handled: u8) i32;
extern "c" fn CFAbsoluteTimeGetCurrent() f64;
extern "c" const kCFRunLoopDefaultMode: ?*const anyopaque;
extern "c" fn usleep(usec: c_uint) c_int;

/// CBManagerState values.
const powered_on = 5;
const power_errors = [_]struct { state: isize, err: Error }{
    .{ .state = 2, .err = error.Unsupported },
    .{ .state = 3, .err = error.Unauthorized },
    .{ .state = 4, .err = error.BluetoothOff },
};
/// CBCharacteristicProperties notify | indicate.
const notifying = 0x10 | 0x20;
/// CBCharacteristicWriteWithoutResponse.
const write_without_response = 1;
const max_characteristics = 8;

const Item = struct {
    index: usize,
    bytes: []u8,
};

/// Everything the delegate callbacks write. One link per process (see the
/// module comment), so it is a single global.
const State = struct {
    gpa: std.mem.Allocator = undefined,
    central: Id = null,
    power: isize = 0,
    peripheral: Id = null,
    connected: bool = false,
    connect_failed: bool = false,
    disconnected: bool = false,
    services_found: bool = false,
    characteristics_found: bool = false,
    subscriptions: usize = 0,
    uuids: [max_characteristics]Id = @splat(null),
    characteristics: [max_characteristics]Id = @splat(null),
    count: usize = 0,
    queue: std.ArrayList(Item) = .empty,

    fn resetLink(self: *State) void {
        for (self.queue.items) |item| self.gpa.free(item.bytes);
        self.queue.deinit(self.gpa);
        for (self.uuids[0..self.count]) |u| objc.release(u);
        if (self.peripheral != null) objc.release(self.peripheral);
        self.* = .{ .gpa = self.gpa, .central = self.central, .power = self.power };
    }
};

var state: State = .{};

const MacLink = struct {
    pub const Error = ble_error;

    last: ?[]u8 = null,

    /// Scans for `spec.advertised` (for `timeout_s` seconds, or until found
    /// when null), connects to the first match, and subscribes to its
    /// notifying characteristics.
    pub fn connect(io: std.Io, gpa: std.mem.Allocator, spec: Spec, timeout_s: ?f64) ble_error!MacLink {
        _ = io; // CoreBluetooth runs on the main run loop, not on `io`.
        std.debug.assert(spec.characteristics.len <= max_characteristics);
        const pool = objc.push();
        defer objc.pop(pool);
        try powerOn(gpa);
        state.resetLink();
        errdefer cancel();

        const scan = objc.send(Id, objc.class("NSArray"), "arrayWithObject:", .{uuid(spec.advertised)});
        objc.send(void, state.central, "scanForPeripheralsWithServices:options:", .{ scan, @as(Id, null) });
        const found = pump(peripheralFound, timeout_s);
        objc.send(void, state.central, "stopScan", .{});
        if (!found) return error.NotFound;

        objc.send(void, state.central, "connectPeripheral:options:", .{ state.peripheral, @as(Id, null) });
        if (!pump(connectSettled, 15) or !state.connected) return error.ConnectFailed;

        objc.send(void, state.peripheral, "setDelegate:", .{delegate()});
        const wanted = objc.send(Id, objc.class("NSArray"), "arrayWithObject:", .{uuid(spec.service)});
        objc.send(void, state.peripheral, "discoverServices:", .{wanted});
        if (!pump(servicesFound, 10)) return error.ServiceMissing;
        const service = findService(spec.service) orelse return error.ServiceMissing;

        objc.send(void, state.peripheral, "discoverCharacteristics:forService:", .{ @as(Id, null), service });
        if (!pump(characteristicsFound, 10)) return error.ServiceMissing;
        try mapCharacteristics(service, spec.characteristics);

        var expected: usize = 0;
        for (state.characteristics[0..state.count]) |ch| {
            if (objc.send(usize, ch, "properties", .{}) & notifying == 0) continue;
            objc.send(void, state.peripheral, "setNotifyValue:forCharacteristic:", .{ @as(u8, 1), ch });
            expected += 1;
        }
        const Subscribed = struct {
            var want: usize = 0;
            fn done() bool {
                return state.subscriptions >= want;
            }
        };
        Subscribed.want = expected;
        if (!pump(Subscribed.done, 10)) return error.ConnectFailed;
        return .{};
    }

    pub fn write(self: *MacLink, index: usize, bytes: []const u8) ble_error!void {
        _ = self;
        if (state.disconnected) return error.Disconnected;
        const pool = objc.push();
        defer objc.pop(pool);
        const data = objc.send(Id, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, bytes.len });
        objc.send(void, state.peripheral, "writeValue:forCharacteristic:type:", .{ data, state.characteristics[index], @as(isize, write_without_response) });
    }

    /// The next notification, or null after `timeout_ms` without one.
    pub fn next(self: *MacLink, timeout_ms: u32) ble_error!?Notification {
        if (self.last) |b| state.gpa.free(b);
        self.last = null;
        if (state.queue.items.len == 0) {
            const pool = objc.push();
            defer objc.pop(pool);
            _ = pump(queued, @as(f64, @floatFromInt(timeout_ms)) / 1000.0);
        }
        if (state.queue.items.len == 0) {
            return if (state.disconnected) error.Disconnected else null;
        }
        const item = state.queue.orderedRemove(0);
        self.last = item.bytes;
        return .{ .index = item.index, .bytes = item.bytes };
    }

    pub fn close(self: *MacLink) void {
        if (self.last) |b| state.gpa.free(b);
        self.last = null;
        const pool = objc.push();
        defer objc.pop(pool);
        cancel();
    }
};

fn cancel() void {
    if (state.peripheral != null and !state.disconnected) {
        objc.send(void, state.central, "cancelPeripheralConnection:", .{state.peripheral});
        _ = pump(disconnected, 2);
    }
    state.resetLink();
}

/// Creates the central once per process and waits until the radio is
/// usable, mapping the states that never will be to errors.
fn powerOn(gpa: std.mem.Allocator) ble_error!void {
    if (state.central == null) {
        state.gpa = gpa;
        const alloc = objc.send(Id, objc.class("CBCentralManager"), "alloc", .{});
        state.central = objc.send(Id, alloc, "initWithDelegate:queue:", .{ delegate(), @as(Id, null) });
    }
    _ = pump(powerKnown, 10);
    for (power_errors) |p| if (state.power == p.state) return p.err;
    if (state.power != powered_on) return error.BluetoothOff;
}

/// Runs the main run loop until `done` holds, the link drops, or
/// `timeout_s` passes (null: no limit). Returns whether `done` held.
fn pump(comptime done: fn () bool, timeout_s: ?f64) bool {
    const deadline = if (timeout_s) |t| CFAbsoluteTimeGetCurrent() + t else null;
    while (!done()) {
        if (state.disconnected) return false;
        var slice: f64 = 0.1;
        if (deadline) |d| {
            const left = d - CFAbsoluteTimeGetCurrent();
            if (left <= 0) return false;
            slice = @min(slice, left);
        }
        // 1 = kCFRunLoopRunFinished: nothing to run yet, so do not spin.
        if (CFRunLoopRunInMode(kCFRunLoopDefaultMode, slice, 1) == 1) _ = usleep(10_000);
    }
    return true;
}

fn powerKnown() bool {
    return state.power >= 2; // past Unknown (0) and Resetting (1)
}
fn peripheralFound() bool {
    return state.peripheral != null;
}
fn connectSettled() bool {
    return state.connected or state.connect_failed;
}
fn servicesFound() bool {
    return state.services_found;
}
fn characteristicsFound() bool {
    return state.characteristics_found;
}
fn queued() bool {
    return state.queue.items.len > 0;
}
fn disconnected() bool {
    return state.disconnected;
}

fn uuid(text: [:0]const u8) Id {
    return objc.send(Id, objc.class("CBUUID"), "UUIDWithString:", .{objc.string(text)});
}

fn sameUuid(obj: Id, want: Id) bool {
    return objc.send(u8, objc.send(Id, obj, "UUID", .{}), "isEqual:", .{want}) != 0;
}

fn findService(text: [:0]const u8) ?Id {
    const want = uuid(text);
    const services = objc.send(Id, state.peripheral, "services", .{});
    const n = objc.send(usize, services, "count", .{});
    for (0..n) |i| {
        const s = objc.send(Id, services, "objectAtIndex:", .{i});
        if (sameUuid(s, want)) return s;
    }
    return null;
}

/// Fills `state.characteristics` in `wanted` order from the service.
fn mapCharacteristics(service: Id, wanted: []const [:0]const u8) ble_error!void {
    const found = objc.send(Id, service, "characteristics", .{});
    const n = objc.send(usize, found, "count", .{});
    for (wanted, 0..) |text, i| {
        state.uuids[i] = objc.retain(uuid(text));
        state.count = i + 1;
        for (0..n) |j| {
            const ch = objc.send(Id, found, "objectAtIndex:", .{j});
            if (sameUuid(ch, state.uuids[i])) state.characteristics[i] = ch;
        }
        if (state.characteristics[i] == null) return error.ServiceMissing;
    }
}

fn indexOf(characteristic: Id) ?usize {
    for (state.uuids[0..state.count], 0..) |u, i| {
        if (sameUuid(characteristic, u)) return i;
    }
    return null;
}

// --- delegate ----------------------------------------------------------------

fn delegate() Id {
    const Static = struct {
        var instance: Id = null;
    };
    if (Static.instance == null) {
        const cls = objc.defineClass("RecBleDelegate", &.{
            .{ .sel = "centralManagerDidUpdateState:", .imp = @ptrCast(&didUpdateState), .types = "v@:@" },
            .{ .sel = "centralManager:didDiscoverPeripheral:advertisementData:RSSI:", .imp = @ptrCast(&didDiscover), .types = "v@:@@@@" },
            .{ .sel = "centralManager:didConnectPeripheral:", .imp = @ptrCast(&didConnect), .types = "v@:@@" },
            .{ .sel = "centralManager:didFailToConnectPeripheral:error:", .imp = @ptrCast(&didFailToConnect), .types = "v@:@@@" },
            .{ .sel = "centralManager:didDisconnectPeripheral:error:", .imp = @ptrCast(&didDisconnect), .types = "v@:@@@" },
            .{ .sel = "peripheral:didDiscoverServices:", .imp = @ptrCast(&didDiscoverServices), .types = "v@:@@" },
            .{ .sel = "peripheral:didDiscoverCharacteristicsForService:error:", .imp = @ptrCast(&didDiscoverCharacteristics), .types = "v@:@@@" },
            .{ .sel = "peripheral:didUpdateNotificationStateForCharacteristic:error:", .imp = @ptrCast(&didUpdateNotificationState), .types = "v@:@@@" },
            .{ .sel = "peripheral:didUpdateValueForCharacteristic:error:", .imp = @ptrCast(&didUpdateValue), .types = "v@:@@@" },
        });
        Static.instance = objc.send(Id, objc.send(Id, cls, "alloc", .{}), "init", .{});
    }
    return Static.instance;
}

fn didUpdateState(_: Id, _: Sel, central: Id) callconv(.c) void {
    state.power = objc.send(isize, central, "state", .{});
}

fn didDiscover(_: Id, _: Sel, _: Id, peripheral: Id, _: Id, _: Id) callconv(.c) void {
    // CoreBluetooth drops a connection whose peripheral nobody retains.
    if (state.peripheral == null) state.peripheral = objc.retain(peripheral);
}

fn didConnect(_: Id, _: Sel, _: Id, _: Id) callconv(.c) void {
    state.connected = true;
}

fn didFailToConnect(_: Id, _: Sel, _: Id, _: Id, _: Id) callconv(.c) void {
    state.connect_failed = true;
}

fn didDisconnect(_: Id, _: Sel, _: Id, _: Id, _: Id) callconv(.c) void {
    state.disconnected = true;
}

fn didDiscoverServices(_: Id, _: Sel, _: Id, _: Id) callconv(.c) void {
    state.services_found = true;
}

fn didDiscoverCharacteristics(_: Id, _: Sel, _: Id, _: Id, _: Id) callconv(.c) void {
    state.characteristics_found = true;
}

fn didUpdateNotificationState(_: Id, _: Sel, _: Id, _: Id, _: Id) callconv(.c) void {
    state.subscriptions += 1;
}

fn didUpdateValue(_: Id, _: Sel, _: Id, characteristic: Id, err: Id) callconv(.c) void {
    if (err != null) return;
    const index = indexOf(characteristic) orelse return;
    const value = objc.send(Id, characteristic, "value", .{});
    const len = objc.send(usize, value, "length", .{});
    const ptr = objc.send(?[*]const u8, value, "bytes", .{});
    const bytes = state.gpa.dupe(u8, if (ptr) |p| p[0..len] else &.{}) catch return;
    state.queue.append(state.gpa, .{ .index = index, .bytes = bytes }) catch state.gpa.free(bytes);
}
