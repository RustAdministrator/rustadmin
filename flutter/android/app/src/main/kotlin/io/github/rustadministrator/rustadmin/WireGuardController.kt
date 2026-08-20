package io.github.rustadministrator.rustadmin

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import androidx.core.content.ContextCompat
import java.net.InetAddress

object WireGuardController {
    const val PACKAGE_NAME = "com.wireguard.android"
    const val CONTROL_PERMISSION = "$PACKAGE_NAME.permission.CONTROL_TUNNELS"
    const val ACTION_SET_TUNNEL_UP = "$PACKAGE_NAME.action.SET_TUNNEL_UP"
    const val ACTION_SET_TUNNEL_DOWN = "$PACKAGE_NAME.action.SET_TUNNEL_DOWN"
    const val EXTRA_TUNNEL = "tunnel"

    private const val LOG_TAG = "RustAdmin/WireGuard"
    private val pendingTunnelLock = Any()
    private var pendingTunnelName: String? = null

    fun isInstalled(context: Context): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.packageManager.getPackageInfo(
                    PACKAGE_NAME,
                    PackageManager.PackageInfoFlags.of(0),
                )
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.getPackageInfo(PACKAGE_NAME, 0)
            }
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }

    fun hasControlPermission(context: Context): Boolean {
        return ContextCompat.checkSelfPermission(
            context,
            CONTROL_PERMISSION,
        ) == PackageManager.PERMISSION_GRANTED
    }

    fun integrationStatus(context: Context): Map<String, Any> {
        return mapOf(
            "installed" to isInstalled(context),
            "permission_granted" to hasControlPermission(context),
        )
    }

    @Suppress("DEPRECATION")
    fun networkSnapshot(context: Context, peer: String): Map<String, Any> {
        val connectivityManager =
            context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        var vpnActive = false
        var nonVpnWifiActive = false
        var localWifiPath = false
        val peerAddress = parseNumericPeerAddress(peer)
        for (network in connectivityManager.allNetworks) {
            val capabilities = connectivityManager.getNetworkCapabilities(network) ?: continue
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                vpnActive = true
            }
            val notSuspended = Build.VERSION.SDK_INT < Build.VERSION_CODES.P ||
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_SUSPENDED)
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
                notSuspended
            ) {
                nonVpnWifiActive = true
                if (peerAddress != null) {
                    val linkProperties = connectivityManager.getLinkProperties(network)
                    localWifiPath = localWifiPath || linkProperties?.routes?.any { route ->
                        !route.hasGateway() && route.destination.contains(peerAddress)
                    } == true
                }
            }
        }
        return mapOf(
            "vpn_active" to vpnActive,
            "non_vpn_wifi_active" to nonVpnWifiActive,
            "local_wifi_path" to localWifiPath,
        )
    }

    internal fun parseNumericPeerAddress(peer: String): InetAddress? {
        val value = peer.trim()
        val host = when {
            value.startsWith("[") && value.contains("]") ->
                value.substring(1, value.indexOf(']'))
            value.count { it == ':' } == 1 && value.substringAfterLast(':').toIntOrNull() != null ->
                value.substringBeforeLast(':')
            else -> value
        }
        val looksNumeric = host.contains(':') ||
            host.count { it == '.' } == 3 && host.all { it.isDigit() || it == '.' }
        if (!looksNumeric) return null
        return try {
            InetAddress.getByName(host)
        } catch (_: Exception) {
            null
        }
    }

    fun setTunnelState(context: Context, tunnelName: String, up: Boolean): Boolean {
        val name = tunnelName.trim()
        if (name.isEmpty() ||
            name.length > 128 ||
            !isInstalled(context) ||
            !hasControlPermission(context)
        ) {
            return false
        }
        val intent = Intent(
            if (up) ACTION_SET_TUNNEL_UP else ACTION_SET_TUNNEL_DOWN,
        ).apply {
            setPackage(PACKAGE_NAME)
            putExtra(EXTRA_TUNNEL, name)
        }
        return try {
            context.sendBroadcast(intent)
            synchronized(pendingTunnelLock) {
                if (up) {
                    pendingTunnelName = name
                } else if (pendingTunnelName == name) {
                    pendingTunnelName = null
                }
            }
            AndroidDiagnosticLog.info(LOG_TAG, "WireGuard tunnel state request sent: up=$up")
            true
        } catch (error: RuntimeException) {
            AndroidDiagnosticLog.error(LOG_TAG, "WireGuard tunnel state request failed", error)
            false
        }
    }

    fun claimPendingTunnel(tunnelName: String): Boolean {
        val name = tunnelName.trim()
        val claimed = synchronized(pendingTunnelLock) {
            if (pendingTunnelName == name) {
                pendingTunnelName = null
                true
            } else {
                false
            }
        }
        if (claimed) {
            AndroidDiagnosticLog.info(
                LOG_TAG,
                "Pending WireGuard tunnel ownership transferred to outgoing session",
            )
        } else {
            AndroidDiagnosticLog.warn(LOG_TAG, "Pending WireGuard tunnel ownership claim rejected")
        }
        return claimed
    }

    fun cancelPendingTunnel(context: Context) {
        val pending = synchronized(pendingTunnelLock) {
            pendingTunnelName.also { pendingTunnelName = null }
        }
        if (!pending.isNullOrEmpty()) {
            AndroidDiagnosticLog.info(
                LOG_TAG,
                "Pending WireGuard tunnel cancelled because app left foreground",
            )
            setTunnelState(context, pending, false)
        }
    }
}
