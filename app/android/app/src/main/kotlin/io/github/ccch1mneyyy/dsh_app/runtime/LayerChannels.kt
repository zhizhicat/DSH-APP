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
internal object LayerChannels {

    /** Probe a mirror by fetching one byte through it. */
    fun probe(url: String, timeoutMs: Int = 8_000): Map<String, Any?> {
        val started = System.currentTimeMillis()
        return try {
            val connection = URL(url).openConnection() as HttpURLConnection
            connection.connectTimeout = timeoutMs
            connection.readTimeout = timeoutMs
            connection.instanceFollowRedirects = true
            connection.setRequestProperty("Range", "bytes=0-0")
            try {
                val code = connection.responseCode
                val latency = System.currentTimeMillis() - started
                mapOf("ok" to (code in 200..299), "status" to code, "latencyMs" to latency)
            } finally {
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
        val file = File(downloads, "layers-index.json")
        downloader.download(url, file, channel.indexSha256)
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
        manifest.put("runtimeVersion", "layers-dsh$engineKey-node$nodeKey-ubuntu$baseKey")
        manifest.put("abi", abi)
        manifest.put("dshVersion", abiInfo.optString("dshVersion", engineKey))
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
        val manifestLayers = JSONObject()
        manifestLayers.put("base", base)
        manifestLayers.put("node", node)
        manifestLayers.put("engine", engine)
        manifest.put("layers", manifestLayers)
        return manifest
    }
}
