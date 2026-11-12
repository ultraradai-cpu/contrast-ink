package ink.contrast.core

import ink.contrast.core.PadLinks.Then
import ink.contrast.core.PadLinks.Usb
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Switching between Wi-Fi and the USB cable (docs/pad-protocol.md, "USB (phase 2)", "The switch"). */
class PadLinksTest {
    @Test fun wifiOnlyWhileTheCableIsntThere() {
        val l = PadLinks()
        assertFalse("no Wi-Fi without a code", l.startWifi())
        l.chooseWifi("123456")
        assertTrue(l.startWifi())
        // the cable is tried every 2 s; each refused try is quiet and changes nothing
        repeat(3) {
            assertTrue(l.tryUsb())
            assertFalse("one try at a time", l.tryUsb())
            assertEquals(Then.NOTHING, l.usbEnded())
            assertTrue("Wi-Fi stays", l.wifi)
        }
    }

    @Test fun theCableTakesOverAndHandsBackToWifi() {
        val l = PadLinks()
        l.chooseWifi("123456")
        assertTrue(l.startWifi())
        assertTrue(l.tryUsb())
        assertEquals("usb-up: the Wi-Fi session closes", Then.CLOSE_WIFI, l.usbOpened())
        assertEquals(Usb.OPEN, l.usb)
        assertFalse(l.wifi)
        assertFalse("a Wi-Fi session never starts while USB is up", l.startWifi())
        assertFalse("and the cable isn't tried again while it is open", l.tryUsb())
        assertEquals("usb dropped, a code held: back to Wi-Fi", Then.BACK_TO_WIFI, l.usbEnded())
        assertTrue("Wi-Fi may start again", l.startWifi())
        assertTrue("and the cable is tried again", l.tryUsb())
    }

    @Test fun theCableWithoutACodeGoesToTheConnectScreenWhenItDrops() {
        val l = PadLinks()
        assertTrue("tried from the connect screen, no code typed", l.tryUsb())
        assertEquals("nothing to close", Then.NOTHING, l.usbOpened())
        assertEquals(Then.CONNECT_SCREEN, l.usbEnded())
        assertFalse(l.startWifi())
        assertTrue(l.tryUsb())
    }

    @Test fun aRefusedCodeIsntHeld() {
        val l = PadLinks()
        l.chooseWifi("000000")
        l.startWifi(); l.wifiEnded()
        l.codeRefused()
        assertNull(l.code)
        l.tryUsb(); l.usbOpened()
        assertEquals(Then.CONNECT_SCREEN, l.usbEnded())
    }

    @Test fun disconnectingTheCablePausesItUntilConnect() {
        val l = PadLinks()
        l.chooseWifi("123456")
        l.tryUsb(); l.usbOpened()
        assertTrue("the open USB session is closed", l.disconnect())
        assertNull("the code is forgotten", l.code)
        assertEquals("its end afterwards is already handled", Then.NOTHING, l.usbEnded())
        assertFalse("not tried again at once (it would just open again)", l.tryUsb())
        l.resumeUsb()
        assertTrue("Connect tries it again", l.tryUsb())
    }

    @Test fun disconnectingWifiKeepsTryingTheCable() {
        val l = PadLinks()
        l.chooseWifi("123456"); l.startWifi()
        assertFalse(l.disconnect())
        assertFalse(l.wifi)
        assertTrue(l.tryUsb())
    }

    @Test fun anotherKeyOverTheCableWarnsAndStops() {
        val l = PadLinks()
        l.chooseWifi("123456"); l.startWifi()
        l.tryUsb()
        assertEquals(Then.WARN_KEY_CHANGED, l.usbEnded(keyChanged = true))
        assertTrue("Wi-Fi goes on", l.wifi)
        assertFalse("no more tries (no warning every 2 s)", l.tryUsb())
        l.chooseWifi("123456")
        assertFalse("typing a code doesn't bring it back", l.tryUsb())
        l.connectAnywayOverUsb()
        assertTrue("\"Connect anyway\" does", l.tryUsb())
    }
}
