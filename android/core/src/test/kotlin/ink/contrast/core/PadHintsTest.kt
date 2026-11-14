package ink.contrast.core

import ink.contrast.core.PadHints.Cause
import ink.contrast.core.PadHints.Hint
import org.junit.Assert.assertEquals
import org.junit.Test

class PadHintsTest {
    @Test fun noPcInTheListSuggestsAHotspotOnlyWithWifiOn() {
        assertEquals(Hint.HOTSPOT, PadHints.noPcFound(wifiOn = true))
        assertEquals(Hint.TURN_ON_WIFI, PadHints.noPcFound(wifiOn = false))
    }

    @Test fun aFailedConnectIsExplainedByItsCause() {
        assertEquals("refused: the PC's tablet link is off", Hint.NOT_ACCEPTING, PadHints.connectFailed(true, Cause.REFUSED))
        assertEquals(Hint.NOT_ACCEPTING, PadHints.connectFailed(false, Cause.REFUSED))
        assertEquals("nothing answered: a network that keeps devices apart", Hint.HOTSPOT, PadHints.connectFailed(true, Cause.NO_ANSWER))
        assertEquals(Hint.TURN_ON_WIFI, PadHints.connectFailed(false, Cause.NO_ANSWER))
        assertEquals(Hint.NONE, PadHints.connectFailed(true, Cause.OTHER))
        assertEquals(Hint.TURN_ON_WIFI, PadHints.connectFailed(false, Cause.OTHER))
    }
}
