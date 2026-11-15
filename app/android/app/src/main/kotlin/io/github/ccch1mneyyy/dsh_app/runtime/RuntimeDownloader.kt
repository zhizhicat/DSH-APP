package io.github.ccch1mneyyy.dsh_app.runtime

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.CancellationException

/**
 * Downloads one runtime artifact through the system DownloadManager (its own
 * network stack, sandboxed away from the app process), verifying the sha256
 * (when known) and the byte count (when known) before the file is revealed
 * under its final name.
 *
 * Caching: an artifact already downloaded under its final name (a previous
 * install that got interrupted before unpack, or a re-entered flow) is
 * verified against the expected digest/byte count and reused instead of
 * re-downloading. Resume: a partial `.part` file is continued with a ranged
 * HTTPS request; a resume that stalls or fails falls back to the whole-file
 * DownloadManager download.
 */
internal class RuntimeDownloader(
    private val app: Context,
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
        // A finished artifact from an earlier pass (same size, same sha) is a hit:
        // skip the network entirely.
        val cachedSha = if (outFile.isFile &&
            (expectedBytes < 0 || outFile.length() == expectedBytes)) sha256Of(outFile) else null
        if (cachedSha != null &&
            (expectedSha256 == null || expectedSha256.equals(cachedSha, ignoreCase = true))) {
            onLog("[dsh-app] cache hit: ${outFile.name} (${outFile.length()} bytes), skipping download")
            onProgress(outFile.length(), if (expectedBytes > 0) expectedBytes else outFile.length())
            return Result(outFile, cachedSha)
        }
        var lastError: Exception? = null
        for (attempt in 1..MAX_ATTEMPTS) {
            if (isCancelled()) throw CancellationException("download cancelled")
            try {
                if (attempt > 1) onLog("[dsh-app] download retry $attempt: $url")
                var sha: String? = null
                if (part.isFile && part.length() > 0) {
                    // Continue a previous pass's partial file when the server allows it.
                    try {
                        sha = resumeOnce(url, part, expectedBytes, onProgress)
                        if (sha == null) onLog("[dsh-app] resume not possible for ${part.name}; whole-file download")
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        onLog("[dsh-app] resume failed (${e.message}); whole-file download")
                        part.delete()
                    }
                }
                if (sha == null) sha = downloadOnce(url, part, expectedBytes, onProgress)
                if (expectedSha256 != null && !expectedSha256.equals(sha, ignoreCase = true)) {
                    // The bytes are wrong — a resumed tail cannot be trusted again.
                    part.delete()
                    throw IOException("sha256 mismatch for $url: expected $expectedSha256, got $sha")
                }
                if (expectedBytes >= 0 && part.length() != expectedBytes) {
                    part.delete()
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
                // Keep the partial file for the next attempt / the next launch.
            }
        }
        val cause = lastError?.let { "${it::class.simpleName}: ${it.message}" } ?: "(no cause captured)"
        throw IOException("download failed after $MAX_ATTEMPTS attempts: $url — $cause", lastError)
    }

    private fun sha256Of(file: File): String? = runCatching {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(BUFFER_BYTES)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                digest.update(buffer, 0, n)
            }
        }
        digest.digest().joinToString("") { "%02x".format(it) }
    }.getOrNull()

    /**
     * Continues [part] over HTTPS with a Range request. Returns the whole-file
     * sha256 once complete, or null when the server ignored the range (200):
     * then the caller should start over. Network trouble here throws; the
     * caller logs and falls back to the whole-file DownloadManager path, and
     * the partial file survives for the next attempt.
     */
    private fun resumeOnce(
        url: String,
        part: File,
        expectedBytes: Long,
        onProgress: (Long, Long) -> Unit,
    ): String? {
        if (expectedBytes in 1..part.length()) {
            // Longer than the artifact should be: not a partial we can trust.
            part.delete()
            return null
        }
        val connection = (java.net.URL(url).openConnection() as java.net.HttpURLConnection).apply {
            connectTimeout = RESUME_CONNECT_TIMEOUT_MS
            readTimeout = RESUME_READ_TIMEOUT_MS
            instanceFollowRedirects = true
            setRequestProperty("Range", "bytes=${part.length()}-")
        }
        val deadline = System.currentTimeMillis() + RESUME_TIMEOUT_MS
        try {
            if (connection.responseCode != 206) return null
            var total = expectedBytes
            // Content-Range: "bytes 12345-67890/99999" — the artifact total sits after the slash.
            val contentRange = connection.getHeaderField("Content-Range")
            val rangeTotal = contentRange?.substringAfter('/', "")?.toLongOrNull() ?: -1L
            if (rangeTotal > 0) total = rangeTotal
            val started = part.length()
            connection.inputStream.use { input ->
                java.io.FileOutputStream(part, true).use { out ->
                    val buffer = ByteArray(BUFFER_BYTES)
                    var read = started
                    while (true) {
                        if (isCancelled()) throw CancellationException("download cancelled")
                        if (System.currentTimeMillis() > deadline) {
                            throw IOException("resume timed out after ${RESUME_TIMEOUT_MS / 1000}s: $url")
                        }
                        val n = input.read(buffer)
                        if (n < 0) break
                        out.write(buffer, 0, n)
                        read += n
                        onProgress(read, if (total > 0) total else read)
                    }
                }
            }
            // Only the appended bytes were streamed; the whole file (base + tail)
            // is digested here so the caller's sha check still sees everything.
            return sha256Of(part) ?: throw IOException("cannot digest resumed ${part.path}")
        } finally {
            connection.disconnect()
        }
    }

    private fun downloadOnce(
        url: String,
        part: File,
        expectedBytes: Long,
        onProgress: (Long, Long) -> Unit,
    ): String {
        val dm = app.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val request = DownloadManager.Request(Uri.parse(url)).apply {
            setTitle(part.name.removeSuffix(".part"))
            // VISIBILITY_HIDDEN(=2) 在新版 Android 只许系统应用使用，enqueue 直接抛
            // SecurityException: Invalid value for visibility: 2（真机实锤）。
            // 改用 VISIBILITY_VISIBLE_NOTIFY_COMPLETED(=1)：下载中显示普通通知，完成可点开。
            setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            setDestinationInExternalFilesDir(app, null, part.name)
            setAllowedOverMetered(true)
            setAllowedOverRoaming(true)
        }
        val id = dm.enqueue(request)
        val query = DownloadManager.Query().setFilterById(id)
        val deadline = System.currentTimeMillis() + DOWNLOAD_TIMEOUT_MS
        try {
            while (true) {
                if (isCancelled()) throw CancellationException("download cancelled")
                if (System.currentTimeMillis() > deadline) {
                    throw IOException("download timed out after ${DOWNLOAD_TIMEOUT_MS / 1000}s: $url")
                }
                var finished = false
                dm.query(query)?.use { c ->
                    if (!c.moveToFirst()) throw IOException("download entry vanished: $url")
                    when (c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))) {
                        DownloadManager.STATUS_SUCCESSFUL -> finished = true
                        DownloadManager.STATUS_FAILED -> {
                            val reason = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
                            throw IOException("download manager failed (reason code $reason): $url")
                        }
                        else -> {
                            val soFar = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
                            onProgress(soFar, if (expectedBytes > 0) expectedBytes else soFar)
                        }
                    }
                } ?: throw IOException("download manager unavailable")
                if (finished) break
                Thread.sleep(500)
            }
            val localUri = dm.query(query)?.use { c ->
                if (c.moveToFirst()) c.getString(c.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI)) else null
            } ?: throw IOException("downloaded file location unknown: $url")
            val staged = File(Uri.parse(localUri).path!!)
            part.parentFile?.mkdirs()
            try {
                if (!staged.renameTo(part)) staged.copyTo(part, overwrite = true)
            } finally {
                staged.delete()
            }
            val digest = MessageDigest.getInstance("SHA-256")
            part.inputStream().use { input ->
                val buffer = ByteArray(BUFFER_BYTES)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    digest.update(buffer, 0, n)
                }
            }
            dm.remove(id)
            return digest.digest().joinToString("") { "%02x".format(it) }
        } catch (e: Exception) {
            dm.remove(id)
            throw e
        }
    }

    private companion object {
        const val MAX_ATTEMPTS = 3
        const val DOWNLOAD_TIMEOUT_MS = 30 * 60 * 1000L
        const val RESUME_CONNECT_TIMEOUT_MS = 15 * 1000
        const val RESUME_READ_TIMEOUT_MS = 45 * 1000
        const val RESUME_TIMEOUT_MS = 15 * 60 * 1000L
        const val BUFFER_BYTES = 1 shl 16
    }
}
