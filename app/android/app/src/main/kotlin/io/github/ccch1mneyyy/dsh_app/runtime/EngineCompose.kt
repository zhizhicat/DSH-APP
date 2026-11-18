package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.security.MessageDigest

/**
 * engine(DSH) 层装机期组装:npm registry 直拉 743 包闭包 + pnpm + adapter/overlay
 * 增量(gh),现场拼出等价层目录。
 *
 * - packages[].path 是安装路径(opt/dsh/node_modules/<name>),下载 URL 按 npm
 *   registry 规范自算(@scope/name → @scope/name/-/name-<v>.tgz)。
 * - 每 tgz 按 compose 的 sha512 integrity 校验后解包,package/ 前缀剥掉摆位。
 * - adapter/overlay 增量包走 gh(小文件),tar 内自带路径前缀。
 * - runtime.json 按 App 端真实选择写(静态 overlay 不含它)。
 *
 * 实验边界:组装树不带构建期 154 个 android 补丁,行为可能有差异。
 */
internal object EngineCompose {

    const val MARKER = "engine-assembled-compose"

    fun npmTarballPath(name: String, version: String): String =
        if (name.startsWith("@")) {
            val bare = name.substringAfter('/')
            "$name/-/$bare-$version.tgz"
        } else {
            "$name/-/$name-$version.tgz"
        }

    private fun verifySha512(file: File, integrity: String) {
        val expect = integrity.removePrefix("sha512-")
        val digest = MessageDigest.getInstance("SHA-512")
        file.inputStream().use { input ->
            val buf = ByteArray(1 shl 16)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                digest.update(buf, 0, n)
            }
        }
        val actual = Base64.encodeToString(digest.digest(), Base64.NO_WRAP)
        if (actual != expect) throw IOException("integrity mismatch: ${file.name}")
    }

    /** 组装出完整层目录;调用方负责消费与清理。 */
    fun assemble(
        context: Context,
        engine: JSONObject,
        registryBase: String,
        ghFallback: String,
        downloads: File,
        nodeVersion: String,
        ubuntuVersion: String,
        downloader: RuntimeDownloader,
        onProgress: (done: Int, total: Int) -> Unit,
        onLog: (String) -> Unit,
    ): File {
        val work = File(context.cacheDir, "engine-compose")
        work.deleteRecursively(); work.mkdirs()
        val tmp = File(work, ".tmp"); tmp.mkdirs()

        fun unpackTgz(tgz: File, destDir: File) {
            destDir.mkdirs()
            val stage = File(tmp, "s" + System.nanoTime())
            TarExtractor(stage) { }.extract(tgz.inputStream(), tgz.name)
            val root = File(stage, "package")
            if (!root.isDirectory) throw IOException("tgz layout unexpected: " + tgz.name)
            root.copyRecursively(destDir, overwrite = true)
            stage.deleteRecursively()
        }

        val packages = engine.getJSONArray("packages")
        val total = packages.length() + 3
        var done = 0
        onLog("[dsh-app] engine compose: " + packages.length() + " packages from " + registryBase)

        for (i in 0 until packages.length()) {
            val p = packages.getJSONObject(i)
            val name = p.getString("name")
            val version = p.getString("version")
            val integrity = p.optString("integrity")
            val installPath = p.getString("path")
            val tgz = File(tmp, "p$i.tgz")
            downloader.download(
                registryBase.trimEnd('/') + "/" + npmTarballPath(name, version),
                tgz, expectedSha256 = null, expectedBytes = -1L,
            ) { _, _ -> }
            if (integrity.startsWith("sha512-")) verifySha512(tgz, integrity)
            unpackTgz(tgz, File(work, installPath))
            tgz.delete()
            done++
            onProgress(done, total)
        }

        val pnpm = engine.optJSONObject("pnpm")
        if (pnpm != null) {
            val tgz = File(tmp, "pnpm.tgz")
            downloader.download(
                registryBase.trimEnd('/') + "/" + pnpm.getString("tarball"),
                tgz, expectedSha256 = null, expectedBytes = -1L,
            ) { _, _ -> }
            pnpm.optString("integrity").takeIf { it.startsWith("sha512-") }?.let { verifySha512(tgz, it) }
            unpackTgz(tgz, File(work, "usr/local/lib/node_modules/pnpm"))
            tgz.delete()
            done++; onProgress(done, total)
        }

        for (pair in listOf("adapterAsset" to "adapterSha256", "overlayAsset" to "overlaySha256")) {
            val asset = engine.optString(pair.first) ?: ""
            if (asset.isEmpty()) continue
            val f = File(tmp, asset)
            downloader.download(
                ghFallback + asset, f,
                engine.optString(pair.second).ifEmpty { null }, -1L,
            ) { _, _ -> }
            TarExtractor(work) { }.extract(f.inputStream(), asset)
            f.delete()
            done++; onProgress(done, total)
        }

        val info = JSONObject()
            .put("runtimeVersion", "layers-compose-1")
            .put("abi", "arm64-v8a")
            .put("dshVersion", engine.optString("version"))
            .put("nodeVersion", nodeVersion)
            .put("pnpmVersion", pnpm?.optString("version") ?: "")
            .put("ubuntuVersion", ubuntuVersion)
            .put("dshPatches", JSONArray())
            .put("dshGoBridge", "compose")
        val dshApp = File(work, "etc/dsh-app")
        dshApp.mkdirs()
        File(dshApp, "runtime.json").writeText(info.toString(2) + "\n")

        tmp.deleteRecursively()
        onLog("[dsh-app] engine compose assembled: $done items")
        return work
    }
}
