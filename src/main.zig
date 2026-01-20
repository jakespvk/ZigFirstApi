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

    // try scaffoldDb(&app);

    var server = try httpz.Server(*App).init(allocator, .{ .port = 8080 }, &app);
    var router = try server.router(.{});
    router.get("/users", getUsers, .{});
    router.get("/users/:id", getUser, .{});
    router.get("/users/search", getUserQuery, .{});
    router.post("/users", createUser, .{});
    router.delete("/users/:id", deleteUser, .{});
    router.put("/users/:id", updateUser, .{});
    try server.listen();
}

const User = struct {
    id: i64,
    name: []const u8,
    email: []const u8,

    pub fn init(name: []const u8, email: []const u8) User {
        return .{ .name = name, .email = email };
    }
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
        const id: i64 = row.int(0);
        const name: []const u8 = try res.arena.dupe(u8, row.text(1));
        const email: []const u8 = try res.arena.dupe(u8, row.text(2));
        try users.append(res.arena, User{ .id = id, .name = name, .email = email });
    }
    const usersSlice = try users.toOwnedSlice(res.arena);
    try res.json(usersSlice, .{});
}

fn getUser(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id_param = req.param("id").?;
    var id: i64 = undefined;
    var name: []const u8 = undefined;
    var email: []const u8 = undefined;
    if (try app.conn.row("select * from user where id = (?1)", .{id_param})) |row| {
        defer row.deinit();
        id = row.int(0);
        name = try res.arena.dupe(u8, row.text(1));
        email = try res.arena.dupe(u8, row.text(2));
    } else {
        res.status = 404;
        return;
    }
    const user = User{ .id = id, .name = name, .email = email };
    try res.json(user, .{});
}

fn getUserQuery(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const query = try req.query();
    var id: i64 = undefined;
    var name: []const u8 = undefined;
    var email: []const u8 = undefined;
    if (query.get("id")) |query_id| {
        if (try app.conn.row("select * from user where id = (?1)", .{query_id})) |row| {
            defer row.deinit();
            id = row.int(0);
            name = try res.arena.dupe(u8, row.text(1));
            email = try res.arena.dupe(u8, row.text(2));
        } else {
            res.status = 404;
            return;
        }
    } else {
        res.status = 404;
        return;
    }
    const user = User{ .id = id, .name = name, .email = email };
    try res.json(user, .{});
}

fn validateEmail(email: []const u8) bool {
    if ((std.mem.indexOfScalar(u8, email, '@') != null) and (std.mem.indexOfScalar(u8, email, '.') != null)) {
        return true;
    }
    return false;
}
const CreateUserRequest = struct {
    name: []const u8,
    email: []const u8,
};

fn createUser(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (try req.json(CreateUserRequest)) |user| {
        if (validateEmail(user.email)) {
            try app.conn.exec("insert into user (name, email) values ((?1), (?2))", .{ user.name, user.email });
            res.status = 204;
        } else {
            res.status = 400;
        }
    }
}

fn deleteUser(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = req.param("id").?;
    app.conn.exec("delete from user where id = (?1)", .{id}) catch |err| {
        std.debug.print("{any}\n", .{err});
        res.status = 500;
        res.body = "ERROR!";
        return;
    };
    res.status = 204;
}

fn updateUser(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = req.param("id").?;
    if (try req.jsonObject()) |user| {
        const name = user.get("name");
        const email = user.get("email");
        if (name == null and email != null) {
            if (validateEmail(email.?.string)) {
                app.conn.exec("update user set email = (?1) where id = (?2)", .{ email.?.string, id }) catch |err| switch (err) {
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
                res.status = 204;
                return;
            }
        } else if (name != null and email == null) {
            app.conn.exec("update user set name = (?1) where id = (?2)", .{ name.?.string, id }) catch |err| switch (err) {
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
            res.status = 204;
            return;
        } else {
            if (validateEmail(email.?.string)) {
                app.conn.exec("update user set name = (?1), email = (?2) where id = (?3)", .{ name.?.string, email.?.string, id }) catch |err| switch (err) {
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
                res.status = 204;
                return;
            }
        }
    }
    res.status = 400;
}

fn scaffoldDb(app: *App) !void {
    try app.conn.exec("create table if not exists user (id integer primary key, name text, email text)", .{});
    try app.conn.exec("insert into user (name, email) values ((?1), (?2)), ((?3), (?4))", .{ "Jake", "jake@email.com", "Kimmy", "kimmy@email.com" });
}
