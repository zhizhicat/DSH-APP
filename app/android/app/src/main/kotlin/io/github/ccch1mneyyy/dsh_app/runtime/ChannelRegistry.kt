package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * Download channels for noruntime builds (assets/channels.json).
 *
 * schema 1: flat channels, each pointing at one manifest + its file base URL.
 * schema 3 (variant channels): adds `sources` (mirror prefixes applied to
 * GitHub release URLs) and channels whose `index` points at a layers-index.json
 * describing base / node / engine layer packages the person can mix.
 */
internal object ChannelRegistry {
    data class Channel(
        val id: String,
        val name: String,
        val manifestUrl: String,
        val manifestSha256: String,
        val filesBaseUrl: String,
    )

    /** A mirror prefix ("https://ghfast.top/") applied to GitHub release URLs; "" = direct. */
    data class Source(val id: String, val name: String, val prefix: String)

    /** schema 3 channel: layer index under a GitHub release dir, reachable via any [Source]. */
    data class LayerChannel(
        val id: String,
        val name: String,
        val githubBase: String,
        val indexPath: String,
        val indexSha256: String?,
    )

    fun load(app: Context): List<Channel> = runCatching {
        val root = JSONObject(app.assets.open("channels.json").bufferedReader().use { it.readText() })
        val channels = mutableListOf<Channel>()
        val items: JSONArray = root.getJSONArray("channels")
        for (i in 0 until items.length()) {
            val c = items.getJSONObject(i)
            if (!c.has("manifest")) continue  // variant channels are not flat
            val manifest = c.getJSONObject("manifest")
            channels += Channel(
                id = c.getString("id"),
                name = c.optString("name", c.getString("id")),
                manifestUrl = manifest.getString("url"),
                manifestSha256 = manifest.getString("sha256"),
                filesBaseUrl = c.getString("filesBaseUrl"),
            )
        }
        channels
    }.getOrElse { emptyList() }

    fun layerChannels(app: Context): List<LayerChannel> = runCatching {
        val root = JSONObject(app.assets.open("channels.json").bufferedReader().use { it.readText() })
        val channels = mutableListOf<LayerChannel>()
        val items: JSONArray = root.getJSONArray("channels")
        for (i in 0 until items.length()) {
            val c = items.getJSONObject(i)
            if (!c.has("index")) continue
            val index = c.getJSONObject("index")
            channels += LayerChannel(
                id = c.getString("id"),
                name = c.optString("name", c.getString("id")),
                githubBase = c.getString("githubBase"),
                indexPath = index.getString("path"),
                indexSha256 = index.optString("sha256").ifEmpty { null },
            )
        }
        channels
    }.getOrElse { emptyList() }

    fun sources(app: Context): List<Source> = runCatching {
        val root = JSONObject(app.assets.open("channels.json").bufferedReader().use { it.readText() })
        val items: JSONArray? = root.optJSONArray("sources")
        val sources = mutableListOf<Source>()
        if (items != null) {
            for (i in 0 until items.length()) {
                val s = items.getJSONObject(i)
                sources += Source(
                    id = s.getString("id"),
                    name = s.optString("name", s.getString("id")),
                    prefix = s.optString("prefix", ""),
                )
            }
        }
        sources
    }.getOrElse { emptyList() }

    fun defaultId(app: Context): String? = runCatching {
        JSONObject(app.assets.open("channels.json").bufferedReader().use { it.readText() })
            .optString("default").ifEmpty { null }
    }.getOrNull()
}
