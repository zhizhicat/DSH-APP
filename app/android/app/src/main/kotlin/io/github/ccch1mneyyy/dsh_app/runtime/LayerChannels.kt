package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * Variant channels (schema 3): one layers-index.json describes base / node /
 * engine layer archives; the person picks one of each, they download in order
 * and unpack over each other (later layers win) via the regular installer.
 */
/**
 * Race-cancelling probes (2026-11-22 拍板「四路齐发，胜者即走，其余直接停止」)：
 * 同一 raceId 的探测共享一组连接，胜者产生后 [cancel] 把其余在飞连接
 * disconnect 掉——不是 Dart 侧忽略结果，是真·掐断，输家连响应都不等。
 */
internal object ProbeRegistry {
    private val conns = java.util.concurrent.ConcurrentHashMap<String, MutableSet<HttpURLConnection>>()

    fun register(raceId: String, conn: HttpURLConnection) {
        conns.getOrPut(raceId) {
            java.util.Collections.newSetFromMap(java.util.concurrent.ConcurrentHashMap())
        }.add(conn)
    }

    fun unregister(raceId: String, conn: HttpURLConnection) {
        conns[raceId]?.remove(conn)
    }

    fun cancel(raceId: String) {
        conns.remove(raceId)?.forEach { runCatching { it.disconnect() } }
    }
}

internal object LayerChannels {

    /** Probe a mirror by fetching one byte through it.
     *  [raceId] non-null registers the connection for cancel-losers. */
    fun probe(url: String, timeoutMs: Int = 8_000, raceId: String? = null): Map<String, Any?> {
        val started = System.currentTimeMillis()
        return try {
            val connection = URL(url).openConnection() as HttpURLConnection
            if (raceId != null) ProbeRegistry.register(raceId, connection)
            connection.connectTimeout = timeoutMs
            connection.readTimeout = timeoutMs
            connection.instanceFollowRedirects = true
            connection.setRequestProperty("Range", "bytes=0-0")
            try {
                val code = connection.responseCode
                val latency = System.currentTimeMillis() - started
                mapOf("ok" to (code in 200..299), "status" to code, "latencyMs" to latency)
            } finally {
                if (raceId != null) ProbeRegistry.unregister(raceId, connection)
                connection.disconnect()
            }
        } catch (e: Exception) {
            mapOf("ok" to false, "status" to -1, "latencyMs" to (System.currentTimeMillis() - started), "error" to (e.message ?: e.javaClass.simpleName))
        }
    }

    /** The layers-index.json for [channel] through the given source prefix. */
    fun fetchIndex(
        channel: ChannelRegistry.LayerChannel,
        source: ChannelRegistry.Source,
        downloads: File,
        downloader: RuntimeDownloader,
    ): JSONObject {
        val url = source.prefix + channel.githubBase + channel.indexPath
        // 先探测（8s）：DownloadManager 的连接阶段没有短超时可注入，
        // 不通的源先在这里快速失败，让 UI 故障转移到下一个源。
        val probe = probe(url, timeoutMs = 8_000)
        if (probe["ok"] != true) {
            throw IOException("source unreachable: sourceId='${source.id}' url=$url status=${probe["status"]}")
        }
        val file = File(downloads, "layers-index.json")
        try {
            // force: the index is small and freshness-sensitive; without a pinned sha
            // the "exists = cache hit" rule would stick the app to whatever index it
            // first fetched (stale engine metadata labeled a fresh install rc.1).
            downloader.download(url, file, channel.indexSha256, force = true)
        } catch (e: IOException) {
            val cause = e.cause?.let { "${it::class.simpleName}: ${it.message}" } ?: ""
            throw IOException(
                "index fetch failed: sourceId='${source.id}' prefix='${source.prefix}' url=$url: ${e.message} $cause", e,
            )
        }
        return JSONObject(file.readText())
    }

    /**
     * Builds the synthetic manifest the existing installer consumes: one whose
     * `layers` describe base + node + engine, in unpack order. Every archive is
     * verified by its own sha256 (from the index), so the index itself is only
     * integrity-checked when the channel pins its sha256.
     */
    fun buildManifest(
        index: JSONObject,
        abi: String,
        baseKey: String,
        nodeKey: String,
        engineKey: String,
    ): JSONObject {
        val layers = index.getJSONObject("layers")
        fun pick(kind: String, key: String): JSONObject {
            val group = layers.getJSONObject(kind)
            val layer = group.optJSONObject(key)
                ?: throw IOException("unknown $kind variant \"$key\"; have ${group.keys().asSequence().toList()}")
            return layer
        }
        val base = pick("base", baseKey)
        val node = pick("node", nodeKey)
        val engine = pick("engine", engineKey)

        val abiInfo = index.optJSONObject("abis")?.optJSONObject(abi)
            ?: throw IOException("layers index has no launch info for $abi")

        val manifest = JSONObject()
        manifest.put("schema", 2)
        // runtimeVersion must describe THIS combination. base.runtimeVersion is the
        // snapshot from the moment the base layer was built (the base is shared across
        // engine/node choices), so trusting it mislabels every non-default combination —
        // the installed manifest claimed dsh rc.1/node 24.9.0 while rc.2/24.22.1 was
        // actually downloaded and running.
        manifest.put("runtimeVersion", "layers-dsh$engineKey-node$nodeKey-base$baseKey")
        manifest.put("abi", abi)
        // dshVersion is the version the person picked, not the ABI-wide default snapshot.
        manifest.put("dshVersion", engineKey)
        manifest.put("nodeVersion", nodeKey)
        manifest.put("pnpmVersion", abiInfo.optString("pnpmVersion"))
        manifest.put("ubuntuVersion", baseKey)
        manifest.put("prootVersion", abiInfo.optString("prootVersion"))
        manifest.put("dshPatches", abiInfo.optJSONArray("dshPatches") ?: org.json.JSONArray())
        manifest.put("dshGoBridge", abiInfo.optJSONObject("dshGoBridge") ?: JSONObject.NULL)
        val launch = abiInfo.optJSONObject("launch")
        if (launch != null) manifest.put("launch", launch)
        val direct = abiInfo.optJSONObject("directEngine")
        if (direct != null) manifest.put("directEngine", direct)
        // The installer verifies the unpacked rootfs against upgrade.baseId and
        // baseCompatibility; both are per-base-distro and travel on the base entry.
        val upgrade = base.optJSONObject("upgrade")
        if (upgrade != null) manifest.put("upgrade", upgrade)
        val baseCompat = base.optJSONObject("baseCompatibility")
        if (baseCompat != null) manifest.put("baseCompatibility", baseCompat)
        val manifestLayers = JSONObject()
        manifestLayers.put("base", base)
        manifestLayers.put("node", node)
        manifestLayers.put("engine", engine)
        manifest.put("layers", manifestLayers)
        return manifest
    }
}
