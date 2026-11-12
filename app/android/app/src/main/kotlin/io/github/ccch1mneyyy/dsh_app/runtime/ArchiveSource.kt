package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import android.content.res.AssetManager
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.InputStream
import java.io.RandomAccessFile
import org.tukaani.xz.SeekableInputStream

/**
 * Where [RuntimeInstaller.install] reads runtime archives from: the bundled APK
 * assets (complete package) or the app-private download directory (noruntime
 * package, [RuntimeDownloader] output). Paths are the manifest's archive names
 * (e.g. "runtime/rootfs-arm64-v8a.tar.xz"); [FileArchiveSource] keys on the
 * basename.
 */
internal interface ArchiveSource {
    /** Compressed length in bytes, or -1 when unknown (manifest bytes are the fallback). */
    fun length(path: String): Long

    fun open(path: String): InputStream

    fun openSeekable(path: String): SeekableInputStream
}

internal class AssetArchiveSource(private val context: Context) : ArchiveSource {
    override fun length(path: String): Long = try {
        context.assets.openFd(path).use { it.length }
    } catch (_: Exception) {
        -1L // compressed asset; fall back to the manifest
    }

    override fun open(path: String): InputStream =
        context.assets.open(path, AssetManager.ACCESS_STREAMING)

    override fun openSeekable(path: String): SeekableInputStream =
        AssetSeekableInputStream(context.assets.openFd(path))
}

internal class FileArchiveSource(private val dir: File) : ArchiveSource {
    private fun fileOf(path: String): File {
        val file = File(dir, path.substringAfterLast('/'))
        check(file.isFile) { "archive file missing: ${file.path}" }
        return file
    }

    override fun length(path: String): Long = try {
        fileOf(path).length()
    } catch (_: Exception) {
        -1L
    }

    override fun open(path: String): InputStream = FileInputStream(fileOf(path))

    override fun openSeekable(path: String): SeekableInputStream = FileSeekableInputStream(fileOf(path))
}

/** [SeekableInputStream] over a plain file; mirrors [AssetSeekableInputStream]. */
internal class FileSeekableInputStream(file: File) : SeekableInputStream() {
    private val raf = RandomAccessFile(file, "r")

    override fun length(): Long = raf.length()

    override fun position(): Long = raf.filePointer

    override fun seek(pos: Long) {
        raf.seek(pos)
    }

    override fun read(): Int = raf.read()

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        return raf.read(b, off, len)
    }

    @Synchronized
    override fun close() {
        raf.close()
    }
}
