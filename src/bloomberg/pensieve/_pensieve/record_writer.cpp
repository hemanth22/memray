#include <chrono>
#include <fcntl.h>
#include <stdexcept>

#include "record_writer.h"

namespace pensieve::tracking_api {

using namespace std::chrono;

RecordWriter::RecordWriter(const std::string& file_name, const std::string& command_line)
: d_buffer(new char[BUFFER_CAPACITY]{0})
, d_command_line(command_line)
, d_stats({0, 0, system_clock::to_time_t(system_clock::now())})
{
    d_header = HeaderRecord{"", d_version, d_stats, d_command_line};
    strncpy(d_header.magic, MAGIC, sizeof(MAGIC));

    fd = ::open(file_name.c_str(), O_CREAT | O_WRONLY | O_CLOEXEC, 0644);
    if (fd < 0) {
        std::runtime_error("Could not open file for writing: " + file_name);
    }
}

RecordWriter::~RecordWriter()
{
    ::close(fd);
}

bool
RecordWriter::flush() noexcept
{
    std::lock_guard<std::mutex> lock(d_mutex);
    return _flush();
}

bool
RecordWriter::_flush() noexcept
{
    if (!d_used_bytes) {
        return true;
    }

    int ret = 0;
    do {
        ret = ::write(fd, d_buffer.get(), d_used_bytes);
    } while (ret < 0 && errno == EINTR);

    if (ret < 0) {
        return false;
    }

    d_used_bytes = 0;

    return true;
}

bool
RecordWriter::reserveHeader() const noexcept
{
    assert(::lseek(fd, 0, SEEK_CUR) == 0);

    int size = sizeof(d_header.magic) + sizeof(d_header.version) + sizeof(d_header.stats)
               + d_header.command_line.length() + 1;
    if (::lseek(fd, size, SEEK_CUR) != size) {
        return false;
    }
    return true;
}

bool
RecordWriter::writeHeader() noexcept
{
    std::lock_guard<std::mutex> lock(d_mutex);
    if (!_flush()) {
        return false;
    }
    ::lseek(fd, 0, SEEK_SET);

    d_stats.end_time = system_clock::to_time_t(system_clock::now());
    d_header.stats = d_stats;
    writeSimpleType(d_header.magic);
    writeSimpleType(d_header.version);
    writeSimpleType(d_header.stats);
    writeString(d_header.command_line.c_str());

    return true;
}

}  // namespace pensieve::tracking_api