const std = @import("std");

const stm = @import("stm.zig");
const Transaction = stm.Transaction;

var test_counter: u64 align(8) = 0;

fn bumpLoop(iters: usize) void {
    var tx = Transaction{};
    var done: usize = 0;
    while (done < iters) : (done += 1) {
        var attempts: u32 = 0;
        while (true) : (attempts += 1) {
            tx.begin();
            const ok = blk: {
                const v = tx.load(&test_counter) catch break :blk false;
                tx.store(&test_counter, v + 1) catch break :blk false;
                break :blk true;
            };
            if (ok and tx.commit()) break;
            if (!ok) tx.abort();
        }
    }
}

test "concurrent counter increments are not lost" {
    test_counter = 0;
    const THREADS = 4;
    const ITERS = 5000;

    var threads: [THREADS]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, bumpLoop, .{ITERS});
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(u64, THREADS * ITERS), test_counter);
}
