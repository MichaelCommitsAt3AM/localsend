#ifndef RUNNER_CLIPBOARD_BRIDGE_H_
#define RUNNER_CLIPBOARD_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <memory>
#include <array>
#include <thread>
#include <functional>
#include <mutex>

class ClipboardBridge {
 public:
  ClipboardBridge(HWND window, flutter::BinaryMessenger* messenger);
  ~ClipboardBridge();
  bool HandleMessage(UINT message, WPARAM wparam);
 private:
  void Stop();
  void ImageTask(std::function<std::function<void()>()> work);
  void MarkRemote();
  std::thread image_worker_;
  std::mutex image_mutex_;
  std::function<void()> image_complete_;
  bool sync_images_ = false;
  uint64_t generation_ = 0;
  HWND window_;
  bool running_ = false;
  bool scheduled_ = false;
  std::array<unsigned int, 4> remote_token_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> methods_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
};

#endif
