#ifndef RUNNER_CLIPBOARD_IMAGES_H_
#define RUNNER_CLIPBOARD_IMAGES_H_
#include <windows.h>
#include <vector>
#include <cstdint>
namespace clipboard_images {
constexpr size_t kMaxBytes = 8 * 1024 * 1024;
// Caller holds the clipboard lock. Copies encoded PNG or a BMP wrapper for DIB.
std::vector<uint8_t> Read();
// WIC decode/encode runs on the bridge's single background worker.
std::vector<uint8_t> Normalize(const std::vector<uint8_t>& source);
std::vector<uint8_t> ToDib(const std::vector<uint8_t>& png);
}
#endif
