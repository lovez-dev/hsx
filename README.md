# hsx

Hash-based proof-of-work challenges for rate limiting and abuse prevention.

A server issues a random challenge. The client incrementally searches for a nonce whose `SHA-256(seed || nonce)` has the required number of leading zero bits. The server verifies the result with one hash and keeps all policy state itself.

## Install

```sh
zig fetch --save "git+https://github.com/lovez-dev/hsx#main"
```

```zig
const dep = b.dependency("hsx", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("hsx", dep.module("hsx"));
```

## Use

The server creates and serializes a challenge, sends it to the client, then verifies the returned proof:

```zig
const hsx = @import("hsx");

const challenge = try hsx.generate(io, 16);
var challenge_buffer: [68]u8 = undefined;
const challenge_text = challenge.encode(&challenge_buffer);

// Send challenge_text to the client.
// The client decodes it and searches incrementally.
const received_challenge = try hsx.Challenge.decode(challenge_text);
var solver = hsx.Solver.init(received_challenge, 0);
const proof = solver.next(100_000) orelse return error.BudgetExhausted;

var proof_buffer: [16]u8 = undefined;
const proof_text = proof.encode(&proof_buffer);

// Receive proof_text on the server and verify it before accepting the request.
const received_proof = try hsx.Proof.decode(proof_text);
if (!hsx.verify(received_challenge, received_proof)) return error.InvalidProof;
```

`Solver.next(attempts)` searches at most the requested number of nonces and can be called repeatedly. Start solvers at different nonces to divide the search space across workers. `Solver.current_nonce()` reports the next position to inspect.

`Challenge.encode` produces `<64 hex seed characters>:<difficulty>`. `Proof.encode` produces a 16-character hexadecimal nonce. These forms are suitable for a request header or a small JSON field.

## Difficulty

Difficulty is the number of leading zero bits required in the SHA-256 digest. The expected work is approximately `2^difficulty` hashes:

| Difficulty | Expected hashes |
| ---: | ---: |
| 16 | 65,536 |
| 20 | 1,048,576 |
| 24 | 16,777,216 |
| 28 | 268,435,456 |

Choose the value for the client devices, request type, and acceptable latency. A proof of work increases the cost of automated requests; it does not prove that the solver is human.

## Server Responsibilities

The library is stateless. The server must bind a challenge to the request or session that received it, expire it, reject reuse, limit attempts, and rate-limit challenge creation and verification. A challenge should be fresh and unpredictable, and its difficulty should not be trusted from an unverified client.

## Build

```sh
zig build test check
zig build test check --release=safe
zig build example
zig build bench -Dbench=true --release=fast -- --sample-count 20 --format table
```

The example covers serialization, incremental solving, server verification, parallel nonce ranges, and tamper rejection. The benchmark is optional and uses `zlap`.

## License

[MIT](LICENSE)
