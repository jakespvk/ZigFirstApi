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

    try createDb(&app);
    // try createData(&app);

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
    subscription: ?Subscription,
    dbAdapter: ?DatabaseAdapter,

    pub fn init(name: []const u8, email: []const u8) User {
        return .{ .name = name, .email = email };
    }
};

const Subscription = struct {
    rowLimit: ?u16,
    columnLimit: ?u16,
    pollFrequency: ?bool,
    subscribed: bool,
};

const DatabaseAdapter = struct {
    columns: ?[][]const u8,
    activeColumns: ?[][]const u8,
    dbType: DbType,

    pub fn getColumns(self: DatabaseAdapter) ![][]const u8 {
        _ = self;
    }

    pub fn setActiveColumns(self: *DatabaseAdapter) ![][]const u8 {
        _ = self;
    }

    pub fn getData(self: DatabaseAdapter) !std.json.ObjectMap {
        _ = self;
    }
};

const DbType = enum {
    None,
    Attio,
    ActiveCampaign,
};

fn getUsers(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    var rows = try app.conn.rows("select * from user as u inner join subscription as s on u.id = s.user_id inner join db_adapter as d on u.id = d.user_id order by u.name", .{});
    defer rows.deinit();
    if (rows.err) |err| {
        res.status = 500;
        try res.json(err, .{});
        return;
    }
    var users = try std.ArrayList(User).initCapacity(res.arena, 4);
    defer users.deinit(res.arena);
    while (rows.next()) |row| {
        try users.append(res.arena, User{
            .id = row.int(0),
            .name = try res.arena.dupe(u8, row.text(1)),
            .email = try res.arena.dupe(u8, row.text(2)),
            .subscription = Subscription{
                .subscribed = row.get(bool, 3),
                .columnLimit = row.int(4),
                .rowLimit = row.int(5),
                .pollFrequency = row.boolean(6),
            },
            .dbAdapter = DatabaseAdapter{
                .dbType = try res.arena.dupe(u8, row.text(7)),
            },
        });
    }
    const usersSlice = try users.toOwnedSlice(res.arena);
    try res.json(usersSlice, .{});
}

fn getUser(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id_param = req.param("id").?;
    var user: User = undefined;
    if (try app.conn.row("select * from user where id = (?1)", .{id_param})) |row| {
        defer row.deinit();
        user.id = row.int(0);
        user.name = try res.arena.dupe(u8, row.text(1));
        user.email = try res.arena.dupe(u8, row.text(2));
        user.subscription = Subscription{
            .subscribed = row.boolean(3),
            .columnLimit = row.int(4),
            .rowLimit = row.int(5),
            .pollFrequency = row.boolean(6),
        };
        user.dbAdapter = DatabaseAdapter{
            .dbType = row.text(7),
        };
    } else {
        res.status = 404;
        return;
    }
    try res.json(user, .{});
}

fn getUserQuery(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const query = try req.query();
    var user: User = undefined;
    if (query.get("id")) |query_id| {
        if (try app.conn.row("select * from user where id = (?1)", .{query_id})) |row| {
            defer row.deinit();
            user.id = row.int(0);
            user.name = try res.arena.dupe(u8, row.text(1));
            user.email = try res.arena.dupe(u8, row.text(2));
            user.subscription = Subscription{
                .subscribed = row.boolean(3),
                .columnLimit = row.int(4),
                .rowLimit = row.int(5),
                .pollFrequency = row.boolean(6),
            };
            user.dbAdapter = DatabaseAdapter{
                .dbType = row.text(7),
            };
        } else {
            res.status = 404;
            return;
        }
    } else {
        res.status = 404;
        return;
    }
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

fn createDb(app: *App) !void {
    try app.conn.exec("create table if not exists user (id integer primary key, name text not null, email text not null)", .{});
    try app.conn.exec("create table if not exists subscription (id integer primary key, user_id integer not null, subscribed boolean, row_limit integer, column_limit integer, poll_frequency boolean, foreign key(user_id) references user(id))", .{});
    try app.conn.exec("create table if not exists database_adapter (id integer primary key, user_id integer not null, type text check(type in ('None', 'Attio','ActiveCampaign')) default 'None', foreign key(user_id) references user(id))", .{});
}

fn createData(app: *App) !void {
    try app.conn.exec("insert into user (name, email) values ((?1), (?2)), ((?3), (?4))", .{ "Jake", "jake@email.com", "Kimmy", "kimmy@email.com" });
}
