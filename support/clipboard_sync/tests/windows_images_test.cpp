// Standalone WIC adapter test: no OS clipboard changes and no network traffic.
#include "../../../app/windows/runner/clipboard_images.h"
#include <algorithm>
#include <cstring>
#include <iostream>
#include <stdexcept>

int main() {
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized)) return 1;
  try {
    BITMAPFILEHEADER file{};
    BITMAPV5HEADER header{};
    header.bV5Size = sizeof(header); header.bV5Width = 2; header.bV5Height = -1;
    header.bV5Planes = 1; header.bV5BitCount = 32; header.bV5Compression = BI_BITFIELDS;
    header.bV5SizeImage = 8; header.bV5RedMask = 0x00ff0000; header.bV5GreenMask = 0x0000ff00;
    header.bV5BlueMask = 0x000000ff; header.bV5AlphaMask = 0xff000000; header.bV5CSType = LCS_sRGB;
    const std::vector<uint8_t> pixels{0, 0, 255, 128, 0, 255, 0, 255};
    std::vector<uint8_t> bmp(sizeof(file) + sizeof(header) + pixels.size());
    file.bfType = 0x4d42; file.bfSize = static_cast<DWORD>(bmp.size());
    file.bfOffBits = sizeof(file) + sizeof(header);
    std::memcpy(bmp.data(), &file, sizeof(file)); std::memcpy(bmp.data() + sizeof(file), &header, sizeof(header));
    std::memcpy(bmp.data() + file.bfOffBits, pixels.data(), pixels.size());
    const auto png = clipboard_images::Normalize(bmp);
    const auto dib = clipboard_images::ToDib(png);
    if (dib.size() != sizeof(header) + pixels.size() ||
        !std::equal(pixels.begin(), pixels.end(), dib.begin() + sizeof(header))) throw std::runtime_error("Pixel/alpha round trip failed");
    bool rejected = false;
    try { clipboard_images::ToDib({1,2,3}); } catch (...) { rejected = true; }
    if (!rejected) throw std::runtime_error("Malformed image accepted");
    rejected = false;
    try { clipboard_images::ToDib(std::vector<uint8_t>(clipboard_images::kMaxBytes + 1)); } catch (...) { rejected = true; }
    if (!rejected) throw std::runtime_error("Oversized image accepted");
    header.bV5Width = 16385;
    std::memcpy(bmp.data() + sizeof(file), &header, sizeof(header));
    rejected = false;
    try { clipboard_images::Normalize(bmp); } catch (...) { rejected = true; }
    if (!rejected) throw std::runtime_error("Oversized dimensions accepted");
    std::cout << "WIC image tests passed: pixels, alpha, malformed input, byte and dimension bounds\n";
    CoUninitialize(); return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; CoUninitialize(); return 1; }
}
