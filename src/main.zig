const std = @import("std");
const httpz = @import("httpz");
const zqlite = @import("zqlite");

const App = struct {
    conn: zqlite.Conn,
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
    var conn = try zqlite.open("test.sqlite", flags);
    defer conn.close();

    var app = App{
        .conn = conn,
    };

    var server = try httpz.Server(*App).init(allocator, .{ .port = 8080 }, &app);
    var router = try server.router(.{});
    router.get("/", sayHello, .{});
    router.get("/users", getUsers, .{});
    router.get("/users/:name", getUser, .{});
    router.get("/users/search", getUserQuery, .{});
    router.post("/users", createUser, .{});
    router.delete("/users/:name", deleteUser, .{});
    router.put("/users/:name", updateUser, .{});
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

const User = struct {
    name: []const u8,
};

fn getUsers(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    var rows = try app.conn.rows("select * from user order by name", .{});
    defer rows.deinit();
    if (rows.err) |err| {
        res.status = 500;
        try res.json(err, .{});
        return;
    }
    var users = try std.ArrayList(User).initCapacity(res.arena, 4);
    defer users.deinit(res.arena);
    while (rows.next()) |row| {
        const name: []const u8 = try res.arena.dupe(u8, row.text(0));
        try users.append(res.arena, User{ .name = name });
    }
    const usersSlice = try users.toOwnedSlice(res.arena);
    try res.json(usersSlice, .{});
}

fn getUser(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name_param = req.param("name").?;
    var name: []const u8 = undefined;
    if (try app.conn.row("select * from user where name = (?1) collate nocase", .{name_param})) |row| {
        defer row.deinit();
        name = try res.arena.dupe(u8, row.text(0));
    } else {
        res.status = 404;
        return;
    }
    const user = User{ .name = name };
    try res.json(user, .{});
}

fn getUserQuery(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const query = try req.query();
    var name: []const u8 = undefined;
    if (query.get("name")) |name_param| {
        if (try app.conn.row("select * from user where name = (?1)", .{name_param})) |row| {
            defer row.deinit();
            name = try res.arena.dupe(u8, row.text(0));
        } else {
            res.status = 404;
            return;
        }
    } else {
        res.status = 404;
        return;
    }
    const user = User{ .name = name };
    try res.json(user, .{});
}

const CreateUserRequest = struct {
    name: []const u8,
};

fn createUser(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (try req.json(CreateUserRequest)) |user| {
        try app.conn.exec("insert into user values (?1)", .{user.name});
    }
    res.status = 204;
}

fn deleteUser(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name_param = req.param("name").?;
    app.conn.exec("delete from user where name = (?1) collate nocase", .{name_param}) catch |err| {
        std.debug.print("{any}\n", .{err});
        res.status = 500;
        res.body = "ERROR!";
        return;
    };
    res.status = 204;
}

const UpdateUserRequest = struct {
    name: []const u8,
};

fn updateUser(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name_param = req.param("name").?;
    if (try req.json(UpdateUserRequest)) |user| {
        app.conn.exec("update user set name = (?1) where name = (?2) collate nocase", .{ user.name, name_param }) catch |err| switch (err) {
            error.Notfound, error.Empty => {
                res.status = 404;
                return;
            },
            else => {
                std.debug.print("{any}\n", .{err});
                res.status = 500;
                return;
            },
        };
    } else {
        res.status = 400;
        return;
    }
    res.status = 204;
}

fn scaffoldDb(app: *App) !void {
    try app.conn.exec("create table if not exists user (name text)", .{});
    try app.conn.exec("insert into user values (?1), (?2)", .{ "Jake", "Kimmy" });
}
