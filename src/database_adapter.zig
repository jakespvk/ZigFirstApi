const std = @import("std");
const DatabaseAdapter = @This();

connection: *anyopaque,
getColumnsOpaquePtr: *const fn (ptr: *anyopaque) [][]const u8,

pub fn init(db_adapter_ptr: anytype) DatabaseAdapter {
    const T = @TypeOf(db_adapter_ptr);

    const gen = struct {
        fn getColumnsOpaque(ptr: *anyopaque) [][]const u8 {
            const db_adapter: T = @ptrCast(@alignCast(ptr));
            db_adapter.getColumns();
        }
    };

    return DatabaseAdapter{
        .connection = db_adapter_ptr,
        .getColumnsOpaquePtr = gen.getColumnsOpaque,
    };
}

pub fn getColumns(self: DatabaseAdapter) ![][]const u8 {
    self.getColumnsOpaquePtr(self.connection);
    const client = std.http.Client.connectTcp(self.connection);
    _ = client;
}
