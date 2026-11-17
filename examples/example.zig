//! `zig build example` — the full client/server proof-of-work flow.

const std = @import("std");
const hsx = @import("hsx");

fn serverVerify(c: hsx.Challenge, p: hsx.Proof, label: []const u8) !void {
    const ok = hsx.verify(c, p);
    std.debug.print("  server verify {s}: {s}\n", .{ label, if (ok) "accepted" else "REJECTED" });
    if (!ok) return error.VerificationFailed;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const difficulty: u8 = 16;

    // 1. Server creates a challenge and sends its encoded form to the client.
    const challenge = try hsx.generate(io, difficulty);
    var cbuf: [68]u8 = undefined;
    const ctext = challenge.encode(&cbuf);
    std.debug.print("challenge: {s}\n", .{ctext});

    // 2. Client decodes it and solves with an incremental solver.
    const decoded = try hsx.Challenge.decode(ctext);
    var solver = hsx.Solver.init(decoded, 0);
    const proof = solver.next(2_000_000) orelse return error.BudgetExhausted;
    var pbuf: [16]u8 = undefined;
    const ptext = proof.encode(&pbuf);
    std.debug.print("proof: {s}  (nonce searched: {d})\n", .{ ptext, solver.current_nonce() });

    // 3. Server decodes and verifies the proof.
    try serverVerify(decoded, try hsx.Proof.decode(ptext), "encoded proof");

    // 4. Parallel solve: split the nonce space across threads.
    const threads = 4;
    const stride: u64 = 1 << 32;
    const Shared = struct {
        challenge: hsx.Challenge,
        // Only the first thread to publish a nonce wins. maxInt means "none".
        found: std.atomic.Value(u64) = std.atomic.Value(u64).init(std.math.maxInt(u64)),

        fn worker(self: *@This(), start: u64) void {
            var s = hsx.Solver.init(self.challenge, start);
            while (self.found.load(.acquire) == std.math.maxInt(u64)) {
                const p = s.next(50_000) orelse continue;
                _ = self.found.cmpxchgStrong(std.math.maxInt(u64), p.nonce, .release, .monotonic);
                return;
            }
        }
    };
    var shared = Shared{ .challenge = decoded };
    var handles: [threads]std.Thread = undefined;
    for (0..threads) |i| handles[i] = try std.Thread.spawn(.{}, Shared.worker, .{ &shared, @as(u64, i) * stride });
    for (handles) |handle| handle.join();
    const parallel_nonce = shared.found.load(.acquire);
    if (parallel_nonce != std.math.maxInt(u64)) {
        std.debug.print("parallel proof: nonce={d}\n", .{parallel_nonce});
        try serverVerify(decoded, .{ .nonce = parallel_nonce }, "parallel proof");
    } else {
        std.debug.print("parallel: no proof found in budget\n", .{});
    }

    // 5. A tampered proof is rejected.
    if (hsx.verify(decoded, .{ .nonce = proof.nonce +% 1 })) return error.TamperAccepted;
    std.debug.print("tampered proof: rejected (as expected)\n", .{});
}
