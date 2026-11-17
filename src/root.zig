//! hsx — hash-based proof-of-work challenges.
//!
//! A server issues a random `Challenge` (seed + difficulty) and the client
//! searches for a `Proof` whose hash has at least `difficulty` leading zero
//! bits. Verification is a single hash. The library holds no state: expiry,
//! one-time use, and rate limiting remain server responsibilities.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Issued by the server. `difficulty` is the required number of leading zero
/// bits in SHA-256(seed || nonce).
pub const Challenge = struct {
    seed: [32]u8,
    difficulty: u8,

    /// Hex: <64 hex chars of seed>:<difficulty decimal>.
    pub fn encode(self: Challenge, out: *[68]u8) []const u8 {
        const hex = std.fmt.bytesToHex(self.seed, .lower);
        return std.fmt.bufPrint(out, "{s}:{d}", .{ &hex, self.difficulty }) catch unreachable;
    }

    pub fn decode(text: []const u8) !Challenge {
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidChallenge;
        if (colon != 64) return error.InvalidChallenge;
        var seed: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&seed, text[0..colon]) catch return error.InvalidChallenge;
        const difficulty = std.fmt.parseInt(u8, text[colon + 1 ..], 10) catch return error.InvalidChallenge;
        return .{ .seed = seed, .difficulty = difficulty };
    }
};

/// Found by the client: the nonce that satisfies the challenge.
pub const Proof = struct {
    nonce: u64,

    /// Hex: <16 hex chars>, big-endian nonce.
    pub fn encode(self: Proof, out: *[16]u8) []const u8 {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, self.nonce, .big);
        const hex = std.fmt.bytesToHex(bytes, .lower);
        @memcpy(out, &hex);
        return out;
    }

    pub fn decode(text: []const u8) !Proof {
        if (text.len != 16) return error.InvalidProof;
        var bytes: [8]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, text) catch return error.InvalidProof;
        return .{ .nonce = std.mem.readInt(u64, &bytes, .big) };
    }
};

/// Generates a fresh challenge with a secure random 32-byte seed.
pub fn generate(io: std.Io, difficulty: u8) !Challenge {
    var seed: [32]u8 = undefined;
    try io.randomSecure(&seed);
    return .{ .seed = seed, .difficulty = difficulty };
}

fn digest(challenge: Challenge, nonce: u64, out: *[32]u8) void {
    var hasher = Sha256.init(.{});
    hasher.update(&challenge.seed);
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, nonce, .big);
    hasher.update(&buf);
    hasher.final(out);
}

fn leading_zero_bits(hash: *const [32]u8) u16 {
    var count: u16 = 0;
    for (hash) |byte| {
        if (byte == 0) {
            count += 8;
        } else {
            count += @intCast(@clz(byte));
            break;
        }
    }
    return count;
}

fn meets(hash: *const [32]u8, difficulty: u8) bool {
    return leading_zero_bits(hash) >= difficulty;
}

/// Server-side check: true iff the proof satisfies the challenge.
pub fn verify(challenge: Challenge, proof: Proof) bool {
    var hash: [32]u8 = undefined;
    digest(challenge, proof.nonce, &hash);
    return meets(&hash, challenge.difficulty);
}

/// Incremental proof search. Call `next` repeatedly to advance the search;
/// start multiple solvers at disjoint nonces to parallelise across threads.
pub const Solver = struct {
    challenge: Challenge,
    current: u64,
    exhausted: bool = false,

    pub fn init(challenge: Challenge, start_nonce: u64) Solver {
        return .{ .challenge = challenge, .current = start_nonce };
    }

    /// Searches up to `attempts` nonces from the current position. Returns the
    /// proof on success, otherwise null. `current` advances past every tried
    /// nonce, so the caller can resume or report progress.
    pub fn next(self: *Solver, attempts: usize) ?Proof {
        if (self.exhausted) return null;
        var hash: [32]u8 = undefined;
        var i: usize = 0;
        while (i < attempts) : (i += 1) {
            const nonce = self.current;
            digest(self.challenge, nonce, &hash);
            if (nonce == std.math.maxInt(u64)) {
                self.exhausted = true;
            } else {
                self.current += 1;
            }
            if (meets(&hash, self.challenge.difficulty)) return .{ .nonce = nonce };
            if (self.exhausted) return null;
        }
        return null;
    }

    pub fn current_nonce(self: *const Solver) u64 {
        return self.current;
    }
};

test "encode/decode round trips" {
    const c = Challenge{ .seed = @splat(0xab), .difficulty = 12 };
    var cbuf: [68]u8 = undefined;
    const ctext = c.encode(&cbuf);
    try std.testing.expectEqual(c.difficulty, (try Challenge.decode(ctext)).difficulty);
    try std.testing.expectEqualSlices(u8, &c.seed, &(try Challenge.decode(ctext)).seed);

    const p = Proof{ .nonce = 0x0123456789abcdef };
    var pbuf: [16]u8 = undefined;
    const ptext = p.encode(&pbuf);
    try std.testing.expectEqual(p.nonce, (try Proof.decode(ptext)).nonce);
}

test "solver finds and verifies a proof" {
    const challenge = Challenge{ .seed = @splat(0), .difficulty = 8 };
    var solver = Solver.init(challenge, 0);
    const proof = solver.next(100_000) orelse return error.NoProofFound;
    try std.testing.expect(verify(challenge, proof));

    var bad_nonce = proof.nonce +% 1;
    while (verify(challenge, .{ .nonce = bad_nonce })) : (bad_nonce +%= 1) {}
    try std.testing.expect(!verify(challenge, .{ .nonce = bad_nonce }));
}

test "difficulty zero accepts the initial nonce" {
    const challenge = Challenge{ .seed = @splat(0), .difficulty = 0 };
    var solver = Solver.init(challenge, 42);
    try std.testing.expectEqual(@as(?Proof, .{ .nonce = 42 }), solver.next(1));
    try std.testing.expectEqual(@as(u64, 43), solver.current_nonce());
}

test "solver resumes after an unsuccessful batch" {
    const challenge = Challenge{ .seed = @splat(0), .difficulty = 255 };
    var solver = Solver.init(challenge, 100);
    try std.testing.expect(solver.next(50) == null);
    try std.testing.expectEqual(@as(u64, 150), solver.current_nonce());
}

test "invalid encoded inputs" {
    try std.testing.expectError(error.InvalidChallenge, Challenge.decode("nothex:8"));
    try std.testing.expectError(error.InvalidProof, Proof.decode("123"));
}
