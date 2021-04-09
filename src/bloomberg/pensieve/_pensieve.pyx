import pathlib
import sys
import logging

cimport cython
import threading

from libcpp cimport bool
from libcpp.memory cimport shared_ptr, make_shared, unique_ptr
from libcpp.string cimport string as cppstring
from libcpp.utility cimport move
from libcpp.vector cimport vector

from _pensieve.tracking_api cimport install_trace_function
from _pensieve.tracking_api cimport Tracker as NativeTracker
from _pensieve.logging cimport initializePythonLoggerInterface
from _pensieve.alloc cimport calloc, free, malloc, realloc, posix_memalign, memalign, valloc, pvalloc
from _pensieve.pthread cimport pthread_create, pthread_join, pthread_t
from _pensieve.record_reader cimport RecordReader
from _pensieve.record_reader cimport getHighWatermarkIndex
from _pensieve.record_reader cimport Py_GetSnapshotAllocationRecords
from _pensieve.records cimport Allocation as NativeAllocation

initializePythonLoggerInterface()

LOGGER = logging.getLogger(__file__)

cdef unique_ptr[NativeTracker] _TRACKER

cdef api void log_with_python(cppstring message, int level):
    LOGGER.log(level, message)


cpdef enum AllocatorType:
    MALLOC = 1
    FREE = 2
    CALLOC = 3
    REALLOC = 4
    POSIX_MEMALIGN = 5
    MEMALIGN = 6
    VALLOC = 7
    PVALLOC = 8
    MMAP = 9
    MUNMAP = 10


def size_fmt(num, suffix='B'):
    for unit in ['','K','M','G','T','P','E','Z']:
        if abs(num) < 1024.0:
            return f"{num:5.3f}{unit}{suffix}"
        num /= 1024.0
    return f"{num:.1f}Y{suffix}"


@cython.freelist(1024)
cdef class AllocationRecord:
    cdef object _tuple
    cdef object _stack_trace
    cdef object _native_stack_trace
    cdef shared_ptr[RecordReader] _reader

    def __init__(self, record):
        self._tuple = record
        self._stack_trace = None

    def __eq__(self, other):
        cdef AllocationRecord _other
        if isinstance(other, AllocationRecord):
            _other = other
            return self._tuple == _other._tuple
        return NotImplemented

    def __hash__(self):
        return hash(self._tuple)

    @property
    def tid(self):
        return self._tuple[0]

    @property
    def address(self):
        return self._tuple[1]

    @property
    def size(self):
        return self._tuple[2]

    @property
    def allocator(self):
        return self._tuple[3]

    @property
    def stack_id(self):
        return self._tuple[4]

    @property
    def n_allocations(self):
        return self._tuple[5]

    def stack_trace(self, max_stacks=None):
        if self._stack_trace is None:
            if max_stacks is None:
                self._stack_trace = self._reader.get().Py_GetStackFrame(self._tuple[4])
            else:
                self._stack_trace = self._reader.get().Py_GetStackFrame(self._tuple[4], max_stacks)
        return self._stack_trace

    def native_stack_trace(self, max_stacks=None):
        if self._native_stack_trace is None:
            if max_stacks is None:
                self._native_stack_trace = self._reader.get().Py_GetNativeStackFrame(
                        self._tuple[6], self._tuple[7])
            else:
                self._native_stack_trace = self._reader.get().Py_GetNativeStackFrame(
                        self._tuple[6], self._tuple[7], max_stacks)
        return self._native_stack_trace

    def __repr__(self):
        return (f"AllocationRecord<tid={hex(self.tid)}, address={hex(self.address)}, "
                f"size={'N/A' if not self.size else size_fmt(self.size)}, allocator={self.allocator!r}, "
                f"allocations={self.n_allocations}>")

cdef class Tracker:
    cdef bool _native_traces
    cdef object _previous_profile_func
    cdef object _previous_thread_profile_func
    cdef object _command_line
    cdef cppstring _output_path
    cdef shared_ptr[RecordReader] _reader
    cdef vector[NativeAllocation] _native_allocations

    def __cinit__(self, object file_name, *, bool native_traces=False):
        self._output_path = str(file_name)
        self._native_traces = native_traces

    def __enter__(self):
        if pathlib.Path(self._output_path).exists():
            raise OSError(f"Output file {self._output_path} already exists")
        if _TRACKER.get() != NULL:
            raise RuntimeError("No more than one Tracker instance can be active at the same time")

        self._command_line = " ".join(sys.argv)
        self._previous_profile_func = sys.getprofile()
        self._previous_thread_profile_func = threading._profile_hook
        threading.setprofile(start_thread_trace)

        _TRACKER.reset(new NativeTracker(self._output_path, self._native_traces, self._command_line))
        return self

    def __del__(self):
        self._reader.reset()

    def __exit__(self, exc_type, exc_value, exc_traceback):
        _TRACKER.reset(NULL)
        sys.setprofile(self._previous_profile_func)
        threading.setprofile(self._previous_thread_profile_func)

    cdef inline RecordReader* _get_new_reader(self) except NULL:
        self._reader = make_shared[RecordReader](self._output_path)
        return self._reader.get()

    cdef inline void _get_allocations(self, RecordReader* reader) except+:
        if self._native_allocations.size() != 0:
            self._native_allocations.clear()

        cdef NativeAllocation native_allocation
        total_allocations = self.header["stats"]["n_allocations"]
        self._native_allocations.reserve(total_allocations)
        while reader.nextAllocationRecord(&native_allocation):
            self._native_allocations.push_back(move(native_allocation))

    def _yield_allocations(self, size_t index):
        assert (self._reader.get() != NULL)
        for elem in Py_GetSnapshotAllocationRecords(self._native_allocations, index):
            alloc = AllocationRecord(elem);
            (<AllocationRecord>alloc)._reader = self._reader
            yield alloc
        self._native_allocations.clear()

    def get_high_watermark_allocation_records(self):
        cdef RecordReader* reader = self._get_new_reader()
        self._get_allocations(reader)
        cdef size_t high_watermark_index = getHighWatermarkIndex(self._native_allocations)
        yield from self._yield_allocations(high_watermark_index)

    def get_leaked_allocation_records(self):
        cdef RecordReader* reader = self._get_new_reader()
        self._get_allocations(reader)

        cdef size_t snapshot_index = self._native_allocations.size() - 1
        yield from self._yield_allocations(snapshot_index)

    def get_allocation_records(self):
        self._reader = make_shared[RecordReader](self._output_path)
        cdef RecordReader* reader = self._reader.get()
        cdef NativeAllocation native_allocation

        while reader.nextAllocationRecord(&native_allocation):
            alloc = AllocationRecord(native_allocation.toPythonObject())
            (<AllocationRecord>alloc)._reader = self._reader
            yield alloc

    @property
    def header(self):
        if self._reader == NULL:
            self._reader = make_shared[RecordReader](self._output_path)

        cdef RecordReader* reader = self._reader.get()
        return reader.getHeader()


def start_thread_trace(frame, event, arg):
    if event in {"call", "c_call"}:
        install_trace_function()
    return start_thread_trace


# Testing utilities

cdef class MemoryAllocator:
    cdef void* ptr

    def __cinit__(self):
        self.ptr = NULL

    def free(self):
        if self.ptr == NULL:
            raise RuntimeError("Pointer cannot be NULL")
        free(self.ptr)
        self.ptr = NULL

    def malloc(self, size_t size):
        self.ptr = malloc(size)

    def calloc(self, size_t size):
        self.ptr = calloc(1, size)

    def realloc(self, size_t size):
        self.ptr = malloc(1)
        self.ptr = realloc(self.ptr, size)

    def posix_memalign(self, size_t size):
        posix_memalign(&self.ptr, sizeof(void*), size)

    def memalign(self, size_t size):
        self.ptr = memalign(sizeof(void*), size)

    def valloc(self, size_t size):
        self.ptr = valloc(size)

    def pvalloc(self, size_t size):
        self.ptr = pvalloc(size)

    def run_in_pthread(self, callback):
        cdef pthread_t thread
        cdef int ret = pthread_create(&thread, NULL, &_pthread_worker, <void*>callback)
        if ret != 0:
            raise RuntimeError("Failed to create thread")
        with nogil:
            pthread_join(thread, NULL)


def _cython_nested_allocation(allocator_fn, size):
    allocator_fn(size)
    cdef void* p = valloc(size);
    free(p)


cdef void* _pthread_worker(void* arg) with gil:
    (<object> arg)()
