package org.localsend.clipboardfeasibility;

import org.junit.Test;
import static org.junit.Assert.*;

public class ProbeTextTest {
    @Test public void utf8LimitIsNotCharacterLimit() {
        String value = "\u20ac".repeat(22000);
        assertEquals("oversize", ProbeText.classify(value).status);
    }
    @Test public void exactBoundaryAndKnownMarker() {
        assertEquals(65536, ProbeText.classify("a".repeat(65536)).bytes);
        assertEquals("oversize", ProbeText.classify("a".repeat(65537)).status);
        assertTrue(ProbeText.classify(ProbeText.FIXTURE).fixtureMatches);
        assertFalse(ProbeText.classify("other text").fixtureMatches);
    }
    @Test public void nullAndEmptyRemainDistinct() {
        assertEquals("non-text", ProbeText.classify(null).status);
        assertEquals("text-readable", ProbeText.classify("").status);
    }
}
