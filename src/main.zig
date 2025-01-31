const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn main() !void {
    var free_list_state = BumpAllocator.init(try std.heap.page_allocator.alloc(u8, 1 << 20));
    const alloc = free_list_state.allocator();

    const mem = try alloc.alignedAlloc(u32, 64, 10);
    for (mem, 0..) |*m, i| m.* = @intCast(i);
    alloc.free(mem);

    const new_mem = try alloc.alignedAlloc(u32, 1, 5);
    alloc.free(new_mem);
}

const BumpAllocator = struct {
    mem: []u8,
    ptr: usize,

    pub fn init(mem: []u8) BumpAllocator {
        return .{ .mem = mem, .ptr = 0 };
    }

    pub fn allocator(self: *BumpAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .free = free,
                .resize = resize,
            },
        };
    }

    fn alloc(ctx: *anyopaque, n: usize, log2_align: u8, ra: usize) ?[*]u8 {
        _ = ra;
        _ = log2_align;
        const state: *BumpAllocator = @ptrCast(@alignCast(ctx));
        if (state.ptr + n >= state.mem.len) {
            return null;
        }
        defer state.ptr += n;

        return state.mem[state.ptr .. state.ptr + n].ptr;
    }

    fn resize(
        _: *anyopaque,
        buf_unaligned: []u8,
        log2_buf_align: u8,
        new_size: usize,
        return_address: usize,
    ) bool {
        _ = buf_unaligned;
        _ = log2_buf_align;
        _ = new_size;
        _ = return_address;
        // Maybe later, for now resizing is not supported.
        return false;
    }

    fn free(ctx: *anyopaque, slice: []u8, log2_buf_align: u8, return_address: usize) void {
        _ = log2_buf_align;
        _ = return_address;
        const state: *BumpAllocator = @ptrCast(@alignCast(ctx));
        if (@intFromPtr(state.mem.ptr) + state.ptr - slice.len == @intFromPtr(slice.ptr)) {
            state.ptr -= slice.len;
        }
    }
};

const FreeListAllocator = struct {
    const FreeList = std.DoublyLinkedList([]u8);

    backing: Allocator,
    free_list: FreeList,

    pub fn init(backing_allocator: Allocator) FreeListAllocator {
        return .{
            .backing = backing_allocator,
            .free_list = .{},
        };
    }

    pub fn allocator(self: *FreeListAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .free = free,
                .resize = resize,
            },
        };
    }

    fn alloc(ctx: *anyopaque, n: usize, log2_align: u8, ra: usize) ?[*]u8 {
        _ = ra;

        const state: *FreeListAllocator = @ptrCast(@alignCast(ctx));
        // Select what block to allocate from.
        var block: *FreeList.Node = blk: {
            var it = state.free_list.first orelse break :blk state.allocateNewBlock(n, null) catch return null;
            while (true) {
                it = it.next orelse break :blk state.allocateNewBlock(n, it) catch return null;
                if (it.data.len >= n) {
                    break :blk it;
                }
            }
        };

        std.log.debug("Allocating from block with data size {d}", .{block.data.len});
        std.log.debug("Alignment is {d}", .{@as(u64, 1) << @intCast(log2_align)});

        var aligned_addr = std.mem.alignForwardLog2(@intFromPtr(block.data.ptr), log2_align);
        var alignment_offset = aligned_addr - @intFromPtr(block.data.ptr);
        std.log.debug("Alignment offset of {d} needed", .{alignment_offset});

        // TODO: Extermely bad but it will do for now.
        while (block.data.len < alignment_offset + n) {
            std.log.debug("Alignment offset makes data not fit, allocating new block", .{});
            block = state.allocateNewBlock(n + alignment_offset, block) catch return null;

            aligned_addr = std.mem.alignForwardLog2(@intFromPtr(block.data.ptr), log2_align);
            alignment_offset = aligned_addr - @intFromPtr(block.data.ptr);
            std.log.debug("Alignment offset {d} needed for new block", .{alignment_offset});
        }

        // Write out the alignment so we can use it the calculate the header position.
        const alignment_ptr: *usize = @ptrFromInt(@intFromPtr(block.data.ptr) + alignment_offset - @sizeOf(usize));
        alignment_ptr.* = alignment_offset;

        // TODO: Subdivide large blocks to save space.

        return block.data[alignment_offset .. alignment_offset + n].ptr;
    }

    fn resize(
        _: *anyopaque,
        buf_unaligned: []u8,
        log2_buf_align: u8,
        new_size: usize,
        return_address: usize,
    ) bool {
        _ = buf_unaligned;
        _ = log2_buf_align;
        _ = new_size;
        _ = return_address;

        // Maybe later, for now resizing is not supported.
        return false;
    }

    fn free(ctx: *anyopaque, slice: []u8, log2_buf_align: u8, return_address: usize) void {
        _ = log2_buf_align;
        _ = return_address;
        const state: *FreeListAllocator = @ptrCast(@alignCast(ctx));
        const alignment: *usize = @ptrFromInt(@intFromPtr(slice.ptr) - @sizeOf(usize));
        std.log.debug("Freeing block that was allocated with alignment offset {d}", .{alignment.*});
        const header_offset = alignment.* + header_size;
        std.log.debug("Header offset for freed block is {d}", .{header_offset});

        const header: *FreeList.Node = @ptrFromInt(@intFromPtr(slice.ptr) - header_offset);
        std.log.debug("Freed blocks data size is {d}", .{header.data.len});

        const new_data_start: [*]u8 = @ptrFromInt(@intFromPtr(slice.ptr) - alignment.*);
        header.data = new_data_start[0 .. slice.len + alignment.*];
        std.log.debug("Header size after removing aligment padding: {d}", .{header.data.len});

        state.free_list.remove(header);
    }

    const header_size = @sizeOf(FreeList.Node) + @sizeOf(usize);

    fn allocateNewBlock(self: *FreeListAllocator, allocation_size: usize, prev_block: ?*FreeList.Node) !*FreeList.Node {
        std.log.debug("Allocating new block with allocation size {d}", .{allocation_size});
        const new_block_size = ((allocation_size + std.mem.page_size - 1) / std.mem.page_size) * std.mem.page_size;
        const memory: [*]align(std.mem.page_size) u8 = @alignCast(self.backing.rawAlloc(std.mem.page_size, std.math.log2(std.mem.page_size), @returnAddress()) orelse return error.OutOfMemory);
        std.log.debug("Actual allocation size was {d}", .{new_block_size});

        const header: *FreeList.Node = @ptrCast(memory);
        const useable_memory = memory[header_size..new_block_size];
        std.log.debug("Useable memory from {d}-{d} with size {d}", .{ header_size, new_block_size, useable_memory.len });

        header.data = useable_memory;
        if (prev_block) |b| {
            self.free_list.insertAfter(b, header);
        } else {
            self.free_list.prepend(header);
        }

        return header;
    }
};
