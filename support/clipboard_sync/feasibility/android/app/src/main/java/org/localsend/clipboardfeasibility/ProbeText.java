package org.localsend.clipboardfeasibility;

import java.nio.charset.StandardCharsets;

/** No clipboard text leaves this classifier; only bounded test metadata does. */
final class ProbeText {
    static final String FIXTURE = "LocalSend clipboard feasibility marker";
    static final int MAX_BYTES = 64 * 1024;

    static Result classify(CharSequence value) {
        if (value == null) return new Result("non-text", 0, false);
        if (value.length() > MAX_BYTES) return new Result("oversize", 0, false);
        int bytes = value.toString().getBytes(StandardCharsets.UTF_8).length;
        if (bytes > MAX_BYTES) return new Result("oversize", 0, false);
        return new Result("text-readable", bytes, FIXTURE.contentEquals(value));
    }

    static final class Result {
        final String status;
        final int bytes;
        final boolean fixtureMatches;
        Result(String status, int bytes, boolean fixtureMatches) {
            this.status = status;
            this.bytes = bytes;
            this.fixtureMatches = fixtureMatches;
        }
    }
}
