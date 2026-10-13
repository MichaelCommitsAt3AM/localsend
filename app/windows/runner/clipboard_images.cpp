#include "clipboard_images.h"
#include <wincodec.h>
#include <wrl/client.h>
#include <stdexcept>
#include <cstring>
using Microsoft::WRL::ComPtr;
namespace clipboard_images {
namespace {
void Check(HRESULT result) { if (FAILED(result)) throw std::runtime_error("Clipboard image unavailable"); }
void Bounds(UINT w, UINT h) {
  if (!w || !h || w > 16384 || h > 16384 || uint64_t(w) * h > 16000000)
    throw std::runtime_error("Clipboard image dimensions exceed limits");
}
struct Decoder {
  ComPtr<IWICImagingFactory> factory;
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  explicit Decoder(const std::vector<uint8_t>& bytes) {
    if (bytes.empty() || bytes.size() > 64000138) throw std::runtime_error("Invalid image size");
    Check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)));
    ComPtr<IWICStream> stream; Check(factory->CreateStream(&stream));
    Check(stream->InitializeFromMemory(const_cast<BYTE*>(bytes.data()), static_cast<DWORD>(bytes.size())));
    Check(factory->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder));
    UINT count; Check(decoder->GetFrameCount(&count));
    if (count != 1) throw std::runtime_error("Animated images unsupported");
    Check(decoder->GetFrame(0, &frame));
    UINT w, h; Check(frame->GetSize(&w, &h)); Bounds(w, h);
  }
};
std::vector<uint8_t> CopyGlobal(UINT format, size_t max) {
  HANDLE handle = GetClipboardData(format); SIZE_T size = handle ? GlobalSize(handle) : 0;
  if (!size || size > max) return {};
  const auto data = static_cast<const uint8_t*>(GlobalLock(handle));
  if (!data) return {};
  std::vector<uint8_t> bytes(data, data + size); GlobalUnlock(handle); return bytes;
}
}
std::vector<uint8_t> Read() {
  const UINT png = RegisterClipboardFormatW(L"PNG");
  if (png && IsClipboardFormatAvailable(png)) return CopyGlobal(png, kMaxBytes);
  const UINT format = IsClipboardFormatAvailable(CF_DIBV5) ? CF_DIBV5 : CF_DIB;
  auto dib = CopyGlobal(format, 64000124);
  if (dib.size() < sizeof(BITMAPINFOHEADER)) return {};
  BITMAPINFOHEADER header; std::memcpy(&header, dib.data(), sizeof(header));
  if ((header.biSize != 40 && header.biSize != 108 && header.biSize != 124) || header.biSize > dib.size() ||
      header.biPlanes != 1 || (header.biBitCount != 24 && header.biBitCount != 32) ||
      header.biWidth <= 0 || header.biHeight == LONG_MIN || header.biHeight == 0 ||
      (header.biCompression != BI_RGB && header.biCompression != BI_BITFIELDS)) return {};
  Bounds(header.biWidth, static_cast<UINT>(header.biHeight < 0 ? -header.biHeight : header.biHeight));
  size_t offset = header.biSize + (header.biSize == 40 && header.biCompression == BI_BITFIELDS ? 12 : 0);
  if (offset > dib.size() || header.biClrUsed != 0) return {};
  BITMAPFILEHEADER file{}; file.bfType = 0x4d42;
  file.bfSize = static_cast<DWORD>(sizeof(file) + dib.size()); file.bfOffBits = static_cast<DWORD>(sizeof(file) + offset);
  std::vector<uint8_t> bmp(sizeof(file) + dib.size());
  std::memcpy(bmp.data(), &file, sizeof(file)); std::memcpy(bmp.data() + sizeof(file), dib.data(), dib.size());
  return bmp;
}
std::vector<uint8_t> Normalize(const std::vector<uint8_t>& source) {
  Decoder image(source);
  ComPtr<IStream> stream; Check(CreateStreamOnHGlobal(nullptr, TRUE, &stream));
  ComPtr<IWICBitmapEncoder> encoder; Check(image.factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder));
  Check(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache));
  ComPtr<IWICBitmapFrameEncode> frame; Check(encoder->CreateNewFrame(&frame, nullptr)); Check(frame->Initialize(nullptr));
  UINT w, h; Check(image.frame->GetSize(&w, &h)); Check(frame->SetSize(w, h));
  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA; Check(frame->SetPixelFormat(&format));
  ComPtr<IWICFormatConverter> converter; Check(image.factory->CreateFormatConverter(&converter));
  Check(converter->Initialize(image.frame.Get(), format, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom));
  Check(frame->WriteSource(converter.Get(), nullptr)); Check(frame->Commit()); Check(encoder->Commit());
  STATSTG stat{}; Check(stream->Stat(&stat, STATFLAG_NONAME));
  if (!stat.cbSize.QuadPart || stat.cbSize.QuadPart > kMaxBytes) throw std::runtime_error("Clipboard PNG exceeds limits");
  LARGE_INTEGER start{}; Check(stream->Seek(start, STREAM_SEEK_SET, nullptr));
  std::vector<uint8_t> bytes(static_cast<size_t>(stat.cbSize.QuadPart)); ULONG read;
  Check(stream->Read(bytes.data(), static_cast<ULONG>(bytes.size()), &read));
  if (read != bytes.size()) throw std::runtime_error("Incomplete clipboard image");
  return bytes;
}
std::vector<uint8_t> ToDib(const std::vector<uint8_t>& png) {
  if (png.size() > kMaxBytes) throw std::runtime_error("Clipboard PNG exceeds limits");
  Decoder image(png);
  UINT w, h; Check(image.frame->GetSize(&w, &h));
  const UINT size = w * h * 4;
  std::vector<uint8_t> dib(sizeof(BITMAPV5HEADER) + size);
  auto header = reinterpret_cast<BITMAPV5HEADER*>(dib.data());
  header->bV5Size = sizeof(*header); header->bV5Width = w; header->bV5Height = -static_cast<LONG>(h);
  header->bV5Planes = 1; header->bV5BitCount = 32; header->bV5Compression = BI_BITFIELDS;
  header->bV5SizeImage = size; header->bV5RedMask = 0x00ff0000; header->bV5GreenMask = 0x0000ff00;
  header->bV5BlueMask = 0x000000ff; header->bV5AlphaMask = 0xff000000; header->bV5CSType = LCS_sRGB;
  ComPtr<IWICFormatConverter> converter; Check(image.factory->CreateFormatConverter(&converter));
  Check(converter->Initialize(image.frame.Get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom));
  Check(converter->CopyPixels(nullptr, w * 4, size, dib.data() + sizeof(*header)));
  return dib;
}
}
