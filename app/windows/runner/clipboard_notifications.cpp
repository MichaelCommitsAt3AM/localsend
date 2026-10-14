#include "clipboard_notifications.h"

#include <cstdio>
#include <windows.h>
#include <appmodel.h>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.UI.Notifications.h>

namespace {
constexpr wchar_t kAppId[] = L"LocalSend.ClipboardSync";
constexpr wchar_t kAppKey[] = L"Software\\Classes\\AppUserModelId\\LocalSend.ClipboardSync";
constexpr wchar_t kProtocolKey[] = L"Software\\Classes\\localsend-clipboard";
// A stub activator keeps the toast in notification center. Activation uses our
// protocol instead of COM, so it also works for unpackaged/portable builds.
constexpr wchar_t kActivator[] = L"{BF4BDF31-CA18-471A-A31D-806896C0C610}";

void SetRegistryText(const wchar_t* key, const wchar_t* name, const std::wstring& text) {
  const LSTATUS status = RegSetKeyValueW(HKEY_CURRENT_USER, key, name, REG_SZ,
      text.c_str(), static_cast<DWORD>((text.size() + 1) * sizeof(wchar_t)));
  if (status != ERROR_SUCCESS) winrt::throw_hresult(HRESULT_FROM_WIN32(status));
}

void CreateRegistryKey(const wchar_t* path) {
  HKEY key = nullptr;
  const LSTATUS status = RegCreateKeyExW(HKEY_CURRENT_USER, path, 0, nullptr, 0,
      KEY_SET_VALUE, nullptr, &key, nullptr);
  if (status != ERROR_SUCCESS) winrt::throw_hresult(HRESULT_FROM_WIN32(status));
  RegCloseKey(key);
}

void RegisterNotifications() {
  std::wstring executable(32768, L'\0');
  const DWORD length = GetModuleFileNameW(nullptr, executable.data(), static_cast<DWORD>(executable.size()));
  if (!length || length >= executable.size()) winrt::throw_hresult(E_FAIL);
  executable.resize(length);

  CreateRegistryKey(kProtocolKey);
  SetRegistryText(kProtocolKey, nullptr, L"URL:LocalSend clipboard");
  SetRegistryText(kProtocolKey, L"URL Protocol", L"");
  constexpr wchar_t kCommandKey[] = L"Software\\Classes\\localsend-clipboard\\shell\\open\\command";
  CreateRegistryKey(kCommandKey);
  // No URI arguments: clicking only opens the app, never consumes remote data.
  SetRegistryText(kCommandKey, nullptr, L"\"" + executable + L"\"");

  CreateRegistryKey(kAppKey);
  SetRegistryText(kAppKey, L"DisplayName", L"LocalSend");
  SetRegistryText(kAppKey, L"CustomActivator", kActivator);
  const auto directory = executable.substr(0, executable.find_last_of(L"\\/"));
  const auto icon = directory + L"\\data\\flutter_assets\\assets\\img\\logo-128.png";
  if (GetFileAttributesW(icon.c_str()) != INVALID_FILE_ATTRIBUTES) {
    SetRegistryText(kAppKey, L"IconUri", icon);
  }
}
}

void NotifyClipboardImageArrival(const std::wstring& title, const std::wstring& body) noexcept {
  if (title.empty() || body.empty()) return;
  try {
    static bool registered = false;
    if (!registered) {
      RegisterNotifications();
      registered = true;
    }
    using namespace winrt::Windows::Data::Xml::Dom;
    using namespace winrt::Windows::UI::Notifications;
    XmlDocument xml;
    xml.LoadXml(L"<toast activationType='protocol' launch='localsend-clipboard://open'>"
        L"<visual><binding template='ToastGeneric'><text/><text/></binding></visual></toast>");
    const auto texts = xml.GetElementsByTagName(L"text");
    // DOM text nodes escape device names and translations, including XML markup.
    texts.Item(0).AppendChild(xml.CreateTextNode(title));
    texts.Item(1).AppendChild(xml.CreateTextNode(body));
    ToastNotification notification(xml);
    notification.Tag(L"clipboard-image");
    notification.Group(L"clipboard");
    notification.Failed([](const ToastNotification&, const ToastFailedEventArgs& args) {
      char message[96];
      sprintf_s(message, "LocalSend: image arrival notification rejected (0x%08lX)\n",
          static_cast<unsigned long>(args.ErrorCode().value));
      OutputDebugStringA(message);
    });
    UINT32 package_name_length = 0;
    const bool packaged = GetCurrentPackageFullName(&package_name_length, nullptr) == ERROR_INSUFFICIENT_BUFFER;
    const auto notifier = packaged ? ToastNotificationManager::CreateToastNotifier()
                                  : ToastNotificationManager::CreateToastNotifier(kAppId);
    notifier.Show(notification);
  } catch (const winrt::hresult_error& error) {
    // Log only the error code, never clipboard content or the device name.
    char message[96];
    sprintf_s(message, "LocalSend: image arrival notification failed (0x%08lX)\n",
        static_cast<unsigned long>(error.code().value));
    OutputDebugStringA(message);
  } catch (...) {
    OutputDebugStringA("LocalSend: image arrival notification failed\n");
  }
}
