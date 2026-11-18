package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * ubuntu-base 装机期自举:proot 起 rootfs 的 dpkg,安装 deb 增量包闭包
 * (tzdata / ca-certificates / git 链),再补最小 overlay(resolv.conf / apt 源)。
 *
 * deb 增量包是构建机绝对路径打的 xz tar,先解到缓存再收集 *.deb。
 * proot 调用形态与 DshProcess 同源:libproot.so + PROOT_LOADER,只是 guest
 * 命令换成 dpkg。失败即抛错让安装回滚到错误态,不留半装的 rootfs。
 */
internal object DpkgBootstrap {

    /** apt 源代号按底座版本映射;未知版本回落 noble(24.04)。 */
    private fun aptCodename(baseKey: String): String = when {
        baseKey.startsWith("26.04") -> "resolute"   // Ubuntu 26.04 LTS
        baseKey.startsWith("24.04") -> "noble"      // Ubuntu 24.04 LTS
        else -> "noble"
    }

    fun run(
        context: Context,
        rootfs: File,
        deltaTar: File,
        onLog: (String) -> Unit,
        baseKey: String = "ubuntu-24.04.5",
    ) {
        val native = context.applicationInfo.nativeLibraryDir
        val tmp = File(context.cacheDir, "proot-tmp").apply { mkdirs() }
        val stage = File(context.cacheDir, "dpkg-stage")
        stage.deleteRecursively(); stage.mkdirs()
        onLog("[dsh-app] dpkg bootstrap: unpacking deb delta ${deltaTar.name}")
        TarExtractor(stage) { }.extract(deltaTar.inputStream(), deltaTar.name)

        val debs = stage.walkTopDown().filter { it.isFile && it.name.endsWith(".deb") }.toList()
        if (debs.isEmpty()) throw IOException("deb delta contains no .deb files")

        // python-build-standalone tar(增量包里的非 deb tarball):strip python/ 前缀装到 opt/python,
        // 与构建侧同布局;软链由 engine overlay 提供,此处只摆二进制树 + pip 源配置。
        val pythonTar = stage.walkTopDown().filter {
            it.isFile && !it.name.endsWith(".deb") && (it.name.endsWith(".tar.gz") || it.name.endsWith(".tgz"))
        }.firstOrNull()
        if (pythonTar != null) {
            onLog("[dsh-app] dpkg bootstrap: python bundle ${pythonTar.name}")
            val pyStage = File(context.cacheDir, "python-stage")
            pyStage.deleteRecursively(); pyStage.mkdirs()
            TarExtractor(pyStage) { }.extract(pythonTar.inputStream(), pythonTar.name)
            val src = File(pyStage, "python")
            if (src.isDirectory) {
                val dest = File(rootfs, "opt/python")
                dest.deleteRecursively()
                src.copyRecursively(dest, overwrite = true)
            }
            pyStage.deleteRecursively()
            File(rootfs, "etc/pip.conf").writeText(
                "[global]\nindex-url = https://pypi.tuna.tsinghua.edu.cn/simple\ndisable-pip-version-check = true\n")
        }
        onLog("[dsh-app] dpkg bootstrap: ${debs.size} debs, installing via proot")

        val argv = mutableListOf(
            "$native/libproot.so",
            "-r", rootfs.canonicalPath,
            "-b", "${stage.canonicalPath}:/inst",
            "/usr/bin/env", "-i",
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME=/root", "TERM=xterm",
            "DEBIAN_FRONTEND=noninteractive",
            "/bin/sh", "-c",
            "dpkg -i /inst/*.deb 2>&1; dpkg --configure -a 2>&1; " +
                // 最小 overlay:DNS + apt 源(清华),与构建期 base 层等价
                "echo 'nameserver 223.5.5.5' > /etc/resolv.conf; " +
                "echo 'nameserver 8.8.8.8' >> /etc/resolv.conf; " +
                "printf '%s\\n' 'deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ ${aptCodename(baseKey)} main universe' " +
                "'deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ ${aptCodename(baseKey)}-updates main universe' " +
                "'deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ ${aptCodename(baseKey)}-security main universe' > /etc/apt/sources.list; " +
                "test -x /usr/bin/dpkg && test -f /etc/resolv.conf",
        )
        val proc = ProcessBuilder(argv).directory(context.filesDir).start()
        val out = StringBuilder()
        Thread { proc.inputStream.bufferedReader().forEachLine { out.appendLine(it) } }.start()
        Thread { proc.errorStream.bufferedReader().forEachLine { out.appendLine(it) } }.start()
        val ok = proc.waitFor(10, TimeUnit.MINUTES)
        if (!ok) {
            proc.destroy()
            throw IOException("dpkg bootstrap timed out after 10min")
        }
        val tail = out.toString().lines().takeLast(12).joinToString("\n")
        if (proc.exitValue() != 0) {
            throw IOException("dpkg bootstrap failed (exit ${proc.exitValue()}):\n$tail")
        }
        onLog("[dsh-app] dpkg bootstrap done:\n$tail")
        stage.deleteRecursively()
    }
}
