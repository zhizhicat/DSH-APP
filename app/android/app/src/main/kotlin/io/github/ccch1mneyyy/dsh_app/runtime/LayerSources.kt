package io.github.ccch1mneyyy.dsh_app.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException

/**
 * v1.5 三层分源：base(rootfs) / node / engine 每层各配各的下载源。
 *
 * - gh-mirror  预构建层包走 GitHub release 镜像前缀（三层通用，现实现）
 * - node-dist  node 层原生源：官方 tar 直拉（实验：需 B 波装机期组装管线——
 *              官方 tar 布局是 node-vX-linux-arm64/ 自包含树，与层 tar 的
 *              opt/node 布局不同构，不能直接解包；启用前须 App 端布局重映射）
 * - lxc        （B 波）base 层原生源：TUNA/官方 LXC rootfs + 装机期 deb 装配
 *
 * A 波（v3r10）三层都先亮 gh 四镜像；experimental 源不进 UI。
 */
internal object LayerSources {

    data class LayerSource(
        val id: String,
        val name: String,
        val kind: String,            // gh-mirror | node-dist | lxc
        val prefix: String = "",     // gh-mirror: URL 前缀
        val distBase: String = "",   // node-dist: e.g. https://npmmirror.com/mirrors/node
        val probePath: String = "",  // node-dist 探测相对路径（版本前）
        val experimental: Boolean = false,
    )

    val ghMirrors = listOf(
        LayerSource("ghfast", "ghfast.top · 国内加速", "gh-mirror", prefix = "https://ghfast.top/"),
        LayerSource("ghproxy", "gh-proxy.com · 国内加速", "gh-mirror", prefix = "https://gh-proxy.com/"),
        LayerSource("ghproxyorg", "gh-proxy.org · 国内加速", "gh-mirror", prefix = "https://gh-proxy.org/"),
        LayerSource("github", "GitHub 直连", "gh-mirror", prefix = ""),
    )

    /** rootfs：gh 四镜像 + ubuntu-base 原生源（镜像站直拉 rootfs+deb 增量组装） */
    val base: List<LayerSource> = ghMirrors + listOf(
        LayerSource("tuna-cdimage", "清华 TUNA · ubuntu-base", "ubuntu-base",
            distBase = "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases", probePath = ""),
        LayerSource("ubuntu-cdimage", "Ubuntu 官方 cdimage", "ubuntu-base",
            distBase = "https://cdimage.ubuntu.com/ubuntu-base/releases", probePath = ""),
    )

    /** node：gh 四镜像 + 五个 node-dist 原生源（官方 tar 直拉，装机期重映射层布局） */
    val node: List<LayerSource> = ghMirrors + listOf(
        LayerSource("aliyun", "阿里云", "node-dist",
            distBase = "https://mirrors.aliyun.com/nodejs-release", probePath = "SHASUMS256.txt"),
        LayerSource("tencent", "腾讯云", "node-dist",
            distBase = "https://mirrors.cloud.tencent.com/nodejs-release", probePath = "SHASUMS256.txt"),
        LayerSource("huawei", "华为云", "node-dist",
            distBase = "https://mirrors.huaweicloud.com/nodejs", probePath = "SHASUMS256.txt"),
        LayerSource("tuna", "清华 TUNA", "node-dist",
            distBase = "https://mirrors.tuna.tsinghua.edu.cn/nodejs-release", probePath = "SHASUMS256.txt"),
        LayerSource("nodejs", "nodejs.org 官方", "node-dist",
            distBase = "https://nodejs.org/dist", probePath = "SHASUMS256.txt"),
    )

    /** engine：gh 四镜像。适配层大包（含 154 补丁的构建产物）只在我们 release 上有，
     *  npm-registry 装机期组装通道已撤（2026-11-19 拍板：不做碎片化下载，纯净版下线），
     *  上游跟随走「适配层重发」而不是装机期拼装。 */
    val engine: List<LayerSource> = ghMirrors

    fun forLayer(layer: String): List<LayerSource> = when (layer) {
        "base" -> base
        "node" -> node
        "engine" -> engine
        else -> throw IOException("unknown layer \"$layer\"")
    }

    fun find(layer: String, id: String): LayerSource? = forLayer(layer).firstOrNull { it.id == id }

    /** UI 源池：experimental 源不进。 */
    fun toJson(): JSONObject {
        fun arr(list: List<LayerSource>) = JSONArray().apply {
            list.filterNot { it.experimental }.forEach { s ->
                put(JSONObject().apply {
                    put("id", s.id); put("name", s.name); put("kind", s.kind)
                    if (s.prefix.isNotEmpty()) put("prefix", s.prefix)
                    if (s.distBase.isNotEmpty()) put("distBase", s.distBase)
                })
            }
        }
        return JSONObject().put("base", arr(base)).put("node", arr(node)).put("engine", arr(engine))
    }

    /** node-dist 层下载 URL：官方布局 /v<version>/node-v<version>-linux-arm64.tar.xz */
    fun nodeDistUrl(source: LayerSource, nodeVersion: String, asset: String): String =
        "${source.distBase}/v$nodeVersion/$asset"

    /** node-dist 探测 URL（拿一个小文件：SHASUMS256.txt） */
    fun nodeProbeUrl(source: LayerSource, nodeVersion: String): String =
        "${source.distBase}/v$nodeVersion/${source.probePath}"

    /**
     * 从源上拉的 SHASUMS256.txt 解析 asset 的官方 sha256。
     * file 已由调用方下载到本地（走 RuntimeDownloader，无 sha 校验）。
     */
    fun shaFromSums(file: File, asset: String): String {
        val line = file.readText().lineSequence().firstOrNull { it.endsWith("  $asset") }
            ?: throw IOException("$asset not listed in SHASUMS256.txt")
        val sha = line.substringBefore(' ').lowercase()
        if (sha.length != 64) throw IOException("malformed SHASUMS entry for $asset")
        return sha
    }
}
