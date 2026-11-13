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
 * under its final name. Retries are whole-file (no range resume).
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
        val cause = lastError?.let { "${it::class.simpleName}: ${it.message}" } ?: "(no cause captured)"
        throw IOException("download failed after $MAX_ATTEMPTS attempts: $url — $cause", lastError)
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
            setNotificationVisibility(DownloadManager.Request.VISIBILITY_HIDDEN)
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
        const val BUFFER_BYTES = 1 shl 16
    }
}
