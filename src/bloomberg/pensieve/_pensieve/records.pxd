from libc.stdint cimport uintptr_t
from libc.time cimport time_t
from libcpp.string cimport string
from libcpp.vector cimport vector
cdef extern from "records.h" namespace "pensieve::tracking_api":

   struct Frame:
       string function_name
       string filename
       int lineno

   struct AllocationRecord:
       long int tid
       uintptr_t address
       size_t size
       string allocator
       vector[Frame] stack_trace

   struct TrackerStats:
       size_t n_allocations
       size_t n_frames
       time_t start_time
       time_t end_time

   struct HeaderRecord:
       int version
       TrackerStats stats
       string command_line

   cdef cppclass Allocation:
       AllocationRecord record
       size_t frame_index
       size_t n_allocactions
       object toPythonObject()

