package io.github.rustadministrator.rustadmin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OutgoingSessionLifecycleTest {
    @Test
    fun backgroundDeadlineExpiresAtConfiguredTimeout() {
        val lifecycle = OutgoingSessionLifecycle(backgroundTimeoutMs = 600_000)
        lifecycle.attach()
        assertTrue(lifecycle.enterBackground(nowMs = 1_000))
        assertFalse(lifecycle.shouldExpire(nowMs = 600_999))
        assertTrue(lifecycle.shouldExpire(nowMs = 601_000))
    }

    @Test
    fun foregroundReturnCancelsPendingDeadline() {
        val lifecycle = OutgoingSessionLifecycle(backgroundTimeoutMs = 600_000)
        lifecycle.attach()
        lifecycle.enterBackground(nowMs = 1_000)

        assertTrue(lifecycle.enterForeground())
        assertFalse(lifecycle.shouldExpire(nowMs = 700_000))
        assertEquals(OutgoingSessionLifecycleState.ACTIVE, lifecycle.state)
    }

    @Test
    fun expiringSessionCannotBeResurrected() {
        val lifecycle = OutgoingSessionLifecycle(backgroundTimeoutMs = 600_000)
        lifecycle.attach()
        lifecycle.enterBackground(nowMs = 1_000)

        assertTrue(lifecycle.beginCleanup())
        assertFalse(lifecycle.enterForeground())
        assertFalse(lifecycle.enterBackground(nowMs = 2_000))
        assertFalse(lifecycle.beginCleanup())
        assertEquals(OutgoingSessionLifecycleState.EXPIRING, lifecycle.state)

        lifecycle.close()
        assertEquals(OutgoingSessionLifecycleState.CLOSED, lifecycle.state)
    }

    @Test
    fun wireGuardPeerAddressParserAcceptsOnlyNumericTargets() {
        assertNotNull(WireGuardController.parseNumericPeerAddress("10.0.77.3"))
        assertNotNull(WireGuardController.parseNumericPeerAddress("10.0.77.3:21118"))
        assertNotNull(WireGuardController.parseNumericPeerAddress("[2001:db8::1]:21118"))
        assertNull(WireGuardController.parseNumericPeerAddress("vpn-host.example:21118"))
        assertNull(WireGuardController.parseNumericPeerAddress("123456789"))
    }

    @Test
    fun tunnelOwnershipRequiresSuccessfulPendingClaim() {
        var claims = 0
        assertFalse(resolveTunnelOwnership(false, "office") {
            claims += 1
            true
        })
        assertFalse(resolveTunnelOwnership(true, "") {
            claims += 1
            true
        })
        assertFalse(resolveTunnelOwnership(true, "office") {
            claims += 1
            false
        })
        assertTrue(resolveTunnelOwnership(true, "office") {
            claims += 1
            true
        })
        assertEquals(2, claims)
    }
}
