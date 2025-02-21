//! # General Purpose Allocator
//!
//! ## Design Priorities
//!
//! ### `OptimizationMode.debug` and `OptimizationMode.release_safe`:
//!
//!  * Detect double free, and emit stack trace of:
//!    - Where it was first allocated
//!    - Where it was freed the first time
//!    - Where it was freed the second time
//!
//!  * Detect leaks and emit stack trace of:
//!    - Where it was allocated
//!
//!  * When a page of memory is no longer needed, give it back to resident memory
//!    as soon as possible, so that it causes page faults when used.
//!
//!  * Do not re-use memory slots, so that memory safety is upheld. For small
//!    allocations, this is handled here; for larger ones it is handled in the
//!    backing allocator (by default `std.heap.page_allocator`).
//!
//!  * Make pointer math errors unlikely to harm memory from
//!    unrelated allocations.
//!
//!  * It's OK for these mechanisms to cost some extra overhead bytes.
//!
//!  * It's OK for performance cost for these mechanisms.
//!
//!  * Rogue memory writes should not harm the allocator's state.
//!
//!  * Cross platform. Operates based on a backing allocator which makes it work
//!    everywhere, even freestanding.
//!
//!  * Compile-time configuration.
//!
//! ### `OptimizationMode.release_fast` (note: not much work has gone into this use case yet):
//!
//!  * Low fragmentation is primary concern
//!  * Performance of worst-case latency is secondary concern
//!  * Performance of average-case latency is next
//!  * Finally, having freed memory unmapped, and pointer math errors unlikely to
//!    harm memory from unrelated allocations are nice-to-haves.
//!
//! ### `OptimizationMode.release_small` (note: not much work has gone into this use case yet):
//!
//!  * Small binary code size of the executable is the primary concern.
//!  * Next, defer to the `.release_fast` priority list.
//!
//! ## Basic Design:
//!
//! Small allocations are divided into buckets:
//!
//! ```
//! index obj_size
//! 0     1
//! 1     2
//! 2     4
//! 3     8
//! 4     16
//! 5     32
//! 6     64
//! 7     128
//! 8     256
//! 9     512
//! 10    1024
//! 11    2048
//! ```
//!
//! The main allocator state has an array of all the "current" buckets for each
//! size class. Each slot in the array can be null, meaning the bucket for that
//! size class is not allocated. When the first object is allocated for a given
//! size class, it allocates 1 page of memory from the OS. This page is
//! divided into "slots" - one per allocated object. Along with the page of memory
//! for object slots, as many pages as necessary are allocated to store the
//! BucketHeader, followed by "used bits", and two stack traces for each slot
//! (allocation trace and free trace).
//!
//! The "used bits" are 1 bit per slot representing whether the slot is used.
//! Allocations use the data to iterate to find a free slot. Frees assert that the
//! corresponding bit is 1 and set it to 0.
//!
//! Buckets have prev and next pointers. When there is only one bucket for a given
//! size class, both prev and next point to itself. When all slots of a bucket are
//! used, a new bucket is allocated, and enters the doubly linked list. The main
//! allocator state tracks the "current" bucket for each size class. Leak detection
//! currently only checks the current bucket.
//!
//! Resizing detects if the size class is unchanged or smaller, in which case the same
//! pointer is returned unmodified. If a larger size class is required,
//! `error.OutOfMemory` is returned.
//!
//! Large objects are allocated directly using the backing allocator and their metadata is stored
//! in a `std.HashMap` using the backing allocator.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.gpa);
const math = std.math;
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const StackTrace = std.builtin.StackTrace;

// Maximum possible hardware page size
const max_page_size: comptime_int = math.powi(std.meta.Int(.unsigned, @bitSizeOf(usize) * 2), 2, @bitSizeOf(usize)) catch unreachable;

/// Integer type for pointing to slots in a small allocation.
const SlotIndex = std.meta.Int(.unsigned, math.log2(max_page_size + 1));

const default_test_stack_trace_frames: usize = if (builtin.is_test) 10 else 6;
const default_sys_stack_trace_frames: usize = if (std.debug.sys_can_stack_trace) default_test_stack_trace_frames else 0;
const default_stack_trace_frames: usize = switch (builtin.mode) {
    .Debug => default_sys_stack_trace_frames,
    else => 0,
};

pub const Config = struct {
    /// Number of stack frames to capture.
    stack_trace_frames: usize = default_stack_trace_frames,

    /// If true, the allocator will have two fields:
    ///  * `total_requested_bytes` which tracks the total allocated bytes of memory requested.
    ///  * `requested_memory_limit` which causes allocations to return `error.OutOfMemory`
    ///    when the `total_requested_bytes` exceeds this limit.
    /// If false, these fields will be `void`.
    enable_memory_limit: bool = false,

    /// Whether to enable safety checks.
    safety: bool = std.debug.runtime_safety,

    /// Whether the allocator may be used simultaneously from multiple threads.
    thread_safe: bool = !builtin.single_threaded,

    /// What type of mutex you'd like to use, for thread safety.
    /// when specified, the mutex type must have the same shape as `std.Thread.Mutex` and
    /// `DummyMutex`, and have no required fields. Specifying this field causes
    /// the `thread_safe` field to be ignored.
    ///
    /// when null (default):
    /// * the mutex type defaults to `std.Thread.Mutex` when thread_safe is enabled.
    /// * the mutex type defaults to `DummyMutex` otherwise.
    MutexType: ?type = null,

    /// This is a temporary debugging trick you can use to turn segfaults into more helpful
    /// logged error messages with stack trace details. The downside is that every allocation
    /// will be leaked, unless used with retain_metadata!
    never_unmap: bool = false,

    /// This is a temporary debugging aid that retains metadata about allocations indefinitely.
    /// This allows a greater range of double frees to be reported. All metadata is freed when
    /// deinit is called. When used with never_unmap, deliberately leaked memory is also freed
    /// during deinit. Currently should be used with never_unmap to avoid segfaults.
    /// TODO https://github.com/ziglang/zig/issues/4298 will allow use without never_unmap
    retain_metadata: bool = false,

    /// Enables emitting info messages with the size and address of every allocation.
    verbose_log: bool = false,
};

pub const Check = enum { ok, leak };

pub fn GeneralPurposeAllocator(comptime config: Config) type {
    return struct {
        backing_allocator: Allocator = std.heap.page_allocator,
        buckets: []Buckets = undefined,
        cur_buckets: []?*BucketHeader = undefined,
        large_allocations: LargeAllocTable = .{},
        empty_buckets: if (config.retain_metadata) Buckets else void =
            if (config.retain_metadata) Buckets{} else {},
        bucket_node_pool: std.heap.MemoryPool(Buckets.Node) = std.heap.MemoryPool(Buckets.Node).init(std.heap.page_allocator),
        small_bucket_count: usize = 0,
        largest_bucket_object_size: usize = 0,

        total_requested_bytes: @TypeOf(total_requested_bytes_init) = total_requested_bytes_init,
        requested_memory_limit: @TypeOf(requested_memory_limit_init) = requested_memory_limit_init,

        mutex: @TypeOf(mutex_init) = mutex_init,

        const Self = @This();

        const total_requested_bytes_init = if (config.enable_memory_limit) @as(usize, 0) else {};
        const requested_memory_limit_init = if (config.enable_memory_limit) @as(usize, math.maxInt(usize)) else {};

        const mutex_init = if (config.MutexType) |T|
            T{}
        else if (config.thread_safe)
            std.Thread.Mutex{}
        else
            DummyMutex{};

        const DummyMutex = struct {
            fn lock(_: *DummyMutex) void {}
            fn unlock(_: *DummyMutex) void {}
        };

        const stack_n = config.stack_trace_frames;
        const one_trace_size = @sizeOf(usize) * stack_n;
        const traces_per_slot = 2;

        pub const Error = mem.Allocator.Error;

        const LargestSizeClassInt = std.math.IntFittingRange(0, 1 << (math.log2(max_page_size - 1)));

        const bucketCompare = struct {
            fn compare(a: *BucketHeader, b: *BucketHeader) std.math.Order {
                return std.math.order(@intFromPtr(a.page), @intFromPtr(b.page));
            }
        }.compare;
        const Buckets = std.Treap(*BucketHeader, bucketCompare);

        const LargeAlloc = struct {
            bytes: []u8,
            requested_size: if (config.enable_memory_limit) usize else void,
            stack_addresses: [trace_n][stack_n]usize,
            freed: if (config.retain_metadata) bool else void,
            log2_ptr_align: if (config.never_unmap and config.retain_metadata) u8 else void,

            const trace_n = if (config.retain_metadata) traces_per_slot else 1;

            fn dumpStackTrace(self: *LargeAlloc, trace_kind: TraceKind) void {
                std.debug.dumpStackTrace(self.getStackTrace(trace_kind));
            }

            fn getStackTrace(self: *LargeAlloc, trace_kind: TraceKind) std.builtin.StackTrace {
                assert(@intFromEnum(trace_kind) < trace_n);
                const stack_addresses = &self.stack_addresses[@intFromEnum(trace_kind)];
                var len: usize = 0;
                while (len < stack_n and stack_addresses[len] != 0) {
                    len += 1;
                }
                return .{
                    .instruction_addresses = stack_addresses,
                    .index = len,
                };
            }

            fn captureStackTrace(self: *LargeAlloc, ret_addr: usize, trace_kind: TraceKind) void {
                assert(@intFromEnum(trace_kind) < trace_n);
                const stack_addresses = &self.stack_addresses[@intFromEnum(trace_kind)];
                collectStackTrace(ret_addr, stack_addresses);
            }
        };
        const LargeAllocTable = std.AutoHashMapUnmanaged(usize, LargeAlloc);

        // Bucket: In memory, in order:
        // * BucketHeader
        // * bucket_used_bits: [N]u8, // 1 bit for every slot; 1 byte for every 8 slots
        // -- below only exists when config.safety is true --
        // * requested_sizes: [N]LargestSizeClassInt // 1 int for every slot
        // * log2_ptr_aligns: [N]u8 // 1 byte for every slot
        // -- above only exists when config.safety is true --
        // * stack_trace_addresses: [N]usize, // traces_per_slot for every allocation

        const BucketHeader = struct {
            page: [*]u8,
            alloc_cursor: SlotIndex,
            used_count: SlotIndex,

            fn usedBits(bucket: *BucketHeader, index: usize) *u8 {
                return @as(*u8, @ptrFromInt(@intFromPtr(bucket) + @sizeOf(BucketHeader) + index));
            }

            fn requestedSizes(bucket: *BucketHeader, size_class: usize) []LargestSizeClassInt {
                if (!config.safety) @compileError("requested size is only stored when safety is enabled");
                const start_ptr = @as([*]u8, @ptrCast(bucket)) + bucketRequestedSizesStart(size_class);
                const sizes = @as([*]LargestSizeClassInt, @ptrCast(@alignCast(start_ptr)));
                const slot_count = @divExact(std.heap.pageSize(), size_class);
                return sizes[0..slot_count];
            }

            fn log2PtrAligns(bucket: *BucketHeader, size_class: usize) []u8 {
                if (!config.safety) @compileError("requested size is only stored when safety is enabled");
                const aligns_ptr = @as([*]u8, @ptrCast(bucket)) + bucketAlignsStart(size_class);
                const slot_count = @divExact(std.heap.pageSize(), size_class);
                return aligns_ptr[0..slot_count];
            }

            fn stackTracePtr(
                bucket: *BucketHeader,
                size_class: usize,
                slot_index: SlotIndex,
                trace_kind: TraceKind,
            ) *[stack_n]usize {
                const start_ptr = @as([*]u8, @ptrCast(bucket)) + bucketStackFramesStart(size_class);
                const addr = start_ptr + one_trace_size * traces_per_slot * slot_index +
                    @intFromEnum(trace_kind) * @as(usize, one_trace_size);
                return @ptrCast(@alignCast(addr));
            }

            fn captureStackTrace(
                bucket: *BucketHeader,
                ret_addr: usize,
                size_class: usize,
                slot_index: SlotIndex,
                trace_kind: TraceKind,
            ) void {
                // Initialize them to 0. When determining the count we must look
                // for non zero addresses.
                const stack_addresses = bucket.stackTracePtr(size_class, slot_index, trace_kind);
                collectStackTrace(ret_addr, stack_addresses);
            }
        };

        pub fn allocator(self: *Self) Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .free = free,
                },
            };
        }

        fn bucketStackTrace(
            bucket: *BucketHeader,
            size_class: usize,
            slot_index: SlotIndex,
            trace_kind: TraceKind,
        ) StackTrace {
            const stack_addresses = bucket.stackTracePtr(size_class, slot_index, trace_kind);
            var len: usize = 0;
            while (len < stack_n and stack_addresses[len] != 0) {
                len += 1;
            }
            return StackTrace{
                .instruction_addresses = stack_addresses,
                .index = len,
            };
        }

        fn bucketRequestedSizesStart(size_class: usize) usize {
            if (!config.safety) @compileError("requested sizes are not stored unless safety is enabled");
            return mem.alignForward(
                usize,
                @sizeOf(BucketHeader) + usedBitsCount(size_class),
                @alignOf(LargestSizeClassInt),
            );
        }

        fn bucketAlignsStart(size_class: usize) usize {
            if (!config.safety) @compileError("requested sizes are not stored unless safety is enabled");
            const slot_count = @divExact(std.heap.pageSize(), size_class);
            return bucketRequestedSizesStart(size_class) + (@sizeOf(LargestSizeClassInt) * slot_count);
        }

        fn bucketStackFramesStart(size_class: usize) usize {
            const unaligned_start = if (config.safety) blk: {
                const slot_count = @divExact(std.heap.pageSize(), size_class);
                break :blk bucketAlignsStart(size_class) + slot_count;
            } else @sizeOf(BucketHeader) + usedBitsCount(size_class);
            return mem.alignForward(
                usize,
                unaligned_start,
                @alignOf(usize),
            );
        }

        fn bucketSize(size_class: usize) usize {
            const slot_count = @divExact(std.heap.pageSize(), size_class);
            return bucketStackFramesStart(size_class) + one_trace_size * traces_per_slot * slot_count;
        }

        fn usedBitsCount(size_class: usize) usize {
            const slot_count = @divExact(std.heap.pageSize(), size_class);
            if (slot_count < 8) return 1;
            return @divExact(slot_count, 8);
        }

        fn detectLeaksInBucket(
            bucket: *BucketHeader,
            size_class: usize,
            used_bits_count: usize,
        ) bool {
            var leaks = false;
            var used_bits_byte: usize = 0;
            while (used_bits_byte < used_bits_count) : (used_bits_byte += 1) {
                const used_byte = bucket.usedBits(used_bits_byte).*;
                if (used_byte != 0) {
                    var bit_index: u3 = 0;
                    while (true) : (bit_index += 1) {
                        const is_used = @as(u1, @truncate(used_byte >> bit_index)) != 0;
                        if (is_used) {
                            const slot_index = @as(SlotIndex, @intCast(used_bits_byte * 8 + bit_index));
                            const stack_trace = bucketStackTrace(bucket, size_class, slot_index, .alloc);
                            const addr = bucket.page + slot_index * size_class;
                            log.err("memory address 0x{x} leaked: {}", .{
                                @intFromPtr(addr), stack_trace,
                            });
                            leaks = true;
                        }
                        if (bit_index == math.maxInt(u3))
                            break;
                    }
                }
            }
            return leaks;
        }

        /// Emits log messages for leaks and then returns whether there were any leaks.
        pub fn detectLeaks(self: *Self) bool {
            self.ensureInitialized() catch unreachable;

            var leaks = false;

            for (self.buckets, 0..) |*buckets, bucket_i| {
                if (buckets.root == null) continue;
                const size_class = @as(usize, 1) << @as(math.Log2Int(usize), @intCast(bucket_i));
                const used_bits_count = usedBitsCount(size_class);
                var it = buckets.inorderIterator();
                while (it.next()) |node| {
                    const bucket = node.key;
                    leaks = detectLeaksInBucket(bucket, size_class, used_bits_count) or leaks;
                }
            }
            var it = self.large_allocations.valueIterator();
            while (it.next()) |large_alloc| {
                if (config.retain_metadata and large_alloc.freed) continue;
                const stack_trace = large_alloc.getStackTrace(.alloc);
                log.err("memory address 0x{x} leaked: {}", .{
                    @intFromPtr(large_alloc.bytes.ptr), stack_trace,
                });
                leaks = true;
            }
            return leaks;
        }

        fn freeBucket(self: *Self, bucket: *BucketHeader, size_class: usize) void {
            const bucket_size = bucketSize(size_class);
            const bucket_slice = @as([*]align(@alignOf(BucketHeader)) u8, @ptrCast(bucket))[0..bucket_size];
            self.backing_allocator.free(bucket_slice);
        }

        fn freeRetainedMetadata(self: *Self) void {
            if (config.retain_metadata) {
                if (config.never_unmap) {
                    // free large allocations that were intentionally leaked by never_unmap
                    var it = self.large_allocations.iterator();
                    while (it.next()) |large| {
                        if (large.value_ptr.freed) {
                            self.backing_allocator.rawFree(large.value_ptr.bytes, large.value_ptr.log2_ptr_align, @returnAddress());
                        }
                    }
                }
                // free retained metadata for small allocations
                var empty_it = self.empty_buckets.inorderIterator();
                while (empty_it.next()) |node| {
                    var bucket = node.key;
                    if (config.never_unmap) {
                        // free page that was intentionally leaked by never_unmap
                        self.backing_allocator.free(bucket.page[0..std.heap.pageSize()]);
                    }
                    // alloc_cursor was set to slot count when bucket added to empty_buckets
                    self.freeBucket(bucket, @divExact(std.heap.pageSize(), bucket.alloc_cursor));
                    self.bucket_node_pool.destroy(node);
                }
                self.empty_buckets.root = null;
            }
        }

        pub fn flushRetainedMetadata(self: *Self) void {
            if (!config.retain_metadata) {
                @compileError("'flushRetainedMetadata' requires 'config.retain_metadata = true'");
            }
            self.freeRetainedMetadata();
            // also remove entries from large_allocations
            var it = self.large_allocations.iterator();
            while (it.next()) |large| {
                if (large.value_ptr.freed) {
                    _ = self.large_allocations.remove(@intFromPtr(large.value_ptr.bytes.ptr));
                }
            }
        }

        fn ensureInitialized(self: *Self) !void {
            if (self.small_bucket_count == 0 or self.largest_bucket_object_size == 0) {
                const pageSize = std.heap.pageSize();

                self.small_bucket_count = math.log2(pageSize);
                self.largest_bucket_object_size = @as(usize, 1) << @intCast(self.small_bucket_count - 1);

                self.buckets = try self.backing_allocator.alloc(Buckets, self.small_bucket_count);
                @memset(self.buckets, Buckets{});

                self.cur_buckets = try self.backing_allocator.alloc(?*BucketHeader, self.small_bucket_count);
                @memset(self.cur_buckets, null);
            }
        }

        /// Returns `Check.leak` if there were leaks; `Check.ok` otherwise.
        pub fn deinit(self: *Self) Check {
            self.ensureInitialized() catch unreachable;

            const leaks = if (config.safety) self.detectLeaks() else false;
            if (config.retain_metadata) {
                self.freeRetainedMetadata();
            }
            self.large_allocations.deinit(self.backing_allocator);
            self.bucket_node_pool.deinit();
            self.backing_allocator.free(self.buckets);
            self.backing_allocator.free(self.cur_buckets);
            self.* = undefined;
            return @as(Check, @enumFromInt(@intFromBool(leaks)));
        }

        fn collectStackTrace(first_trace_addr: usize, addresses: *[stack_n]usize) void {
            if (stack_n == 0) return;
            @memset(addresses, 0);
            var stack_trace = StackTrace{
                .instruction_addresses = addresses,
                .index = 0,
            };
            std.debug.captureStackTrace(first_trace_addr, &stack_trace);
        }

        fn reportDoubleFree(ret_addr: usize, alloc_stack_trace: StackTrace, free_stack_trace: StackTrace) void {
            var addresses: [stack_n]usize = [1]usize{0} ** stack_n;
            var second_free_stack_trace = StackTrace{
                .instruction_addresses = &addresses,
                .index = 0,
            };
            std.debug.captureStackTrace(ret_addr, &second_free_stack_trace);
            log.err("Double free detected. Allocation: {} First free: {} Second free: {}", .{
                alloc_stack_trace, free_stack_trace, second_free_stack_trace,
            });
        }

        const Slot = struct {
            bucket: *BucketHeader,
            slot_index: usize,
            ptr: [*]u8,
        };

        fn allocSlot(self: *Self, size_class: usize, trace_addr: usize) Error!Slot {
            try self.ensureInitialized();

            const bucket_index = math.log2(size_class);
            var buckets = &self.buckets[bucket_index];
            const slot_count = @divExact(std.heap.pageSize(), size_class);
            if (self.cur_buckets[bucket_index] == null or self.cur_buckets[bucket_index].?.alloc_cursor == slot_count) {
                const new_bucket = try self.createBucket(size_class);
                errdefer self.freeBucket(new_bucket, size_class);
                const node = try self.bucket_node_pool.create();
                node.key = new_bucket;
                var entry = buckets.getEntryFor(new_bucket);
                std.debug.assert(entry.node == null);
                entry.set(node);
                self.cur_buckets[bucket_index] = node.key;
            }
            const bucket = self.cur_buckets[bucket_index].?;

            const slot_index = bucket.alloc_cursor;
            bucket.alloc_cursor += 1;

            const used_bits_byte = bucket.usedBits(slot_index / 8);
            const used_bit_index: u3 = @as(u3, @intCast(slot_index % 8)); // TODO cast should be unnecessary
            used_bits_byte.* |= (@as(u8, 1) << used_bit_index);
            bucket.used_count += 1;
            bucket.captureStackTrace(trace_addr, size_class, slot_index, .alloc);
            return .{
                .bucket = bucket,
                .slot_index = slot_index,
                .ptr = bucket.page + slot_index * size_class,
            };
        }

        fn searchBucket(
            buckets: *Buckets,
            addr: usize,
            current_bucket: ?*BucketHeader,
        ) ?*BucketHeader {
            const search_page: [*]u8 = @ptrFromInt(mem.alignBackward(usize, addr, std.heap.pageSize()));
            if (current_bucket != null and current_bucket.?.page == search_page) {
                return current_bucket;
            }
            var search_header: BucketHeader = undefined;
            search_header.page = search_page;
            const entry = buckets.getEntryFor(&search_header);
            return if (entry.node) |node| node.key else null;
        }

        /// This function assumes the object is in the large object storage regardless
        /// of the parameters.
        fn resizeLarge(
            self: *Self,
            old_mem: []u8,
            log2_old_align: u8,
            new_size: usize,
            ret_addr: usize,
        ) bool {
            const entry = self.large_allocations.getEntry(@intFromPtr(old_mem.ptr)) orelse {
                if (config.safety) {
                    @panic("Invalid free");
                } else {
                    unreachable;
                }
            };

            if (config.retain_metadata and entry.value_ptr.freed) {
                if (config.safety) {
                    reportDoubleFree(ret_addr, entry.value_ptr.getStackTrace(.alloc), entry.value_ptr.getStackTrace(.free));
                    @panic("Unrecoverable double free");
                } else {
                    unreachable;
                }
            }

            if (config.safety and old_mem.len != entry.value_ptr.bytes.len) {
                var addresses: [stack_n]usize = [1]usize{0} ** stack_n;
                var free_stack_trace = StackTrace{
                    .instruction_addresses = &addresses,
                    .index = 0,
                };
                std.debug.captureStackTrace(ret_addr, &free_stack_trace);
                log.err("Allocation size {d} bytes does not match free size {d}. Allocation: {} Free: {}", .{
                    entry.value_ptr.bytes.len,
                    old_mem.len,
                    entry.value_ptr.getStackTrace(.alloc),
                    free_stack_trace,
                });
            }

            // Do memory limit accounting with requested sizes rather than what
            // backing_allocator returns because if we want to return
            // error.OutOfMemory, we have to leave allocation untouched, and
            // that is impossible to guarantee after calling
            // backing_allocator.rawResize.
            const prev_req_bytes = self.total_requested_bytes;
            if (config.enable_memory_limit) {
                const new_req_bytes = prev_req_bytes + new_size - entry.value_ptr.requested_size;
                if (new_req_bytes > prev_req_bytes and new_req_bytes > self.requested_memory_limit) {
                    return false;
                }
                self.total_requested_bytes = new_req_bytes;
            }

            if (!self.backing_allocator.rawResize(old_mem, log2_old_align, new_size, ret_addr)) {
                if (config.enable_memory_limit) {
                    self.total_requested_bytes = prev_req_bytes;
                }
                return false;
            }

            if (config.enable_memory_limit) {
                entry.value_ptr.requested_size = new_size;
            }

            if (config.verbose_log) {
                log.info("large resize {d} bytes at {*} to {d}", .{
                    old_mem.len, old_mem.ptr, new_size,
                });
            }
            entry.value_ptr.bytes = old_mem.ptr[0..new_size];
            entry.value_ptr.captureStackTrace(ret_addr, .alloc);
            return true;
        }

        /// This function assumes the object is in the large object storage regardless
        /// of the parameters.
        fn freeLarge(
            self: *Self,
            old_mem: []u8,
            log2_old_align: u8,
            ret_addr: usize,
        ) void {
            const entry = self.large_allocations.getEntry(@intFromPtr(old_mem.ptr)) orelse {
                if (config.safety) {
                    @panic("Invalid free");
                } else {
                    unreachable;
                }
            };

            if (config.retain_metadata and entry.value_ptr.freed) {
                if (config.safety) {
                    reportDoubleFree(ret_addr, entry.value_ptr.getStackTrace(.alloc), entry.value_ptr.getStackTrace(.free));
                    return;
                } else {
                    unreachable;
                }
            }

            if (config.safety and old_mem.len != entry.value_ptr.bytes.len) {
                var addresses: [stack_n]usize = [1]usize{0} ** stack_n;
                var free_stack_trace = StackTrace{
                    .instruction_addresses = &addresses,
                    .index = 0,
                };
                std.debug.captureStackTrace(ret_addr, &free_stack_trace);
                log.err("Allocation size {d} bytes does not match free size {d}. Allocation: {} Free: {}", .{
                    entry.value_ptr.bytes.len,
                    old_mem.len,
                    entry.value_ptr.getStackTrace(.alloc),
                    free_stack_trace,
                });
            }

            if (!config.never_unmap) {
                self.backing_allocator.rawFree(old_mem, log2_old_align, ret_addr);
            }

            if (config.enable_memory_limit) {
                self.total_requested_bytes -= entry.value_ptr.requested_size;
            }

            if (config.verbose_log) {
                log.info("large free {d} bytes at {*}", .{ old_mem.len, old_mem.ptr });
            }

            if (!config.retain_metadata) {
                assert(self.large_allocations.remove(@intFromPtr(old_mem.ptr)));
            } else {
                entry.value_ptr.freed = true;
                entry.value_ptr.captureStackTrace(ret_addr, .free);
            }
        }

        pub fn setRequestedMemoryLimit(self: *Self, limit: usize) void {
            self.requested_memory_limit = limit;
        }

        fn resize(
            ctx: *anyopaque,
            old_mem: []u8,
            log2_old_align_u8: u8,
            new_size: usize,
            ret_addr: usize,
        ) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const log2_old_align = @as(Allocator.Log2Align, @intCast(log2_old_align_u8));
            self.mutex.lock();
            defer self.mutex.unlock();

            self.ensureInitialized() catch return false;
            assert(old_mem.len != 0);

            const aligned_size = @max(old_mem.len, @as(usize, 1) << log2_old_align);
            if (aligned_size > self.largest_bucket_object_size) {
                return self.resizeLarge(old_mem, log2_old_align, new_size, ret_addr);
            }
            const size_class_hint = math.ceilPowerOfTwoAssert(usize, aligned_size);

            var bucket_index = math.log2(size_class_hint);
            var size_class: usize = size_class_hint;
            const bucket = while (bucket_index < self.small_bucket_count) : (bucket_index += 1) {
                if (searchBucket(&self.buckets[bucket_index], @intFromPtr(old_mem.ptr), self.cur_buckets[bucket_index])) |bucket| {
                    break bucket;
                }
                size_class *= 2;
            } else blk: {
                if (config.retain_metadata) {
                    if (!self.large_allocations.contains(@intFromPtr(old_mem.ptr))) {
                        // object not in active buckets or a large allocation, so search empty buckets
                        if (searchBucket(&self.empty_buckets, @intFromPtr(old_mem.ptr), null)) |bucket| {
                            // bucket is empty so is_used below will always be false and we exit there
                            break :blk bucket;
                        } else {
                            @panic("Invalid free");
                        }
                    }
                }
                return self.resizeLarge(old_mem, log2_old_align, new_size, ret_addr);
            };
            const byte_offset = @intFromPtr(old_mem.ptr) - @intFromPtr(bucket.page);
            const slot_index = @as(SlotIndex, @intCast(byte_offset / size_class));
            const used_byte_index = slot_index / 8;
            const used_bit_index = @as(u3, @intCast(slot_index % 8));
            const used_byte = bucket.usedBits(used_byte_index);
            const is_used = @as(u1, @truncate(used_byte.* >> used_bit_index)) != 0;
            if (!is_used) {
                if (config.safety) {
                    reportDoubleFree(ret_addr, bucketStackTrace(bucket, size_class, slot_index, .alloc), bucketStackTrace(bucket, size_class, slot_index, .free));
                    @panic("Unrecoverable double free");
                } else {
                    unreachable;
                }
            }

            // Definitely an in-use small alloc now.
            if (config.safety) {
                const requested_size = bucket.requestedSizes(size_class)[slot_index];
                if (requested_size == 0) @panic("Invalid free");
                const log2_ptr_align = bucket.log2PtrAligns(size_class)[slot_index];
                if (old_mem.len != requested_size or log2_old_align != log2_ptr_align) {
                    var addresses: [stack_n]usize = [1]usize{0} ** stack_n;
                    var free_stack_trace = StackTrace{
                        .instruction_addresses = &addresses,
                        .index = 0,
                    };
                    std.debug.captureStackTrace(ret_addr, &free_stack_trace);
                    if (old_mem.len != requested_size) {
                        log.err("Allocation size {d} bytes does not match resize size {d}. Allocation: {} Resize: {}", .{
                            requested_size,
                            old_mem.len,
                            bucketStackTrace(bucket, size_class, slot_index, .alloc),
                            free_stack_trace,
                        });
                    }
                    if (log2_old_align != log2_ptr_align) {
                        log.err("Allocation alignment {d} does not match resize alignment {d}. Allocation: {} Resize: {}", .{
                            @as(usize, 1) << @as(math.Log2Int(usize), @intCast(log2_ptr_align)),
                            @as(usize, 1) << @as(math.Log2Int(usize), @intCast(log2_old_align)),
                            bucketStackTrace(bucket, size_class, slot_index, .alloc),
                            free_stack_trace,
                        });
                    }
                }
            }
            const prev_req_bytes = self.total_requested_bytes;
            if (config.enable_memory_limit) {
                const new_req_bytes = prev_req_bytes + new_size - old_mem.len;
                if (new_req_bytes > prev_req_bytes and new_req_bytes > self.requested_memory_limit) {
                    return false;
                }
                self.total_requested_bytes = new_req_bytes;
            }

            const new_aligned_size = @max(new_size, @as(usize, 1) << log2_old_align);
            const new_size_class = math.ceilPowerOfTwoAssert(usize, new_aligned_size);
            if (new_size_class <= size_class) {
                if (old_mem.len > new_size) {
                    @memset(old_mem[new_size..], undefined);
                }
                if (config.verbose_log) {
                    log.info("small resize {d} bytes at {*} to {d}", .{
                        old_mem.len, old_mem.ptr, new_size,
                    });
                }
                if (config.safety) {
                    bucket.requestedSizes(size_class)[slot_index] = @intCast(new_size);
                }
                return true;
            }

            if (config.enable_memory_limit) {
                self.total_requested_bytes = prev_req_bytes;
            }
            return false;
        }

        fn free(
            ctx: *anyopaque,
            old_mem: []u8,
            log2_old_align_u8: u8,
            ret_addr: usize,
        ) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const log2_old_align = @as(Allocator.Log2Align, @intCast(log2_old_align_u8));
            self.mutex.lock();
            defer self.mutex.unlock();

            self.ensureInitialized() catch unreachable;
            assert(old_mem.len != 0);

            const aligned_size = @max(old_mem.len, @as(usize, 1) << log2_old_align);
            if (aligned_size > self.largest_bucket_object_size) {
                self.freeLarge(old_mem, log2_old_align, ret_addr);
                return;
            }
            const size_class_hint = math.ceilPowerOfTwoAssert(usize, aligned_size);

            var bucket_index = math.log2(size_class_hint);
            var size_class: usize = size_class_hint;
            const bucket = while (bucket_index < self.small_bucket_count) : (bucket_index += 1) {
                if (searchBucket(&self.buckets[bucket_index], @intFromPtr(old_mem.ptr), self.cur_buckets[bucket_index])) |bucket| {
                    break bucket;
                }
                size_class *= 2;
            } else blk: {
                if (config.retain_metadata) {
                    if (!self.large_allocations.contains(@intFromPtr(old_mem.ptr))) {
                        // object not in active buckets or a large allocation, so search empty buckets
                        if (searchBucket(&self.empty_buckets, @intFromPtr(old_mem.ptr), null)) |bucket| {
                            // bucket is empty so is_used below will always be false and we exit there
                            break :blk bucket;
                        } else {
                            @panic("Invalid free");
                        }
                    }
                }
                self.freeLarge(old_mem, log2_old_align, ret_addr);
                return;
            };
            const byte_offset = @intFromPtr(old_mem.ptr) - @intFromPtr(bucket.page);
            const slot_index = @as(SlotIndex, @intCast(byte_offset / size_class));
            const used_byte_index = slot_index / 8;
            const used_bit_index = @as(u3, @intCast(slot_index % 8));
            const used_byte = bucket.usedBits(used_byte_index);
            const is_used = @as(u1, @truncate(used_byte.* >> used_bit_index)) != 0;
            if (!is_used) {
                if (config.safety) {
                    reportDoubleFree(ret_addr, bucketStackTrace(bucket, size_class, slot_index, .alloc), bucketStackTrace(bucket, size_class, slot_index, .free));
                    // Recoverable if this is a free.
                    return;
                } else {
                    unreachable;
                }
            }

            // Definitely an in-use small alloc now.
            if (config.safety) {
                const requested_size = bucket.requestedSizes(size_class)[slot_index];
                if (requested_size == 0) @panic("Invalid free");
                const log2_ptr_align = bucket.log2PtrAligns(size_class)[slot_index];
                if (old_mem.len != requested_size or log2_old_align != log2_ptr_align) {
                    var addresses: [stack_n]usize = [1]usize{0} ** stack_n;
                    var free_stack_trace = StackTrace{
                        .instruction_addresses = &addresses,
                        .index = 0,
                    };
                    std.debug.captureStackTrace(ret_addr, &free_stack_trace);
                    if (old_mem.len != requested_size) {
                        log.err("Allocation size {d} bytes does not match free size {d}. Allocation: {} Free: {}", .{
                            requested_size,
                            old_mem.len,
                            bucketStackTrace(bucket, size_class, slot_index, .alloc),
                            free_stack_trace,
                        });
                    }
                    if (log2_old_align != log2_ptr_align) {
                        log.err("Allocation alignment {d} does not match free alignment {d}. Allocation: {} Free: {}", .{
                            @as(usize, 1) << @as(math.Log2Int(usize), @intCast(log2_ptr_align)),
                            @as(usize, 1) << @as(math.Log2Int(usize), @intCast(log2_old_align)),
                            bucketStackTrace(bucket, size_class, slot_index, .alloc),
                            free_stack_trace,
                        });
                    }
                }
            }

            if (config.enable_memory_limit) {
                self.total_requested_bytes -= old_mem.len;
            }

            // Capture stack trace to be the "first free", in case a double free happens.
            bucket.captureStackTrace(ret_addr, size_class, slot_index, .free);

            used_byte.* &= ~(@as(u8, 1) << used_bit_index);
            bucket.used_count -= 1;
            if (config.safety) {
                bucket.requestedSizes(size_class)[slot_index] = 0;
            }
            if (bucket.used_count == 0) {
                var entry = self.buckets[bucket_index].getEntryFor(bucket);
                // save the node for destruction/insertion into in empty_buckets
                const node = entry.node.?;
                entry.set(null);
                if (self.cur_buckets[bucket_index] == bucket) {
                    self.cur_buckets[bucket_index] = null;
                }
                if (!config.never_unmap) {
                    self.backing_allocator.free(bucket.page[0..std.heap.pageSize()]);
                }
                if (!config.retain_metadata) {
                    self.freeBucket(bucket, size_class);
                    self.bucket_node_pool.destroy(node);
                } else {
                    // move alloc_cursor to end so we can tell size_class later
                    const slot_count = @divExact(std.heap.pageSize(), size_class);
                    bucket.alloc_cursor = @as(SlotIndex, @truncate(slot_count));
                    var empty_entry = self.empty_buckets.getEntryFor(node.key);
                    empty_entry.set(node);
                }
            } else {
                @memset(old_mem, undefined);
            }
            if (config.verbose_log) {
                log.info("small free {d} bytes at {*}", .{ old_mem.len, old_mem.ptr });
            }
        }

        // Returns true if an allocation of `size` bytes is within the specified
        // limits if enable_memory_limit is true
        fn isAllocationAllowed(self: *Self, size: usize) bool {
            if (config.enable_memory_limit) {
                const new_req_bytes = self.total_requested_bytes + size;
                if (new_req_bytes > self.requested_memory_limit)
                    return false;
                self.total_requested_bytes = new_req_bytes;
            }

            return true;
        }

        fn alloc(ctx: *anyopaque, len: usize, log2_ptr_align: u8, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            self.ensureInitialized() catch return null;
            if (!self.isAllocationAllowed(len)) return null;
            return allocInner(self, len, @as(Allocator.Log2Align, @intCast(log2_ptr_align)), ret_addr) catch return null;
        }

        fn allocInner(
            self: *Self,
            len: usize,
            log2_ptr_align: Allocator.Log2Align,
            ret_addr: usize,
        ) Allocator.Error![*]u8 {
            try self.ensureInitialized();

            const new_aligned_size = @max(len, @as(usize, 1) << @as(Allocator.Log2Align, @intCast(log2_ptr_align)));
            if (new_aligned_size > self.largest_bucket_object_size) {
                try self.large_allocations.ensureUnusedCapacity(self.backing_allocator, 1);
                const ptr = self.backing_allocator.rawAlloc(len, log2_ptr_align, ret_addr) orelse
                    return error.OutOfMemory;
                const slice = ptr[0..len];

                const gop = self.large_allocations.getOrPutAssumeCapacity(@intFromPtr(slice.ptr));
                if (config.retain_metadata and !config.never_unmap) {
                    // Backing allocator may be reusing memory that we're retaining metadata for
                    assert(!gop.found_existing or gop.value_ptr.freed);
                } else {
                    assert(!gop.found_existing); // This would mean the kernel double-mapped pages.
                }
                gop.value_ptr.bytes = slice;
                if (config.enable_memory_limit)
                    gop.value_ptr.requested_size = len;
                gop.value_ptr.captureStackTrace(ret_addr, .alloc);
                if (config.retain_metadata) {
                    gop.value_ptr.freed = false;
                    if (config.never_unmap) {
                        gop.value_ptr.log2_ptr_align = log2_ptr_align;
                    }
                }

                if (config.verbose_log) {
                    log.info("large alloc {d} bytes at {*}", .{ slice.len, slice.ptr });
                }
                return slice.ptr;
            }

            const new_size_class = math.ceilPowerOfTwoAssert(usize, new_aligned_size);
            const slot = try self.allocSlot(new_size_class, ret_addr);
            if (config.safety) {
                slot.bucket.requestedSizes(new_size_class)[slot.slot_index] = @intCast(len);
                slot.bucket.log2PtrAligns(new_size_class)[slot.slot_index] = log2_ptr_align;
            }
            if (config.verbose_log) {
                log.info("small alloc {d} bytes at {*}", .{ len, slot.ptr });
            }
            return slot.ptr;
        }

        fn createBucket(self: *Self, size_class: usize) Error!*BucketHeader {
            const page = try self.backing_allocator.alignedAlloc(u8, 1, std.heap.pageSize());
            errdefer self.backing_allocator.free(page);

            try self.ensureInitialized();

            const bucket_size = bucketSize(size_class);
            const bucket_bytes = try self.backing_allocator.alignedAlloc(u8, @alignOf(BucketHeader), bucket_size);
            const ptr = @as(*BucketHeader, @ptrCast(bucket_bytes.ptr));
            ptr.* = BucketHeader{
                .page = page.ptr,
                .alloc_cursor = 0,
                .used_count = 0,
            };
            // Set the used bits to all zeroes
            @memset(@as([*]u8, @as(*[1]u8, ptr.usedBits(0)))[0..usedBitsCount(size_class)], 0);
            if (config.safety) {
                // Set the requested sizes to zeroes
                @memset(mem.sliceAsBytes(ptr.requestedSizes(size_class)), 0);
            }
            return ptr;
        }
    };
}

const TraceKind = enum {
    alloc,
    free,
};

const test_config = Config{};

test "small allocations - free in same order" {
    var gpa = GeneralPurposeAllocator(test_config){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const allocator = gpa.allocator();

    var list = std.ArrayList(*u64).init(std.testing.allocator);
    defer list.deinit();

    var i: usize = 0;
    while (i < 513) : (i += 1) {
        const ptr = try allocator.create(u64);
        try list.append(ptr);
    }

    for (list.items) |ptr| {
        allocator.destroy(ptr);
    }
}

test "small allocations - free in reverse order" {
    var gpa = GeneralPurposeAllocator(test_config){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const allocator = gpa.allocator();

    var list = std.ArrayList(*u64).init(std.testing.allocator);
    defer list.deinit();

    var i: usize = 0;
    while (i < 513) : (i += 1) {
        const ptr = try allocator.create(u64);
        try list.append(ptr);
    }

    while (list.popOrNull()) |ptr| {
        allocator.destroy(ptr);
    }
}

test "large allocations" {
    var gpa = GeneralPurposeAllocator(test_config){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const allocator = gpa.allocator();

    const ptr1 = try allocator.alloc(u64, 42768);
    const ptr2 = try allocator.alloc(u64, 52768);
    allocator.free(ptr1);
    const ptr3 = try allocator.alloc(u64, 62768);
    allocator.free(ptr3);
    allocator.free(ptr2);
}

test "very large allocation" {
    var gpa = GeneralPurposeAllocator(test_config){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const allocator = gpa.allocator();

    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, math.maxInt(usize)));
}

test "realloc" {
    var gpa = GeneralPurposeAllocator(test_config){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const allocator = gpa.allocator();

    var slice = try allocator.alignedAlloc(u8, @alignOf(u32), 1);
    defer allocator.free(slice);
    slice[0] = 0x12;

    // This reallocation should keep its pointer address.
    const old_slice = slice;
    slice = try allocator.realloc(slice, 2);
    try std.testing.expect(old_slice.ptr == slice.ptr);
    try std.testing.expect(slice[0] == 0x12);
    slice[1] = 0x34;

    // This requires upgrading to a larger size class
    slice = try allocator.realloc(slice, 17);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[1] == 0x34);
}

test "shrink" {
    var gpa = GeneralPurposeAllocator(test_config){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const allocator = gpa.allocator();

    var slice = try allocator.alloc(u8, 20);
    defer allocator.free(slice);

    @memset(slice, 0x11);

    try std.testing.expect(allocator.resize(slice, 17));
    slice = slice[0..17];

    for (slice) |b| {
        try std.testing.expect(b == 0x11);
    }

    try std.testing.expect(allocator.resize(slice, 16));
    slice = slice[0..16];

    for (slice) |b| {
        try std.testing.expect(b == 0x11);
    }
}

test "large object - grow" {
    var gpa = GeneralPurposeAllocator(test_config){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const allocator = gpa.allocator();

    var slice1 = try allocator.alloc(u8, std.heap.pageSize() * 2 - 20);
    defer allocator.free(slice1);

    const old = slice1;
    slice1 = try allocator.realloc(slice1, std.heap.pageSize() * 2 - 10);
    try std.testing.expect(slice1.ptr == old.ptr);

    slice1 = try allocator.realloc(slice1, std.heap.pageSize() * 2);
    try std.testing.expect(slice1.ptr == old.ptr);

    slice1 = try allocator.realloc(slice1, std.heap.pageSize() * 2 + 1);
}

test "realloc small object to large object" {
    var gpa = GeneralPurposeAllocator(test_config){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const allocator = gpa.allocator();

    var slice = try allocator.alloc(u8, 70);
    defer allocator.free(slice);
    slice[0] = 0x12;
    slice[60] = 0x34;

    // This requires upgrading to a large object
    const large_object_size = std.heap.pageSize() * 2 + 50;
    slice = try allocator.realloc(slice, large_object_size);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[60] == 0x34);
}

test "shrink large object to large object" {
    var gpa = GeneralPurposeAllocator(test_config){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const allocator = gpa.allocator();

    var slice = try allocator.alloc(u8, std.heap.pageSize() * 2 + 50);
    defer allocator.free(slice);
    slice[0] = 0x12;
    slice[60] = 0x34;

    if (!allocator.resize(slice, std.heap.pageSize() * 2 + 1)) return;
    slice = slice.ptr[0 .. std.heap.pageSize() * 2 + 1];
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[60] == 0x34);

    try std.testing.expect(allocator.resize(slice, std.heap.pageSize() * 2 + 1));
    slice = slice[0 .. std.heap.pageSize() * 2 + 1];
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[60] == 0x34);

    slice = try allocator.realloc(slice, std.heap.pageSize() * 2);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[60] == 0x34);
}

test "shrink large object to large object with larger alignment" {
    var gpa = GeneralPurposeAllocator(test_config){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const allocator = gpa.allocator();

    var debug_buffer: [1000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&debug_buffer);
    const debug_allocator = fba.allocator();

    const alloc_size = std.heap.pageSize() * 2 + 50;
    var slice = try allocator.alignedAlloc(u8, 16, alloc_size);
    defer allocator.free(slice);

    const big_alignment: usize = switch (builtin.os.tag) {
        .windows => std.heap.pageSize() * 32, // Windows aligns to 64K.
        else => std.heap.pageSize() * 2,
    };
    // This loop allocates until we find a page that is not aligned to the big
    // alignment. Then we shrink the allocation after the loop, but increase the
    // alignment to the higher one, that we know will force it to realloc.
    var stuff_to_free = std.ArrayList([]align(16) u8).init(debug_allocator);
    while (mem.isAligned(@intFromPtr(slice.ptr), big_alignment)) {
        try stuff_to_free.append(slice);
        slice = try allocator.alignedAlloc(u8, 16, alloc_size);
    }
    while (stuff_to_free.popOrNull()) |item| {
        allocator.free(item);
    }
    slice[0] = 0x12;
    slice[60] = 0x34;

    slice = try allocator.reallocAdvanced(slice, big_alignment, alloc_size / 2);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[60] == 0x34);
}

test "realloc large object to small object" {
    var gpa = GeneralPurposeAllocator(test_config){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const allocator = gpa.allocator();

    var slice = try allocator.alloc(u8, std.heap.pageSize() * 2 + 50);
    defer allocator.free(slice);
    slice[0] = 0x12;
    slice[16] = 0x34;

    slice = try allocator.realloc(slice, 19);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[16] == 0x34);
}

test "overridable mutexes" {
    var gpa = GeneralPurposeAllocator(.{ .MutexType = std.Thread.Mutex }){
        .backing_allocator = std.testing.allocator,
        .mutex = std.Thread.Mutex{},
    };
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const allocator = gpa.allocator();

    const ptr = try allocator.create(i32);
    defer allocator.destroy(ptr);
}

test "non-page-allocator backing allocator" {
    var gpa = GeneralPurposeAllocator(.{}){ .backing_allocator = std.testing.allocator };
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const allocator = gpa.allocator();

    const ptr = try allocator.create(i32);
    defer allocator.destroy(ptr);
}

test "realloc large object to larger alignment" {
    var gpa = GeneralPurposeAllocator(test_config){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const allocator = gpa.allocator();

    var debug_buffer: [1000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&debug_buffer);
    const debug_allocator = fba.allocator();

    var slice = try allocator.alignedAlloc(u8, 16, std.heap.pageSize() * 2 + 50);
    defer allocator.free(slice);

    const big_alignment: usize = switch (builtin.os.tag) {
        .windows => std.heap.pageSize() * 32, // Windows aligns to 64K.
        else => std.heap.pageSize() * 2,
    };
    // This loop allocates until we find a page that is not aligned to the big alignment.
    var stuff_to_free = std.ArrayList([]align(16) u8).init(debug_allocator);
    while (mem.isAligned(@intFromPtr(slice.ptr), big_alignment)) {
        try stuff_to_free.append(slice);
        slice = try allocator.alignedAlloc(u8, 16, std.heap.pageSize() * 2 + 50);
    }
    while (stuff_to_free.popOrNull()) |item| {
        allocator.free(item);
    }
    slice[0] = 0x12;
    slice[16] = 0x34;

    slice = try allocator.reallocAdvanced(slice, 32, std.heap.pageSize() * 2 + 100);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[16] == 0x34);

    slice = try allocator.reallocAdvanced(slice, 32, std.heap.pageSize() * 2 + 25);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[16] == 0x34);

    slice = try allocator.reallocAdvanced(slice, big_alignment, std.heap.pageSize() * 2 + 100);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[16] == 0x34);
}

test "large object shrinks to small but allocation fails during shrink" {
    var failing_allocator = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = 5 });
    var gpa = GeneralPurposeAllocator(.{}){ .backing_allocator = failing_allocator.allocator() };
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const allocator = gpa.allocator();

    var slice = try allocator.alloc(u8, std.heap.pageSize() * 2 + 50);
    defer allocator.free(slice);
    slice[0] = 0x12;
    slice[3] = 0x34;

    // Next allocation will fail in the backing allocator of the GeneralPurposeAllocator

    try std.testing.expect(allocator.resize(slice, 4));
    slice = slice[0..4];
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[3] == 0x34);
}

test "objects of size 1024 and 2048" {
    var gpa = GeneralPurposeAllocator(test_config){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const allocator = gpa.allocator();

    const slice = try allocator.alloc(u8, 1025);
    const slice2 = try allocator.alloc(u8, 3000);

    allocator.free(slice);
    allocator.free(slice2);
}

test "setting a memory cap" {
    var gpa = GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const allocator = gpa.allocator();

    gpa.setRequestedMemoryLimit(1010);

    const small = try allocator.create(i32);
    try std.testing.expect(gpa.total_requested_bytes == 4);

    const big = try allocator.alloc(u8, 1000);
    try std.testing.expect(gpa.total_requested_bytes == 1004);

    try std.testing.expectError(error.OutOfMemory, allocator.create(u64));

    allocator.destroy(small);
    try std.testing.expect(gpa.total_requested_bytes == 1000);

    allocator.free(big);
    try std.testing.expect(gpa.total_requested_bytes == 0);

    const exact = try allocator.alloc(u8, 1010);
    try std.testing.expect(gpa.total_requested_bytes == 1010);
    allocator.free(exact);
}

test "double frees" {
    // use a GPA to back a GPA to check for leaks of the latter's metadata
    var backing_gpa = GeneralPurposeAllocator(.{ .safety = true }){};
    defer std.testing.expect(backing_gpa.deinit() == .ok) catch @panic("leak");

    const GPA = GeneralPurposeAllocator(.{ .safety = true, .never_unmap = true, .retain_metadata = true });
    var gpa = GPA{ .backing_allocator = backing_gpa.allocator() };
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const allocator = gpa.allocator();

    // detect a small allocation double free, even though bucket is emptied
    const index: usize = 6;
    const size_class: usize = @as(usize, 1) << 6;
    const small = try allocator.alloc(u8, size_class);
    try std.testing.expect(GPA.searchBucket(&gpa.buckets[index], @intFromPtr(small.ptr), gpa.cur_buckets[index]) != null);
    allocator.free(small);
    try std.testing.expect(GPA.searchBucket(&gpa.buckets[index], @intFromPtr(small.ptr), gpa.cur_buckets[index]) == null);
    try std.testing.expect(GPA.searchBucket(&gpa.empty_buckets, @intFromPtr(small.ptr), null) != null);

    // detect a large allocation double free
    const large = try allocator.alloc(u8, 2 * std.heap.pageSize());
    try std.testing.expect(gpa.large_allocations.contains(@intFromPtr(large.ptr)));
    try std.testing.expectEqual(gpa.large_allocations.getEntry(@intFromPtr(large.ptr)).?.value_ptr.bytes, large);
    allocator.free(large);
    try std.testing.expect(gpa.large_allocations.contains(@intFromPtr(large.ptr)));
    try std.testing.expect(gpa.large_allocations.getEntry(@intFromPtr(large.ptr)).?.value_ptr.freed);

    const normal_small = try allocator.alloc(u8, size_class);
    defer allocator.free(normal_small);
    const normal_large = try allocator.alloc(u8, 2 * std.heap.pageSize());
    defer allocator.free(normal_large);

    // check that flushing retained metadata doesn't disturb live allocations
    gpa.flushRetainedMetadata();
    try std.testing.expect(gpa.empty_buckets.root == null);
    try std.testing.expect(GPA.searchBucket(&gpa.buckets[index], @intFromPtr(normal_small.ptr), gpa.cur_buckets[index]) != null);
    try std.testing.expect(gpa.large_allocations.contains(@intFromPtr(normal_large.ptr)));
    try std.testing.expect(!gpa.large_allocations.contains(@intFromPtr(large.ptr)));
}

test "bug 9995 fix, large allocs count requested size not backing size" {
    // with AtLeast, buffer likely to be larger than requested, especially when shrinking
    var gpa = GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};
    const allocator = gpa.allocator();

    var buf = try allocator.alignedAlloc(u8, 1, std.heap.pageSize() + 1);
    try std.testing.expect(gpa.total_requested_bytes == std.heap.pageSize() + 1);
    buf = try allocator.realloc(buf, 1);
    try std.testing.expect(gpa.total_requested_bytes == 1);
    buf = try allocator.realloc(buf, 2);
    try std.testing.expect(gpa.total_requested_bytes == 2);
}
