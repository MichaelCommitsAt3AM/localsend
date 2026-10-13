#ifndef RUNNER_CLIPBOARD_SECRETS_H_
#define RUNNER_CLIPBOARD_SECRETS_H_
#include <optional>
#include <string>

// Dedicated per-user DPAPI identity file. Never plaintext settings or clipboard history.
std::optional<std::string> LoadClipboardSecret();
void SaveClipboardSecret(const std::string& value);
#endif
