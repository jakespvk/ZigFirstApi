const std = @import("std");
const httpz = @import("httpz");

const App = struct {};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var app = App{};

    var server = try httpz.Server(*App).init(allocator, .{ .port = 8080 }, &app);
    var router = try server.router(.{});
    router.get("/", sayHello, .{});
    try server.listen();
}

fn sayHello(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const HelloStruct = struct {
        message: []const u8,
    };
    _ = app;
    _ = req;

    const hello = HelloStruct{ .message = "Hello, world!" };
    try res.json(hello, .{});
}
