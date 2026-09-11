package com.mobileproxymish.app.cellular

import java.net.Socket
import javax.net.SocketFactory
import javax.net.ssl.SSLSocketFactory

/**
 * Kotlin sees SSLSocketFactory.getDefault() through the inherited SocketFactory static
 * signature, so the Android/JDK stubs expose only the four-argument endpoint overloads
 * at the call site. Keep the compatibility narrow to androidTest: the runtime object must
 * still be an SSLSocketFactory and the real layered TLS member performs the operation.
 */
internal fun SocketFactory.createSocket(
    rawSocket: Socket,
    host: String,
    port: Int,
    autoClose: Boolean,
): Socket {
    val tlsFactory = this as? SSLSocketFactory
        ?: throw IllegalStateException("default socket factory is not TLS-capable")
    return tlsFactory.createSocket(rawSocket, host, port, autoClose)
}
