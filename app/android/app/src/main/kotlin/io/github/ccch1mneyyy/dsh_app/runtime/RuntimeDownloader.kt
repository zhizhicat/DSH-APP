package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.DigestInputStream
import java.security.MessageDigest
import java.util.concurrent.CancellationException

/**
 * Streams one runtime archive over HTTPS into the app-private download
 * directory, verifying the sha256 (when known) and the byte count (when known)
 * before the file is revealed under its final name. Retries are whole-file
 * (no range resume); each attempt writes a fresh ".part" file.
 */
internal class RuntimeDownloader(
    private val onLog: (String) -> Unit,
    private val isCancelled: () -> Boolean = { false },
) {
    data class Result(val file: File, val sha256: String)

    /** @param expectedSha256 lowercase hex, or null to skip the digest check. */
    fun download(
        url: String,
        outFile: File,
        expectedSha256: String? = null,
        expectedBytes: Long = -1L,
        onProgress: (read: Long, total: Long) -> Unit = { _, _ -> },
    ): Result {
        outFile.parentFile?.mkdirs()
        val part = File(outFile.parentFile, outFile.name + ".part")
        var lastError: Exception? = null
        for (attempt in 1..MAX_ATTEMPTS) {
            if (isCancelled()) throw CancellationException("download cancelled")
            try {
                if (attempt > 1) onLog("[dsh-app] download retry $attempt: $url")
                val sha = downloadOnce(url, part, expectedBytes, onProgress)
                if (expectedSha256 != null && !expectedSha256.equals(sha, ignoreCase = true)) {
                    throw IOException("sha256 mismatch for $url: expected $expectedSha256, got $sha")
                }
                if (expectedBytes >= 0 && part.length() != expectedBytes) {
                    throw IOException("byte count mismatch for $url: expected $expectedBytes, got ${part.length()}")
                }
                if (outFile.exists() && !outFile.delete()) throw IOException("cannot replace ${outFile.path}")
                if (!part.renameTo(outFile)) throw IOException("cannot finalize ${outFile.path}")
                return Result(outFile, sha)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                lastError = e
                onLog("[dsh-app] download attempt $attempt failed: $e")
            } finally {
                part.delete()
            }
        }
        throw IOException("download failed after $MAX_ATTEMPTS attempts: $url", lastError)
    }

    private fun downloadOnce(
        url: String,
        part: File,
        expectedBytes: Long,
        onProgress: (Long, Long) -> Unit,
    ): String {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = CONNECT_TIMEOUT_MS
        connection.readTimeout = READ_TIMEOUT_MS
        connection.instanceFollowRedirects = true
        try {
            connection.setRequestProperty("Accept", "*/*")
            val code = connection.responseCode
            if (code !in 200..299) throw IOException("HTTP $code for $url")
            val total = connection.contentLengthLong.takeIf { it > 0 }
                ?: expectedBytes.takeIf { it > 0 }
                ?: -1L
            val digest = MessageDigest.getInstance("SHA-256")
            var read = 0L
            var lastReported = 0L
            connection.inputStream.let { raw: InputStream ->
                DigestInputStream(raw, digest).use { input ->
                    val buffer = ByteArray(BUFFER_BYTES)
                    while (true) {
                        if (isCancelled()) throw CancellationException("download cancelled")
                        val n = input.read(buffer)
                        if (n < 0) break
                        read += n
                        if (read - lastReported >= REPORT_INTERVAL_BYTES) {
                            lastReported = read
                            onProgress(read, total)
                        }
                    }
                }
            }
            onProgress(read, if (total > 0) total else read)
            return digest.digest().joinToString("") { "%02x".format(it) }
        } finally {
            connection.disconnect()
        }
    }

    private companion object {
        const val MAX_ATTEMPTS = 3
        const val CONNECT_TIMEOUT_MS = 15_000
        const val READ_TIMEOUT_MS = 60_000
        const val BUFFER_BYTES = 1 shl 16
        const val REPORT_INTERVAL_BYTES = 512L * 1024
    }
}
