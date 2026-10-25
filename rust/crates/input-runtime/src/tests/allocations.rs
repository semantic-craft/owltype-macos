use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

thread_local! {
    static COUNT: Cell<usize> = const { Cell::new(0) };
    static BYTES: Cell<usize> = const { Cell::new(0) };
}

struct Counting;

fn record(size: usize) {
    let _ = COUNT.try_with(|count| count.set(count.get().wrapping_add(1)));
    let _ = BYTES.try_with(|bytes| bytes.set(bytes.get().wrapping_add(size)));
}

// 安全：指针和布局原样委托给 System，只在当前线程累计整数。
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        record(layout.size());
        unsafe { System.alloc(layout) }
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        record(layout.size());
        unsafe { System.alloc_zeroed(layout) }
    }
    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        record(size);
        unsafe { System.realloc(pointer, layout, size) }
    }
    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        unsafe { System.dealloc(pointer, layout) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

pub(super) fn count<T>(operation: impl FnOnce() -> T) -> (T, usize) {
    let before = COUNT.with(Cell::get);
    let result = operation();
    (result, COUNT.with(Cell::get).wrapping_sub(before))
}

pub(crate) fn count_bytes<T>(operation: impl FnOnce() -> T) -> (T, usize, usize) {
    let before = BYTES.with(Cell::get);
    let (result, allocations) = count(operation);
    (
        result,
        allocations,
        BYTES.with(Cell::get).wrapping_sub(before),
    )
}
