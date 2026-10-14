#include "clipboard_bridge.h"
#include "clipboard_secrets.h"
#include "clipboard_images.h"
#include "clipboard_notifications.h"
#include <flutter/standard_method_codec.h>
#include <flutter/event_stream_handler_functions.h>
#include <cstring>
#include <string>
#include <random>
#include <stdexcept>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
constexpr size_t kMaxBytes = 65536;
constexpr UINT_PTR kClipboardTimer = 0x434C4950;
constexpr UINT kImageComplete = WM_APP + 0x451;

std::wstring ArrivalText(const Map* args, const char* key, size_t limit) {
  if (!args) return {};
  const auto value = args->find(Value(key));
  const auto text = value != args->end() ? std::get_if<std::string>(&value->second) : nullptr;
  if (!text || text->empty() || text->size() > 1024) return {};
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text->data(), static_cast<int>(text->size()), nullptr, 0);
  if (length <= 0) return {};
  std::wstring wide(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text->data(), static_cast<int>(text->size()), wide.data(), length);
  if (wide.size() > limit) wide.resize(limit);
  if (!wide.empty() && wide.back() >= 0xd800 && wide.back() <= 0xdbff) wide.pop_back();
  return wide;
}

class ClipboardLock {
 public:
  explicit ClipboardLock(HWND window) : open_(OpenClipboard(window) != 0) {}
  ~ClipboardLock() { if (open_) CloseClipboard(); }
  bool open() const { return open_; }
 private:
  bool open_;
};

bool Excluded() {
  const UINT exclude = RegisterClipboardFormatW(L"ExcludeClipboardContentFromMonitorProcessing");
  if (exclude && IsClipboardFormatAvailable(exclude)) return true;
  for (const wchar_t* name : {L"CanIncludeInClipboardHistory", L"CanUploadToCloudClipboard"}) {
    const UINT format = RegisterClipboardFormatW(name);
    if (format && IsClipboardFormatAvailable(format)) {
      HANDLE data = GetClipboardData(format);
      if (!data || GlobalSize(data) < sizeof(DWORD)) return true;
      auto flag = static_cast<const DWORD*>(GlobalLock(data));
      if (!flag) return true;
      const bool excluded = *flag != 1; GlobalUnlock(data);
      if (excluded) return true;
    }
  }
  return false;
}
}

ClipboardBridge::ClipboardBridge(HWND window, flutter::BinaryMessenger* messenger) : window_(window) {
  std::random_device random;
  for (auto& part : remote_token_) part = random();
  methods_ = std::make_unique<flutter::MethodChannel<Value>>(messenger,
      "org.localsend.localsend_app/clipboard", &flutter::StandardMethodCodec::GetInstance());
  events_ = std::make_unique<flutter::EventChannel<Value>>(messenger,
      "org.localsend.localsend_app/clipboard_events", &flutter::StandardMethodCodec::GetInstance());
  events_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<Value>>(
      [this](const Value*, std::unique_ptr<flutter::EventSink<Value>>&& sink) {
        sink_ = std::move(sink); return std::unique_ptr<flutter::StreamHandlerError<Value>>();
      }, [this](const Value*) {
        Stop(); sink_.reset(); return std::unique_ptr<flutter::StreamHandlerError<Value>>();
      }));
  methods_->SetMethodCallHandler([this](const flutter::MethodCall<Value>& call,
      std::unique_ptr<flutter::MethodResult<Value>> result) {
    const std::string& method = call.method_name();
    if (method == "loadSecret" || method == "saveSecret") {
      try {
        if (method == "loadSecret") {
          const auto value = LoadClipboardSecret();
          result->Success(value ? Value(*value) : Value());
        } else {
          const auto args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
          if (!args) throw std::runtime_error("Missing secure configuration");
          SaveClipboardSecret(std::get<std::string>(args->at(Value("value")))); result->Success();
        }
      } catch (...) { result->Error("SECURE_STORAGE_FAILED", "Clipboard secure storage unavailable"); }
      return;
    }
    if (method == "status" || method == "authorize") {
      result->Success(Value(Map{{Value("supported"), Value(true)}, {Value("authorized"), Value(true)},
          {Value("running"), Value(running_)}, {Value("sequence"), Value(static_cast<int64_t>(GetClipboardSequenceNumber()))}}));
    } else if (method == "start") {
      const auto args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto option = args ? args->find(Value("syncImages")) : Map::const_iterator();
      sync_images_ = args && option != args->end() && std::get_if<bool>(&option->second) && std::get<bool>(option->second);
      if (!running_ && !AddClipboardFormatListener(window_)) {
        result->Error("LISTENER_FAILED", "Windows clipboard listener could not start"); return;
      }
      running_ = true; result->Success(); // Never read/broadcast the startup clipboard.
    } else if (method == "stop") {
      Stop(); result->Success();
    } else if (method == "read") {
      if (!running_) { result->Error("STOPPED", "Clipboard sync is stopped"); return; }
      ClipboardLock lock(window_);
      if (!lock.open()) { result->Error("CLIPBOARD_BUSY", "Clipboard is busy; try again"); return; }
      Map data{{Value("text"), Value()}, {Value("sequence"), Value(static_cast<int64_t>(GetClipboardSequenceNumber()))}};
      const UINT origin = RegisterClipboardFormatW(L"LocalSendClipboardRemoteOrigin");
      HANDLE origin_data = origin ? GetClipboardData(origin) : nullptr;
      if (origin_data && GlobalSize(origin_data) == sizeof(remote_token_)) {
        const void* marker = GlobalLock(origin_data);
        const bool own = marker && std::memcmp(marker, remote_token_.data(), sizeof(remote_token_)) == 0;
        if (marker) GlobalUnlock(origin_data);
        if (own) { data[Value("suppressEcho")] = Value(true); result->Success(Value(data)); return; }
      }
      if (!Excluded() && sync_images_ && (IsClipboardFormatAvailable(CF_DIB) || IsClipboardFormatAvailable(CF_DIBV5) ||
          IsClipboardFormatAvailable(RegisterClipboardFormatW(L"PNG")))) {
        if (image_worker_.joinable()) { result->Error("CLIPBOARD_BUSY", "Clipboard image processing is busy"); return; }
        std::vector<uint8_t> source;
        try { source = clipboard_images::Read(); } catch (...) { result->Error("INVALID_IMAGE", "Clipboard image unavailable or oversized"); return; }
        if (source.empty()) { result->Success(Value(data)); return; }
        const DWORD sequence = GetClipboardSequenceNumber(); const auto generation = generation_;
        auto pending = std::shared_ptr<flutter::MethodResult<Value>>(std::move(result));
        ImageTask([this, source = std::move(source), pending, sequence, generation]() -> std::function<void()> {
          try {
            auto png = clipboard_images::Normalize(source);
            return [this, pending, png = std::move(png), sequence, generation] {
              if (!running_ || generation_ != generation) { pending->Error("STOPPED", "Clipboard sync stopped"); return; }
              if (GetClipboardSequenceNumber() != sequence) { pending->Success(Value(Map{{Value("text"), Value()},
                  {Value("sequence"), Value(static_cast<int64_t>(GetClipboardSequenceNumber()))}})); return; }
              pending->Success(Value(Map{{Value("text"), Value()}, {Value("image"), Value(png)},
                  {Value("sequence"), Value(static_cast<int64_t>(sequence))}}));
            };
          } catch (...) { return [pending] { pending->Error("INVALID_IMAGE", "Clipboard image unavailable or oversized"); }; }
        });
        return;
      }
      if (!Excluded() && IsClipboardFormatAvailable(CF_UNICODETEXT)) {
        HANDLE memory = GetClipboardData(CF_UNICODETEXT);
        const SIZE_T size = memory ? GlobalSize(memory) : 0;
        if (size > 0 && size <= (kMaxBytes + 1) * sizeof(wchar_t)) {
          auto wide = static_cast<const wchar_t*>(GlobalLock(memory));
          if (wide) {
            size_t length = 0;
            while (length < size / sizeof(wchar_t) && wide[length] != L'\0') ++length;
            if (length < size / sizeof(wchar_t) && length > 0) {
              const int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide,
                  static_cast<int>(length), nullptr, 0, nullptr, nullptr);
              if (bytes > 0 && bytes <= static_cast<int>(kMaxBytes)) {
                std::string text(bytes, '\0');
                WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, static_cast<int>(length), text.data(), bytes, nullptr, nullptr);
                data[Value("text")] = Value(text);
              }
            }
            GlobalUnlock(memory);
          }
        }
      }
      result->Success(Value(data));
    } else if (method == "writeImage") {
      const auto args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto image = args ? args->find(Value("image")) : Map::const_iterator();
      const auto bytes = args && image != args->end() ? std::get_if<std::vector<uint8_t>>(&image->second) : nullptr;
      if (!running_ || !sync_images_ || !bytes || bytes->empty() || bytes->size() > clipboard_images::kMaxBytes) {
        result->Error("INVALID_IMAGE", "Clipboard image unsupported or disabled"); return;
      }
      if (image_worker_.joinable()) { result->Error("CLIPBOARD_BUSY", "Clipboard image processing is busy"); return; }
      int64_t expected = static_cast<int64_t>(GetClipboardSequenceNumber());
      const auto seq = args->find(Value("sequence"));
      if (seq != args->end()) {
        if (const auto n = std::get_if<int32_t>(&seq->second)) expected = *n;
        else if (const auto n64 = std::get_if<int64_t>(&seq->second)) expected = *n64;
      }
      const auto generation = generation_; auto png = *bytes;
      const auto arrival_title = ArrivalText(args, "notificationTitle", 63);
      const auto arrival_body = ArrivalText(args, "notificationBody", 255);
      auto pending = std::shared_ptr<flutter::MethodResult<Value>>(std::move(result));
      ImageTask([this, png = std::move(png), pending, expected, generation, arrival_title, arrival_body]() -> std::function<void()> {
        try {
          auto dib = clipboard_images::ToDib(png);
          return [this, pending, png = std::move(png), dib = std::move(dib), expected, generation, arrival_title, arrival_body] {
            if (!running_ || !sync_images_ || generation_ != generation) { pending->Error("STOPPED", "Clipboard sync stopped"); return; }
            ClipboardLock lock(window_);
            if (!lock.open()) { pending->Error("CLIPBOARD_BUSY", "Clipboard is busy"); return; }
            if (static_cast<int64_t>(GetClipboardSequenceNumber()) != expected) { pending->Error("STALE_WRITE", "Local clipboard changed"); return; }
            auto allocate = [](const std::vector<uint8_t>& bytes) -> HGLOBAL {
              HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes.size()); void* data = memory ? GlobalLock(memory) : nullptr;
              if (!data) { if (memory) GlobalFree(memory); return nullptr; }
              std::memcpy(data, bytes.data(), bytes.size()); GlobalUnlock(memory); return memory;
            };
            HGLOBAL png_memory = allocate(png), dib_memory = allocate(dib);
            if (!png_memory || !dib_memory) {
              if (png_memory) GlobalFree(png_memory); if (dib_memory) GlobalFree(dib_memory);
              pending->Error("ALLOCATION_FAILED", "Clipboard image allocation failed"); return;
            }
            const UINT png_format = RegisterClipboardFormatW(L"PNG");
            if (!png_format || !EmptyClipboard()) { GlobalFree(png_memory); GlobalFree(dib_memory); pending->Error("WRITE_FAILED", "Clipboard image write failed"); return; }
            const bool png_ok = SetClipboardData(png_format, png_memory) != nullptr;
            const bool dib_ok = SetClipboardData(CF_DIBV5, dib_memory) != nullptr;
            if (!png_ok) GlobalFree(png_memory); if (!dib_ok) GlobalFree(dib_memory);
            if (png_ok || dib_ok) MarkRemote();
            if (!png_ok && !dib_ok) { pending->Error("WRITE_FAILED", "Clipboard image write failed"); return; }
            NotifyClipboardImageArrival(arrival_title, arrival_body);
            pending->Success(Value(static_cast<int64_t>(GetClipboardSequenceNumber())));
          };
        } catch (...) { return [pending] { pending->Error("INVALID_IMAGE", "Clipboard image invalid or oversized"); }; }
      });
    } else if (method == "write") {
      if (!running_) { result->Error("STOPPED", "Clipboard sync is stopped"); return; }
      const auto args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto text_it = args ? args->find(Value("text")) : Map::const_iterator();
      if (!args || text_it == args->end() || !std::holds_alternative<std::string>(text_it->second)) {
        result->Error("INVALID_TEXT", "Missing plain text"); return;
      }
      const std::string& text = std::get<std::string>(text_it->second);
      if (text.empty() || text.size() > kMaxBytes || text.find('\0') != std::string::npos) {
        result->Error("INVALID_TEXT", "Unsupported clipboard text"); return;
      }
      const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
      if (length <= 0) { result->Error("INVALID_TEXT", "Invalid UTF-8 text"); return; }
      HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, (static_cast<size_t>(length) + 1) * sizeof(wchar_t));
      auto wide = memory ? static_cast<wchar_t*>(GlobalLock(memory)) : nullptr;
      if (!wide) { if (memory) GlobalFree(memory); result->Error("ALLOCATION_FAILED", "Clipboard allocation failed"); return; }
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), wide, length);
      wide[length] = L'\0'; GlobalUnlock(memory);
      ClipboardLock lock(window_);
      if (!lock.open()) { GlobalFree(memory); result->Error("CLIPBOARD_BUSY", "Clipboard is busy; try again"); return; }
      const auto seq_it = args->find(Value("sequence"));
      int64_t expected = static_cast<int64_t>(GetClipboardSequenceNumber());
      if (seq_it != args->end()) {
        if (const auto sequence32 = std::get_if<int32_t>(&seq_it->second)) expected = *sequence32;
        else if (const auto sequence64 = std::get_if<int64_t>(&seq_it->second)) expected = *sequence64;
      }
      if (expected != static_cast<int64_t>(GetClipboardSequenceNumber())) {
        GlobalFree(memory); result->Error("STALE_WRITE", "Local clipboard changed before remote write"); return;
      }
      if (!EmptyClipboard() || !SetClipboardData(CF_UNICODETEXT, memory)) {
        GlobalFree(memory); result->Error("WRITE_FAILED", "Windows clipboard write failed"); return;
      }
      const UINT origin = RegisterClipboardFormatW(L"LocalSendClipboardRemoteOrigin");
      HGLOBAL origin_memory = GlobalAlloc(GMEM_MOVEABLE, sizeof(remote_token_));
      void* origin_value = origin_memory ? GlobalLock(origin_memory) : nullptr;
      if (origin_value) {
        std::memcpy(origin_value, remote_token_.data(), sizeof(remote_token_)); GlobalUnlock(origin_memory);
        if (!origin || !SetClipboardData(origin, origin_memory)) GlobalFree(origin_memory);
      } else if (origin_memory) GlobalFree(origin_memory);
      // OS owns memory after SetClipboardData. Mark remote data private to OS history
      // and to our monitor, suppressing the native callback echo.
      const UINT exclude = RegisterClipboardFormatW(L"ExcludeClipboardContentFromMonitorProcessing");
      HGLOBAL flag = GlobalAlloc(GMEM_MOVEABLE, sizeof(DWORD));
      auto value = flag ? static_cast<DWORD*>(GlobalLock(flag)) : nullptr;
      if (value) {
        *value = 1; GlobalUnlock(flag);
        if (!exclude || !SetClipboardData(exclude, flag)) GlobalFree(flag);
      } else if (flag) GlobalFree(flag);
#ifdef _DEBUG
      NotifyClipboardImageArrival(L"LocalSend text received", L"Copied text is ready for pasting.");
#endif
      result->Success(Value(static_cast<int64_t>(GetClipboardSequenceNumber())));
    } else { result->NotImplemented(); }
  });
}

ClipboardBridge::~ClipboardBridge() {
  if (image_worker_.joinable()) image_worker_.join();
  Stop(); events_->SetStreamHandler(nullptr); methods_->SetMethodCallHandler(nullptr);
}
void ClipboardBridge::Stop() {
  ++generation_;
  if (running_) RemoveClipboardFormatListener(window_);
  running_ = false; scheduled_ = false; KillTimer(window_, kClipboardTimer);
}
bool ClipboardBridge::HandleMessage(UINT message, WPARAM wparam) {
  if (message == kImageComplete) {
    if (image_worker_.joinable()) image_worker_.join();
    std::function<void()> complete;
    { std::lock_guard<std::mutex> lock(image_mutex_); complete = std::move(image_complete_); }
    if (complete) complete(); return true;
  }
  if (message == WM_CLIPBOARDUPDATE && running_) {
    if (!scheduled_) { scheduled_ = SetTimer(window_, kClipboardTimer, 20, nullptr) != 0; }
    return true;
  }
  if (message == WM_TIMER && wparam == kClipboardTimer) {
    KillTimer(window_, kClipboardTimer); scheduled_ = false;
    if (running_ && sink_) sink_->Success(Value(Map{{Value("kind"), Value("changed")}}));
    return true;
  }
  return false;
}

void ClipboardBridge::ImageTask(std::function<std::function<void()>()> work) {
  image_worker_ = std::thread([this, work = std::move(work)] {
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    auto complete = work();
    { std::lock_guard<std::mutex> lock(image_mutex_); image_complete_ = std::move(complete); }
    PostMessage(window_, kImageComplete, 0, 0);
    if (SUCCEEDED(com)) CoUninitialize();
  });
}

void ClipboardBridge::MarkRemote() {
  const UINT origin = RegisterClipboardFormatW(L"LocalSendClipboardRemoteOrigin");
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, sizeof(remote_token_));
  void* marker = memory ? GlobalLock(memory) : nullptr;
  if (marker) {
    std::memcpy(marker, remote_token_.data(), sizeof(remote_token_)); GlobalUnlock(memory);
    if (!origin || !SetClipboardData(origin, memory)) GlobalFree(memory);
  } else if (memory) GlobalFree(memory);
  const UINT exclude = RegisterClipboardFormatW(L"ExcludeClipboardContentFromMonitorProcessing");
  memory = GlobalAlloc(GMEM_MOVEABLE, sizeof(DWORD)); auto flag = memory ? static_cast<DWORD*>(GlobalLock(memory)) : nullptr;
  if (flag) { *flag = 1; GlobalUnlock(memory); if (!exclude || !SetClipboardData(exclude, memory)) GlobalFree(memory); }
  else if (memory) GlobalFree(memory);
}
