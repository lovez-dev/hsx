//! Benchmarks proof search and verification with zlap.
const std = @import("std");
const builtin = @import("builtin");
const bench = @import("zlap");
const hsx = @import("hsx");

var benchmark_io: std.Io = undefined;
var benchmark_challenge: hsx.Challenge = .{ .seed = @splat(0), .difficulty = 0 };

const Case = enum {
    solve,
    verify,

    fn workload(comptime kind: Case) bench.Workload {
        return struct {
            fn run(allocator: std.mem.Allocator, count: usize) !void {
                _ = allocator;
                for (0..count) |_| {
                    switch (kind) {
                        .solve => {
                            var solver = hsx.Solver.init(benchmark_challenge, 0);
                            const proof = solver.next(1) orelse continue;
                            std.mem.doNotOptimizeAway(proof);
                        },
                        .verify => {
                            const ok = hsx.verify(benchmark_challenge, .{ .nonce = 42 });
                            std.mem.doNotOptimizeAway(ok);
                        },
                    }
                }
            }
        }.run;
    }
};

pub fn main(init: std.process.Init) !void {
    if (builtin.mode != .fast) return error.UseReleaseFast;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var sample_count: usize = 20;
    var format: enum { table, markdown, json } = .table;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.MissingValue;
        if (std.mem.eql(u8, args[i], "--sample-count")) {
            sample_count = try std.fmt.parseInt(usize, args[i + 1], 10);
            if (sample_count == 0 or sample_count > bench.SAMPLE_SIZE / 3) return error.InvalidSampleCount;
        } else if (std.mem.eql(u8, args[i], "--format")) {
            format = std.meta.stringToEnum(@TypeOf(format), args[i + 1]) orelse return error.InvalidFormat;
        } else return error.UnexpectedArgument;
    }
    benchmark_io = init.io;
    defer benchmark_io = undefined;
    benchmark_challenge = try hsx.generate(init.io, 16);

    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &output.interface;
    if (format == .json) try writer.writeAll("[\n");
    if (format == .markdown) try writer.writeAll("| Case | Mean ns/op | Median ns/op | p95 ns/op |\n| --- | ---: | ---: | ---: |\n");
    inline for (comptime std.meta.tags(Case), 0..) |kind, index| {
        const result = try bench.runConfigured(init.io, .{
            .allocator = init.gpa,
            .batch_size = 1000,
            .warmup_batches = 3,
            .sample_count = sample_count,
            .batch_repeats = 1,
            .min_sample_ns = std.time.ns_per_ms,
            .rounds = 3,
            .count_allocations = false,
        }, kind.workload());
        switch (format) {
            .table => try writer.print("{s}: mean={d:.2} ns/op, median={d:.2}, p95={d:.2}\n", .{ @tagName(kind), result.mean(), result.median(), result.percentile(95) }),
            .markdown => try writer.print("| {s} | {d:.2} | {d:.2} | {d:.2} |\n", .{ @tagName(kind), result.mean(), result.median(), result.percentile(95) }),
            .json => try writer.print("{s}  {{\"case\":\"{s}\",\"mean_ns\":{d},\"median_ns\":{d},\"p95_ns\":{d}}}", .{ if (index == 0) "" else ",\n", @tagName(kind), result.mean(), result.median(), result.percentile(95) }),
        }
    }
    if (format == .json) try writer.writeAll("\n]\n");
    try writer.flush();
}
