package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * Download channels for noruntime builds (assets/channels.json). Each channel
 * points at a remote runtime manifest (pinned by sha256) plus the base URL its
 * archives live under; the manifest's own digests verify every archive.
 *
 * v1 ships the official r15 build product (Ubuntu 24.04.5 + Node 24.22.1).
 * Debian channels need a build-runtime.sh variant to produce the rootfs first
 * (档二后置推), then land here as additional entries.
 */
internal object ChannelRegistry {
    data class Channel(
        val id: String,
        val name: String,
        val manifestUrl: String,
        val manifestSha256: String,
        val filesBaseUrl: String,
    )

    fun load(app: Context): List<Channel> {
        val text = app.assets.open("channels.json").bufferedReader().use { it.readText() }
        val root = JSONObject(text)
        val channels = mutableListOf<Channel>()
        val items: JSONArray = root.getJSONArray("channels")
        for (i in 0 until items.length()) {
            val c = items.getJSONObject(i)
            val manifest = c.getJSONObject("manifest")
            channels += Channel(
                id = c.getString("id"),
                name = c.optString("name", c.getString("id")),
                manifestUrl = manifest.getString("url"),
                manifestSha256 = manifest.getString("sha256"),
                filesBaseUrl = c.getString("filesBaseUrl"),
            )
        }
        return channels
    }

    fun defaultId(app: Context): String? = runCatching {
        JSONObject(app.assets.open("channels.json").bufferedReader().use { it.readText() })
            .optString("default").ifEmpty { null }
    }.getOrNull()
}
