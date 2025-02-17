const std = @import("std");
const WasmAllocator = @import("WasmAllocator.zig");
const utils = @import("utils.zig");

const HashMap = std.HashMap;
pub const Address: type = [20]u8;

const AddressUtils = utils.AddressUtils;
const U256Utils = utils.U256Utils;

pub const SolStorageType = enum {
    U256Storage,
    AddressStorage,
    MappingStorage,
};

pub const U256Storage = struct {
    offset: [32]u8,
    cache: []u8,
    const inner_type: type = u256;

    pub fn init(offset_value: [32]u8) @This() {
        return .{
            .offset = offset_value,
            .cache = undefined,
        };
    }

    pub fn set_value(self: *@This(), value: u256) !void {
        const offset_bytes = try utils.bytes32ToBytes(self.offset);
        const value_bytes = try utils.u256ToBytes(value);
        try utils.write_storage(offset_bytes, value_bytes);
        if (utils.isSliceUndefined(self.cache)) {
            self.cache = utils.allocator.alloc(u8, 32) catch return error.OutOfMemory;
        }
        self.cache = value_bytes;
    }

    pub fn get_value(self: *@This()) !u256 {
        if (utils.isSliceUndefined(self.cache)) {
            const offset_bytes = try utils.bytes32ToBytes(self.offset);
            self.cache = try utils.read_storage(offset_bytes);
        }
        return utils.bytesToU256(self.cache);
    }
};

pub const AddressStorage = struct {
    offset: [32]u8,
    cache: []u8,
    const inner_type: type = Address;

    pub fn init(offset_value: [32]u8) @This() {
        return .{
            .offset = offset_value,
            .cache = undefined,
        };
    }

    pub fn set_value(self: *@This(), value: Address) !void {
        const offset_bytes = try utils.bytes32ToBytes(self.offset);
        const address_bytes = try utils.addressToBytes(value);
        try utils.write_storage(offset_bytes, address_bytes);
        if (utils.isSliceUndefined(self.cache)) {
            self.cache = utils.allocator.alloc(u8, 32) catch return error.OutOfMemory;
        }
        self.cache = address_bytes;
    }

    pub fn get_value(self: *@This()) !Address {
        if (utils.isSliceUndefined(self.cache)) {
            const offset_bytes = try utils.bytes32ToBytes(self.offset);
            self.cache = try utils.read_storage(offset_bytes);
        }
        const result = utils.bytesToAddress(self.cache);
        return result;
    }
};

const MappingInfo = struct {
    ValueInnerType: type,
    value_utils: type,
};

const NestedMappingInfo = struct {
    ValueInnerType: type,
    nested_key_type: type,
    nested_value_type: type,
};

pub fn MappingStorage(comptime KeyType: type, comptime ValueStorageType: type) type {
    const value_inner_type: type = ValueStorageType.inner_type;
    const key_utils = utils.getValueUtils(KeyType);
    const value_utils = utils.getValueUtils(value_inner_type);
    const converter_type = struct {
        key_utils: key_utils,
        value_utils: value_utils,
    };

    return struct {
        offset: [32]u8,
        cache: std.AutoHashMap(KeyType, ValueStorageType),
        converter: converter_type,
        const inner_type: type = @TypeOf(@This());
        const ValueInnerType: type = value_inner_type;

        pub fn init(offset: [32]u8) @This() {
            return .{ .offset = offset, .cache = undefined, .converter = .{
                .key_utils = key_utils{},
                .value_utils = value_utils{},
            } };
        }

        fn compute_mapping_slot(slot: [32]u8, key: []const u8) ![32]u8 {
            var concat = try utils.allocator.alloc(u8, 32 + key.len);
            defer utils.allocator.free(concat);

            std.mem.copyForwards(u8, concat[0..32], &slot);
            std.mem.copyForwards(u8, concat[32..], key);

            return utils.keccak256(concat);
        }

        pub fn setter(self: *@This(), key: KeyType) !ValueStorageType {
            const key_bytes = try self.converter.key_utils.to_bytes(key);
            const slot_key_offset = try compute_mapping_slot(self.offset, key_bytes);
            const result = ValueStorageType.init(slot_key_offset);
            return result;
        }

        // if it is nested mapping, this can't be called.
        pub fn get(self: *@This(), key: KeyType) !ValueInnerType {
            if (!utils.is_primitives(ValueInnerType)) {
                @panic("Can't get value from nested mapping");
            }
            const key_bytes = try self.converter.key_utils.to_bytes(key);
            const slot_key_offset = try compute_mapping_slot(self.offset, key_bytes);
            var storage_helper = ValueStorageType.init(slot_key_offset);
            const result = storage_helper.get_value();
            return result;
        }

        // This will only be called when mapping is nested.
        pub fn get_value(self: *@This()) !ValueInnerType {
            return self;
        }

        // pub fn remove(self: *@This(), key: KeyType) !void {
        //     const key_bytes = try self.converter.key_utils.to_bytes(key);
        //     const slot_key_offset = try compute_mapping_slot(self.offset, key_bytes);
        //     var storage_helper = ValueStorageType.init(slot_key_offset);
        //     try storage_helper.set_value(utils.ZERO_BYTES);
        // }
    };
}

// Define mixin for shared initialization behavior
pub fn SolStorage(comptime Self: type) type {
    return struct {
        pub fn init() Self {
            var result: Self = undefined;
            comptime var offset: u32 = 0;
            inline for (std.meta.fields(Self)) |field| {
                @field(result, field.name) = switch (field.type) {
                    U256Storage => field.type.init(utils.u32ToBytes32(offset)),
                    AddressStorage => field.type.init(utils.u32ToBytes32(offset)),
                    // Todo, support edge case.
                    else => blk: {
                        const offset_bytes = utils.u32ToBytes32(offset);
                        break :blk field.type.init(offset_bytes);
                    },
                };
                offset += 1;
            }
            return result;
        }
    };
}
