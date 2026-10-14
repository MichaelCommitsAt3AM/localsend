#ifndef RUNNER_CLIPBOARD_NOTIFICATIONS_H_
#define RUNNER_CLIPBOARD_NOTIFICATIONS_H_

#include <string>

// Best effort: notification failures must not fail a successful clipboard write.
void NotifyClipboardImageArrival(const std::wstring& title, const std::wstring& body) noexcept;

#endif
