//! A toy implementation of Transaction Locking II.
//!
//! Source: https://dcl.epfl.ch/site/_media/education/4.pdf

/// A global version-clock that is incremented once by
/// each transaction that writes to memory, and is read by all transactions.
var global_version_clock = std.atomic.Value(u64){ .raw = 0 };

pub var version: usize = 0;

pub const lock_table_bits = 20;
/// Lock table size of 2^20.
pub const lock_table_size = 1 << lock_table_bits;

/// The amount of times we spin to wait on a lock. Tunable.
const spin_lock_limit = 256;

// Sizes of read and write sets. Tunable.
const size_read_set = 512;
const size_write_set = 512;

const lock_bit: u1 = 1;

/// The stripe lock table: ~8 MB, zero-initialized into .bss.
/// A single PS array is shared by every transactional structure.
var lock_table = std.mem.zeroes([lock_table_size]std.atomic.Value(u64));

/// The paper uses 0x3FFFFC as the mask (upper 2 bits and lower 2 bits are 0)
/// this is targeted at 32-bit lock values to keep addresses 4-byte aligned.
///
/// We use 64-bit, which means we leave the lower 3 bits empty for 8-byte alignment
/// and we do an AND (lock_table-size - 1) to keep the address within the
/// 2^20 sized table.
inline fn lockFor(addr: u64) *std.atomic.Value(u64) {
    return &lock_table[(addr >> 3) & (lock_table_size - 1)];
}

/// Address of the lock that 'covers' the variable being read.
///
/// This follows the TL2 description so we omit the observed version number of the
/// lock.
const ReadEntry = *std.atomic.Value(u64);

const WriteEntry = struct {
    /// Address of the variable.
    addr: *u64,
    /// Value to be written to the variable.
    value: u64,
    /// The read version.
    rdv: u64 = 0,
};

inline fn filterBit(addr: usize) u64 {
    const h = (addr >> 3) ^ (addr >> 6);
    return @as(u64, 1) << @as(u6, @truncate(h));
}

pub const Transaction = struct {
    const Kind = enum { Write, Read };

    /// The read version number.
    rv: u64 = 0,

    /// Indicates if a transaction has sampled the global version clock,
    /// which is compulsory before stores and reads.
    has_begun: bool = false,

    read_set: [size_read_set]ReadEntry = undefined,
    num_reads: u64 = 0,

    write_set: [size_write_set]WriteEntry = undefined,
    num_writes: u64 = 0,

    /// One-word Bloom filter over write-set addresses
    /// so reads can usually skip the write-set scan.
    bloom_filter: u64 = 0,

    /// Samples the global version clock. All transactions must
    /// call `begin` at the start.
    pub fn begin(tx: *Transaction) void {
        tx.rv = global_version_clock.load(.acquire);
        tx.has_begun = true;
    }

    /// Buffers a 'read' into memory. Reads do not happen
    /// until `commit` is called.
    pub fn load(tx: *Transaction, p: *u64) !u64 {
        if (!tx.has_begun) return error.UninitializedTransaction;

        const a = @intFromPtr(p);
        std.debug.assert(a & 7 == 0);

        const mask = filterBit(a);

        // Fast-path: if load address has already appeared in the write set,
        // we return the last value written to the address.
        if (tx.bloom_filter & mask == mask) {
            for (0..tx.num_writes) |i| {
                // Iterate from the back since we want the last value
                // written for write-after-write consistency
                const j = tx.num_writes - i;
                if (@intFromPtr(tx.write_set[j].addr) == a)
                    return tx.write_set[j].value;
            }
        }

        const lock = lockFor(a);

        const v1 = lock.load(.acquire);

        // Buffer the read from address.
        const val = @atomicLoad(u64, p, .acquire);

        const v2 = lock.load(.acquire);

        // Post-validation checks:
        if (v2 & lock_bit != 0 // location's versioned write-lock is free
        or
            v2 != v1 // has not changed
        or
            tx.rv < (v2 >> 1) // lock's version field <= tx.rv
        )
            return error.Conflict;

        // Validation succeeds, assign lock address to read set.
        tx.read_set[tx.num_reads] = lock;
        tx.num_reads += 1;

        return val;
    }

    /// Buffers a 'write' into memory. Writes do not happen
    /// until `commit` is called.
    pub fn store(tx: *Transaction, p: *u64, value: u64) !void {
        if (!tx.has_begun) return error.UninitializedTransaction;

        const a = @intFromPtr(p);
        std.debug.assert(a & 7 == 0);

        const mask = filterBit(a);

        tx.write_set[tx.num_writes] = .{ .addr = p, .value = value };
        tx.num_writes += 1;
        tx.bloom_filter |= mask;
    }

    /// Commits the buffered reads and writes into actual memory.
    ///
    /// This follows steps 3-6 in the paper.
    pub fn commit(tx: *Transaction) bool {
        if (tx.num_writes == 0) {
            tx.abort();
            return true;
        }

        // Step 3: Lock the write set using bounded spinning
        //
        // Fail fast if one of these locks are not successfully acquired.
        for (0..tx.num_writes) |i| {
            const w = &tx.write_set[i];
            var spins: usize = 0;
            const lock = lockFor(@intFromPtr(w.addr));

            while (true) {
                const v = lock.load(.monotonic);
                if (v & lock_bit == 0) {
                    if (lock.cmpxchgWeak(
                        v,
                        v | lock_bit,
                        .acq_rel,
                        .monotonic,
                    ) == null) {
                        w.rdv = v >> 1;
                        break;
                    }
                }
                spins += 1;

                if (spins >= spin_lock_limit) {
                    tx.abort();
                    return false;
                }

                std.atomic.spinLoopHint();
            }
        }

        // Step 4: Increment-and-fetch global clock. read the
        // value into local var 'wv'.
        const wv = global_version_clock.fetchAdd(1, .acq_rel) + 1;

        // Step 5: Validate the read set.
        // In the special case that rv + 1 = wv:
        // it is not necessary to revalidate the readset,
        // since it is guaranteed no concurrently executing transaction could
        // have modified it
        if (tx.rv + 1 != wv) {
            for (tx.read_set[0..tx.num_reads]) |r| {
                var is_written: ?u64 = null;

                // Scan the write set for the read version.
                for (tx.write_set[0..tx.num_writes]) |w| {
                    if (lockFor(@intFromPtr(w.addr)) == r) {
                        is_written = w.rdv;
                        break;
                    }
                }

                if (is_written) |v| {
                    // Validate versioned write lock  <= rv
                    if (v > tx.rv) {
                        tx.releaseLocks(tx.num_writes);
                        tx.abort();
                        return false;
                    }

                    continue;
                }

                const v = r.load(.acquire);
                const is_gt_rv = v >> 1 > tx.rv;
                const is_locked_others = v & lock_bit != 0;

                if (is_gt_rv or is_locked_others) {
                    tx.releaseLocks(tx.num_writes);
                    tx.abort();
                    return false;
                }
            }
        }

        // Step 6: Commit and release locks
        const released_word = wv << 1; // lock bit clear, version = wv
        for (tx.write_set[0..tx.num_writes]) |w| {
            @atomicStore(u64, w.addr, w.value, .release);
            var lock = lockFor(@intFromPtr(w.addr));
            lock.store(released_word, .release);
        }

        tx.abort();
        return true;
    }

    /// Release all held locks.
    fn releaseLocks(tx: *Transaction, upto: usize) void {
        for (0..upto) |i| {
            const lock = lockFor(@intFromPtr(tx.write_set[i].addr));
            const v = lock.load(.acquire);
            if (v & lock_bit != 0) lock.store(v & ~@as(u64, lock_bit), .release);
        }
    }

    /// Clears counters for the next transaction.
    pub fn abort(tx: *Transaction) void {
        tx.num_writes = 0;
        tx.num_reads = 0;
        tx.bloom_filter = 0;
    }
};

const std = @import("std");
