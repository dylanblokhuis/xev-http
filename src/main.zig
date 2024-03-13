const std = @import("std");
const xev = @import("xev");

const net = std.net;
const Allocator = std.mem.Allocator;

const port = 3000;

const CompletionPool = std.heap.MemoryPoolExtra(xev.Completion, .{ .alignment = @alignOf(xev.Completion) });
const ClientPool = std.heap.MemoryPoolExtra(Client, .{ .alignment = @alignOf(Client) });

pub fn main() !void {
    var thread_pool = xev.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    var loop = try xev.Loop.init(.{
        .entries = 4096,
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const addr = try net.Address.parseIp4("0.0.0.0", port);
    var socket = try xev.TCP.init(addr);

    std.log.info("Listening on port {}", .{port});

    try socket.bind(addr);
    try socket.listen(std.os.linux.SOMAXCONN);
    var completion_pool = CompletionPool.init(alloc);
    var client_pool = ClientPool.init(alloc);

    while (true) {
        // std.log.info("Accepting new conn", .{});
        const c = try completion_pool.create();
        const client = try client_pool.create();

        client.* = Client{
            .loop = &loop,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .socket = undefined,
            .completion_pool = &completion_pool,
            .socket_pool = &client_pool,
        };
        socket.accept(&loop, c, Client, client, Client.acceptCallback);
        try loop.run(.once);
    }
}

const Client = struct {
    loop: *xev.Loop,
    arena: std.heap.ArenaAllocator,
    socket: xev.TCP = undefined,
    completion_pool: *CompletionPool,
    socket_pool: *ClientPool,

    fn acceptCallback(
        self_: ?*Client,
        l: *xev.Loop,
        c: *xev.Completion,
        r: xev.TCP.AcceptError!xev.TCP,
    ) xev.CallbackAction {
        const self = self_.?;
        self.socket = r catch unreachable;

        const httpOk =
            \\HTTP/1.1 200 OK
            \\Content-Type: text/plain
            \\Server: xev-http
            \\Content-Length: {d}
            \\
            \\{s}
        ;

        const content_str =
            \\Hello, World! {d}
        ;

        const content = std.fmt.allocPrint(self.arena.allocator(), content_str, .{0}) catch unreachable;
        const buf = std.fmt.allocPrint(self.arena.allocator(), httpOk, .{ content.len, content }) catch unreachable;

        self.socket.write(l, c, .{ .slice = buf }, Client, self, writeCallback);

        return .disarm;
    }

    fn writeCallback(
        self_: ?*Client,
        l: *xev.Loop,
        c: *xev.Completion,
        s: xev.TCP,
        buf: xev.WriteBuffer,
        r: xev.TCP.WriteError!usize,
    ) xev.CallbackAction {
        _ = buf; // autofix
        _ = r catch unreachable;

        // We do nothing for write, just put back objects into the pool.
        const self = self_.?;
        // self.completion_pool.destroy(c);
        s.shutdown(l, c, Client, self, shutdownCallback);
        // self.destroyBuf(buf.slice);

        return .disarm;
    }

    fn shutdownCallback(
        self_: ?*Client,
        l: *xev.Loop,
        c: *xev.Completion,
        s: xev.TCP,
        r: xev.TCP.ShutdownError!void,
    ) xev.CallbackAction {
        _ = r catch {};

        const self = self_.?;
        s.close(l, c, Client, self, closeCallback);
        return .disarm;
    }

    fn closeCallback(
        self_: ?*Client,
        l: *xev.Loop,
        c: *xev.Completion,
        socket: xev.TCP,
        r: xev.TCP.CloseError!void,
    ) xev.CallbackAction {
        _ = l;
        _ = r catch unreachable;
        _ = socket;

        var self = self_.?;
        self.arena.deinit();
        self.completion_pool.destroy(c);
        self.socket_pool.destroy(self);
        return .disarm;
    }
};
