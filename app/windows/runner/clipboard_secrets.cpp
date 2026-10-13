#include "clipboard_secrets.h"
#include <windows.h>
#include <wincrypt.h>
#include <dpapi.h>
#include <shlobj.h>
#include <filesystem>
#include <fstream>
#include <vector>
#include <stdexcept>

namespace {
constexpr size_t kMaxBytes = 65536;
std::filesystem::path IdentityPath() {
  PWSTR local = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local)))
    throw std::runtime_error("Clipboard secure directory unavailable");
  std::filesystem::path path(local); CoTaskMemFree(local);
  return path / L"LocalSendClipboard" / L"identity.v1";
}
DATA_BLOB Entropy() {
  static BYTE context[] = "localsend-clipboard-v1";
  return DATA_BLOB{static_cast<DWORD>(sizeof(context) - 1), context};
}
}

std::optional<std::string> LoadClipboardSecret() {
  const auto path = IdentityPath();
  std::error_code error;
  const bool exists = std::filesystem::exists(path, error);
  if (error) throw std::runtime_error("Clipboard secure file inaccessible");
  if (!exists) return std::nullopt;
  const auto size = std::filesystem::file_size(path, error);
  if (error || size == 0 || size > kMaxBytes) throw std::runtime_error("Invalid clipboard secure file");
  std::ifstream input(path, std::ios::binary);
  std::vector<BYTE> bytes(static_cast<size_t>(size));
  if (!input.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size())))
    throw std::runtime_error("Clipboard secure file read failed");
  DATA_BLOB encrypted{static_cast<DWORD>(bytes.size()), bytes.data()}, plaintext{};
  auto entropy = Entropy();
  if (!CryptUnprotectData(&encrypted, nullptr, &entropy, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &plaintext))
    throw std::runtime_error("Clipboard identity cannot be decrypted by this Windows user");
  if (plaintext.cbData > kMaxBytes) {
    SecureZeroMemory(plaintext.pbData, plaintext.cbData); LocalFree(plaintext.pbData);
    throw std::runtime_error("Invalid clipboard identity size");
  }
  std::string value(reinterpret_cast<const char*>(plaintext.pbData), plaintext.cbData);
  SecureZeroMemory(plaintext.pbData, plaintext.cbData); LocalFree(plaintext.pbData);
  return value;
}

void SaveClipboardSecret(const std::string& value) {
  if (value.empty() || value.size() > kMaxBytes - 4096) throw std::runtime_error("Invalid clipboard identity size");
  const auto path = IdentityPath(); std::filesystem::create_directories(path.parent_path());
  DATA_BLOB plaintext{static_cast<DWORD>(value.size()), reinterpret_cast<BYTE*>(const_cast<char*>(value.data()))}, encrypted{};
  auto entropy = Entropy();
  if (!CryptProtectData(&plaintext, L"LocalSend clipboard identity", &entropy, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &encrypted))
    throw std::runtime_error("Clipboard identity encryption failed");
  const auto temporary = path.parent_path() / L"identity.v1.tmp";
  HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr);
  if (file == INVALID_HANDLE_VALUE) { LocalFree(encrypted.pbData); throw std::runtime_error("Clipboard secure file unavailable"); }
  DWORD written = 0;
  const bool saved = WriteFile(file, encrypted.pbData, encrypted.cbData, &written, nullptr) && written == encrypted.cbData && FlushFileBuffers(file);
  CloseHandle(file); LocalFree(encrypted.pbData);
  if (!saved || !MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
    throw std::runtime_error("Clipboard identity atomic save failed");
}
